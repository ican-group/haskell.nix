{ stdenv
, lib
, haskellLib
, runCommand
, writeShellScriptBin
, makeWrapper
, qemu
, qemuSuffix ? (haskellLib.qemuByHostPlatform hostPlatform)
  # Command used to run host-platform ELF binaries on the build platform.
  # Defaults to qemu user-mode emulation; darwin build hosts pass
  # hyper-linux's `hl` instead (qemu user-mode does not exist on macOS).
  # When set, the `qemu` argument is never forced.
, pipeCommand ? "${qemu}/bin/qemu-${qemuSuffix}"
, iserv-proxy
, iserv-proxy-interpreter
, iserv-proxy-interpreter-prof
, gmp
, buildPlatform
, hostPlatform
, symlinkJoin
, ...
}:
let
  qemuIservWrapperScript = enableProfiling:
    let
      interpreter =
        if enableProfiling
          then iserv-proxy-interpreter-prof
          else iserv-proxy-interpreter;
    in
      writeShellScriptBin ("iserv-wrapper" + lib.optionalString enableProfiling "-prof") ''
    #!${stdenv.shell}
    set -euo pipefail
    ISERV_ARGS=''${ISERV_ARGS:-}
    PROXY_ARGS=''${PROXY_ARGS:-}
    # Unset configure flags as configure should have run already
    unset configureFlags
    (>&2 echo "---> Starting iserv-proxy with piped ${interpreter.exeName} (emulator: ${pipeCommand})")
    # GHC must track the proxy PID so cancellation signals reach the proxy.
    exec ${iserv-proxy}/bin/iserv-proxy "$@" --pipe ${pipeCommand} ${interpreter}/bin/${interpreter.exeName} tmp --stdio $ISERV_ARGS
    '';
  qemuIservWrapper = symlinkJoin { name = "iserv-wrapper"; paths = [ (qemuIservWrapperScript false) (qemuIservWrapperScript true) ]; };
  configureFlags = lib.optional (hostPlatform.isAarch32 || hostPlatform.isAndroid) "--disable-split-sections";
  ghcOptions =
    [ "-fexternal-interpreter"
      "-pgmi" "${qemuIservWrapper}/bin/iserv-wrapper"
      "-L${gmp}/lib"
         # Required to work-around https://gitlab.haskell.org/ghc/ghc/issues/15275
    ] ++ lib.optionals hostPlatform.isAarch64 [ "-fPIC" "-optc-fPIC" ]
      # The GHC RTS references dlopen/dlclose/dlsym/dlerror even with
      # -dynamic-system-linker disabled. Link -ldl for android.
      ++ lib.optionals hostPlatform.isAndroid ["-optl-ldl"];

  # Wrapper for running test executables under the emulator
  qemuTestWrapper = writeShellScriptBin "test-wrapper" ''
    set -euo pipefail
    ${pipeCommand} "$@"
  '';

  # Choose the appropriate test wrapper
  testWrapper = [ "${qemuTestWrapper}/bin/test-wrapper" ];

  # v2 builder ghc wrapper — counterpart to the one in
  # `overlays/mingw_w64.nix`.  Cross targets need every GHC
  # invocation to silently get `-fexternal-interpreter
  # -pgmi <wrapper>` so the slice's `cabal v2-build` (which doesn't
  # consume the v1-only `setupBuildFlags`) can still drive iserv
  # via qemu.  Putting these flags into per-package `ghc-options:`
  # in cabal.project would change cabal's UnitId hash and fork the
  # same package's UnitId across slices that need to compose; the
  # wrapper approach keeps `ghc --info` (and therefore the
  # UnitId-relevant compiler identity) unchanged.
  wrapGhc = ghc:
    runCommand "${ghc.name}-with-iserv"
      { nativeBuildInputs = [ makeWrapper ];
        passthru = {
          inherit (ghc) version meta;
          targetPrefix = ghc.targetPrefix or "";
        };
      } ''
        mkdir -p $out/bin
        prefix="${ghc.targetPrefix or ""}"
        # Wrap `ghc` and `ghci` with the iserv ghc-options.
        for prog in ghc ghci ghc-${ghc.version} ghci-${ghc.version}; do
          if [ -x ${ghc}/bin/$prefix$prog ]; then
            makeWrapper \
              ${ghc}/bin/$prefix$prog \
              $out/bin/$prefix$prog \
              --add-flags ${lib.escapeShellArg (lib.concatStringsSep " " ghcOptions)}
          fi
        done
        # Symlink every other bin from the real ghc unchanged so
        # cabal can find ghc-pkg, hsc2hs, runghc, runhaskell,
        # haddock, etc. as it expects.
        for f in ${ghc}/bin/$prefix*; do
          base=$(basename "$f")
          [ -e "$out/bin/$base" ] || ln -s "$f" "$out/bin/$base"
        done
        # Forward $ghc/lib/ and $ghc/share/ so `ghc --print-libdir`
        # (which makeWrapper preserves via getExecutablePath) still
        # finds the boot libs.
        #
        # `if`, not `[ -d ... ] && ...`: this loop is the LAST command in the
        # builder, so with a missing directory the `&&` form left the loop's
        # exit status at 1 and the whole derivation failed -- silently, since a
        # failed test writes nothing.  `set -e` never fired (the test is the
        # left operand of `&&`, which is exempt); the script simply ran off the
        # end with a non-zero status, and the log was empty.
        for d in lib share; do
          if [ -d ${ghc}/$d ]; then ln -s ${ghc}/$d $out/$d; fi
        done
      '';

in { inherit configureFlags ghcOptions testWrapper wrapGhc; }
