# Build the eval-time dummy `ghc` + `ghc-pkg` pair that cabal-install runs
# against during plan-to-nix.  Returns `{ dummy-ghc, dummy-ghc-pkg }`.
#
# `dummy-ghc`'s `--info` output shapes the elaborated install plan (and
# therefore each unit's `pkgHashConfigInputs` and UnitId); it mirrors what real
# haskell.nix cross-GHCs report so plan-nix's recorded UnitIds line up with what
# the slice's `cabal v2-build` computes against the real compiler.  `dummy-ghc`
# is diffed against the real GHC's `--info` by `test/dummy-ghc-info/default.nix`
# (via `(import ./dummy-ghc.nix {...}).dummy-ghc`).
#
# `dummy-ghc-pkg` answers `ghc-pkg dump --global` from a synthesised dump of the
# compiler's pre-existing boot packages (empty for `emptyGlobalPackageDb`
# compilers).  Memoised per (compiler, evalSystem) on the compiler passthru
# (`compiler.<ghc>.dummyGhcPkgs`, overlays/stable-haskell.nix) and also called
# inline from lib/call-cabal-project-to-nix.nix.
{ pkgs, ghc, evalPackages, prebuilt-depends ? [] }:
let
  # The `RTS ways` a stable-haskell compiler reports: read off the compiler
  # itself, which is where overlays/stable-haskell.nix's `fixRtsWays` wrote the
  # very same string into the real `settings` -- `tests.dummy-ghc-info` compares
  # the two byte for byte, so they must come from one place.  The fallback is
  # the pre-`dynamicStage2` value, for any stable-haskell compiler that does not
  # declare one.  See lib/stable-haskell-rts-ways.nix.
  shRtsWays = ghc.rtsWays or (import ./stable-haskell-rts-ways.nix).withProfiling;
  # Is the `ghc` BINARY dynamically linked (`cabal.project.stage2.dynamic`,
  # i.e. the Makefile's DYNAMIC=1)?  A property of the executable, so it is the
  # same answer for the native compiler and for every `-target` wrapper around
  # it -- unlike everything else in this file, it does not vary with the target.
  shGhcDynamic = if (ghc.ghcIsDynamic or false) then "YES" else "NO";
  # Real GHC normalises a few fields in its platform strings
  # (`Target platform`, `target platform string`) away from the
  # nixpkgs `parsed.*` values:
  #
  #   * 32-bit x86 cpu reported as `i386`, not `i686`
  #     (musl32 / aarch32-style 32-bit cross).
  #   * 32-bit ARMv7 cpu reported as `armv7`, not `armv7a`
  #     (armv7a-android-prebuilt / aarch32 cross).
  #   * Windows targets reported as `<cpu>-unknown-mingw32`, not
  #     nixpkgs' `<cpu>-w64-windows` (ucrt64 / mingwW64 cross).
  #
  # Mirror those normalisations here so the dummy and real `--info`
  # outputs match — verified by `tests.dummy-ghc-info` on
  # musl32 (i686), armv7a-android-prebuilt (armv7a), and ucrt64
  # (x86_64-w64-mingw32).
  platformString = p: with p.parsed;
    let
      cpuName =
        if cpu.name == "i686" then "i386"
        else if cpu.name == "armv7a" then "armv7"
        else cpu.name;
      vendorName = if p.isWindows then "unknown" else vendor.name;
      kernelName = if p.isWindows then "mingw32" else kernel.name;
    in
      "${cpuName}-${vendorName}-${kernelName}";
  # The stable-haskell fork brands its `--info` with `Edition` (hardcoded in
  # compiler/GHC/Driver/Session.hs), emitted by every ghc914-sh (native and
  # cross).  Match it so the dummy `--info` equals the real ghc914-sh `--info`
  # (tests.dummy-ghc-info).
  #
  # (`ld supports verbatim namespace` — a per-target linker capability cabal
  # does not consult for elaboration — is handled via the test's ignoredFields
  # rather than reproduced here.)
  #
  # Bound here, carrying its own leading newline, rather than written as an
  # `optionalString` on its own line in the script below: an interpolation that
  # occupies a line still emits that line's whitespace when it yields "", which
  # changes the generated script — and hence every non-stable-haskell
  # compiler's dummy-ghc hash, its dummy-ghc-pkg-dump, and every plan-nix
  # derived from it.  Keeping the newline inside the conditional makes the
  # script byte-identical for compilers that are not the fork.
  editionInfoLine = pkgs.lib.optionalString (ghc.isStableHaskell or false)
    "\n    echo ',(\"Edition\",\"Stable Haskell\")'";
  # A `<pkg>/<pkg>.cabal.in` fallback for the stable-haskell fork, whose boot
  # packages live outside the GHC source tree layout and ship only the generated
  # `.cabal.in`.  (The `compiler/` and `libraries/` `.cabal.in` branches below
  # are NOT gated — they predate the fork and serve every compiler.)
  #
  # Emitted as a whole `elif` branch carrying its own leading newline, and only
  # for the fork.  Written inline it adds 2 lines per boot package (~90 in
  # total) to the generated dump for EVERY compiler: dead code for hadrian GHCs,
  # since an earlier branch always matches first, but it still changes
  # dummy-ghc-pkg-dump's hash and with it every plan-nix that consumes it.
  # Keeping the newline inside the conditional leaves the script byte-identical
  # for compilers that are not the fork.
  dotCabalInBranches = paths:
    pkgs.lib.optionalString (ghc.isStableHaskell or false)
      (pkgs.lib.concatMapStrings
        (p: "\nelif [ -f ${p}.cabal.in ]; then\n  cabal_file=${p}.cabal.in")
        paths);
  dummy-ghc = evalPackages.writeTextFile {
  name = "dummy-" + ghc.name;
  executable = true;
  destination = "/bin/${ghc.targetPrefix}ghc";
  # New versions of cabal pass `-package-env=-`, but dummy-ghc can safely ignore it.
  text = ''
    #!${evalPackages.runtimeShell}
    if [[ "$1" == "-package-env=-" ]]; then
      shift
    fi
    case "$*" in
      --version*)
        echo "The Glorious Glasgow Haskell Compilation System, version ${ghc.version}"
        ;;
      --numeric-version*)
        echo "${ghc.version}"
        ;;
    ${pkgs.lib.optionalString (ghc.targetPrefix == "js-unknown-ghcjs-") ''
      --numeric-ghc-version*)
        echo "${ghc.version}"
        ;;
      --numeric-ghcjs-version*)
        echo "${ghc.version}"
        ;;
    ''}
      --supported-languages*)
        cat ${import ./supported-languages.nix { inherit pkgs evalPackages ghc; }}
        ;;
      --print-global-package-db*)
        echo "$out/dumby-db"
        ;;
      --info*)
        echo '[("target os","${
            if pkgs.stdenv.targetPlatform.isLinux
              then "OSLinux"
            else if pkgs.stdenv.targetPlatform.isDarwin
              then "OSDarwin"
            else if pkgs.stdenv.targetPlatform.isWindows
              then "OSMinGW32"
            else if pkgs.stdenv.targetPlatform.isGhcjs
              then "OSGhcjs"
            else if pkgs.stdenv.targetPlatform.isWasi
              then "OSWasi"
            else throw "Unknown target os ${pkgs.stdenv.targetPlatform.config}"
          }")'
        echo ',("target arch","${
            if pkgs.stdenv.targetPlatform.isx86_64
              then "ArchX86_64"
            else if pkgs.stdenv.targetPlatform.isx86
              then "ArchX86"
            else if pkgs.stdenv.targetPlatform.isRiscV64
              then "ArchRISCV64"
            else if pkgs.stdenv.targetPlatform.isAarch64
              then "ArchAArch64"
            # Real GHC reports `ArchARM <ArmArch> [<ArmISAExt>...] <ArmABI>`
            # for 32-bit ARM targets, with the constructor arguments
            # spelling out the ISA + extensions + float convention.
            # Generic ArchAArch32 (no parameters) is what real GHC emits
            # for other aarch32 cpus we currently don't have a more
            # specific override for.
            #
            # The armv7a value is compiler-family specific, because it is
            # *detected* rather than derived from the triple:
            #
            #   * a configure-built (hadrian / bindist) GHC for
            #     armv7a-android-prebuilt reports
            #     `ArchARM ARMv7 [VFPv3,NEON] SOFTFP`;
            #   * a stable-haskell compiler reports
            #     `ArchARM ARMv7 [VFPv2] SOFT`, its settings coming from
            #     `ghc-toolchain-bin` probing the NDK prebuilt cc, which
            #     is invoked with no `-mfpu=`/`-mfloat-abi=` and so falls
            #     back to the conservative defaults.
            #
            # Both confirmed by CI: mainline ghc9124's
            # armv7a-android-prebuilt `tests.dummy-ghc-info` passes with
            # the SOFTFP string (build 2011050), while ghc914-sh's fails
            # against it (build 2039035, eval 2453).
            #
            # NOTE: `SOFT` vs `SOFTFP` is a real ABI claim -- GHC feeds it
            # to `llc -float-abi=`, and Android's armv7a ABI is softfp.
            # Keeping the dummy equal to the compiler is what this file is
            # for (a divergence forks UnitIds), but the *compiler's* value
            # looks wrong.  Making ghc-toolchain probe with the NDK's
            # flags, so it agrees with hadrian, would be the better fix
            # and would collapse this branch back to one string.
            else if pkgs.stdenv.targetPlatform.parsed.cpu.name == "armv7a"
              then (if (ghc.isStableHaskell or false)
                      then "ArchARM ARMv7 [VFPv2] SOFT"
                      else "ArchARM ARMv7 [VFPv3,NEON] SOFTFP")
            else if pkgs.stdenv.targetPlatform.isAarch32
              then "ArchAArch32"
            else if pkgs.stdenv.targetPlatform.isJavaScript
              then "ArchJavaScript"
            else if pkgs.stdenv.targetPlatform.isWasm
              then "ArchWasm32"
            else throw "Unknown target arch ${pkgs.stdenv.targetPlatform.config}"
        }")'
        echo ',("target platform string","${platformString pkgs.stdenv.targetPlatform}")'
        # Real cross GHC reports `Host platform = buildPlatform`
        # (where ghc itself runs), NOT the cross-target platform.
        # `pkgs.stdenv.hostPlatform` for a cross-pkgs context IS the
        # cross target — which would be wrong here.  Use buildPlatform
        # for both Build and Host so dummy mirrors real GHC; the only
        # cross-relevant field is then `Target platform`.
        echo ',("Build platform","${platformString pkgs.stdenv.buildPlatform}")'
        echo ',("Host platform","${platformString pkgs.stdenv.buildPlatform}")'
        echo ',("Target platform","${platformString pkgs.stdenv.targetPlatform}")'
        # `cross compiling` is YES iff GHC's build platform differs
        # from its target platform.  Real GHC emits this on every
        # `--info`; cabal-install reads it to drive cross-toolchain
        # detection.
        #
        # Two rules, because the two compiler families genuinely answer
        # this differently.
        #
        # A configure-built (hadrian / bindist) GHC keys "cross" off
        # cpu + kernel, NOT the full triple -- a libc switch (e.g.
        # pkgsCross.musl64: gnu -> musl on x86_64-linux) reports
        # `cross compiling: NO` because the cpu and kernel both match
        # the build host.  Comparing full `.config` strings would
        # wrongly mark these as cross.
        #
        # A stable-haskell CROSS compiler always reports YES.  Its
        # target settings come from `ghc-toolchain-bin`, which only ever
        # sees the target triple and so cannot tell the session is
        # cross, and `crossCompiler` in overlays/stable-haskell.nix
        # therefore rewrites the field unconditionally --
        #   sed -i 's|("cross compiling","NO")|("cross compiling","YES")|'
        # -- deliberately: YES is also what makes GHC default TH
        # evaluation to the external interpreter rather than loading
        # target objects in-process.  That rewrite runs for every cross
        # target, so the dummy must say YES for every cross target too,
        # libc-only crosses included.
        #
        # The rules differ on exactly one shape: x86_64-linux ->
        # x86_64-linux-musl (`musl64` and `static`), where cpu and
        # kernel match but the triple does not.  Both of those
        # `tests.dummy-ghc-info` jobs failed on this field in eval 2453
        # (builds 2039304 and 2039470) while musl32, mingwW64,
        # aarch64-multiplatform{,-musl}, wasi32 and native passed; and
        # the mainline ghc9103/ghc9124 musl64 jobs pass with the
        # cpu+kernel rule, which is why that rule has to stay for them.
        echo ',("cross compiling","${
          if (ghc.isStableHaskell or false)
            then (if pkgs.stdenv.buildPlatform.config != pkgs.stdenv.targetPlatform.config
                    then "YES" else "NO")
          else if pkgs.stdenv.buildPlatform.parsed.cpu.name != pkgs.stdenv.targetPlatform.parsed.cpu.name
          || pkgs.stdenv.buildPlatform.parsed.kernel.name != pkgs.stdenv.targetPlatform.parsed.kernel.name
            then "YES" else "NO"}")'${editionInfoLine}
        ${
          # GHC < 9.8 doesn't emit a `Project Unit Id` field in
          # `ghc --info` and registers its boot packages without
          # the `-inplace` suffix (`base-4.18.3.0` rather than
          # `base-4.18.3.0-inplace`).  Skip the field and the
          # suffix below for those versions so cabal computes
          # UnitIds against the dummy that match what it would
          # compute against the real GHC.
          # stable-haskell compilers override this via passthru.projectUnitId:
          # their `ghc` library is registered under the munged version
          # (`ghc-9.14-inplace`), not haskell.nix's full version string.
          if pkgs.lib.versionAtLeast ghc.version "9.8"
            then ''echo ',("Project Unit Id","${ghc.projectUnitId or "ghc-${ghc.version}-inplace"}")' ''
            else ""
        }
        ${
          # stable-ghc-9.14 (semaphore-compat 2) reports the `-jsem` protocol
          # version it speaks; mainline 9.14.1 prints no such field.
          if ghc.isStableHaskell or false
            then ''echo ',("Semaphore version","2")' ''
            else ""
        }
        ${
          # stable-ghc-9.14 `ghc --info` also echoes the per-target settings
          # dials that overlays/stable-haskell.nix `addTargetDials` writes
          # (the same constants for every target).
          if ghc.isStableHaskell or false
            then ''
              echo ',("target is dynamic","YES")'
              echo ',("target ships dynamic libraries","NO")'
              echo ',("target is profiled","NO")'
              echo ',("target ships profiling libraries","NO")'
            ''
            else ""
        }
        ${ let
          # Every stable-haskell (ghc914-sh) compiler — native AND every cross
          # — is the SAME stage-2 `ghc-bin` binary (each cross "compiler" is a
          # thin `-target` wrapper around it), so the `Stage` (2) and the
          # `RTS ways` (`shRtsWays`, written into every one of their `settings`
          # files by overlays/stable-haskell.nix) are identical across all of
          # them; only the settings-derived fields vary with `-target`.
          # Mainline compilers keep their per-target values (isSH = false).
          isSH = ghc.isStableHaskell or false;
        in
          # Capability fields cabal-install reads to decide what
          # configure-args to record in plan.json's per-pkg
          # `configure-args` entries.  Without these, cabal assumes
          # the compiler can't build shared libs / dynamic-too,
          # so it records `--disable-shared` /
          # `--disable-library-for-ghci` — which feeds into the
          # package's UnitId hash.  Mirror real GHC's capabilities
          # so plan-to-nix's recorded ids match what cabal would
          # compute against the actual compiler.
          #
          # The values are conditioned on the *target* platform
          # because cabal reads `ghc --info` to decide things like
          # `--enable-shared` vs `--disable-shared`, and those
          # decisions feed into the package's UnitId hash.
          #
          # Reference outputs (verified by running `ghc --info` on
          # the actual cross GHC derivation in /nix/store):
          #
          #   * x86_64-w64-mingw32 (Windows mingw): no
          #     `Support shared libraries` field at all,
          #     `Support dynamic-too: NO`, `GHC Dynamic: NO`,
          #     RTS ways without any `_dyn` ways, Stage 1.
          #   * ghcjs / wasm: built stage-1 with only `v debug` ways
          #     and no dynamic linking.
          #   * native Linux/Darwin: dynamic everything, Stage 2.
          if pkgs.stdenv.targetPlatform.isGhcjs
             || pkgs.stdenv.targetPlatform.isWasm
          then
            # wasm (wasi32 / wasm32) gained an interpreter and
            # dynamic-RTS-ways support in GHC 9.12+.  Real GHC for
            # 9.12+ wasm reports:
            #   `Tables next to code: NO`
            #   `Have interpreter: YES`, `Use interpreter: YES`
            #   `target RTS linker only supports shared libraries: YES`
            #   `RTS ways: v debug debug_dyn dyn`
            # while earlier wasm builds and all ghcjs builds keep
            # the legacy stage-1-without-interpreter values.
            #
            # `target RTS linker only supports shared libraries` is
            # load-bearing for wasm 9.12+: cabal reads it to decide
            # `--enable-shared` is required.  Lying "NO" causes the
            # plan to record `--disable-shared`, so the slice builds
            # only `.a` files; then TH-evaluating modules like
            # `th-orphans` fail at compile time with
            # `dyld.findSystemLibrary(libHSth-…so): not found` plus
            # `wasm-ld: error: unable to find library -lHS…-ghc<v>`
            # (the link command uses shared-lib naming).  GHC < 9.12
            # omits the field entirely across every target we've
            # surveyed (mingw, aarch64-multiplatform, musl64), so we
            # gate the emission on the version too.
            let newWasm = pkgs.stdenv.targetPlatform.isWasm
                       && builtins.compareVersions ghc.version "9.12" >= 0;
                emitRtsLinkerShared = builtins.compareVersions ghc.version "9.12" >= 0;
            in ''
            echo ',("Support dynamic-too","YES")'
            echo ',("Support reexported-modules","YES")'
            echo ',("Support thinning and renaming package flags","YES")'
            echo ',("Tables next to code","${if newWasm then "NO" else "YES"}")'
            echo ',("Have interpreter","${if newWasm then "YES" else "NO"}")'
            echo ',("Use interpreter","${if newWasm then "YES" else "NO"}")'
            echo ',("Have native code generator","YES")'
            ${if emitRtsLinkerShared
              then ''echo ',("target RTS linker only supports shared libraries","${if newWasm then "YES" else "NO"}")' ''
              else ""}
            echo ',("GHC Dynamic","${if isSH then shGhcDynamic else "NO"}")'
            echo ',("RTS ways","${if isSH then shRtsWays else if newWasm then "v debug debug_dyn dyn" else "v debug"}")'
            echo ',("Stage","${if isSH then "2" else "1"}")'
          ''
          else if pkgs.stdenv.targetPlatform.isWindows
          then ''
            echo ',("Support dynamic-too","NO")'
            echo ',("Support reexported-modules","YES")'
            echo ',("Support thinning and renaming package flags","YES")'
            echo ',("Tables next to code","YES")'
            echo ',("Have interpreter","YES")'
            echo ',("Use interpreter","YES")'
            echo ',("Have native code generator","YES")'
            # Cross-mingw real GHC < 9.12 omits this field entirely;
            # GHC ≥ 9.12 emits "NO".  Match that or the dummy-ghc-info
            # diff test trips.
            ${if builtins.compareVersions ghc.version "9.12" >= 0
              then ''echo ',("target RTS linker only supports shared libraries","NO")' ''
              else ""}
            echo ',("GHC Dynamic","${if isSH then shGhcDynamic else "NO"}")'
            echo ',("RTS ways","${if isSH then shRtsWays else "v thr thr_debug thr_debug_p thr_p debug debug_p p"}")'
            echo ',("Stage","${if isSH then "2" else "1"}")'
          ''
          else if pkgs.stdenv.targetPlatform.isAndroid
               || pkgs.stdenv.targetPlatform.isStatic
               || (pkgs.stdenv.buildPlatform.parsed.cpu.name != pkgs.stdenv.targetPlatform.parsed.cpu.name
                   && pkgs.stdenv.targetPlatform.isLinux)
          then ''
            # Cross-built linux GHC (android / aarch64-multiplatform
            # / etc.) or pkgsStatic: GHC built without dynamic
            # support — RTS ways have no `_dyn` family,
            # `GHC Dynamic: NO`, and no `Support shared libraries`
            # field at all (cabal interprets absence as no-shared).
            # Falling through to the "otherwise" branch makes
            # plan-to-nix record `--enable-shared`, which the
            # slice's real ghc silently flips to `--disable-shared`,
            # forking the UnitId on `pkgHashSharedLib`.
            #
            # Stage = 1 whenever the cpu architecture differs
            # between build and target (real cross-compiler, only
            # bootstrapped one stage); Stage = 2 for same-arch
            # variants like pkgsStatic on x86_64-musl from
            # x86_64-gnu (the GHC is fully bootstrapped because
            # the cpu matches the build host).
            #
            # Reference: `aarch64-unknown-linux-android-ghc --info`,
            # `aarch64-unknown-linux-gnu-ghc --info`, and the
            # pkgsStatic `x86_64-unknown-linux-musl-ghc --info`.
            echo ',("Support dynamic-too","YES")'
            echo ',("Support reexported-modules","YES")'
            echo ',("Support thinning and renaming package flags","YES")'
            echo ',("Tables next to code","YES")'
            echo ',("Have interpreter","YES")'
            echo ',("Use interpreter","YES")'
            echo ',("Have native code generator","YES")'
            # Real cross GHC < 9.12 (android / aarch64-multiplatform /
            # musl64 / etc.) omits this field; ≥ 9.12 emits "NO".
            ${if builtins.compareVersions ghc.version "9.12" >= 0
              then ''echo ',("target RTS linker only supports shared libraries","NO")' ''
              else ""}
            echo ',("GHC Dynamic","${if isSH then shGhcDynamic else "NO"}")'
            echo ',("RTS ways","${if isSH then shRtsWays else "v thr thr_debug thr_debug_p thr_p debug debug_p p"}")'
            echo ',("Stage","${if isSH then "2" else (if pkgs.stdenv.buildPlatform.parsed.cpu.name != pkgs.stdenv.targetPlatform.parsed.cpu.name then "1" else "2")}")'
          ''
          else let
            # stable-haskell (cabalProject-built) native compilers: what the
            # ghc binary and the stage2 rts actually are depends on how stage2
            # was built, so both fields are read off the compiler
            # (`ghcIsDynamic`, `rtsWays`) rather than assumed here -- static
            # binary + four vanilla ways with cabal.project.stage2.static, a
            # dynamic binary + the dyn ways with .dynamic, plus the profiled
            # ways either way (overlays/stable-haskell.nix `bootLibProfiling`).
            # Cabal keys `--enable-shared` vs `--disable-shared` (and hence
            # every pkgHash/UnitId) on these fields, so a value here that
            # disagrees with the real compiler makes plan-nix unit-ids
            # unreproducible in v2 slice builds -- which is why neither is
            # written out twice.
            isStableHaskell = ghc.isStableHaskell or false;
          in ''
            # Native (Linux / Darwin / etc.).  Real GHC 9.14.1 omits
            # `Support shared libraries` on these — cabal infers it
            # from `Support dynamic-too` and `RTS ways` instead — so
            # we omit it here too, keeping the dummy and real `--info`
            # outputs byte-equivalent (verified by
            # `tests.dummy-ghc-info`).
            echo ',("Support dynamic-too","YES")'
            echo ',("Support reexported-modules","YES")'
            echo ',("Support thinning and renaming package flags","YES")'
            echo ',("Tables next to code","YES")'
            echo ',("Have interpreter","YES")'
            echo ',("Use interpreter","YES")'
            echo ',("Have native code generator","YES")'
            # Native real GHC < 9.12 omits this field; ≥ 9.12 emits "NO".
            ${if builtins.compareVersions ghc.version "9.12" >= 0
              then ''echo ',("target RTS linker only supports shared libraries","NO")' ''
              else ""}
            echo ',("GHC Dynamic","${if isStableHaskell then shGhcDynamic else "YES"}")'
            # Real `ghc --info` RTS-ways strings (verified per-version
            # against the actual cross / native GHCs):
            #
            #   * 9.6 / 9.8 (nixpkgs bootstrap native, non-musl):
            #     10-way, weird ordering, no `v`/`p` and no
            #     `_p_dyn` variants.
            #   * 9.10 native, OR any pre-9.12 build that targets
            #     musl (haskell.nix's musl64 ghc): 12-way, includes
            #     `v` and `p` but no `_p_dyn` variants.
            #   * 9.12 / 9.14: full 16-way including `_p_dyn`.
            #
            # The string is compared byte-for-byte, so the order
            # must match verbatim.  Cross GHCs with a different cpu
            # take a different branch above (8-way set without any
            # `_dyn`); this rule is only for native-cpu targets.
            ${if isStableHaskell
              then ''echo ',("RTS ways","${shRtsWays}")' ''
              else if pkgs.lib.versionAtLeast ghc.version "9.12"
              then ''echo ',("RTS ways","v thr thr_debug thr_debug_p thr_debug_p_dyn thr_debug_dyn thr_p thr_p_dyn thr_dyn debug debug_p debug_p_dyn debug_dyn p p_dyn dyn")' ''
              else if pkgs.lib.versionAtLeast ghc.version "9.10"
                   || pkgs.stdenv.targetPlatform.isMusl
              then ''echo ',("RTS ways","v thr thr_debug thr_debug_p thr_debug_dyn thr_p thr_dyn debug debug_p debug_dyn p dyn")' ''
              else ''echo ',("RTS ways","debug thr thr_debug thr_p dyn debug_dyn thr_dyn thr_debug_dyn thr_debug_p debug_p")' ''
            }
            echo ',("Stage","2")'
          ''
        }
        echo ']'
        ;;
      --print-libdir*)
        echo $out/ghc/libdir
        ;;
      *)
        echo "Unknown argument '$*'" >&2
        exit 1
        ;;
      esac
    exit 0
  '';
}
  ;
    # `ghc` is the compiler variant already selected for this eval platform
    # (`evalWith.${evalSystem}`), so its `raw-src` is a plain eval-platform tree.
    ghcSrc = ghc.raw-src or ghc.buildGHC.raw-src;

    # Compilers whose global package db is intentionally EMPTY (the
    # stable-haskell `-target` cross wrappers, see
    # overlays/stable-haskell.nix `crossCompiler`) ship no boot libraries
    # at all: every boot package (rts, base, …) is built from source by the
    # project's own plan.  Their dummy `ghc-pkg dump` must therefore be
    # empty too — synthesising the usual pre-existing package set would
    # make cabal treat the boot packages as installed and none of them
    # would be planned.
    emptyDump = ghc.emptyGlobalPackageDb or false;
    dummy-ghc-pkg-dump = evalPackages.runCommand "dummy-ghc-pkg-dump" {
      buildInputs = prebuilt-depends;
      nativeBuildInputs = [
        # `cabal2json` is Cabal-syntax-json, so it has to be able to parse the
        # boot packages' `.cabal` files.  Stable-haskell boot libs come from the
        # Cabal 3.17 fork, so they get the fork's cabal2json (the
        # `cabal-syntax-json-condtree-3.17` port); every other compiler keeps
        # the shared 3.16 one.  This is the one nix-tools consumer that is NOT
        # reachable through the `nix-tools` project option, so it has to
        # discriminate here.
        (if ghc.isStableHaskell or false
          then evalPackages.haskell-nix.nix-tools-unchecked-sh
          else evalPackages.haskell-nix.nix-tools-unchecked).exes.cabal2json
        evalPackages.jq
      ];
    } (let varname = x: builtins.replaceStrings ["-"] ["_"] x; in ''
          PACKAGE_VERSION=${ghc.version}
          ProjectVersion=${ghc.version}

          # The following logic is from GHC m4/setup_project_version.m4

          # Split PACKAGE_VERSION into (possibly empty) parts
          VERSION_MAJOR=`echo $PACKAGE_VERSION | sed 's/^\([^.]*\)\(\.\{0,1\}\(.*\)\)$/\1'/`
          VERSION_TMP=`echo $PACKAGE_VERSION | sed 's/^\([^.]*\)\(\.\{0,1\}\(.*\)\)$/\3'/`
          VERSION_MINOR=`echo $VERSION_TMP | sed 's/^\([^.]*\)\(\.\{0,1\}\(.*\)\)$/\1'/`
          ProjectPatchLevel=`echo $VERSION_TMP | sed 's/^\([^.]*\)\(\.\{0,1\}\(.*\)\)$/\3'/`

          # Calculate project version as an integer, using 2 digits for minor version
          case $VERSION_MINOR in
            ?) ProjectVersionInt=''${VERSION_MAJOR}0''${VERSION_MINOR} ;;
            ??) ProjectVersionInt=''${VERSION_MAJOR}''${VERSION_MINOR} ;;
            *) echo bad minor version in $PACKAGE_VERSION; exit 1 ;;
          esac
          # AC_SUBST([ProjectVersionInt])

          # The project patchlevel is zero unless stated otherwise
          test -z "$ProjectPatchLevel" && ProjectPatchLevel=0

          # Save split version of ProjectPatchLevel
          ProjectPatchLevel1=`echo $ProjectPatchLevel | sed 's/^\([^.]*\)\(\.\{0,1\}\(.*\)\)$/\1/'`
          ProjectPatchLevel2=`echo $ProjectPatchLevel | sed 's/^\([^.]*\)\(\.\{0,1\}\(.*\)\)$/\3/'`

          # The project patchlevel1/2 is zero unless stated otherwise
          test -z "$ProjectPatchLevel1" && ProjectPatchLevel1=0
          test -z "$ProjectPatchLevel2" && ProjectPatchLevel2=0

          # AC_SUBST([ProjectPatchLevel1])
          # AC_SUBST([ProjectPatchLevel2])

          # Remove dots from the patch level; this allows us to have versions like 6.4.1.20050508
          ProjectPatchLevel=`echo $ProjectPatchLevel | sed 's/\.//'`

          # AC_SUBST([ProjectPatchLevel])

          # The version of the GHC package changes every day, since the
          # patchlevel is the current date.  We don't want to force
          # recompilation of the entire compiler when this happens, so for
          # GHC HEAD we omit the patchlevel from the package version number.
          #
          # The ProjectPatchLevel1 > 20000000 iff GHC HEAD. If it's for a stable
          # release like 7.10.1 or for a release candidate such as 7.10.1.20141224
          # then we don't omit the patchlevel components.

          ProjectVersionMunged="$ProjectVersion"
          if test "$ProjectPatchLevel1" -gt 20000000; then
            ProjectVersionMunged="''${VERSION_MAJOR}.''${VERSION_MINOR}"
          fi
          # AC_SUBST([ProjectVersionMunged])

          # The version used for libraries tightly coupled with GHC (e.g.
          # ghc-internal) which need a major version bump for every minor/patchlevel
          # GHC version.
          # Example: for GHC=9.10.1, ProjectVersionForLib=9.1001
          #
          # Just like with project version munged, we don't want to use the
          # patchlevel version which changes every day, so if using GHC HEAD, the
          # patchlevel = 00.
          case $VERSION_MINOR in
            ?) ProjectVersionForLibUpperHalf=''${VERSION_MAJOR}.0''${VERSION_MINOR} ;;
            ??) ProjectVersionForLibUpperHalf=''${VERSION_MAJOR}.''${VERSION_MINOR} ;;
            *) echo bad minor version in $PACKAGE_VERSION; exit 1 ;;
          esac
          # GHC HEAD uses patch level version > 20000000
          case $ProjectPatchLevel1 in
            ?) ProjectVersionForLib=''${ProjectVersionForLibUpperHalf}0''${ProjectPatchLevel1} ;;
            ??) ProjectVersionForLib=''${ProjectVersionForLibUpperHalf}''${ProjectPatchLevel1} ;;
            *) ProjectVersionForLib=''${ProjectVersionForLibUpperHalf}00
          esac

          PKGS=""
          ${pkgs.lib.concatStrings
            (builtins.map (name: ''
              cabal_file=""
              if [ -f ${ghcSrc}/libraries/${name}/${name}.cabal ]; then
                cabal_file=${ghcSrc}/libraries/${name}/${name}.cabal
              elif [ -f ${ghcSrc}/libraries/Cabal/${name}/${name}.cabal ]; then
                cabal_file=${ghcSrc}/libraries/Cabal/${name}/${name}.cabal
              elif [ -f ${ghcSrc}/libraries/${name}/${name}/${name}.cabal ]; then
                cabal_file=${ghcSrc}/libraries/${name}/${name}/${name}.cabal
              elif [ -f ${ghcSrc}/compiler/${name}.cabal ]; then
                cabal_file=${ghcSrc}/compiler/${name}.cabal
              elif [ -f ${ghcSrc}/compiler/${name}.cabal.in ]; then
                cabal_file=${ghcSrc}/compiler/${name}.cabal.in
              elif [ -f ${ghcSrc}/libraries/${name}/${name}.cabal.in ]; then
                cabal_file=${ghcSrc}/libraries/${name}/${name}.cabal.in
              elif [ -f ${ghcSrc}/utils/haddock/${name}/${name}.cabal ]; then
                cabal_file=${ghcSrc}/utils/haddock/${name}/${name}.cabal
              elif [ -f ${ghcSrc}/${name}/${name}.cabal ]; then
                cabal_file=${ghcSrc}/${name}/${name}.cabal${
                  dotCabalInBranches [ "${ghcSrc}/${name}/${name}" ]}
              fi
              if [[ "$cabal_file" != "" ]]; then
                fixed_cabal_file=$(mktemp)
                cat $cabal_file | sed -e "s/@ProjectVersionMunged@/$ProjectVersionMunged/g" -e "s/@ProjectVersionForLib@/$ProjectVersionForLib/g" -e 's/default: *@[A-Za-z0-9]*@/default: False/g' -e 's/@Suffix@//g' > $fixed_cabal_file
                json_cabal_file=$(mktemp)
                cabal2json $fixed_cabal_file > $json_cabal_file

                exposed_modules="$(jq -r '.components.lib."exposed-modules"//[]|.[]|select(type=="string")' $json_cabal_file)"
                reexported_modules="$(jq -r '.components.lib."reexported-modules"//[]|.[]|select(type=="string")' $json_cabal_file | sed 's/.* as //g')"

                # FIXME This is a bandaid. Rather than doing this, conditionals should be interpreted.
                ${pkgs.lib.optionalString pkgs.stdenv.targetPlatform.isGhcjs ''
                exposed_modules+=" $(jq -r '.components.lib."exposed-modules"//[]|.[]|select(type=="object" and ._if.arch == "javascript")|._then[]' $json_cabal_file)"
                ''}
                ${pkgs.lib.optionalString pkgs.stdenv.targetPlatform.isWindows ''
                exposed_modules+=" $(jq -r '.components.lib."exposed-modules"//[]|.[]|select(type=="object" and ._if.os == "windows")|._then[]' $json_cabal_file)"
                ''}
                ${pkgs.lib.optionalString (!pkgs.stdenv.targetPlatform.isWindows) ''
                exposed_modules+=" $(jq -r '.components.lib."exposed-modules"//[]|.[]|select(type=="object" and ._if.not.os == "windows")|._then[]' $json_cabal_file)"
                ''}

                EXPOSED_MODULES_${varname name}="$(tr '\n' ' ' <<< "$exposed_modules $reexported_modules")"
                deps="$(jq -r '.components.lib."build-depends"//[]|.[]|select(.package)|.package' $json_cabal_file)"
                deps+=" $(jq -r '.components.lib."build-depends"//[]|.[]|select((.if.flag or ._if.not.flag) and ._if.not.flag != "vendor-filepath")._then[]|.package' $json_cabal_file)"
                ''
                # containers-0.8 uses `if impl(ghc) build-depends: template-haskell`
                + ''
                deps+=" $(jq -r '.components.lib."build-depends"//[]|.[]|select(._if.impl == "ghc")|._then[]|.package' $json_cabal_file)"
                ${pkgs.lib.optionalString pkgs.stdenv.targetPlatform.isWindows ''
                deps+=" $(jq -r '.components.lib."build-depends"//[]|.[]|select(._if.os == "windows")|._then[]|.package' $json_cabal_file)"
                ''}
                ${pkgs.lib.optionalString (!pkgs.stdenv.targetPlatform.isWindows) ''
                deps+=" $(jq -r '.components.lib."build-depends"//[]|.[]|select(._if.not.os == "windows")|._then[]|.package' $json_cabal_file)"
                ''
                # Fix problem with `haskeline` using a `terminfo` flag
                # For haskell-nix ghc we can use ghc.enableTerminfo to get the flag setting
                + pkgs.lib.optionalString (name == "haskeline" && !pkgs.stdenv.targetPlatform.isWindows && ghc.enableTerminfo or true) ''
                deps+=" terminfo"
                ''
                # Same for `text` built with the `simdutf` flag: its installed
                # conf depends on system-cxx-std-lib, but the flag conditional
                # in text.cabal is invisible to the extraction above.  Without
                # this edge the solver never marks system-cxx-std-lib
                # pre-existing and the pruned component package DB has a
                # broken installed text.  Compilers whose bundled text links
                # simdutf set passthru.enableTextSimdutf (e.g. ghc914-sh).
                + pkgs.lib.optionalString (name == "text" && ghc.enableTextSimdutf or false) ''
                deps+=" system-cxx-std-lib"
                ''
                # Similar issue for Win32:filepath build-depends (hidden behind `if impl(ghc >= 8.0)`)
                + pkgs.lib.optionalString (name == "Win32" && pkgs.stdenv.targetPlatform.isWindows) ''
                deps+=" filepath"
                ''
                }
                DEPS_${varname name}="$(tr '\n' ' ' <<< "$deps")"
                VER_${varname name}="$(jq -r '.version' $json_cabal_file)"
                PKGS+=" ${name}"
                LAST_PKG="${name}"
              fi
            '') (pkgs.lib.optionals (!emptyDump)
                  (pkgs.lib.filter (n: n != "system-cxx-std-lib") (pkgs.haskell-nix.ghc-pre-existing ghc))))
          }
          ${ # There is no .cabal file for system-cxx-std-lib
            pkgs.lib.optionalString (!emptyDump && builtins.compareVersions ghc.version "9.2" >= 0) (
              let name="system-cxx-std-lib"; in ''
                EXPOSED_MODULES_${varname name}=""
                DEPS_${varname name}=""
                VER_${varname name}="1.0"
                PKGS+=" ${name}"
                LAST_PKG="${name}"
              '')
            # ghcjs packages (before the ghc JS backend). TODO remove this when GHC 8.10 support is dropped
            + pkgs.lib.optionalString (pkgs.stdenv.targetPlatform.isGhcjs && builtins.compareVersions ghc.version "9" < 0) ''
                EXPOSED_MODULES_${varname "ghcjs-prim"}="GHCJS.Prim GHCJS.Prim.Internal GHCJS.Prim.Internal.Build"
                DEPS_${varname "ghcjs-prim"}="base ghc-prim"
                VER_${varname "ghcjs-prim"}="0.1.1.0"
                EXPOSED_MODULES_${varname "ghcjs-th"}="GHCJS.Prim.TH.Eval GHCJS.Prim.TH.Types"
                DEPS_${varname "ghcjs-th"}="base binary bytestring containers ghc-prim ghci template-haskell"
                VER_${varname "ghcjs-th"}="0.1.0.0"
                PKGS+=" ghcjs-prim ghcjs-th"
                LAST_PKG="ghcjs-th"
              ''
          }${
            # Nothing above writes `$out` when the boot-package loop produced no
            # entries, and the loop below only writes it if some prebuilt-depend
            # has a `package.conf.d` — so for `emptyGlobalPackageDb` compilers
            # the derivation would fail with no output at all.  Create it
            # explicitly in exactly that case.
            #
            # Gated on `emptyDump`, and appended to the closing `}` above rather
            # than written on a line of its own: a line that interpolates to ""
            # is still a line, and one extra line here re-hashes
            # dummy-ghc-pkg-dump for EVERY compiler — and with it every plan-nix
            # that consumes it.  The preceding value already ends in a newline,
            # so this lands at the start of its own line when it fires.
            pkgs.lib.optionalString emptyDump "touch $out"}
          for l in "''${pkgsHostTarget[@]}"; do
            if [ -d "$l/package.conf.d" ]; then
              files=("$l/package.conf.d/"*.conf)
              for file in "''${files[@]}"; do
                 cat "$file" >> $out
                 echo '---' >> $out
              done
            fi
          done
          ${
            # GHC ≥ 9.8 registers its pre-existing packages with
            # ids that carry an `-inplace` suffix
            # (`base-4.19.2.0-inplace`).  Two boot packages are
            # exceptions even there:
            #   - `rts`: GHC's runtime, registered as `id: rts-1.0.3`
            #   - `system-cxx-std-lib`: virtual placeholder for the
            #     host C++ stdlib, registered as
            #     `id: system-cxx-std-lib-1.0`
            # GHC < 9.8 registers everything with just
            # `<name>-<version>`, no `-inplace` suffix at all.
            # Mirror those real ids in the dummy `ghc-pkg dump` —
            # both as the package's own id and as the dep id used
            # by other packages — so the unit-id cabal computes
            # against the dummy matches what it computes against
            # the real GHC.
            ""
          }suffix() {
            ${if ghc.isStableHaskell or false then ''
              # stable-haskell compilers: the stage2 boot-lib slices are
              # built in local-`packages:` mode (v2LocalPackageSlices,
              # overlays/stable-haskell.nix), and the fork elaborates
              # local units to plain `<name>-<version>` ids — no
              # `-inplace` suffix for ANY package.
              echo ""
            '' else if pkgs.lib.versionAtLeast ghc.version "9.8" then ''
              case "$1" in
                rts|system-cxx-std-lib) echo "" ;;
                *) echo "-inplace" ;;
              esac
            '' else ''
              echo ""
            ''}
          }
          for pkg in $PKGS; do
            varname="$(echo $pkg | tr "-" "_")"
            ver="VER_$varname"
            exposed_mods="EXPOSED_MODULES_$varname"
            deps="DEPS_$varname"
            echo "name: $pkg" >> $out
            echo "version: ''${!ver}" >> $out
            echo "id: $pkg-''${!ver}$(suffix $pkg)" >> $out
            echo "exposed-modules: ''${!exposed_mods}" >> $out
            echo "depends:" >> $out
            for dep in ''${!deps}; do
              ver_dep="VER_$(echo $dep | tr "-" "_")"
              if [[ "''${!ver_dep}" != "" ]]; then
                echo "  $dep-''${!ver_dep}$(suffix $dep)" >> $out
              fi
            done
            if [[ "$pkg" != "$LAST_PKG" ]]; then
              echo '---' >> $out
            fi
          done
        '');
  # Dummy `ghc-pkg` that uses the captured output
  dummy-ghc-pkg = evalPackages.writeTextFile {
    name = "dummy-pkg-" + ghc.name;
    executable = true;
    destination = "/bin/${ghc.targetPrefix}ghc-pkg";
    text = ''
      #!${evalPackages.runtimeShell}
      case "$*" in
        --version)
          echo "GHC package manager version ${ghc.version}"
          ;;
      ${pkgs.lib.optionalString (ghc.targetPrefix == "js-unknown-ghcjs-") ''
        --numeric-ghcjs-version)
          echo "${ghc.version}"
          ;;
      ''}
        'dump --global -v0')
          cat ${dummy-ghc-pkg-dump}
          ;;
        *)
          echo "Unknown argument '$*'. " >&2
          echo "Additional ghc-pkg-options are not currently supported." >&2
          echo "See https://github.com/input-output-hk/haskell.nix/pull/658" >&2
          exit 1
          ;;
        esac
      exit 0
    '';
  };
in { inherit dummy-ghc dummy-ghc-pkg; }
