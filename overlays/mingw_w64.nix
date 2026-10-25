# Cross compilation logic.
# Returns override fields for use with nix-tools.
{ lib
, runCommand
, writeShellScriptBin
, makeWrapper
, wine
, mingw_w64_pthreads
, iserv-proxy
, iserv-proxy-interpreter
, iserv-proxy-interpreter-prof
, gmp
, libffi
, hostPlatform
, symlinkJoin
}:
let

  configureFlags = ["--disable-split-sections"];

  wineIservWrapperScript = enableProfiling:
    let
      interpreter =
        if enableProfiling
          then iserv-proxy-interpreter-prof
          else iserv-proxy-interpreter;
      no-load-call = lib.optionalString (interpreter.exeName != "remote-iserv.exe") "--no-load-call";
    in
      writeShellScriptBin ("iserv-wrapper" + lib.optionalString enableProfiling "-prof") ''
        set -euo pipefail
        ISERV_ARGS=''${ISERV_ARGS:-}
        PROXY_ARGS=''${PROXY_ARGS:-}
        # unset the configureFlags.
        # configure should have run already
        # without restting it, wine might fail
        # due to a too large environment.
        unset configureFlags
        unset configurePhase
        WINEPREFIX=''${WINEPREFIX:-$(mktemp -d)}
        REMOTE_ISERV=''${REMOTE_ISERV:-$(mktemp -d)}
        (>&2 echo "---> Starting iserv-proxy with piped ${interpreter.exeName} via wine")
        REMOTE_ISERV=$(mktemp -d)
        ln -s ${interpreter}/bin/* $REMOTE_ISERV
        # See coment in comp-builder.nix for where this comes from and why it's here
        # TODO use `LINK_DLL_FOLDERS` here once it is in all the nixpkgs we want to support.
        for p in $pkgsHostTargetAsString; do
          find "$p" -iname '*.dll' -exec ln -sf {} $REMOTE_ISERV \;
          find "$p" -iname '*.dll.a' -exec ln -sf {} $REMOTE_ISERV \;
        done
        # Some DLLs have a `lib` prefix but we attempt to load them without the prefix.
        # This was a problem for `double-conversion` package when used in TH code.
        # Creating links from the `X.dll` to `libX.dll` works around this issue.
        (
        cd $REMOTE_ISERV
        for l in lib*.dll; do
          ln -s "$l" "''${l#lib}"
        done
        )
        # Not sure why this `unset` helps.  It might avoids some kind of overflow issue.  We see `wine` fail to start when building `cardano-wallet-cli` test `unit`.
        unset pkgsHostTargetAsString
        unset LINK_DLL_FOLDERS
        WINEDLLOVERRIDES="winemac.drv=d" WINEDEBUG=warn-all,fixme-all,-menubuilder,-mscoree,-ole,-secur32,-winediag WINEPREFIX=$TMP \
          ${iserv-proxy}/bin/iserv-proxy $@ --pipe ${lib.getExe wine} $REMOTE_ISERV/${interpreter.exeName} tmp --stdio ${no-load-call} $ISERV_ARGS
      '';

  wineIservWrapper = symlinkJoin { name = "iserv-wrapper"; paths = [ (wineIservWrapperScript false) (wineIservWrapperScript true) ]; };

  ################################################################################
  # Build logic (TH support via remote iserv via wine)
  #
  ghcOptions = [
    "-fexternal-interpreter"
    "-pgmi" "${wineIservWrapper}/bin/iserv-wrapper"
    # TODO: this should be automatically injected based on the extraLibrary.
    "-L${mingw_w64_pthreads}/lib"
    "-L${mingw_w64_pthreads}/bin"
    "-L${gmp}/lib"
    ];

  ################################################################################
  # Test logic via wine
  #
  wineTestWrapper = writeShellScriptBin "test-wrapper" ''
    set -euo pipefail
    export WINEDLLOVERRIDES="winemac.drv=d"
    export WINEDEBUG=warn-all,fixme-all,-menubuilder,-mscoree,-ole,-secur32,-winediag
    export LC_ALL=en_US.UTF-8
    export WINEPREFIX=''${WINEPREFIX:-$(mktemp -d)}
    Path="''${Path:-}"
    unset configureFlags
    unset configurePhase
    unset LINK_DLL_FOLDERS
    for path in ''${nativeBuildInputs:-}; do
      if [ -d "$path/bin" ]; then
        Path="$Path;$(${wine}/bin/winepath -w $path/bin)";
      fi
    done
    export Path
    ${lib.getExe wine} $@
  '';
  testWrapper = ["${wineTestWrapper}/bin/test-wrapper"];

  ################################################################################
  # v2 builder ghc wrapper.
  #
  # The v2 cabal-slice builder runs `cabal v2-build` inside each
  # slice, so it can't put `-fexternal-interpreter -pgmi <wrapper>`
  # into the per-package `ghc-options:` block — that would change
  # cabal's UnitId hash and fork the same package's UnitId across
  # slices that need to compose.
  #
  # Instead, wrap ghc itself with `--add-flags` so every invocation
  # silently prepends the iserv-related options.  Cabal still sees
  # the unwrapped compiler-id (via `ghc --info`), so the UnitId
  # hash inputs are unchanged.  Other binaries (`ghc-pkg`,
  # `hsc2hs`, `runghc`, ...) are symlinked through unchanged so
  # cabal can still invoke them.
  #
  # Exposed as a function so callers can hand in the cross ghc
  # they have on hand (avoids `templateHaskell` having to look up
  # a ghc by `compiler-nix-name`).
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

  # Host-platform runtime DLLs that `iserv-proxy-interpreter.exe`
  # is linked against and must be loadable when wine starts it.
  # The wineIservWrapper symlinks every `*.dll` it can find under
  # `pkgsHostTargetAsString` into REMOTE_ISERV; surfacing these
  # explicitly via the v2 slice's buildInputs makes them appear in
  # `pkgsHostTarget` so the wrapper can pick up `libmcfgthread-2.dll`,
  # `libgmp-10.dll`, `libffi-8.dll`, etc.  Mirrors the `-L<...>/lib`
  # entries v1 already passes through `ghcOptions`.
  iservRuntimeLibs = [ mingw_w64_pthreads gmp libffi ];

in { inherit testWrapper ghcOptions configureFlags wrapGhc iservRuntimeLibs; }
