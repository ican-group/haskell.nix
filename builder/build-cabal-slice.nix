# Proof-of-concept builder for a cabal-store slice.
#
# Runs `cabal v2-build` in an isolated, pre-populated store and captures
# the store entries that this invocation produced.  Compose multiple
# slices by passing them as `depSlices` to a downstream call.
#
# Caller writes its own cabal.project and stages its own sources in the
# `preBuild` hook, which runs inside the build dir.  By the end of
# `preBuild`, the working directory must be the project root (a directory
# containing `cabal.project`).
#
# Output layout:
#   $out/store/ghc-<ver>[-inplace]/<unit-id>/        -- newly installed unit
#   $out/store/ghc-<ver>[-inplace]/package.db/<unit-id>.conf
#   (or, with the stable-haskell cabal fork's staged store layout,
#   $out/store/host/<platform>/package.conf.d/<unit-id>.conf — see
#   the "Staged store layout" comment in buildPhase)
#   $out/plan.json                                   -- recorded slice plan (lifted from cache)
#
# Note: `dist-newstyle/` is staged into `$out` during the build
# so `comp-v2-builder.nix`'s test/bench install step can grab the
# unpinged binary, but is trimmed to just `plan.json` at end of
# installPhase (see `trimDistNewstyle`) — downstream consumers
# never need the source-tarball / build-tree bulk.
#
# Composition: each dep's $out/store/... is copied into the downstream
# slice's starting store.  Only units NOT already present in that
# starting store are emitted to the downstream's $out/store/, which
# keeps each slice's hash sensitive only to its own inputs.
#
# POC limitations:
#   - No cross-compilation.
#   - No haddock, no test suites.
#   - No per-component selection within a local package beyond whatever
#     `target` resolves to.
{ stdenv, lib, ghc, cabal-install, pkgs, pkgsBuildBuild, buildPackages, haskellLib, makeGhcShim }@outerArgs:

let outerGhc = ghc; in

{ pname                       # `<pkg>-<ctype>-<cname>` (or
                              # with a `-doc` suffix for haddock
                              # slices).  Combined with `version`
                              # to give the derivation name; on
                              # cross, stdenv inserts the host
                              # platform's config between them so
                              # the resulting drv name matches v1's
                              # `<pkg>-<ctype>-<cname>-<crossSuffix>-<version>`
                              # convention.
, version                     # The package's `pkgVersion`, used
                              # directly as the derivation `version`
                              # attribute.
, hardeningDisable ? []       # Per-slice stdenv `hardeningDisable`
                              # list — strips the named hardening
                              # flags from `NIX_HARDENING_ENABLE`.
                              # Forwarded from the slice's
                              # `component.hardeningDisable` module
                              # option by `comp-v2-builder.nix`.
, depSlices ? []
, localRepo ? null           # derivation with <pkg>-<ver>.tar.gz files
, v2Fragment ? null          # per-package build-time-composition fragment
                             # (see comp-v2-builder.nix `v2Fragment`).  When
                             # set, the installPhase writes this package's own
                             # repo entry + cabal.project blocks + constraint +
                             # sublib seeds + lib-dep pointer into `$out`, so a
                             # downstream slice can compose the closure at build
                             # time without walking deps in Nix.  STEP 1:
                             # emitted but not yet consumed.
, buildToolSourceFrags ? []  # list of `{ pkgName; pkgVersion; tarball;
                             # cabalFile; }` source-only frags (two-stage
                             # cross): a build-tool's SOURCE staged into the
                             # slicing repo so the slice's own cabal can
                             # build it BUILD-stage, without a drv edge to
                             # the tool's (cyclic) built slice.  See
                             # comp-v2-builder.nix `buildToolSourceFrags`.
, metadataSourceFrags ? []   # same `{ pkgName; pkgVersion; tarball; cabalFile; }`
                             # shape: sources for SOLVER-ONLY goals — deps the
                             # package's sibling components need for cabal's
                             # package-granularity solve but the target
                             # component never builds or links.  Index
                             # candidates only: no store unit, no constraint,
                             # no sysLibs.  See comp-v2-builder.nix
                             # `metadataSourceFrags`.
, preBuild                   # stage sources, write cabal.project, cd into project dir
, target ? "all"
, passthru ? {}              # extra attrs to attach to the derivation
, extraBuildInputs ? []      # e.g. component.libs / frameworks — things ld needs at link time
, extraNativeBuildInputs ? [] # e.g. build-tools — tools on PATH at build time
, propagated ? []            # things to put in `propagatedBuildInputs`
                             # so downstream slices (using this slice as a
                             # buildInput) inherit them automatically via
                             # stdenv's propagation chain.
, ghc ? outerGhc             # caller may override (e.g. swap in a wrapped
                             # ghc for cross-TH); defaults to the outer `ghc`.
, buildToolBinOverlays ? []  # list of `{ name; buildSlice; }` entries.
                             # After composing the starting cabal-store,
                             # replace `<storeDir>/<ghc>/<exe-unit>/bin/<name>`
                             # with the build-platform binary from
                             # `${buildSlice}/bin/${name}`.  cabal v2-build
                             # prepends each build-tool unit's `bin/` to
                             # PATH before invoking ghc — if the composed
                             # unit is the cross-target one (which it is
                             # on cross, so cabal recognises its unit-id
                             # from plan-nix), ghc's `-pgmF` preprocessor
                             # lookup picks the host-arch binary and fails
                             # at `posix_spawnp` with "Exec format error".
                             # Overlaying the build-platform binary keeps
                             # the cross-target unit-id (so cabal's solver
                             # is happy) but lets the executable actually
                             # run on the build machine.
, twoStage ? false           # stable-haskell two-stage (cross) plan:
                             # pass `--with-build-compiler` /
                             # `--with-build-hc-pkg` (the compiler's
                             # buildGHC) to every cabal invocation so
                             # the slice re-plans with the same
                             # build/host stage split the project plan
                             # was made with.  Without it cabal
                             # defaults the build compiler to the host
                             # path — the TARGET wrapper — and plans
                             # build-stage goals for the target.
, expectedPackage ? null     # if non-null, the only package name
                             # cabal's dry-run plan is allowed to
                             # build.  Any other package means cabal
                             # couldn't reuse a unit we composed into
                             # the starting store (typically a
                             # UnitId-hash input mismatch).
, expectedUnitId ? null      # if non-null, the unit-id cabal must
                             # actually produce inside this slice's
                             # `$out/store/...`.  Sourced from the
                             # project's plan-nix.json (the canonical
                             # plan).  After the build's installPhase
                             # captures unit-ids into
                             # `$buildRoot/captured-unit-ids`, the
                             # captured set must equal `[expectedUnitId]`
                             # exactly: anything missing or extra is a
                             # fail.  Sibling unit-ids of the same
                             # package (e.g. cabal accidentally
                             # rebuilding the lib alongside an
                             # exe-only slice) count as extras here —
                             # the upstream lib slice is what
                             # downstream consumers compose, so a
                             # second copy with a different unit-id
                             # would silently fork dep hashes.
, solverIncludesGlobalDb ? false
                             # keep the compiler's real global package db
                             # in the slice solver's installed index
                             # alongside the composed store units (see
                             # the merged-snapshot block in the solver-
                             # visibility section).  Set by
                             # comp-v2-builder for consumer-style slices
                             # (any slice whose component has
                             # `pre-existing` deps, or any slice of a
                             # project without `v2LocalPackageSlices`).
, allowedSiblingUnitPrefix ? null
                             # if non-null (local-`packages:` mode
                             # slices, see comp-v2-builder.nix
                             # `isLocalPackageSlice`), the target
                             # package's `<name>-<version>`: captured
                             # units `<prefix>` / `<prefix>-<comp>` are
                             # tolerated alongside `expectedUnitId`.
                             # cabal never satisfies an INTRA-package
                             # dep from an installed unit, so a local
                             # target's required sibling components
                             # (rts's way sublibs depend on lib:rts)
                             # are necessarily built in-slice — under
                             # the fork's deterministic local ids they
                             # can't fork dep hashes.
, dryRunOnly ? false         # if true, run only `cabal v2-build
                             # --dry-run` (no actual build), skip the
                             # unit-id check, and always succeed.
                             # Used by the `.checkAgainstPlan`
                             # diagnostic drv attached to each slice.
, planNixJsonFile ? null     # /nix/store path of the project's
                             # plan-nix.json (full `install-plan`
                             # list).  When set together with
                             # `dryRunOnly`, the install phase
                             # iterates every entry in the slice's
                             # `dist-newstyle/cache/plan.json`,
                             # finds the matching entry in plan-nix
                             # (by id, otherwise by pkg-name +
                             # component) and emits a `jq -S | diff`
                             # of the two with full file context.
                             # NOT a build-time dep of the slice
                             # itself — only the sibling
                             # `checkAgainstPlan` drv passes it.
, doHaddock ? false          # if true, also run `cabal v2-haddock`
                             # after the build and copy the resulting
                             # html tree to `$out/share/doc/<pkg>/html`.
                             # Used by `comp-v2-builder.nix`'s
                             # sibling `docSlice` derivation to
                             # generate haddock without forking the
                             # main library slice's UnitId.  The
                             # main `cabal v2-build` is still run so
                             # the slice's `$out/store/...` is
                             # populated and downstream consumers
                             # (testers / IDE tools) can use the doc
                             # slice as a drop-in for the lib slice
                             # when they want both bytes and docs.
, withProgFlags ? ""         # extra `--with-PROG=PATH` flags
                             # appended to the `cabal v2-build`
                             # command (wrapped in
                             # `--configure-option=` so cabal threads
                             # them through to per-package Setup
                             # configure — `cabal v2-build` itself
                             # rejects arbitrary `--with-PROG`).
                             # Used by `comp-v2-builder.nix` on cross
                             # to point cabal at the build-platform
                             # exe of each transitive build-tool;
                             # makes the build-tool's cabal-built
                             # unit-id stable across slices in the
                             # same project (every slice passes the
                             # same flags so the uid hash matches).
, allowedBuildToolPackages ? []
                             # Package names whose appearance in
                             # cabal's plan / captured-unit set is
                             # accepted in addition to
                             # `expectedPackage`.  Used on cross:
                             # cabal's solver always plans every
                             # transitive `build-tool-depends:` and
                             # may also build it, so the slice
                             # legitimately captures those units
                             # alongside the target.  Any captured
                             # pkg-name outside `expectedPackage ∪
                             # allowedBuildToolPackages` is still a
                             # fail.
, confLibraryDirs ? []       # Extra paths to append to each
                             # captured unit's `.conf` library-dirs
                             # fields, AFTER cabal's `Setup register`
                             # has run.  Used to point downstream
                             # consumers' GHC runtime linker (the
                             # one that loads packages for TH eval
                             # under `-fexternal-interpreter`) at
                             # the `extra-libraries:` entries' real
                             # foreign-lib locations (openssl/libsodium/
                             # ...).  Post-register injection is the
                             # only place we can do this without
                             # forking the slice's unit-id from
                             # plan-nix — passing `--extra-lib-dirs`
                             # at configure time would land in
                             # `pkgHashExtraLibDirs` and diverge.
                             # Downstream consumers' unit-ids aren't
                             # affected either: their config hash
                             # records each dep's unit-id, not the
                             # dep's `.conf` content.
}:

let
  stageCabalFile = import ./stage-cabal-file.nix;
  # Cross-aware program names. nixpkgs' cross GHCs prefix every
  # binary with `${ghc.targetPrefix}` (e.g. `javascript-unknown-ghcjs-ghc-pkg`)
  # and don't ship the unprefixed `ghc-pkg`, so plain `ghc-pkg` on
  # PATH only exists for native builds.  Use the prefixed name
  # uniformly.
  targetPrefix = ghc.targetPrefix or "";
  ghcBin       = "${targetPrefix}ghc";
  ghcPkgBin    = "${targetPrefix}ghc-pkg";

  # Extra `--with-PROG` flags to pass to cabal so it picks up the
  # cross compiler's tools instead of looking for unprefixed names.
  # GHC-related tools key off `ghc.targetPrefix`; the C toolchain
  # (gcc / ld / ar / strip) keys off `stdenv.cc.bintools.targetPrefix`,
  # which can differ from `ghc.targetPrefix` (notably for ghcjs,
  # where ghc is `javascript-unknown-ghcjs-` but the C toolchain
  # is emscripten with no prefix).
  ccPrefix = if stdenv.hasCC or (stdenv.cc != null)
             then stdenv.cc.targetPrefix else "";
  binPrefix = if stdenv.hasCC or (stdenv.cc != null)
              then stdenv.cc.bintools.targetPrefix else "";

  # nixpkgs' `pkgsStatic` stdenv adapter (`makeStaticBinaries` in
  # `pkgs/stdenv/adapters.nix`) appends `-static` to the UNSALTED
  # `NIX_CFLAGS_LINK` of every derivation it builds.  A cc-wrapper only reads
  # the salted `NIX_CFLAGS_LINK_<targetPlatform.config>`, but `add-flags.sh`
  # folds the unsalted variable into it for every role the wrapper is
  # registered under -- and in a `pkgsStatic` slice BOTH wrappers are
  # registered at host role:
  #
  #   NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_musl=1   (target cc)
  #   NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu=1    (build cc)
  #
  # so `-static` lands on the BUILD-platform gcc as well.  That is harmless
  # while every build-platform tool comes from a separate (non-static)
  # derivation, but the stable-haskell two-stage plan links real
  # build-platform executables -- `alex`, `happy`, `deriveConstants`,
  # `genprimopcode` -- inside this slice with the build-platform gcc, and
  # nixpkgs' glibc ships no `libc.a` in its default output:
  #
  #   ld.bfd: cannot find -lc: No such file or directory
  #   ld.bfd: have you installed the static version of the c library ?
  #
  # Move the flag from the unsalted variable to the host-salted one (done in
  # the buildPhase, because the adapter appends via `overrideAttrs` and would
  # win over anything set in the derivation's `env`).  The target cc still
  # links `-static`; the build-platform cc no longer does.
  staticHostSalt = lib.replaceStrings [ "-" "." ] [ "_" "_" ]
    stdenv.hostPlatform.config;

  # On cross, `cabalPkgConfigWrapper` is named
  # `${targetPrefix}pkg-config` (e.g. `x86_64-w64-mingw32-pkg-config`).
  # Cabal calls plain `pkg-config` by default, so for cross we have
  # to point it at the prefixed binary via `--with-pkg-config=`.
  # Mirrors comp-builder.nix:345.
  pkgConfigPrefix = buildPackages.cabalPkgConfigWrapper.targetPrefix;
  # Only emit cross-aware overrides; for native, cabal finds
  # everything on PATH itself.  Avoiding `--with-PROG=` flags on
  # native is also important for UnitId stability — every entry
  # in `--with-PROG=` enters cabal's `pkgHashProgramArgs`, so
  # passing them in the slice build but not in the user's later
  # `cabal v2-build` invocation forks the UnitId and forces a
  # rebuild downstream.
  # `cabal v2-build` only accepts `--with-compiler=` — it has no
  # per-tool `--with-ghc-pkg=` flag and instead does a "near
  # compiler" lookup expecting an unprefixed `ghc-pkg` in the same
  # directory.  Cross GHCs ship only `<prefix>ghc-pkg`, so we build a
  # tiny symlink farm that exposes unprefixed names alongside the
  # prefixed ones and point `--with-compiler=` at it.
  # Two-pass: link every source file under its own name first, then
  # synthesise unprefixed aliases ONLY for prefixed names that have
  # no real unprefixed sibling in the source bin/.  GHC 9.14.1's
  # android cross ships both `<prefix>deriveConstants` and a real
  # `deriveConstants` (for build-host use); the previous single-pass
  # loop hit the prefixed name first (alphabetical glob), created an
  # alias `$out/bin/deriveConstants -> <prefix>deriveConstants`, then
  # crashed on the real `deriveConstants`'s raw `ln -s` with "File
  # exists".
  # When cabal v2-build instantiates a backpack signature on ghcjs,
  # GHC's JS backend may not emit a `.o` for the signature module
  # (the signature is filled by an external implementation unit).
  # Cabal then asks `emar` to archive both `Module.o` and `Consumer.o`,
  # and `llvm-ar` aborts because `Module.o` is absent.  This wrapper
  # filters out missing `.o` entries (both inline argv and in
  # response files) before delegating to the real `emar`.  Pass-through
  # when nothing is missing.
  #
  # Cabal's `--with-ar=` flag would have been the natural lever, but
  # cabal v2-build's internal "Building library" step reads
  # `ar command` from GHC's `settings` file rather than honouring
  # `--with-ar=`.  So instead we materialise a writable settings file
  # in the shim and `sed`-swap the `ar command` entry (matching the
  # approach v1 takes in `comp-builder.nix`).
  ghcjsArWrapper = pkgsBuildBuild.writeShellScript "ghcjs-ar-wrapper" ''
    REAL_AR=${pkgsBuildBuild.emscripten}/bin/emar
    args=()
    for arg in "$@"; do
      if [[ "$arg" == @* ]]; then
        rspfile="''${arg#@}"
        newrsp="''${rspfile}.filtered"
        while IFS= read -r line || [ -n "$line" ]; do
          if [[ "$line" == *.o ]] && [[ ! -e "$line" ]]; then
            continue
          fi
          echo "$line"
        done < "$rspfile" > "$newrsp"
        args+=("@$newrsp")
      elif [[ "$arg" == *.o ]] && [[ ! -e "$arg" ]]; then
        continue
      else
        args+=("$arg")
      fi
    done
    # `--format=gnu`: emar is llvm-ar, whose DEFAULT format on a macOS build
    # host is darwin — member data 8-aligned with '\n' padding that is
    # COUNTED IN the member size field.  Mach-O readers tolerate the trailing
    # pad, but wasm ones don't: a cbits `.o` (e.g. time's HsTime.o) archived
    # that way reads back as <valid wasm> + pad, and every consumer that
    # parses it to entry end — `wasm-ld` at the TH interpreter / final link,
    # `llvm-nm` — fails with "section too large".  GNU format records exact
    # member sizes, matching what the JS linker's archive walk expects.
    exec "$REAL_AR" --format=gnu "''${args[@]}"
  '';

  ghcShim = makeGhcShim {
    inherit ghc ghcjsArWrapper;
    # iserv-dyn dlopens our haskell `.so` deps at TH eval time; on
    # native-musl those transitively pull in `libstdc++.so` (e.g. via
    # `double-conversion`).  Musl's `libstdc++.so` has DT_RUNPATH
    # pointing only at musl's libc dir, not at the gcc lib dir where
    # `libgcc_s.so.1` lives — and musl's dyld only consults the
    # immediate library's RUNPATH, so the lookup fails.  Have the
    # ghc shim prefix `LD_LIBRARY_PATH` with the musl-gcc libs dir
    # for ghc and its children (iserv-dyn) only.  v1 sets the env
    # globally (`comp-builder.nix:507`); doing it derivation-wide
    # breaks glibc `git` for `source-repository-package` resolution.
    extraLibraryPaths = lib.optional
      haskellLib.isNativeMusl
      "${buildPackages.gcc-unwrapped.lib}/${stdenv.hostPlatform.config}/lib";
  };

  # Two-stage (stable-haskell -target cross) plan: thread the build
  # compiler through to cabal.  The real build compiler here vs the
  # dummy pair at plan time is fine — compiler PATHS don't enter
  # cabal's unit hashes (only the probed compiler id / platform do,
  # and the dummies report the same values as the real compilers).
  # `ghc` may be a TH-wrapping of the project compiler (wrapGhc) whose
  # passthru doesn't carry buildGHC — fall back to the unwrapped outer
  # compiler.
  twoStageBuildGhc = ghc.buildGHC or outerGhc.buildGHC;
  # The BUILD compiler must not inherit the HOST platform's C flags.
  #
  # This nixpkgs' cc-wrapper suffixes its env vars by dependency ROLE, not by
  # platform salt -- a cross slice's env has no `NIX_CFLAGS_COMPILE_<platform>`
  # at all, only `NIX_CFLAGS_COMPILE` (host role) and `..._FOR_BUILD`.  So the
  # plain `NIX_CFLAGS_COMPILE` carries `-isystem` for every HOST C dep, and the
  # build compiler's own baked-in cc-wrapper -- built as a host compiler in its
  # own context, and a different store path from the slice stdenv's cc (see
  # `setupNeedsCxxRpath` below for the mirror-image bug) -- reads that very
  # variable.  Every BUILD-stage C compile in a cross slice therefore picks up
  # the host include path.
  #
  # `-isystem` is searched before the default system directories, so on a
  # windows cross mingw's `pthread.h` shadows glibc's the moment GHC compiles
  # its link stub -- which includes the NATIVE `Rts.h` -> `rts/OSThreads.h` ->
  # `<pthread.h>` -- and the build dies on a header that mingw's pthread.h
  # itself needs but the native sysroot has no reason to carry:
  #
  #   mingw_w64-pthreads/include/pthread.h:66:10:
  #     fatal error: process.h: No such file or directory
  #
  # -- while building the build-stage `hsc2hs` of the `Win32` slice, which
  # every mingwW64 and ucrt64 job propagates from.
  #
  # Clearing the host role for the build compiler is safe: the build cc reads
  # nothing else from it, and the build role's own `..._FOR_BUILD` is left
  # alone.  Gated on host /= build so a native slice -- where the two roles are
  # the same variable -- keeps flags it is entitled to.  Exec'ing the real ghc
  # keeps `/proc/self/exe` (and so GHC's `getBaseDir` topdir) pointing at the
  # compiler rather than at this shim.
  buildStageNeedsHostFlagsCleared =
    twoStage && stdenv.hostPlatform.config != stdenv.buildPlatform.config;
  twoStageBuildGhcBin =
    if !buildStageNeedsHostFlagsCleared
    then "${twoStageBuildGhc}/bin/ghc"
    else "${pkgs.pkgsBuildBuild.runCommand "build-stage-ghc" {
             preferLocalBuild = true;
           } ''
             mkdir -p $out/bin
             # Mirror the whole bin/ first: cabal's near-compiler lookup
             # (`guessToolFromGhcPath`) canonicalizes the configured ghc and
             # probes ITS directory for ghc-pkg/hsc2hs, and a script is a real
             # file, so that directory is this one.
             for f in ${twoStageBuildGhc}/bin/*; do
               ln -sf "$f" "$out/bin/$(basename "$f")"
             done
             rm -f $out/bin/ghc
             printf '#!/bin/sh\nunset NIX_CFLAGS_COMPILE NIX_LDFLAGS\nexec %s "$@"\n' \
               ${twoStageBuildGhc}/bin/ghc > $out/bin/ghc
             chmod +x $out/bin/ghc
           ''}/bin/ghc";
  twoStageFlags = lib.optionalString twoStage (
    " --with-build-compiler=${twoStageBuildGhcBin}"
    + " --with-build-hc-pkg=${twoStageBuildGhc}/bin/ghc-pkg");

  # The BUILD-stage `setup` executable cabal compiles for each unit is linked
  # by the BUILD compiler against that compiler's OWN registered `text` -- and
  # stage2 builds `text` with `+simdutf` deliberately (`overlays/
  # stable-haskell.nix`, recorded as `enableTextSimdutf = true`).  `+simdutf`
  # makes `text` depend on `system-cxx-std-lib`, whose conf carries a bare
  # `extra-libraries: stdc++`, so every `setup` links `-lstdc++`.
  #
  # gcc resolves that from its own internal search path, so the LINK succeeds;
  # what is missing is the RUNPATH.  nixpkgs' cc-wrapper contributes its
  # `-L`/rpath flags only for the salt it is registered under
  # (`NIX_LDFLAGS_<config>`), and the compiler's baked-in build cc-wrapper is a
  # different store path from the slice stdenv's cc.  In a CROSS slice the
  # stdenv populates the HOST salt, so nothing populates the build one, and
  # `setup` links fine but dies the moment cabal runs it:
  #
  #   setup: error while loading shared libraries: libstdc++.so.6:
  #   cannot open shared object file: No such file or directory
  #
  # -- the `ghc-boot` slice failure every mingwW64 and ghcjs job of eval 2453
  # propagates from.  Note this is NOT the composed project's `package text /
  # flags: -simdutf`: that governs the HOST `text` built inside the slice,
  # while the offender is the build compiler's pre-existing one.
  #
  # Give the build salt an explicit `-L` + `-rpath` for the build platform's
  # C++ runtime.  `twoStage` is tested first so `twoStageBuildGhc` (which has
  # no `buildGHC` to fall back on for a single-stage compiler) is never forced.
  buildCxxLib = pkgsBuildBuild.stdenv.cc.cc.lib or pkgsBuildBuild.stdenv.cc.cc;
  buildSalt = lib.replaceStrings [ "-" "." ] [ "_" "_" ]
    stdenv.buildPlatform.config;
  setupNeedsCxxRpath =
    twoStage
    && stdenv.buildPlatform.isLinux
    && stdenv.buildPlatform.config != stdenv.hostPlatform.config
    && (twoStageBuildGhc.enableTextSimdutf or false);

  # Two-stage build-tool source staging, appended verbatim to the
  # own-source block of the build-time slicing repo.  Leads with a newline
  # so it attaches after the own-source `''}` without a standalone line;
  # empty (zero bytes) unless `buildToolSourceFrags` is non-empty, which
  # keeps non-two-stage (native / single-stage-cross) slice UnitId hashes
  # byte-identical.  Each frag becomes an index candidate (tarball +
  # .cabal) so the slice's own cabal can build the tool BUILD-stage —
  # no built slice, no store unit, no constraint.
  # Flag pins for metadata-staged solver-only candidates: `package
  # <name> / flags:` blocks reproducing the plan's flag assignments, so
  # the slice's re-solve elaborates those source candidates exactly as
  # plan-nix did instead of exploring flag space (see comp-v2-builder
  # `metadataSourceFrags`).  Empty string when there are none, keeping
  # existing slices byte-identical.
  metadataFlagBlocks = lib.concatMapStrings (f:
    let fl = f.flags or {};
        flagsLine = lib.concatStringsSep " "
          (lib.mapAttrsToList (n: v: (if v then "+" else "-") + n) fl);
    in lib.optionalString (fl != {}) ''
      package ${f.pkgName}
        flags: ${flagsLine}
    '') metadataSourceFrags;

  stageFrag = stageFragWith {};
  # `viaRedirect`: for staging into `$out` (`metadataFragExport`); see
  # builder/stage-cabal-file.nix.
  stageFragWith = { viaRedirect ? false }: f: ''

      ln -sf ${f.tarball} $v2repo/package/${f.pkgName}-${f.pkgVersion}.tar.gz
      mkdir -p $v2idx/${f.pkgName}/${f.pkgVersion}
      ${stageCabalFile {
        fragment = f;
        copyOptions = " -f --no-preserve=mode";
        singleLine = true;
        inherit viaRedirect;
        target = "$v2idx/${f.pkgName}/${f.pkgVersion}/${f.pkgName}.cabal";
      }}'';
  # Metadata (solver-only) sources additionally get stripped down to
  # what the SOLVER may see of them: cabal solves a package goal with
  # the deps of all its components, but a metadata candidate's
  # test/bench/exe deps — and those of sublibraries nothing references —
  # are not in plan-json (dependencies' non-library components are never
  # planned), so their goals could never be satisfied from a
  # plan-projected index (vector's internal `library benchmarks-O2`
  # wants tasty; optparse-applicative's test-suite wants QuickCheck).
  #
  #   pass 1: drop test-suite / benchmark / executable / foreign-library
  #           stanzas (top-level keyword to next top-level construct;
  #           `[^ \t\r]` keeps CRLF cabal files — hackage revisions are
  #           CRLF — from resetting the skip at a `\r`-only "blank" line);
  #   pass 2: drop named `library <sub>` stanzas whose name appears
  #           nowhere outside library headers — an UNREFERENCED sublib
  #           (benchmarks-O2).  Referenced ones (attoparsec's main
  #           library needs its public `attoparsec-internal`) stay, and
  #           their deps are lib deps the plan does know.
  #
  # These units are never build targets and nothing hashes their package
  # descriptions; the main library, kept sublibs, `common` blocks and
  # `flag` definitions make library solving behave exactly as plan-nix's.
  stageMetadataFrag = stageMetadataFragWith {};
  stageMetadataFragWith = opts: f:
    let cab = "$v2idx/${f.pkgName}/${f.pkgVersion}/${f.pkgName}.cabal"; in
    stageFragWith opts f + ''

      awk 'BEGIN{s=0} /^(test-suite|benchmark${if f.keepExes or false then "" else "|executable"}|foreign-library)[ \t]/{s=1;next} /^[^ \t\r]/{s=0} s==1{next} {print}' \
        ${cab} > ${cab}.x && mv ${cab}.x ${cab}
      for hsnix_sub in $(awk '/^library[ \t]+[^ \t\r]/{print $2}' ${cab} | tr -d '\r'); do
        hsnix_refs=$(grep -v '^[Ll]ibrary' ${cab} | grep -cw "$hsnix_sub" || true)
        if [ "$hsnix_refs" = 0 ]; then
          awk -v sl="$hsnix_sub" \
            'BEGIN{s=0} $0 ~ ("^library[ \t]+" sl "[ \t\r]*$") {s=1;next} /^[^ \t\r]/{s=0} s==1{next} {print}' \
            ${cab} > ${cab}.x && mv ${cab}.x ${cab}
        fi
      done'';
  # The staging commands go through a store FILE `source`d by the
  # build script: several hundred metadata frags (the build-stage
  # setup universe) inlined into the script push the builder's
  # env+argv past ARG_MAX ("Argument list too long" executing bash).
  extraFragStaging = lib.optionalString (buildToolSourceFrags != [] || metadataSourceFrags != [])
    # Two-stage build-tool sources verbatim (their exes really build
    # in-slice), then solver-only metadata sources, stanza-stripped —
    # the sets are disjoint by construction (metadata frags are the
    # OUT-of-closure remainder).
    "\nsource ${pkgsBuildBuild.writeText "hsnix-stage-frags"
      (lib.concatMapStrings stageFrag buildToolSourceFrags
       + lib.concatMapStrings stageMetadataFrag metadataSourceFrags)}";
  # The same metadata sources, staged into this slice's OUTPUT as
  # `repo-frag-meta/` so downstream slices see them too.  A consumer that
  # solves this package from source under a build-tool qualifier
  # (`build:pkgb:pkga:exe.vector` in a single-stage cross plan, where the
  # installed host units do not count) opens the same sibling goals this
  # slice did -- vector's `benchmarks-O2` wants tasty -- and those
  # siblings are no longer built slices with their own `repo-frag`.
  metadataFragExport = lib.optionalString (metadataSourceFrags != []) ''
    (
      v2repo=$out/repo-frag-meta
      v2idx=$out/repo-frag-meta/index
      mkdir -p $v2repo/package $v2idx
      source ${pkgsBuildBuild.writeText "hsnix-export-meta-frags"
        (lib.concatMapStrings (stageMetadataFragWith { viaRedirect = true; })
           metadataSourceFrags)}
    )
  '';

  # The pkg-config with-flag is deliberately INDEPENDENT of
  # `ghc.targetPrefix`: two-stage host slices get a WRAPPED ghc whose
  # passthru drops targetPrefix, leaving `crossWithFlags` empty — yet
  # the deployed pkg-config is still the PREFIXED cross wrapper, and
  # without `--with-pkg-config` cabal finds no pkg-config at all
  # (readPkgConfigDb -> NoPkgConfigDb) and rejects every
  # `pkgconfig-depends` of a SOURCE goal with "no pkg-config executable
  # was found" (zlib's own slice under the musl cross).  Composed
  # installed deps never re-check pkgconfig-depends, which is why only
  # slices that SOLVE a pkgconfig-using package from source ever see it.
  pkgConfigWithFlag = lib.optionalString (pkgConfigPrefix != "")
    " --with-pkg-config=${pkgConfigPrefix}pkg-config";

  crossWithFlags = lib.optionalString (targetPrefix != "") (
    " --with-compiler=$hsnixCompilerDir/${ghcBin}"
    + lib.optionalString (stdenv.hasCC or (stdenv.cc != null)) (
        # CC
        (if stdenv.hostPlatform.isGhcjs
         then " --with-gcc=${pkgsBuildBuild.emscripten}/bin/emcc"
         else " --with-gcc=${ccPrefix}cc")
        # BINTOOLS
      + " --with-ar=${binPrefix}ar"
      + " --with-strip=${binPrefix}strip"
        # Starting with ghc 9.10 the `ld command` is no longer in
        # the GHC settings file; pass it explicitly.  ghcjs uses
        # emcc as the linker.
      + (if stdenv.hostPlatform.isGhcjs
         then " --with-ld=${pkgsBuildBuild.emscripten}/bin/emcc"
         else lib.optionalString
                (builtins.compareVersions ghc.version "9.8" >= 0)
                " --with-ld=${binPrefix}ld")
    )
  );
  # The build-platform C compiler for build-stage tool sources; see
  # `depsBuildBuild` below for why its placement depends on the target.
  buildStageCc = [ pkgsBuildBuild.stdenv.cc pkgsBuildBuild.libiconv ];
  buildCcInDepsBuildBuild =
    stdenv.hostPlatform != stdenv.buildPlatform && !stdenv.hostPlatform.isGhcjs;
in

stdenv.mkDerivation ({
  inherit pname version hardeningDisable;
} // {
  # GHC / hsc2hs / cabal write/read source files; without a UTF-8
  # locale they fall back to the C encoding and crash on non-ASCII
  # input (e.g. `commitBuffer: invalid argument (cannot encode
  # character '\194')` when hsc2hs hits a degree symbol).  Mirrors
  # `comp-builder.nix:459-461,503`.
  LANG = "en_US.UTF-8";
  LC_ALL = "en_US.UTF-8";
} // lib.optionalAttrs (stdenv.buildPlatform.libc == "glibc") {
  LOCALE_ARCHIVE = "${buildPackages.glibcLocales}/lib/locale/locale-archive";
} // lib.optionalAttrs (buildToolSourceFrags != [] && stdenv.buildPlatform.isDarwin) {
  # A build-stage build-tool (happy/hsc2hs) compiled from source inside a
  # ghcjs-target slice links `-static -liconv` with the NATIVE build compiler,
  # but the compiler's fixed clang-wrapper reads a `NIX_LDFLAGS_<salt>` this
  # cross slice never populates, so `-liconv` can't be found.  clang also
  # honours the `LIBRARY_PATH` env var for `-l` search (salt-independent), so
  # point it at the build-platform libiconv.  Darwin only — the flag/lib layout
  # is macOS-specific and other build hosts don't hit the ghcjs-slice case.
  LIBRARY_PATH = "${pkgsBuildBuild.libiconv}/lib";
} // {
  # GHCJS runs Template Haskell splices by linking the splice as a
  # JS module and executing it via node at compile-time, so node has
  # to be on PATH inside this build env (just like haskellLib.check
  # for ghcjs binaries).  Mirrors the same `optional isGhcjs nodejs`
  # in lib/check.nix.  The wasm backend's TH needs it too: GHC runs
  # splices under its JSFFI dynamic linker (`$topdir/dyld.mjs`), a node
  # script, and looks `node` up on PATH
  # (compiler/GHC/Runtime/Interpreter/Wasm.hs).
  #
  # `lndir` is used in the buildPhase to compose dep slices into
  # `$out/store` as a symlink tree — see comments there.
  # `cabalPkgConfigWrapper` (haskell.nix's build-time pkg-config
  # wrapper, matching comp-builder.nix:432) is needed when any
  # package in the cabal plan has `pkgconfig-depends:` — cabal's
  # solver invokes pkg-config to query module versions.  This slice
  # re-runs the solver for the subset of packages it can see, so
  # rather than plumb a per-slice flag we always include it.
  nativeBuildInputs = [ ghc cabal-install
                        (pkgsBuildBuild.lndir or pkgsBuildBuild.xorg.lndir)
                        buildPackages.cabalPkgConfigWrapper
                        # `jq` is used by the unit-id mismatch diagnostic
                        # to extract / pretty-print plan.json entries for
                        # the diff between plan-nix and the slice's
                        # actual `dist-newstyle/cache/plan.json`.
                        pkgsBuildBuild.jq
                        # `gawk` for the per-slice diagnostics (extras
                        # filter, conf parsing) and for darwin stdenv's
                        # own setup.sh which calls `awk` during fixup —
                        # missing on darwin's default sandbox PATH so
                        # we plumb it through nativeBuildInputs.
                        pkgsBuildBuild.gawk
                        # cabal-install clones `source-repository-package`
                        # blocks via `git clone file://...`, which needs
                        # `git` on PATH (cabal raises [Cabal-6666] "The
                        # program 'git' is required but it could not be
                        # found." otherwise).
                        #
                        # On native-musl pick the host (musl) git over
                        # the build (glibc) one so it isn't tripped up
                        # by `LD_LIBRARY_PATH=<musl-gcc-libs>` (set by
                        # the ghc shim for iserv's libgcc lookup at
                        # TH-eval time) when ghc/iserv invoke `git`
                        # from a TH callback.  `test/githash` does the
                        # same.  `pkgs.gitReallyMinimal` would be
                        # auto-spliced back to the build platform by
                        # `mkDerivation`'s `nativeBuildInputs`
                        # handling, so reach through `pkgsHostHost`,
                        # which exposes a leaf with no `__spliced`.
                        (if haskellLib.isNativeMusl
                         then pkgs.pkgsHostHost.gitReallyMinimal
                         else pkgsBuildBuild.gitReallyMinimal) ]
    ++ lib.optional (stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm) pkgsBuildBuild.nodejs
    # Two-stage build-tool source builds (e.g. happy + happy-lib, hsc2hs,
    # staged via `buildToolSourceFrags`) compile with the native BUILD
    # compiler, whose settings invoke bare `ar` and a wrapped `cc`/`ld`.  On a
    # target whose stdenv ships no C toolchain (ghcjs), nothing else provides
    # them, so a build-stage `.a` archive step fails ([Cabal-6666] "'ar' …
    # could not be found") and a build-stage exe link fails ("ld: library not
    # found for -liconv").  Add the full native (build-platform) cc wrapper: it
    # puts `ar`/`ld`/`nm` on PATH (via its propagated bintools) AND wires the
    # darwin default libs (libiconv, …) into the wrapper's search flags.  Only
    # for build-tool slices; others are unchanged (empty list → byte-identical).
    # `libiconv` too: `ghc-internal`/`base` list `extra-libraries: iconv` on
    # darwin, so every build-stage exe link passes `-liconv`; a proper exe
    # slice finds `libiconv.dylib` via its darwin stdenv, but a build-stage
    # sub-build inside a ghcjs-target slice gets no native `-L` for it
    # ("ld: library not found for -liconv").  Adding it as a build-platform
    # native input puts `-L<libiconv>/lib` into the build wrapper's search.
    ++ lib.optionals (buildToolSourceFrags != [] && !buildCcInDepsBuildBuild)
         buildStageCc
    ++ extraNativeBuildInputs;
  # ...but on a C-capable cross target the build compiler must go in
  # `depsBuildBuild`, not `nativeBuildInputs`.  In `nativeBuildInputs` the
  # cc-wrapper setup hook gives it the HOST role, so it collects `-isystem`
  # for this slice's `buildInputs` — the target's C libraries.  On mingw that
  # hands the native `cc` the mingw-w64 pthreads headers, and a build-stage
  # tool's link (GHC compiles a stub that includes Rts.h → OSThreads.h →
  # <pthread.h>) dies with "process.h: No such file or directory".  In
  # `depsBuildBuild` it only sees build-platform deps.  Native slices keep the
  # old placement (build == host, so no difference and no rebuild), and so
  # does ghcjs, which has no target C libraries to leak.
  depsBuildBuild = lib.optionals (buildToolSourceFrags != [] && buildCcInDepsBuildBuild)
    buildStageCc;
  # `depSlices` go in `propagatedBuildInputs` so stdenv chains each
  # slice's `nix-support/propagated-build-inputs` transitively.
  # Concretely: `cardano-lmdb:lib:ffi` declares `pkgconfig = [lmdb]`
  # in its own `propagated`; with chaining, `cardano-lmdb:lib:cardano-lmdb`
  # records lmdb in its own propagation file, and a downstream
  # consumer (`cardano-lmdb-simple`) gets lmdb in its build env
  # automatically — no manual `transitiveDepLibs` walk required.
  # Normal nixpkgs deps like `lmdb` carry `__spliced` so they
  # auto-swap to the consumer's pkg-set under cross-compilation; the
  # only entries that don't auto-swap are the slice $outs themselves
  # (ad-hoc mkDerivation results), which are mostly inert directories
  # of cabal-store symlinks anyway.
  #
  # The buildPhase finds slices by walking `pkgsHostTarget` (the bash
  # array stdenv builds from buildInputs *and* propagatedBuildInputs)
  # for entries that expose a `store/` subdir.  Same pattern as v1's
  # `make-config-files.nix:102-114`.  Slices have no `lib/`/`include/`
  # at $out so stdenv's NIX_LDFLAGS / NIX_CFLAGS injection finds
  # nothing to add — propagation is for iteration + transitive
  # sysLib chaining only.
  buildInputs = extraBuildInputs;
  propagatedBuildInputs = propagated ++ depSlices;
  # `fixupPhase` is what stdenv uses to write
  # `nix-support/propagated-build-inputs` from `propagatedBuildInputs`.
  # Without it the slice's `propagated` (pkgconfig deps, frameworks,
  # ...) silently fail to flow into downstream consumers — notably the
  # v2 shell, where it makes `pkg-config --list-all` miss zlib etc.
  phases = [ "buildPhase" "installPhase" "fixupPhase" ];
  # Skip stripping: strip.sh from cctools' wrapper trips on
  # `exit_code: unbound variable` under stdenv's `set -u`, and our
  # slice $out is a tree of /nix/store symlinks anyway — nothing to
  # strip that the dep slices haven't already stripped themselves.
  dontStrip = true;
  inherit passthru;

  buildPhase = ''
    set -euo pipefail

    buildRoot=$PWD

    # --- Timing instrumentation --------------------------------------
    # A slice that is slow has to be attributable from its build log
    # alone -- there is no way to attach a profiler to something nix ran
    # an hour ago on a remote builder.  `sliceMark` prints an elapsed
    # wall-clock second count at every phase boundary, and `sliceStamp`
    # stamps each line of cabal's own output, so the gap after
    # "Resolving dependencies..." IS the solver and the gap before it is
    # everything cabal does to get there (reading the config, the index
    # and `ghc-pkg dump`).  Each cabal call is additionally wrapped in
    # bash's `time`, which splits wall from CPU: real >> user+sys means
    # the cost is I/O (index untar, store composition, NFS), while
    # real ~= user means it is compute (the solver).
    #
    # Caveat worth knowing when reading the stamps: cabal's stdout is a
    # pipe here, so if it ever block-buffers, a burst of lines will all
    # carry the timestamp of the flush.  The `sliceMark`s around each
    # call are unaffected and remain the authoritative totals.
    sliceMark() { printf '[slice %5ds] === %s\n' "$SECONDS" "$*"; }
    sliceStamp() { while IFS= read -r sliceLine; do
      printf '[slice %5ds] %s\n' "$SECONDS" "$sliceLine"; done; }
    sliceMark "buildPhase start"
    ${lib.optionalString (stdenv.hostPlatform.isStatic or false) ''
    # See `staticHostSalt` above: keep pkgsStatic's `-static` off the
    # build-platform C toolchain, which this slice also uses -- to link the
    # two-stage plan's build-stage executables.  This sits exactly where the
    # blank line was so that on every other platform it expands to that same
    # blank line: the buildPhase text, and so every non-static slice's
    # derivation hash, is unchanged.
    export NIX_CFLAGS_LINK_${staticHostSalt}="''${NIX_CFLAGS_LINK_${staticHostSalt}:-}''${NIX_CFLAGS_LINK:-}"
    export NIX_CFLAGS_LINK=""
    ''}${lib.optionalString setupNeedsCxxRpath ''

    # See `setupNeedsCxxRpath` above: the build compiler links the build-stage
    # `setup` exe against `-lstdc++` (its own `text` is `+simdutf`, so it
    # depends on `system-cxx-std-lib`), but in a cross slice nothing populates
    # the build salt, so the binary carries no RUNPATH for libstdc++ and dies
    # at exec.  Append one; the `:-` keeps whatever stdenv already set.
    export NIX_LDFLAGS_${buildSalt}="''${NIX_LDFLAGS_${buildSalt}:-} -L${buildCxxLib}/lib -rpath ${buildCxxLib}/lib"
    ''}
    # --- Compose starting store --------------------------------------
    # Use $out/store as the cabal store dir from the start so that
    # any path baked into a built binary (e.g. alex's `Paths_alex`
    # data-dir, which records `<storeDir>/<unit>/share/...` at
    # compile time) points at a permanent /nix/store location.  If
    # we used a $buildRoot/... path here, the binary's baked path
    # would point at an ephemeral build dir that vanishes after
    # the slice finishes — and a downstream consumer running the
    # binary (e.g. language-c invoking alex during preprocessing)
    # would fail with "AlexTemplate.hs: openFile: does not exist".
    #
    # Compose dep slices via `lndir` instead of `cp -r`: every dep
    # slice file becomes a symlink into the dep slice's $out under
    # /nix/store.  Cabal reads through the symlinks transparently;
    # nothing here actually owns those files — so when we install
    # this slice, leaving the symlinks in $out/store is fine.
    # Downstream slices composing this $out follow the symlinks back
    # to the original dep slices (kept alive by nix's GC roots).
    #
    # Find the dep slices by iterating `pkgsHostTarget` (the bash
    # array stdenv populates from `buildInputs`) and looking for
    # entries that expose a `store/` subdir — the marker for a
    # cabal slice's $out.  Same pattern as v1's
    # `make-config-files.nix:102-114` (which iterates the same
    # array looking for `package.conf.d`).
    #
    # Only *direct* slice deps are in `buildInputs` (so the closure
    # cost stays out of the nix-side eval).  Each slice writes the
    # transitive set of slices it composed in to
    # `$out/nix-support/transitive-deps` (one store path per line);
    # follow that file here to pull in the indirect ones too.
    storeDir=$out/store
    mkdir -p $storeDir
    declare -A seenDeps
    depSliceCount=0
    addDep() {
      local d=$1
      if [ -n "$d" ] && [ -d "$d/store" ] && [ -z "''${seenDeps[$d]:-}" ]; then
        seenDeps[$d]=1
        # Counted here rather than read off the array afterwards: under
        # `set -u`, `''${#seenDeps[@]}` on an array that was `declare -A`'d
        # but never assigned is an UNBOUND VARIABLE, not 0 (bash 5.3
        # included) -- so a leaf slice with no dep slices died on the
        # instrumentation instead of building.
        depSliceCount=$((depSliceCount + 1))
        # Compose per top-level entry rather than `lndir`ing `$d/store`
        # wholesale, so the dep's `build` -> `host` alias can be SKIPPED.
        # That alias is now kept in every slice's output (see the
        # installPhase), because cabal bakes `<slice>/dist-newstyle/store/
        # build/<plat>/lib/<unit>/share` into a BUILD-stage tool's
        # `Paths_<pkg>` datadir and the binary needs it to resolve forever
        # after -- `alex` failed with
        #   .../store/build/.../alex-3.5.4.2-.../share/AlexTemplate.hs:
        #   openFile: does not exist
        # when it was dropped.  Following it here instead would relink every
        # unit a second time (it points at `host`, which we have already
        # walked) and, worse, materialise `build/` as a REAL directory that
        # shadows this slice's own alias below -- which is exactly why it
        # used to be deleted.  Skipping is the cheap half of that trade.
        local sub b
        for sub in "$d"/store/*; do
          [ -e "$sub" ] || continue
          b=$(basename "$sub")
          [ "$b" = build ] && continue
          if [ -d "$sub" ]; then
            mkdir -p "$storeDir/$b"
            lndir -silent "$sub" "$storeDir/$b"
          else
            ln -sf "$sub" "$storeDir/$b"
          fi
        done
      fi
    }
    for dep in "''${pkgsHostTarget[@]}"; do
      addDep "$dep"
      if [ -f "$dep/nix-support/transitive-deps" ]; then
        while IFS= read -r tdep; do
          addDep "$tdep"
        done < "$dep/nix-support/transitive-deps"
      fi
    done
    sliceMark "composed starting store from $depSliceCount dep slices"

    # --- Staged store layout (stable-haskell cabal fork) --------------
    # The fork's `v2-build` takes its install dirs and store package dbs
    # from `distStoreDirLayout` — `<dist>/store/<stage>/<platform>/` with
    # the db at `package.conf.d` — and its `--store-dir` flag no longer
    # reaches project builds at all (DistDirLayout.hs
    # `defaultStoreDirLayout`, ProjectPlanning.hs `computeInstallDirs` /
    # `corePackageDbs`).  Mainline cabal instead installs under
    # `--store-dir`'s `ghc-<ver>/` with the db at `package.db`.  Support
    # both:
    #
    #  * The slice's dist dir is moved INTO `$out` (`--builddir=$distDir`
    #    below) with its `store/` a relative symlink back to `$storeDir`
    #    — so every path the fork bakes into artifacts (a Paths_ module's
    #    datadir, .conf fields, RPATHs: all spelled
    #    `$out/dist-newstyle/store/...`) resolves through a symlink that
    #    lives in `$out` forever, and the store files themselves land in
    #    `$storeDir` where the compose/capture protocol expects them.
    #  * The fork plans every unit in a stage — `build` (runs on the
    #    build machine: setup scripts, build tools) or `host` — and each
    #    stage gets its own store dir.  Natively both stages are the
    #    same toolchain and a unit's id is the same hash in either
    #    stage, so symlink `build` → `host`: a unit captured once (from
    #    its own slice, host stage) satisfies downstream build-stage
    #    lookups (e.g. `Cabal` for a dep's setup script) without a
    #    rebuild.  Cross stages differ by platform, so they still land
    #    in separate `<platform>/` subdirs below the shared link.
    #    (Both symlinks are inert for mainline cabal, which never looks
    #    at `<dist>/store/`.)
    distDir=$out/dist-newstyle
    mkdir -p $distDir
    ln -sfn ../store $distDir/store
    mkdir -p $storeDir/host
    if [ ! -e $storeDir/build ]; then
      ln -sn host $storeDir/build
    fi

    # Locate the store dir cabal reads/writes package dbs in, for
    # whichever of the two layouts is in play, setting:
    #   ghcDir     — `<store>/ghc-<ver>` (mainline) or
    #                `<store>/host/<platform>` (fork), "" if neither
    #                exists yet (first slice, nothing composed)
    #   storePkgDb — the db dir name under $ghcDir (`package.db` /
    #                `package.conf.d`)
    # Glob with `for` + `-d` tests, not `ls -d <glob> | head`: stdenv's
    # setup.sh sets `shopt -s nullglob` globally, so an unmatched glob
    # would leave `ls -d` with NO arguments — which lists the CURRENT
    # dir, yielding the bogus `ghcDir="."`.  `for` just skips unmatched
    # globs under nullglob (and the `-d` test rejects the literal
    # pattern if nullglob were ever off).
    # The compiler's platform dir name inside the staged store: the fork
    # names it after the compiler's `--info` "Target platform"
    # (DistDirLayout.hs `betterPlatform`).  On cross the composed store
    # holds a SECOND platform dir — build-stage units (native) reached
    # through the `build` → `host` link — so the host dir must be picked
    # by name, not by glob order.
    hostPlatformDir=$(${ghcBin} --info 2>/dev/null \
      | sed -n 's/.*("Target platform","\([^"]*\)").*/\1/p' | head -1)

    discoverStore() {
      local d
      ghcDir=""
      storePkgDb=package.db
      for d in $storeDir/ghc-*; do
        [ -d "$d" ] || continue
        ghcDir=$d
        break
      done
      if [ -z "$ghcDir" ] && [ -n "$hostPlatformDir" ] \
         && [ -d "$storeDir/host/$hostPlatformDir" ]; then
        ghcDir=$storeDir/host/$hostPlatformDir
        storePkgDb=package.conf.d
      fi
      if [ -z "$ghcDir" ]; then
        # No dir matches the compiler's platform (or --info gave none).
        # Natively there is exactly one platform dir — take it.  On cross
        # the composed store also holds the build-stage (native) platform
        # dir reached through the `build` → `host` link, so guessing by
        # glob order could silently pick the wrong platform: fail instead.
        local candidates=()
        for d in $storeDir/host/*/; do
          [ -d "$d" ] || continue
          candidates+=("''${d%/}")
        done
        if [ "''${#candidates[@]}" -eq 1 ]; then
          ghcDir=''${candidates[0]}
          storePkgDb=package.conf.d
        elif [ "''${#candidates[@]}" -gt 1 ]; then
          echo "discoverStore: cannot identify the host platform dir in $storeDir/host" >&2
          echo "  (ghc --info Target platform: '$hostPlatformDir'; candidates: ''${candidates[*]})" >&2
          exit 1
        fi
      fi
    }
    # `package.db` needs to be a writable directory (cabal/ghc-pkg
    # rewrite `package.cache`, recache, etc.).  After lndir it's a
    # dir of symlinks under a real dir — fine for adding files —
    # but `package.cache` and `package.cache.lock` must be
    # writable real files, not symlinks pointing at read-only
    # /nix/store paths (otherwise `ghc-pkg recache`'s `flock()`
    # fails with `hLock: invalid argument`).  Remove the symlinks;
    # ghc-pkg will create real files in their place.
    discoverStore
    if [ -n "$ghcDir" ]; then
      for f in package.cache package.cache.lock; do
        if [ -L "$ghcDir/$storePkgDb/$f" ]; then
          rm "$ghcDir/$storePkgDb/$f"
        fi
      done
    fi
    ${lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) ''
      # Cross slice: evict composed BUILD-stage library units.  On cross the
      # solver's installed index is the HOST db only (see "Solver visibility"
      # below), so a build-stage library a custom setup needs — e.g. the
      # Cabal-syntax that entropy's Setup.hs imports, composed from its
      # setup-dep slice — is always planned `(requires build)` and rebuilt
      # in-slice under the same deterministic id.  Its composed receipt and
      # conf are read-only symlinks, so the fork's staged install then dies
      # writing the receipt (`withFile: permission denied` on
      # `units/<pkgid>`).  They can never be reused here, and build-stage
      # byproducts are evicted from $out anyway (below), so drop them up
      # front and let the rebuild install cleanly.  Only symlinked receipts
      # that have a conf (libraries composed from dep slices) go; composed
      # build-tool exes (alex, hsc2hs) are left for the PATH overlays, with
      # their receipts made writable in case they are rebuilt.
      # (Only with a known host dir: without it every dir would qualify.)
      # This runs BEFORE the loop below that drops each db's composed
      # `package.cache` symlink and recaches it, so the BUILD-platform db --
      # which nothing recaches later -- gets a cache without the evicted
      # units rather than one still listing them.
      [ -n "$hostPlatformDir" ] && for platDir in $storeDir/host/*/; do
        platDir=''${platDir%/}
        [ "''${platDir##*/}" = "$hostPlatformDir" ] && continue
        [ -d "$platDir/units" ] || continue
        for receipt in "$platDir"/units/*; do
          [ -L "$receipt" ] || continue
          uid=''${receipt##*/}
          if [ ! -e "$platDir/package.conf.d/$uid.conf" ]; then
            # A composed build-tool exe (no conf).  Keep it -- the PATH
            # overlays use it -- but it can be rebuilt in-slice too, e.g.
            # exe:hspec-discover once the lib it links (evicted just
            # below) is rebuilt, and the fork then rewrites its receipt by
            # opening it, which fails through the read-only symlink
            # (`withFile: permission denied`, build 2153839).  Make the
            # receipt a writable copy of itself.  The exe and its docs need
            # nothing: cabal copies those into place.
            cp --remove-destination "$(readlink -f "$receipt")" "$receipt"
            chmod u+w "$receipt"
            continue
          fi
          echo "evicting composed build-stage unit: $uid"
          rm -f "$receipt" "$platDir/package.conf.d/$uid.conf"
          if [ -d "$platDir/lib/$uid" ]; then
            chmod -R u+w "$platDir/lib/$uid" 2>/dev/null || true
            rm -rf "$platDir/lib/$uid"
          fi
        done
      done
    ''}# Every composed platform db must be writable AND carry a real
    # `package.cache`:
    #  * Build-stage tools built from source in-slice (happy/happy-lib, staged
    #    via `buildToolSourceFrags`) get registered by `ghc-pkg recache` into
    #    the BUILD-platform db (`store/host/<build-platform>`, reached through
    #    the `build`→`host` link) — a DIFFERENT platform dir than the cross
    #    target's that `discoverStore` fixes above.  Its `package.cache{,.lock}`
    #    may be composed as read-only symlinks into /nix/store, so the recache
    #    `flock()` fails with `hLock: invalid argument (Bad file descriptor)`.
    #  * A dep slice does not necessarily SHIP a cache at all (whether one is
    #    composed in depends on which dep slice's db got composed first), and
    #    ghc refuses a non-empty db with no cache ("there is no package.cache
    #    in …") — which kills the SETUP compile of any slice whose
    #    setup-depends resolve to composed units (leksah: ghc-boot's
    #    setup-scope Cabal-3.16 twin db held two confs and no cache once the
    #    plan gained a package and the compose order shifted).
    # So make every composed platform db writable and freshly cached
    # unconditionally, not just when build tools are staged in-slice.
    for db in $storeDir/host/*/package.conf.d; do
      [ -d "$db" ] || continue
      for f in package.cache package.cache.lock; do
        [ -L "$db/$f" ] && rm "$db/$f" || true
      done
      if [ ! -e "$db/package.cache" ]; then
        ${ghcPkgBin} --package-db=$db recache
      fi
    done

    ${lib.optionalString (buildToolBinOverlays != []) ''
      # Overlay each cross-target build-tool's `bin/<name>` in the
      # composed store with the build-platform binary.  See the
      # `buildToolBinOverlays` arg's doc-string.
      ${lib.concatMapStrings (e: ''
        shopt -s nullglob
        for binFile in $storeDir/ghc-*/*-e-${e.name}-*/bin/${e.name} \
                       $storeDir/host/*/*-e-${e.name}-*/bin/${e.name} \
                       $storeDir/host/*/bin/${e.name}; do
          chmod u+w "$(dirname "$binFile")" 2>/dev/null || true
          rm -f "$binFile"
          cp -L ${e.buildSlice}/bin/${e.name} "$binFile"
          chmod u+rx "$binFile" 2>/dev/null || true
        done
        shopt -u nullglob
      '') buildToolBinOverlays}
    ''
    }${lib.optionalString (allowedSiblingUnitPrefix != null) ''
      # Local-`packages:` slice: evict composed units of the TARGET
      # package itself.  cabal never satisfies an intra-package dep
      # from an installed unit — a local target's sibling components
      # always build in-slice — so the composed twins are unusable,
      # and the fork's staged install would collide with their
      # read-only conf / `units/` receipt symlinks when it registers
      # the in-slice rebuilds under the same deterministic ids
      # (`withFile: permission denied` on `units/<pkgid>-<comp>`).
      # The sibling SLICES stay composed for everything else they
      # carry (their transitive dep closure, repo fragments).
      discoverStore
      if [ -n "$ghcDir" ] && [ -d "$ghcDir/$storePkgDb" ]; then
        sibling_pkgid=${lib.escapeShellArg allowedSiblingUnitPrefix}
        shopt -s nullglob
        for conf in "$ghcDir/$storePkgDb/$sibling_pkgid.conf" \
                    "$ghcDir/$storePkgDb/$sibling_pkgid"-*.conf; do
          [ -L "$conf" ] || continue      # composed symlink, not ours
          uid=$(basename "''${conf%.conf}")
          echo "evicting composed same-package unit: $uid"
          rm "$conf"
          rm -f "$ghcDir/units/$uid"
          if [ -d "$ghcDir/$uid" ]; then
            chmod -R u+w "$ghcDir/$uid" 2>/dev/null || true
            rm -rf "$ghcDir/$uid"
          fi
        done
        shopt -u nullglob
      fi
    ''}# Snapshot existing unit filenames so we can identify new ones later.
    discoverStore
    if [ -n "$ghcDir" ] && [ -d "$ghcDir/$storePkgDb" ]; then
      # No chmod needed — the db dir is a real dir from lndir,
      # and the `.conf` entries in it are symlinks pointing at
      # read-only /nix/store paths.  ghc-pkg recache only needs to
      # write `package.cache`, which doesn't exist yet (we removed
      # any symlinked one above).
      ${ghcPkgBin} --package-db=$ghcDir/$storePkgDb recache
      ( cd $ghcDir/$storePkgDb && ls *.conf 2>/dev/null ) > $buildRoot/confs-before || true

      # Also snapshot the flat <ghcDir>/lib/ that cabal uses for
      # dylibs.  See installPhase for how this is used to emit only
      # *new* lib files to $out.
      if [ -d "$ghcDir/lib" ]; then
        ( cd $ghcDir/lib && ls 2>/dev/null ) > $buildRoot/lib-before || true
      else
        : > $buildRoot/lib-before
      fi

      # And the flat <ghcDir>/bin/ — the staged layout installs every
      # unit's executables there (`bindir = pkgroot </> "bin"`, flat,
      # not per-unit), so new entries can only be identified by diff.
      if [ -d "$ghcDir/bin" ]; then
        ( cd $ghcDir/bin && ls 2>/dev/null ) > $buildRoot/bin-before || true
      else
        : > $buildRoot/bin-before
      fi

      # Snapshot all unit directories (not just those with .conf).
      # Exe-only units have a dir like <ghcDir>/<unit-id>/bin/<name>
      # but no corresponding .conf in package.db.  We need to catch
      # those too so a downstream compose can find them.
      #
      # `find -maxdepth 1 -type d` rather than `ls -d */` because the
      # OS-prefix patch on cabal-install puts `-` at the start of
      # some unit-ids (e.g. `-clsss-...`), and bash expands `*/` into
      # those names as args to `ls`, which then interprets the
      # leading `-` as flags and silently produces no output.
      ( cd $ghcDir \
          && find . -mindepth 1 -maxdepth 1 -type d \
          | sed 's|^\./||' ) \
        > $buildRoot/unitdirs-before || true
    else
      : > $buildRoot/confs-before
      : > $buildRoot/lib-before
      : > $buildRoot/bin-before
      : > $buildRoot/unitdirs-before
    fi

    # --- Solver visibility of composed units (staged store layout) ---
    # The fork DOES reuse store entries, but only as a post-solve
    # improvement pass, so the solver still has to see the units.
    # `improveInstallPlanWithStoreUnits` (ProjectPlanning.hs, driven from
    # `phaseImprovePlan`) walks the plan bottom-up and promotes a unit to
    # Installed when it has a receipt under
    # `<store>/<stage>/<platform>/units/<unit-id>`, is not a local
    # (`LocalUnpackedPackage`) package, and every one of its dependencies
    # is itself pre-existing, installed, or being improved.  It reads the
    # receipt dirs directly rather than through Store.hs's
    # `getStoreEntries`, which is why that module looks unused from here.
    #
    # That pass cannot rescue a unit the SOLVER already chose to build from
    # source, and being bottom-up, one local package low in the graph fails
    # the third guard for everything above it.  So a unit still only avoids
    # `(requires build)` if the SOLVER already sees it as INSTALLED in the
    # toolchain's package db — the same mechanism the fork's stage
    # system uses for boot libraries.  GHC itself needs no help
    # (cabal passes the dist store db — our composed store, through
    # the `$distDir/store` symlink — on every ghc command line), but
    # the solver's installed-package index comes from `ghc-pkg dump
    # --global`.  Prepend a tool dir whose ghc-pkg re-points the
    # stage-compiler's (empty) global db at the composed db: the
    # compiler's own ghc-pkg wrapper puts its baked
    # `--global-package-db` BEFORE "$@", and ghc-pkg's flag handling
    # is last-wins, so appending ours overrides it.  Every other tool
    # is symlinked alongside so cabal's near-compiler discovery
    # (haddock, hsc2hs, ...) keeps working.  Unit-id hashes are
    # unaffected: `pkgHashPackageDbs` stays `[GlobalPackageDB]` (no
    # path enters the hash).
    composedDb=""${lib.optionalString (targetPrefix != "")
      # The dir `crossWithFlags` points `--with-compiler=` at.  It is an
      # ABSOLUTE path, so the solver-tools farm below (a PATH prefix)
      # cannot reach cabal by itself; when that farm exists it re-points
      # this variable at itself.
      "\n    hsnixCompilerDir=${ghcShim}/bin"}
    if [ -n "$ghcDir" ] && [ "$storePkgDb" = package.conf.d ]; then
      composedDb=$ghcDir/$storePkgDb
      ${lib.optionalString solverIncludesGlobalDb ''
        # Consumer-style slice (it has `pre-existing` deps): the real
        # global db must STAY in the solver's installed index alongside
        # the composed units — the composed-db override below would
        # otherwise make every boot lib unknown to the solver
        # ("unknown package: base").  Inject each global conf into the
        # composed db as a SYMLINK to a `''${pkgroot}`-resolved copy
        # under $buildRoot: symlinked confs are invisible to the
        # slice's unit capture (which keys on real files), and the
        # installPhase drops them again so nothing dangling ships in
        # $out.  Snapshot-only is fine — the solver's installed index
        # is read once, up front.  (Stage-style slices —
        # `v2LocalPackageSlices`, no pre-existing deps — keep the
        # composed-only view: the previous stage compiler's global db
        # carries unrelated registrations the solver must not see.)
        libdir=$(${ghcBin} --print-libdir)
        globalSnap=$buildRoot/global-conf-snapshot
        mkdir -p $globalSnap
        shopt -s nullglob
        # name-version index of the composed units: a composed instance
        # means plan-nix chose a REINSTALLED unit for that package
        # version, so the boot instance of the SAME name+version must
        # not become a second installed candidate — the solver could
        # satisfy an `installed` pin with the boot copy and fork every
        # dependent's unit-id (leksah: composed haddock-library-1.11.0
        # reinstall vs the compiler's boot haddock-library-1.11.0).
        # Different VERSIONS stay visible: `==` pins steer those (e.g.
        # a composed setup-scope Cabal-3.16 alongside boot Cabal-3.17).
        composedNV=$buildRoot/composed-name-versions
        : > $composedNV
        for conf in "$composedDb"/*.conf; do
          [ -e "$conf" ] || continue
          awk '/^name:/{n=$2} /^version:/{v=$2} END{if(n!="")print n"-"v}' \
            "$conf" >> $composedNV
        done
        for conf in "$libdir/package.conf.d"/*.conf; do
          confBase=$(basename "$conf")
          [ -e "$composedDb/$confBase" ] && continue
          nv=$(awk '/^name:/{n=$2} /^version:/{v=$2} END{if(n!="")print n"-"v}' "$conf")
          if [ -n "$nv" ] && grep -qx -- "$nv" $composedNV; then
            echo "skipping boot conf shadowed by composed reinstall: $confBase"
            continue
          fi
          sed "s|\''${pkgroot}|$libdir|g" "$conf" > "$globalSnap/$confBase"
          ln -s "$globalSnap/$confBase" "$composedDb/$confBase"
        done
        shopt -u nullglob
        ${ghcPkgBin} --package-db=$composedDb recache
      ''}
      wrapBin=$buildRoot/solver-tools
      mkdir -p $wrapBin
      realGhcBinDir=${
        # On cross, cabal is NOT told to find the compiler on PATH: it gets
        # an absolute `--with-compiler=` inside the ghc shim, and its
        # "near compiler" lookup then takes `ghc-pkg` from the SHIM's own
        # bin/ -- so a PATH-only override left the composed units invisible
        # to the solver and every `installed` pin below was unsatisfiable
        # ("rejecting: host:<dep> ... requires installed instance").  Mirror
        # the shim (the dir cabal actually uses) instead of the raw compiler
        # bin/, and re-point `--with-compiler=` at the farm.
        if targetPrefix != "" then "${ghcShim}/bin"
        else ''$(dirname "$(type -P ${ghcBin})")''}
      for tool in "$realGhcBinDir"/*; do
        ln -sf "$tool" "$wrapBin/$(basename "$tool")"
      done
      # ghc must be a real file, not a symlink: Cabal's
      # `guessToolFromGhcPath` canonicalizes the configured ghc path
      # and tries the REAL dir's ghc-pkg first (cabal#7390) — which
      # would find the compiler's own ghc-pkg and skip our override.
      for g in "$realGhcBinDir"/${ghcBin} "$realGhcBinDir"/${ghcBin}-[0-9]*; do
        [ -e "$g" ] || continue
        gName=$(basename "$g")
        rm -f "$wrapBin/$gName"
        printf '#!/bin/sh\nexec %s "$@"\n' "$g" > "$wrapBin/$gName"
        chmod +x "$wrapBin/$gName"
      done
      for gp in "$realGhcBinDir"/${ghcPkgBin}*${lib.optionalString (targetPrefix != "")
        # Cabal's near-compiler lookup asks for `ghc-pkg`, not
        # `<prefix>ghc-pkg` (the shim exposes both), so the unprefixed
        # alias needs the same `--global-package-db` override.
        " \"$realGhcBinDir\"/ghc-pkg*"}; do
        [ -e "$gp" ] || continue
        gpName=$(basename "$gp")
        rm -f "$wrapBin/$gpName"
        printf '#!/bin/sh\nexec %s --global-package-db %s "$@"\n' \
          "$gp" "$composedDb" > "$wrapBin/$gpName"
        chmod +x "$wrapBin/$gpName"
      done
      export PATH=$wrapBin:$PATH${lib.optionalString (targetPrefix != "")
        "\n      hsnixCompilerDir=$wrapBin"}
    fi
    # The size of the solver's INSTALLED index: every `.conf` here is a
    # package the solver has to consider.  If planning is slow and this
    # number is large, the composed db (not the source repo) is the input
    # to look at.
    sliceMark "solver-visible installed units: $(
      if [ -n "$composedDb" ] && [ -d "$composedDb" ];
        then ls -1 "$composedDb"/*.conf 2>/dev/null | wc -l; else echo 0; fi)"

    # --- CABAL_DIR and optional local-repo ---------------------------
    export HOME=$buildRoot/home
    mkdir -p $HOME/.cabal
    export CABAL_DIR=$HOME/.cabal

    # emcc is very slow if it cannot cache stuff in $HOME, and
    # newer nixpkgs default its cache dir to a /nix/store path
    # that isn't writable.  Set up a writable EM_CACHE explicitly.
    ${lib.optionalString stdenv.hostPlatform.isGhcjs ''
      export EM_CACHE=$(mktemp -d)
      if [ -d ${pkgsBuildBuild.emscripten}/share/emscripten/cache ]; then
        cp -r ${pkgsBuildBuild.emscripten}/share/emscripten/cache/* $EM_CACHE/
        chmod -R u+w $EM_CACHE
      fi
    ''}

    # Cross-TH on windows uses a wrapped ghc that prepends
    # `-fexternal-interpreter -pgmi <wineIservWrapper>`.  The
    # wrapper script reads `pkgsHostTargetAsString` (under
    # `set -u`) to find host-platform DLLs.  stdenv exposes
    # `pkgsHostTarget` as a bash array; flatten it always (use
    # `[*]` with the empty default so unset/empty arrays produce
    # an empty string rather than an `unbound variable` error).
    export pkgsHostTargetAsString="''${pkgsHostTarget[*]:-}"

    ${if v2Fragment != null then ''
      # --- Build-time slicing repo (STEP 2: composed from fragments) ---
      # Assemble the per-slice hackage repo here instead of in Nix: this
      # package's own source (passed directly — our own `repo-frag` isn't
      # built yet) plus every dep's `repo-frag/` reached through the same
      # `transitive-deps` closure walk used for the store above.  cabal
      # hashes package *source* + `.cabal` descriptions (not the index
      # bytes or repo path), so a content-equivalent repo keeps unit-ids
      # identical to the old Nix-assembled `slicingRepo`.
      v2repo=$buildRoot/local-repo
      v2idx=$(mktemp -d)
      mkdir -p $v2repo/package
      declare -A seenRepoFrag
      repoFragMetas=()
      addRepoFrag() {
        local f=$1
        if [ -n "$f" ] && [ -d "$f/repo-frag" ] && [ -z "''${seenRepoFrag[$f]:-}" ]; then
          seenRepoFrag[$f]=1
          [ -d "$f/repo-frag-meta" ] && repoFragMetas+=("$f/repo-frag-meta")
          for t in "$f"/repo-frag/package/*; do
            [ -e "$t" ] && ln -sf "$t" "$v2repo/package/$(basename "$t")"
          done
          if [ -d "$f/repo-frag/index" ]; then
            # `-n` (no-clobber): a multi-sublib package (e.g. happy-lib's
            # grammar/frontend/tabular) appears under several fragment
            # paths that all carry the *same* `<pkg>/<ver>/<pkg>.cabal`;
            # the .cabal is identical, so skip duplicates rather than
            # re-copy onto the read-only file the first copy left.
            cp -rL --no-preserve=mode -n "$f"/repo-frag/index/. "$v2idx"/
          fi
        fi
      }
      # This package's own source + .cabal (own fragment not built yet).
      ln -s ${v2Fragment.tarball} $v2repo/package/${v2Fragment.pkgName}-${v2Fragment.pkgVersion}.tar.gz
      mkdir -p $v2idx/${v2Fragment.pkgName}/${v2Fragment.pkgVersion}
      ${stageCabalFile {
        fragment = v2Fragment;
        target = "$v2idx/${v2Fragment.pkgName}/${v2Fragment.pkgVersion}/${v2Fragment.pkgName}.cabal";
      }}${extraFragStaging}
      # Dep closure repo-frags (direct + transitive — same walk as store).
      for dep in "''${pkgsHostTarget[@]}"; do
        addRepoFrag "$dep"
        if [ -f "$dep/nix-support/transitive-deps" ]; then
          while IFS= read -r tdep; do addRepoFrag "$tdep"; done < "$dep/nix-support/transitive-deps"
        fi
      done
      # Deps' metadata-only sibling sources (see `metadataFragExport`),
      # after every real fragment and without clobbering: a package that
      # is a built slice anywhere in the closure keeps its own entry.
      for m in "''${repoFragMetas[@]}"; do
        for t in "$m"/package/*; do
          [ -e "$t" ] && [ ! -e "$v2repo/package/$(basename "$t")" ] \
            && ln -s "$t" "$v2repo/package/$(basename "$t")"
        done
        cp -rL --no-preserve=mode -n "$m"/index/. "$v2idx"/
      done
      # Hackage index tarball (sorted, fixed mtime — as the Nix repo did).
      tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
          -czf $v2repo/00-index.tar.gz -C $v2idx .
      cat > $CABAL_DIR/config <<EOF
      repository hackage.haskell-nix
        url: file://$v2repo
        secure: False
      EOF
      sliceMark "assembled slicing repo: $(ls -1 $v2repo/package | wc -l) tarballs, $(
        find $v2idx -name '*.cabal' | wc -l) index entries"
      time cabal update hackage.haskell-nix
      sliceMark "cabal update (build-time slicing repo)"
    '' else lib.optionalString (localRepo != null) ''
      # Hackage-style local repo: `00-index.tar.gz` + `package/<pkg>-<ver>.tar.gz`.
      # See comp-v2-builder.nix `slicingRepo` for why we use this layout
      # over `file+noindex://`.  `secure: False` skips TUF root-key checks
      # (we don't sign this repo); the cabal.project then sets
      # `active-repositories: hackage.haskell-nix` so the solver only sees
      # this repo (no other repository is declared in CABAL_DIR/config).
      # cabal only reads from the repo dir at solve time (its mutable
      # index cache lives under `$CABAL_DIR/packages/`), so we point
      # cabal at the `localRepo` /nix/store path directly — no copy
      # into $buildRoot, no chmod -- just reference it in place.
      cat > $CABAL_DIR/config <<EOF
      repository hackage.haskell-nix
        url: file://${localRepo}
        secure: False
      EOF

      # `file://` repos need `cabal update` to populate
      # `$CABAL_DIR/packages/<repo>/` from the repo's
      # `00-index.tar.gz` before the solver can see anything.  This
      # is purely local IO — no network.
      sliceMark "slicing repo: $(ls -1 ${localRepo}/package | wc -l) tarballs"
      time cabal update hackage.haskell-nix
      sliceMark "cabal update (localRepo)"
    ''}

    # --- Caller hook: stage sources + write cabal.project ------------
    mkdir -p $buildRoot/project
    cd $buildRoot/project
    ${preBuild}
    sliceMark "preBuild (source staging)"

    ${lib.optionalString (v2Fragment != null) ''
      # --- Compose cabal.project from per-package fragments ----------
      # The cabal.project is built entirely here, at build time: a local
      # skeleton (`v2Fragment.localCabalProject`) plus the closure-derived
      # sections (extra-packages / per-package block groups / allow-boot /
      # constraints) composed from the per-package fragments — so the
      # dependency-closure walk never happens in the Nix evaluator.
      # cabal hashes content not field order, so local-then-closure is
      # equivalent to the old Nix-assembled project (verified by an
      # order-insensitive diff while this was being developed).

      # Self's fragment (its own $out isn't built yet) materialised from
      # the passed values, so self participates in the block groups.
      selfFrag=$(mktemp -d); mkdir -p $selfFrag/nix-support/v2-frag
      printf '%s' ${lib.escapeShellArg v2Fragment.pkgName} > $selfFrag/nix-support/v2-frag/pkg-name
      cp ${builtins.toFile "flags"             v2Fragment.flagsBlock}            $selfFrag/nix-support/v2-frag/flags
      cp ${builtins.toFile "ghc-options"       v2Fragment.ghcOptionsBlock}       $selfFrag/nix-support/v2-frag/ghc-options
      cp ${builtins.toFile "configure-options" v2Fragment.configureOptionsBlock} $selfFrag/nix-support/v2-frag/configure-options
      cp ${builtins.toFile "program-options"   v2Fragment.programOptionsBlock}   $selfFrag/nix-support/v2-frag/program-options
      cp ${builtins.toFile "doc"               v2Fragment.docBlock}              $selfFrag/nix-support/v2-frag/doc
      cp ${builtins.toFile "extra-lib-dirs"    v2Fragment.extraLibDirsBlock}     $selfFrag/nix-support/v2-frag/extra-lib-dirs
      cp ${builtins.toFile "config"            v2Fragment.configBlock}           $selfFrag/nix-support/v2-frag/config
      cp ${builtins.toFile "setup-constraints" (lib.concatMapStrings (s: s + "\n") v2Fragment.setupConstraints)} \
        $selfFrag/nix-support/v2-frag/setup-constraints
      cp ${pkgs.writeText "source-repo-block" v2Fragment.sourceRepoBlock} \
        $selfFrag/nix-support/v2-frag/source-repo-block

      # all-dep closure fragments (blocks scope): self + direct + transitive.
      declare -A seenBlk; blkFrags=()
      addBlk() { local f=$1; if [ -n "$f" ] && [ -d "$f/nix-support/v2-frag" ] && [ -z "''${seenBlk[$f]:-}" ]; then seenBlk[$f]=1; blkFrags+=("$f"); fi; }
      addBlk "$selfFrag"
      for dep in "''${pkgsHostTarget[@]}"; do
        addBlk "$dep"
        [ -f "$dep/nix-support/transitive-deps" ] && while IFS= read -r d; do addBlk "$d"; done < "$dep/nix-support/transitive-deps"
      done

      # depends-closure fragments (extra-packages + constraints scope).
      # Seeded purely from the library `depends` edges (`libDepSlices` =
      # the complete `dependsSlices`), walked transitively via each dep's
      # `lib-dep-slices` pointer.  `exe-depends` (build tools) are NOT
      # folded in here: they provide source via the repo but get no
      # constraints, so a build tool's own lib closure never lands in the
      # constraints scope.
      declare -A seenLib; libFrags=()
      addLib() { local f=$1; if [ -n "$f" ] && [ -d "$f/nix-support/v2-frag" ] && [ -z "''${seenLib[$f]:-}" ]; then seenLib[$f]=1; libFrags+=("$f"); fi; }
      ${lib.concatMapStrings (s: ''
        addLib ${s}
        [ -f ${s}/nix-support/lib-dep-slices ] && while IFS= read -r d; do addLib "$d"; done < ${s}/nix-support/lib-dep-slices
      '') v2Fragment.libDepSlices}

      # Emit "<pkg-name>\t<frag-dir>" name-sorted.
      # Emit one "<pkg-name>\t<frag-dir>" line per *pkg-name*, name-sorted.
      # `-k1,1 -u` dedups by pkg-name: a multi-sublib package contributes
      # several fragments (one per sublib slice) that all share the same
      # pkg-name and emit identical per-package content (block / constraint /
      # extra-package), so we keep just one — matching how the Nix side
      # dedups via `sliceCanonicalNames` / `libConstraintPins` (by name).
      sortedByName() { local f; for f in "$@"; do printf '%s\t%s\n' "$(cat "$f"/nix-support/v2-frag/pkg-name)" "$f"; done | sort -t"$(printf '\t')" -k1,1 -u; }

      # Is `<pkg> ==<ver>` (a fragment's version pin) already composed
      # into the staged store db?  Used below to route such deps through
      # the solver's installed-package index instead of the slicing repo
      # (empty-safe: composedDb is "" outside the staged layout).
      isComposedDep() {
        local vpin=$1 pv depConf
        [ -n "$composedDb" ] || return 1
        pv=''${vpin/ ==/-}
        for depConf in "$composedDb/$pv.conf" "$composedDb/$pv-"*.conf; do
          [ -e "$depConf" ] && return 0
        done
        return 1
      }

      {
        # extra-packages: self entry first, then lib-dep pins (name-sorted).
        epline=""; epsep=""
        ${lib.optionalString (v2Fragment.selfExtraPackage != "")
          ''epline=${lib.escapeShellArg v2Fragment.selfExtraPackage}; epsep=", "''}
        while IFS=$'\t' read -r name f; do
          [ -n "$name" ] || continue
          # Skip self: the local package is built from `packages:` (+
          # `selfExtraPackage` / `any.<pkg> source`).  Its own library
          # fragment can enter `libFrags` via `ownLibSlice` (kept in the
          # walk only to reach the library's transitive dep constraints);
          # also listing it as a repo `extra-packages` entry makes cabal's
          # target matcher ambiguous (Cabal-7130).
          [ "$name" = ${lib.escapeShellArg v2Fragment.pkgName} ] && continue
          # Source-repo packages are declared via source-repository-package
          # (below), not extra-packages — listing both makes the solver
          # consider the tarball candidate and fork the UnitId.
          [ -s "$f/nix-support/v2-frag/source-repo-block" ] && continue
          c=$(cat "$f"/nix-support/v2-frag/constraint)
          # An `extra-packages:` entry is a BUILD goal — the solver must
          # produce it from source, so an `installed` pin on it is
          # unsatisfiable.  Deps already composed into the staged store
          # db are reused as installed instances (see the constraints
          # loop below) and must NOT be listed here.
          isComposedDep "''${c%%,*}" && continue
          epline="$epline$epsep''${c%%,*}"; epsep=", "
        done < <(sortedByName "''${libFrags[@]}")
        [ -n "$epline" ] && echo "extra-packages: $epline"

        # Seven block groups, grouped by type, name-sorted across the closure.
        # `config` is the configuration-pragma delta against the skeleton's
        # `package *` baseline (v2-project-globals.nix `perPkgConfigBlocks`).
        for blk in config flags ghc-options configure-options program-options doc extra-lib-dirs; do
          while IFS=$'\t' read -r name f; do cat "$f/nix-support/v2-frag/$blk"; done < <(sortedByName "''${blkFrags[@]}")
        done
${lib.optionalString (metadataSourceFrags != []) ''
        # Plan flag assignments for metadata-staged (solver-only)
        # candidates — see `metadataFlagBlocks` (store file: the block
        # list is large and must stay out of the script's env).
        cat ${pkgsBuildBuild.writeText "hsnix-metadata-flags" metadataFlagBlocks}
''}
        # constraints: self `any.<pkg> source`, then lib-dep pins (name-sorted).
        echo "constraints: any.${v2Fragment.pkgName} source"
        while IFS=$'\t' read -r name f; do
          [ -n "$name" ] || continue
          # Self is pinned via `any.<pkg> source` above (it's the local
          # `packages:` target); don't re-pin it from its `ownLibSlice`
          # fragment.
          [ "$name" = ${lib.escapeShellArg v2Fragment.pkgName} ] && continue
          c=$(cat "$f"/nix-support/v2-frag/constraint)
          # Fragment pins are `<pkg> ==<ver>, <pkg> source` — the
          # `source` half made mainline cabal solve the dep from
          # source with plan-nix's unit-id, and the store-improvement
          # layer then skipped the actual rebuild.  The stable-haskell
          # fork has no such layer (see the solver-visibility block
          # above): when the dep's unit is already composed into the
          # store db, pin it `installed` instead so the solver reuses
          # that exact unit (its conf carries plan-nix's unit-id, so
          # downstream `--dependency=` hashes are unchanged).
          if isComposedDep "''${c%%,*}"; then
            c="''${c%%,*}, $name installed"
          fi
          echo "constraints: $c"
        done < <(sortedByName "''${libFrags[@]}")

        # Per-package custom-setup pins (`<pkg>:setup.<dep> ==<ver>`),
        # collected across the all-dep closure so Custom-build packages'
        # setups (notably their `Cabal`) resolve as plan-nix recorded —
        # keeping their unit-ids reproducible (e.g. ghc-paths).
        for f in "''${blkFrags[@]}"; do
          [ -f "$f/nix-support/v2-frag/setup-constraints" ] && \
            sed 's/^/constraints: /' "$f/nix-support/v2-frag/setup-constraints" || true
        done

        # source-repository-package blocks for source-repo packages in
        # the closure (deduped by name) — e.g. lib:ghc via useLocalGhcLib.
        while IFS=$'\t' read -r name f; do
          [ -s "$f/nix-support/v2-frag/source-repo-block" ] || continue
          # A source-repository-package block makes the package LOCAL —
          # always solved from source — which contradicts the `installed`
          # pin the constraints loop gives deps already composed into
          # the staged store db.  Skip the block for those; the slice's
          # own target keeps its block (it must build from source).
          if [ "$name" != ${lib.escapeShellArg v2Fragment.pkgName} ]; then
            c=$(cat "$f"/nix-support/v2-frag/constraint)
            isComposedDep "''${c%%,*}" && continue
          fi
          cat "$f/nix-support/v2-frag/source-repo-block"
        done < <(sortedByName "''${blkFrags[@]}")
      } > cabal.project.closure

      # local skeleton (via file — no shell escaping) + composed sections.
      # Use a redirect (not `cp`, which would create cabal.project with
      # the store file's read-only mode and break the `>>` append).
      cat ${builtins.toFile "local-cabal-project" v2Fragment.localCabalProject} > cabal.project
      cat cabal.project.closure >> cabal.project

    ''}

    # --- Build -------------------------------------------------------
    if [ ! -f cabal.project ]; then
      echo "ERROR: preBuild did not produce a cabal.project" >&2
      exit 1
    fi
    # Everything between the `preBuild` mark and this one is the
    # build-time cabal.project composition -- notably `isComposedDep`,
    # which globs the composed db once per lib-dep fragment, so this gap
    # grows with (deps x installed units) rather than with either alone.
    sliceMark "composed cabal.project ($(wc -l < cabal.project) lines)"
    echo "--- cabal.project ---"
    cat cabal.project
    # Dump the shim's .cabal too — its `build-depends` line is the
    # transitive lib-closure version pin set comp-v2-builder
    # synthesised, and is often what shapes cabal-install's solve.
    for shim_cabal in *.tar.gz; do
      case "$shim_cabal" in hs-nix-v2-shim-*.tar.gz)
        echo "--- $shim_cabal/hs-nix-v2-shim.cabal ---"
        tar -xOzf "$shim_cabal" --wildcards '*/hs-nix-v2-shim.cabal' 2>/dev/null \
          || tar -xOzf "$shim_cabal" hs-nix-v2-shim-0/hs-nix-v2-shim.cabal 2>/dev/null \
          || echo "(could not extract shim .cabal from $shim_cabal)"
        ;;
      esac
    done

    # cabal.project's `with-compiler:` only pins ghc; everything
    # else (`ghc-pkg`, `hsc2hs`, ...) has to come via CLI flags
    # because cabal.project doesn't accept `with-PROG` fields.
    # `--store-dir=` is a global flag and must come before the
    # subcommand; `--with-PROG=` flags belong to the subcommand and
    # must come after `v2-build` (otherwise cabal silently ignores
    # them and falls back to "near compiler" lookup, which fails for
    # cross GHCs that ship only prefixed binaries).
    cabalGlobalArgs="--store-dir=$storeDir"
    # `--builddir=$distDir` puts the dist tree in $out so paths the
    # stable-haskell fork bakes from `distStoreDirLayout` stay valid
    # after the build (see the staged-store-layout comment above).
    # comp-v2-builder's `trimDistNewstyle` clears the bulk out of $out
    # again, keeping the `store` symlink.
    cabalCmdArgs="--builddir=$distDir ${pkgConfigWithFlag}${crossWithFlags}${twoStageFlags}${withProgFlags}"
    # Match v1's `-j` behaviour: cap GHC's per-module parallelism at
    # 4 even when nix gives us more cores.  Going much wider tends to
    # thrash memory on big modules (cardano-ledger templates,
    # plutus-core deriving, etc.) and slow the overall build.
    #
    # cabal-install 3.16's `setupHsBuildFlags` deliberately sets
    # `buildNumJobs = mempty` (with a "TODO" upstream), so neither
    # `cabal v2-build --jobs` nor `--ghc-options=-jN` actually
    # parallelise per-module compilation: `--jobs` is package-level
    # only, and `--ghc-options=-jN` would land in
    # `pkgHashConfigureOptions` and break plan-nix UnitId matching.
    # Our `setup-build-num-jobs-env.patch` reads
    # `HASKELLNIX_BUILD_NUM_JOBS` from the env at build time and feeds
    # it to `Setup build -jN`.  Build-phase flag, so UnitIds stay
    # stable.
    export HASKELLNIX_BUILD_NUM_JOBS=$(($NIX_BUILD_CORES > 4 ? 4 : $NIX_BUILD_CORES))

    ${lib.optionalString (expectedPackage != null) ''
      # Dry-run the plan first and verify that cabal isn't planning
      # to build any package other than `expectedPackage`.  Anything
      # else is a dep cabal couldn't reuse from the composed
      # starting store — typically because some UnitId-hash input
      # (`--with-PROG=`, `package <n>` `ghc-options`,
      # `extra-(include|lib)-dirs`, dep UnitId, ...) diverged from
      # what produced that dep's slice.  Catching this early avoids
      # spending minutes rebuilding from source what should have
      # been a free store hit.
      echo "--- cabal v2-build --dry-run ${target} ---"
      # `plan.log` is parsed below, so stamp only what goes to the build
      # log: `tee` writes the clean copy, `sliceStamp` timestamps stdout.
      dryRunStart=$SECONDS
      time { cabal $cabalGlobalArgs v2-build $cabalCmdArgs --dry-run ${target} 2>&1 \
        | tee plan.log | sliceStamp; }
      dryRunSecs=$((SECONDS - dryRunStart))
      sliceMark "cabal v2-build --dry-run took ''${dryRunSecs}s (solve + elaborate, no building)"

      # A dry run is planning and nothing else, so if it is slow the cost
      # is in one of three places and they are not distinguishable from
      # the outside: reading the inputs (index + `ghc-pkg dump`), the
      # SOLVER searching, or elaboration.  `-v3` is the only thing that
      # tells them apart -- it is where cabal's modular solver prints its
      # `trying:` / `rejecting:` trace -- so re-run at `-v3` and digest
      # it, but only once we already know this slice is slow.  A solve
      # that prints a handful of steps and still takes minutes is NOT the
      # solver, and that negative result is the useful half of this.
      if [ "$dryRunSecs" -ge 60 ]; then
        sliceMark "SLOW PLAN: re-running --dry-run -v3 to find out where"
        timeout 900 cabal $cabalGlobalArgs v2-build $cabalCmdArgs \
          --dry-run -v3 ${target} > solver.log 2>&1 || true
        sliceMark "-v3 dry run captured $(wc -l < solver.log) lines"
        echo "[slice] solver steps (\"[__N] trying/rejecting\"): $(
          grep -c '^\[__[0-9]' solver.log || true)"
        echo "[slice]   trying:   $(grep -c 'trying:' solver.log || true)"
        echo "[slice]   rejecting: $(grep -c 'rejecting:' solver.log || true)"
        echo "[slice] packages the solver worked hardest on:"
        sed -n 's/.*rejecting: *\([^ ,(]*\).*/\1/p' solver.log \
          | sed 's/:.*//; s/-[0-9][0-9.]*$//' | sort | uniq -c | sort -rn \
          | head -15 | sed 's/^/[slice]   /'
        echo "[slice] last 40 lines before the plan was produced:"
        grep -v '^\[__[0-9]' solver.log | tail -40 | sed 's/^/[slice]   /'
        cp solver.log $buildRoot/solver.log || true
      fi

      # Parse the "In order, the following will/would be built:" block
      # — the per-package lines look like
      #   ` - foo-1.2.3 (lib) (requires build)`
      # — and split each `<pkg>-<ver>` token at the rightmost `-`
      # whose right-hand side starts with a digit.  Filter out
      # `expectedPackage` and any package in `allowedBuildToolPackages`
      # (transitive `build-tool-depends:` goals on cross, which the
      # solver always plans); whatever remains is a rebuild.
      expected_pkg=${lib.escapeShellArg expectedPackage}
      allowed_build_tools=${lib.escapeShellArg
        (lib.concatStringsSep " " allowedBuildToolPackages)}
      extras=$(awk -v expected="$expected_pkg" -v allowed="$allowed_build_tools" '
        BEGIN {
          n = split(allowed, a, " ")
          for (i = 1; i <= n; i++) allowed_set[a[i]] = 1
        }
        /^In order, the following / { capturing=1; next }
        capturing && /^$/ { capturing=0; next }
        capturing && /^ - / {
          pkg_ver = $2
          # The stable-haskell Cabal fork prints the plan with a per-unit stage
          # qualifier when a slice runs in two-stage mode (`--with-build-compiler`
          # present → "Toolchains: build/host"):
          #   ` - host rts-headers-1.0.3 (lib) (requires build)`
          # so the `<name>-<version>` token is $3, not $2.  Skip a leading stage
          # keyword.  (A real package is never named exactly build/host/target.)
          #
          # BUILD-stage units are tolerated wholesale: the fork elaborates
          # build tools (and their setup-style deps, e.g. the Cabal fork
          # for Custom setups) as inplace units of the consuming plan, so
          # the first slice that needs one legitimately builds it into the
          # composed store (where unit receipts let later slices reuse it).
          # Only HOST-stage extras indicate a real composition failure.
          if (pkg_ver == "build") next
          if (pkg_ver == "host" || pkg_ver == "target") pkg_ver = $3
          n = split(pkg_ver, parts, "-")
          for (i = n; i > 0; i--) if (parts[i] ~ /^[0-9]+(\.[0-9]+)*$/) break
          if (i <= 1) { name = pkg_ver }
          else {
            name = parts[1]
            for (j = 2; j < i; j++) name = name "-" parts[j]
          }
          if (name != expected && !(name in allowed_set)) print name
        }
      ' plan.log | sort -u)

      if [ -n "$extras" ]; then
        # Re-run cabal verbosely to capture the actual `Setup configure`
        # invocation cabal computed for each unexpected package.  The
        # `--cid=` and `--dependency=` lines on that command line ARE
        # cabal's UnitId hash inputs — comparing them with the
        # corresponding pre-installed unit's `.conf` makes the diverged
        # input visible at a glance.  We'd be running `cabal v2-build`
        # at this point anyway, so the only extra cost is the verbose
        # output.  (`|| true` because cabal will exit non-zero in the
        # presence of errors that the dev needs to see — we still want
        # to print the diagnostic.)
        echo "" >&2
        echo "[diagnostic] re-running cabal v2-build -v to capture setup" >&2
        echo "[diagnostic] configure args for the unexpected packages..." >&2
        cabal $cabalGlobalArgs v2-build $cabalCmdArgs -v ${target} > diag.log 2>&1 || true

        echo "" >&2
        echo "ERROR: cabal v2-build planned to build packages other than" >&2
        echo "$expected_pkg in this slice:" >&2
        printf '  - %s\n' $extras >&2
        echo "" >&2

        for pkg in $extras; do
          echo "==== $pkg ============================================" >&2

          # cabal's planned setup configure call.  Format:
          #   ["--working-dir=...","configure","--verbose=2",...]
          # Find the line that mentions tmp/src-N/<pkg>-<ver> (cabal
          # extracts each package into a unique src dir before calling
          # Setup configure), then split on `","` and print only the
          # hash-relevant args (`--cid=`, `--dependency=`,
          # `--flags=`, `--exact-configuration`, `--package-db=`).
          echo "" >&2
          echo "  cabal's Setup configure call (hash-relevant args):" >&2
          awk -v p="$pkg" '
            /^\[/ && $0 ~ "tmp/src-[0-9]+/" p "-[0-9]" {
              n = split($0, a, "\",\"")
              for (i = 1; i <= n; i++) {
                arg = a[i]
                gsub(/^\["/, "", arg)
                gsub(/"\]$/, "", arg)
                if (arg ~ /^--cid=/ \
                    || arg ~ /^--dependency=/ \
                    || arg ~ /^--flags?=/ \
                    || arg ~ /^-f / \
                    || arg ~ /^--package-db=/ \
                    || arg ~ /^--exact-configuration/ \
                    || arg ~ /^--ghc-option=/) {
                  print "    " arg
                }
              }
              exit
            }
          ' diag.log >&2

          # Pre-installed units in the starting store with the same
          # name.  cabal would have reused these if any of their
          # UnitIds matched what cabal computed above; the fact that
          # this branch fired means none did, so the diff between the
          # `--dependency=` list and each unit's `depends:` line is
          # the smoking gun.  Filter to symlink confs only — those are
          # the originals composed in via lndir.  Real-file confs at
          # this point come from the diagnostic v2-build run we just
          # made and would just clutter the listing.
          echo "" >&2
          echo "  Pre-installed unit(s) for $pkg in the starting store:" >&2
          found=0
          for conf in $ghcDir/$storePkgDb/*.conf; do
            [ -L "$conf" ] || continue
            pname=$(awk '$1=="name:"{print $2; exit}' "$conf")
            [ "$pname" = "$pkg" ] || continue
            found=1
            id=$(awk '$1=="id:"{print $2; exit}' "$conf")
            version=$(awk '$1=="version:"{print $2; exit}' "$conf")
            # `depends:` may span multiple lines (continuation indent)
            depends=$(awk '
              /^depends:/ { flag=1; sub(/^depends:[[:space:]]*/, ""); printf "%s ", $0; next }
              flag && /^[[:space:]]/ { printf "%s ", $0; next }
              flag { exit }
            ' "$conf" | xargs)
            echo "    id:       $id" >&2
            echo "    version:  $version" >&2
            echo "    depends:  $depends" >&2
            echo "    .conf:    $conf" >&2
            echo "" >&2
          done
          if [ "$found" = 0 ]; then
            echo "    (no pre-installed unit with this package name)" >&2
            echo "" >&2
          fi
        done

        echo "" >&2
        echo "A UnitId is a hash of cabal's Setup configure args, so the" >&2
        echo "ones that drift between slices are usually:" >&2
        echo "  * --dependency=<dep>=<dep-unit-id> — a transitive dep" >&2
        echo "    is resolving to a different UnitId, often because" >&2
        echo "    cabal in this slice picks a GHC-bundled" >&2
        echo "    (\"-inplace\") version while the dep's standalone" >&2
        echo "    slice picked a reinstalled version (or vice versa)." >&2
        echo "    Pin the version in cabal.project's constraints." >&2
        echo "  * --flags=... — flag assignment differs.  Check the" >&2
        echo "    \`package <n>\\n  flags:\` blocks emitted by" >&2
        echo "    \`comp-v2-builder.flagBlockFor\`." >&2
        echo "  * --ghc-option=... — \`package <n>\\n  ghc-options:\`" >&2
        echo "    blocks differ.  Check \`perPackageOptionOf\` and" >&2
        echo "    \`configure-args.nix\`'s plan-id-keyed entries." >&2
        exit 1
      fi
    ''}

    ${if dryRunOnly then ''
      # `dryRunOnly` mode: stop after planning so the diagnostic in
      # `installPhase` can compare cabal's `dist-newstyle/cache/plan.json`
      # against plan-nix without the cost (and the failure modes) of
      # the actual build.  Only used by the `.checkAgainstPlan`
      # sibling drv.
      echo "--- cabal v2-build --dry-run ${target} (dryRunOnly) ---"
      time { cabal $cabalGlobalArgs v2-build $cabalCmdArgs --dry-run ${target} 2>&1 \
        | tee $buildRoot/build.log | sliceStamp; } || true
      sliceMark "cabal v2-build --dry-run (dryRunOnly)"
    '' else ''
      # `cabal v2-build` accepts remote-package component targets
      # (e.g. `:pkg:foo:lib:sublibname`) as long as the package is
      # listed via `extra-packages:` in cabal.project AND its tarball
      # is in the slicing repo's index — both conditions are met by
      # comp-v2-builder for non-shim slices.
      echo "--- cabal v2-build ${target} ---"
      time { cabal $cabalGlobalArgs v2-build $cabalCmdArgs -v ${target} 2>&1 \
        | tee $buildRoot/build.log | sliceStamp; }
      sliceMark "cabal v2-build"
      ${lib.optionalString doHaddock ''
        echo "--- cabal v2-haddock ${target} ---"
        time { cabal $cabalGlobalArgs v2-haddock $cabalCmdArgs \
          --haddock-html --haddock-hyperlink-source --haddock-quickjump \
          ${target} 2>&1 | tee -a $buildRoot/build.log | sliceStamp; }
        sliceMark "cabal v2-haddock"
        # Cabal `v2-haddock` installs the main library's html into
        # the unit-store `<unit>/share/doc/html/`, but for
        # sublibraries it only emits the html under the per-package
        # working dist dir at
        # `dist-newstyle/tmp/src-*/<pkg>-<ver>/dist/doc/html/<pkg>/<sublib>/`
        # — and then cabal wipes that tmp dir before the slice's
        # `installPhase` runs.  Capture the html here (still in the
        # buildPhase) and copy it into the sublib unit's
        # `share/doc/html/` so the doc slice matches the main-lib
        # layout for downstream consumers.
        tgt_pkg=$(printf '%s' ${lib.escapeShellArg target} | awk -F: '{print $3}')
        tgt_cname=$(printf '%s' ${lib.escapeShellArg target} | awk -F: '{print $5}')
        if [ "$tgt_cname" != "$tgt_pkg" ]; then
          sublib_html_src=$(find $distDir/tmp \
                              -path "*/dist/doc/html/$tgt_pkg/$tgt_cname" \
                              -type d -print -quit 2>/dev/null || true)
          if [ -n "$sublib_html_src" ]; then
            # The sublib's conf was just written by `cabal v2-build`'s
            # register step before `v2-haddock` ran; find its uid by
            # the cabal-mangled `z-<pkg>-z-<sublib>` name.  Re-discover
            # first: if the composed starting store was empty, cabal
            # created the store dir during the build we just ran.
            discoverStore
            for conf in $ghcDir/$storePkgDb/*.conf; do
              [ -e "$conf" ] || continue
              if [ "$(awk '/^name:/ {print $2; exit}' "$conf")" \
                   = "z-$tgt_pkg-z-$tgt_cname" ]; then
                target_uid=$(awk '/^id:/ {print $2; exit}' "$conf")
                ghc_dir=$(dirname "$(dirname "$conf")")
                target_html_dir="$ghc_dir/$target_uid/share/doc/html"
                mkdir -p "$target_html_dir"
                chmod -R u+w "$target_html_dir"
                cp -rL "$sublib_html_src"/. "$target_html_dir/"
                break
              fi
            done
          fi
        fi
      ''}
    ''}
  '';

  installPhase = if dryRunOnly then ''
    set -euo pipefail

    # `dryRunOnly` install: capture cabal's planned plan.json (and,
    # when `planNixJsonFile` was passed, diff each entry against
    # plan-nix).  Always exits 0 so the diagnostic remains
    # inspectable even when cabal's planning fails.
    mkdir -p $out
    cp $buildRoot/build.log $out/build.log 2>/dev/null || true
    # Only written when the plan was slow enough to trigger the -v3
    # re-run (see buildPhase); keeps the full solver trace for a
    # slice whose log has already scrolled past.
    cp $buildRoot/solver.log $out/solver.log 2>/dev/null || true

    # Capture the slice's cabal.project verbatim, plus every shim
    # `.cabal` file extracted from a `hs-nix-v2-shim-*.tar.gz` staged
    # in the project dir.  The shim's `build-depends` line carries
    # the transitive lib-dep version pins comp-v2-builder synthesised
    # — diffing it against plan-nix's resolved versions is often the
    # quickest way to see why the solver chose a different unit-id.
    if [ -f $buildRoot/project/cabal.project ]; then
      cp $buildRoot/project/cabal.project $out/cabal.project
    fi
    for shim_cabal in $buildRoot/project/*.tar.gz; do
      [ -f "$shim_cabal" ] || continue
      case "$shim_cabal" in
        */hs-nix-v2-shim-*.tar.gz)
          base=$(basename "$shim_cabal" .tar.gz)
          tar -xOzf "$shim_cabal" --wildcards '*/hs-nix-v2-shim.cabal' \
            > $out/$base.cabal 2>/dev/null \
            || tar -xOzf "$shim_cabal" "$base/hs-nix-v2-shim.cabal" \
              > $out/$base.cabal 2>/dev/null \
            || rm -f $out/$base.cabal
          ;;
      esac
    done

    actualPlan=$distDir/cache/plan.json
    if [ -f "$actualPlan" ]; then
      cp "$actualPlan" $out/plan.json
    fi

    ${lib.optionalString (planNixJsonFile != null) ''
      cp ${planNixJsonFile} $out/plan-nix.json
      diffReport=$out/diff-report.txt
      : > "$diffReport"

      if [ ! -f "$actualPlan" ]; then
        echo "(no dist-newstyle/cache/plan.json — cabal failed to plan)" \
          > "$diffReport"
        exit 0
      fi

      # For each `configured` entry in the slice's plan.json, find a
      # matching entry in plan-nix (by id, otherwise by pkg-name +
      # component-name + component-type) and emit a `jq -S | diff`
      # with full file context.  Pre-existing / cabal-shim entries
      # are skipped (no comparable plan-nix entry).
      jq -c '.["install-plan"] | .[] | select(.type == "configured")' \
        "$actualPlan" \
      | while IFS= read -r actualEntry; do
          actualId=$(echo "$actualEntry" | jq -r '.id')
          pkgName=$(echo "$actualEntry" | jq -r '."pkg-name" // empty')
          # Find plan-nix entry: id match first, otherwise by
          # pkg-name + component-name + component-type.
          expectedEntry=$(jq --arg id "$actualId" --argjson actual "$actualEntry" '
            (map(select(.id == $id)) | .[0]) //
            (map(select(
                ."pkg-name"   == ($actual."pkg-name") and
                ."pkg-version"== ($actual."pkg-version") and
                (."component-name" // null) == ($actual."component-name" // null) and
                (."component-type" // null) == ($actual."component-type" // null)
            )) | .[0]) //
            empty
          ' ${planNixJsonFile})
          {
            echo "=========================================================="
            echo "$pkgName  (actual id: $actualId)"
            echo "=========================================================="
            if [ -z "$expectedEntry" ]; then
              echo "(no plan-nix entry for $pkgName / $actualId)"
              echo
              echo "actual:"
              echo "$actualEntry" | jq -S .
              continue
            fi
            diff -U 1000000 \
              <(echo "$expectedEntry" | jq -S .) \
              <(echo "$actualEntry"   | jq -S .) || true
            echo
          } >> "$diffReport"
        done
      echo "Plan diff report: $diffReport" >&2
    ''}

    exit 0
  '' else ''
    set -euo pipefail

    # `$out/store` is the cabal store dir we built into (composed
    # via `lndir` from the dep slices, with cabal's new units
    # written as real files alongside the symlinks).  Real files
    # are ours; symlinks are dep-slice content that we just leave
    # in place so downstream consumers can follow them back to the
    # original dep slices.
    # KEEP the staged-layout alias (`build` → `host`).  It used to be
    # dropped here, on the grounds that every consuming slice re-creates it
    # and that leaving it made `lndir` traverse the store twice downstream.
    # The first half is true of the CONSUMER's store; it is not true of the
    # paths cabal bakes into artifacts.  A BUILD-stage tool's `Paths_<pkg>`
    # datadir is spelled `<this slice>/dist-newstyle/store/build/<plat>/
    # lib/<unit>/share` -- an absolute path into THIS output -- so deleting
    # the alias left it dangling for good:
    #   alex: .../store/build/.../alex-3.5.4.2-.../share/AlexTemplate.hs:
    #         openFile: does not exist
    # (`ghc-lib-ghc-<triple>`, where genprimopcode's lexer runs alex).  The
    # host-stage units were never affected -- their baked paths say `host/`,
    # which is the real directory.
    # The double-traversal it was avoiding is handled in the buildPhase
    # instead: the compose step skips a dep's `build` entry by name, so
    # nothing follows the alias and `build/` is never materialised.
    # The fork's staged install leaves `<unit>.lock` files directly in
    # the store dir (its `storeIncomingDirectory` IS the store dir);
    # they're staging debris like `incoming/` below.
    rm -f $out/store/host/*/*.lock 2>/dev/null || true
    # `host/` was pre-created for the stage-unifying `build` link; with
    # the mainline (ghc-*) layout it stays empty — drop it (rmdir only
    # removes empty dirs), and the alias with it, or the output would ship
    # a `build` symlink pointing at a directory that is no longer there.
    if rmdir $out/store/host 2>/dev/null; then
      rm -f $out/store/build
    fi
    discoverStore
    if [ -z "$ghcDir" ]; then
      rm -rf $out/store
      mkdir -p $out
    else
      ${lib.optionalString solverIncludesGlobalDb ''
        # Drop the solver-visibility global-conf symlinks injected at
        # the start of the buildPhase (see the block above the
        # solver-tools wrapper) — they point into $buildRoot and would
        # ship dangling.  Symlinks only; real confs are the slice's own.
        shopt -s nullglob
        for conf in $ghcDir/$storePkgDb/*.conf; do
          [ -L "$conf" ] || continue
          case "$(readlink "$conf")" in
            "$buildRoot"/global-conf-snapshot/*) rm "$conf" ;;
          esac
        done
        shopt -u nullglob
      ''}
      : > $buildRoot/captured-unit-ids

      # ---- Walk new confs --------------------------------------
      # Real files (not symlinks) are units cabal installed in this
      # slice.  Record them as captured.
      for conf in $ghcDir/$storePkgDb/*.conf; do
        [ -e "$conf" ] || continue
        [ -L "$conf" ] && continue        # dep-slice symlink, not ours
        base=$(basename $conf)
        unitId=''${base%.conf}
        echo "$unitId" >> $buildRoot/captured-unit-ids
        echo "captured store unit: $unitId"
      done

      # ---- Walk new unit dirs (incl. bin-only) ------------------
      # `lndir` materialised dep-slice unit dirs as real
      # directories full of symlinked files.  A "new" unit dir is
      # one that didn't exist before cabal ran (recorded in the
      # `unitdirs-before` snapshot).  Record bin-only units (exe /
      # test / bench, no .conf in the package db) as captured.
      for unitDir in $ghcDir/*/; do
        [ -d "$unitDir" ] || continue
        unitId=$(basename "$unitDir")
        case "$unitId" in
          # `bin` and `etc` are the staged layout's flat bindir /
          # sysconfdir, not unit dirs.
          lib|bin|etc|units|package.db|package.conf.d|incoming) continue ;;
        esac
        if grep -qx -- "$unitId" $buildRoot/unitdirs-before 2>/dev/null; then
          continue
        fi
        if [ ! -f $ghcDir/$storePkgDb/$unitId.conf ]; then
          echo "$unitId" >> $buildRoot/captured-unit-ids
          echo "captured store unit: $unitId (bin-only)"
        fi
      done

      # ---- Walk new flat-bin executables -----------------------
      # The stable-haskell fork's staged layout installs exe units
      # into the FLAT `<ghcDir>/bin/` (`bindir = pkgroot </> "bin"`),
      # not a per-unit dir — so an exe the slice built is invisible
      # to both walks above (no `.conf`, no new unit dir).  Identify
      # new entries by diff against the `bin-before` snapshot and map
      # each to its unit id through the slice's own elaborated plan.
      if [ -d "$ghcDir/bin" ] && [ -f "$distDir/cache/plan.json" ]; then
        ( cd $ghcDir/bin && ls 2>/dev/null ) > $buildRoot/bin-after || true
        while IFS= read -r newBin; do
          [ -n "$newBin" ] || continue
          # HOST-stage entries only: the dir we diffed is the HOST
          # staged store, and in a two-stage plan the same exe name can
          # exist in both stages under different unit ids.
          uid=$(jq -r --arg exe "exe:$newBin" \
            '.["install-plan"][]
             | select(.["component-name"] == $exe and ((.stage // "host") == "host"))
             | .id' \
            "$distDir/cache/plan.json" 2>/dev/null | head -n1)
          # The fork's elaborated plan carries a stage prefix on unit
          # ids (`host:alex-…`); store paths, confs, and plan-nix all
          # use the bare id — strip it.
          uid=''${uid#host:}
          uid=''${uid#build:}
          if [ -n "$uid" ] && [ "$uid" != "null" ] \
             && ! grep -qx -- "$uid" $buildRoot/captured-unit-ids; then
            echo "$uid" >> $buildRoot/captured-unit-ids
            echo "captured store unit: $uid (flat bin)"
          fi
        done < <(comm -13 <(sort $buildRoot/bin-before) <(sort $buildRoot/bin-after))
      fi

      # ---- BUILD-stage units captured this build ----------------
      # The fork stage-qualifies every goal; SETUP scopes (and build
      # tools) are BUILD-stage.  A custom setup that `setup-depends`
      # on a local/inplace-style package — the haskell-gi family,
      # where gi-gmodule's Setup imports gi-glib — makes cabal plan
      # and build a BUILD-stage copy of that dep in-slice, by design
      # (the same in-slice tool building the two-stage cross plans
      # do; plan-nix's make-install-plan elaborates the same way, so
      # the slice's own unit id is unaffected — its HOST lib deps
      # still resolve to the composed units).  On native the stage-
      # unifying store link makes those units land in the host store
      # dir, so the walks above capture them.  Record their bare ids
      # so the unit-id checks below can tolerate them.
      : > $buildRoot/build-stage-unit-ids
      : > $buildRoot/host-stage-unit-ids
      if [ -f "$distDir/cache/plan.json" ]; then
        jq -r '.["install-plan"][]
               | select(.stage == "build")
               | .id | sub("^(host|build):"; "")' \
          "$distDir/cache/plan.json" 2>/dev/null | sort -u \
          > $buildRoot/build-stage-unit-ids || true
        jq -r '.["install-plan"][]
               | select((.stage // "host") == "host")
               | .id | sub("^(host|build):"; "")' \
          "$distDir/cache/plan.json" 2>/dev/null | sort -u \
          > $buildRoot/host-stage-unit-ids || true
      fi

      # ---- Evict BUILD-stage byproducts from $out ----------------
      # They exist so THIS slice's setup / build tools could run;
      # SHIPPING them poisons downstream slices: a consumer's fork
      # sees the plan-id conf already installed and skips its own
      # in-slice build-stage build, but byproducts don't reliably
      # carry their files through consumer-of-consumer composition
      # (leksah: haskell-gi's setup compile found a stale
      # cabal-doctest conf with no files behind it).  Consuming
      # slices rebuild build-stage goals from the composed repo
      # source instead — exactly what two-stage cross plans do.
      # Deterministic-id packages can appear in BOTH stages of the
      # slice's plan under one bare id — never evict those (the
      # host unit owns the id in the store).
      if [ -s $buildRoot/build-stage-unit-ids ]; then
        while IFS= read -r uid; do
          [ -n "$uid" ] || continue
          grep -qx -- "$uid" $buildRoot/host-stage-unit-ids && continue
          grep -qx -- "$uid" $buildRoot/captured-unit-ids || continue
          echo "evicting build-stage byproduct: $uid"
          rm -f "$ghcDir/$storePkgDb/$uid.conf"
          rm -f "$ghcDir/units/$uid"
          if [ -d "$ghcDir/$uid" ]; then
            chmod -R u+w "$ghcDir/$uid" 2>/dev/null || true
            rm -rf "$ghcDir/$uid"
          fi
          grep -vx -- "$uid" $buildRoot/captured-unit-ids \
            > $buildRoot/captured-unit-ids.tmp || true
          mv $buildRoot/captured-unit-ids.tmp $buildRoot/captured-unit-ids
        done < $buildRoot/build-stage-unit-ids
      fi

      # ---- Drop cabal's `incoming/` staging area ---------------
      # `incoming/` is cabal's per-build install staging dir and
      # has nothing useful for downstream consumers.  Leaving it in
      # `$out` would lndir into the next slice's compose with the
      # read-only /nix/store mode bits, blocking cabal there from
      # creating its own `incoming/<unit>.lock` files.  Cabal
      # leaves the dir mode 555 after install, so chmod it
      # writable before rm — on darwin's sandbox even root
      # otherwise can't unlink inside it.
      if [ -d "$ghcDir/incoming" ]; then
        chmod -R u+w "$ghcDir/incoming" 2>/dev/null || true
        rm -rf "$ghcDir/incoming"
      fi

      if [ -z "$(ls $ghcDir/$storePkgDb/ 2>/dev/null)" ] \
         && [ "$(ls $ghcDir/ 2>/dev/null | wc -l)" -le 1 ]; then
        rm -rf $out/store
      else
        # Cabal bakes the absolute store-dir path into conf files
        # for the units it just installed.  Rewrite to ''${pkgroot}
        # so the conf is relocatable when downstream slices
        # re-compose it.  We only touch real (non-symlink) confs —
        # dep-slice confs were already rewritten by their producing
        # slice.  Two spellings can appear: the physical `$ghcDir`
        # (mainline, baked from `--store-dir`) and the dist-store
        # route through the `$distDir/store` symlink (the fork bakes
        # everything from `distStoreDirLayout`).
        storePrefix="$ghcDir"
        distStorePrefix="$distDir/store/''${ghcDir#$out/store/}"
        for conf in $ghcDir/$storePkgDb/*.conf; do
          [ -e "$conf" ] || continue
          [ -L "$conf" ] && continue
          sed -i -e "s|$distStorePrefix|\''${pkgroot}|g" \
                 -e "s|$storePrefix|\''${pkgroot}|g" $conf
          ${lib.optionalString (confLibraryDirs != []) ''
            # Append the slice's foreign-lib paths (from
            # `component.libs` — openssl, libsodium, ...) to the
            # .conf's `library-dirs:` / `library-dirs-static:` /
            # `dynamic-library-dirs:` fields.  GHC's runtime linker
            # uses these to dlopen each `extra-libraries:` entry
            # (e.g. `extra-libraries: ssl crypto` → `libssl.so`),
            # which would otherwise fail with `cannot open shared
            # object file` under `-fexternal-interpreter` because
            # neither cabal nor `ghc-iserv` carries the dirs in
            # its RPATH.  v1 baked these into the .conf via
            # `make-config-files.nix:flagsAndConfig "extra-lib-dirs"`;
            # in v2 we post-process after `cabal v2-build` registers
            # the unit so the unit-id stays equal to plan-nix's
            # (passing `--extra-lib-dirs` to `Setup configure`
            # would land in `pkgHashExtraLibDirs` and fork the
            # hash from plan-nix).
            for field in library-dirs library-dirs-static dynamic-library-dirs; do
              ${lib.concatMapStrings (p: ''
                sed -i "/^$field:/a\\    ${p}" $conf
              '') confLibraryDirs}
            done
          ''}
        done
        ${ghcPkgBin} --package-db=$ghcDir/$storePkgDb recache
      fi
    fi

    # dist-newstyle is already in $out — the build ran with
    # `--builddir=$distDir` — so callers can grab exes etc. from it
    # directly (comp-v2-builder's `trimDistNewstyle` clears the bulk
    # later, keeping the `store` symlink and lifting plan.json).

    # `cabal v2-haddock` writes html into the haddocked unit's
    # `$out/store/<ghc>/<unit-id>/share/doc/html/` — the same
    # cabal-store layout the rest of the slice's `$out/store/`
    # already uses, so the doc slice can be `lndir`'d into
    # `~/.cabal/store/` without reshaping.  Cross-package
    # hyperlinks in the generated html are *absolute*
    # `file:///nix/store/<doc-slice>/store/<ghc>/<unit-id>/share/doc/html/...`
    # urls (haddock embeds the build-time `--read-interface=` path),
    # so they resolve back into the doc slice's own `$out/store/`
    # tree on the same host.  We deliberately don't synthesise a
    # stable `share/doc/html` symlink elsewhere — there is nothing
    # to gain by hiding the unit-id.

    ${lib.optionalString doHaddock ''
      # cabal v2-haddock emits html into every unit it touches —
      # the target plus every dep it haddock'd to satisfy
      # `--read-interface`.  We only want the target's html in
      # this slice's $out/store; deps' html lives in the deps'
      # own `.doc` slices.  Identify the target unit by the
      # conf's `name:` field — main libs use the plain pkg name,
      # sublibs use the cabal-mangled `z-<pkg>-z-<sublib>` form
      # — and strip `share/doc/` from every other unit dir.
      targetSpec=${lib.escapeShellArg target}
      tgt_pkg=$(printf '%s' "$targetSpec" | awk -F: '{print $3}')
      tgt_cname=$(printf '%s' "$targetSpec" | awk -F: '{print $5}')
      if [ "$tgt_cname" = "$tgt_pkg" ]; then
        expected_name="$tgt_pkg"
      else
        expected_name="z-$tgt_pkg-z-$tgt_cname"
      fi
      # Only consider confs this slice wrote — dep-slice confs are
      # lndir'd in as symlinks (see the `captured store unit` loop
      # near line 1004 that uses the same check).  Without this,
      # when a doc slice has both the base (non-doc) main-lib
      # composed in via depSlices AND its own doc-variant of the
      # same package, the first lexicographic match wins
      # (`5836f819` from the base slice vs `bb5ba586` this slice's
      # --cid).  Whichever it is, the loop's `break` may pick the
      # base-slice's conf — then we'd strip docs from this slice's
      # own --cid unit, which is exactly where cabal v2-haddock
      # installed them.
      target_uid=
      for conf in $ghcDir/$storePkgDb/*.conf; do
        [ -e "$conf" ] || continue
        [ -L "$conf" ] && continue
        name_in_conf=$(awk '/^name:/ {print $2; exit}' "$conf")
        if [ "$name_in_conf" = "$expected_name" ]; then
          target_uid=$(awk '/^id:/ {print $2; exit}' "$conf")
          break
        fi
      done
      if [ -n "$target_uid" ]; then
        for unit_dir in $ghcDir/*/; do
          uid=$(basename "$unit_dir")
          case "$uid" in
            package.db|package.conf.d|incoming|lib|bin|etc|units) continue ;;
          esac
          if [ "$uid" != "$target_uid" ] && [ -d "$unit_dir/share/doc" ]; then
            chmod -R u+w "$unit_dir/share/doc" 2>/dev/null || true
            rm -rf "$unit_dir/share/doc"
          fi
        done
      else
        echo "WARN: doc slice could not locate the target unit" \
             "($expected_name) in the package db; not stripping" \
             "non-target haddocks." >&2
      fi
    ''}

    # Emit the UnitIds this slice's build produced, one per line.
    # Useful for:
    #   - diagnostics / downstream verification that the expected
    #     unit was actually built
    #   - distinguishing slices that share a cabal UnitId but were
    #     built with different ghc-options etc. (since cabal's
    #     UnitId doesn't hash everything that affects compiled
    #     bytes, two slices can collide here even when their nix
    #     store paths differ — emitting the UnitId makes the
    #     collision visible).
    if [ -s $buildRoot/captured-unit-ids ]; then
      cp $buildRoot/captured-unit-ids $out/unit-ids
    else
      : > $out/unit-ids
    fi

    # Emit the transitive set of dep slices this slice was composed
    # from.  Format: one slice store path per line, sorted, no
    # duplicates.  Downstream consumers list this slice as a *direct*
    # buildInput and read the file to bring in the indirect ones —
    # so transitive closure stays out of the nix-side eval.
    mkdir -p $out/nix-support
    {
      for dep in "''${pkgsHostTarget[@]}"; do
        if [ -d "$dep/store" ]; then
          echo "$dep"
          if [ -f "$dep/nix-support/transitive-deps" ]; then
            cat "$dep/nix-support/transitive-deps"
          fi
        fi
      done
    } | sort -u > $out/nix-support/transitive-deps

    ${lib.optionalString (v2Fragment != null) ''
      # --- v2 build-time-composition fragment (additive; STEP 1) -----
      # This package's own contribution, for a downstream slice to
      # compose the slicing repo + cabal.project at *build* time by
      # following pointer files — no Nix-side dep-graph walk.
      mkdir -p $out/repo-frag/package \
               $out/repo-frag/index/${v2Fragment.pkgName}/${v2Fragment.pkgVersion} \
               $out/nix-support/v2-frag
      # Source tarball (symlink — keeps the fragment a tiny set of links).
      ln -s ${v2Fragment.tarball} \
        $out/repo-frag/package/${v2Fragment.pkgName}-${v2Fragment.pkgVersion}.tar.gz
      # Index `.cabal`: the untouched revision override when present,
      # otherwise the effective tarball metadata (byte-identical, so
      # cabal keeps `pkgHashPkgDescriptionHash` Nothing).
      ${stageCabalFile {
        fragment = v2Fragment;
        target = "$out/repo-frag/index/${v2Fragment.pkgName}/${v2Fragment.pkgVersion}/${v2Fragment.pkgName}.cabal";
      }}
      ${metadataFragExport}
      # Per-package cabal.project blocks (emitted as separate files so a
      # consumer can group by block-type across the closure, matching the
      # current cabal.project byte-layout).  Written via `toFile` so the
      # multi-line block text needs no shell escaping.
      printf '%s' ${lib.escapeShellArg v2Fragment.pkgName}        > $out/nix-support/v2-frag/pkg-name
      cp ${builtins.toFile "flags"             v2Fragment.flagsBlock}            $out/nix-support/v2-frag/flags
      cp ${builtins.toFile "ghc-options"       v2Fragment.ghcOptionsBlock}       $out/nix-support/v2-frag/ghc-options
      cp ${builtins.toFile "configure-options" v2Fragment.configureOptionsBlock} $out/nix-support/v2-frag/configure-options
      cp ${builtins.toFile "program-options"   v2Fragment.programOptionsBlock}   $out/nix-support/v2-frag/program-options
      cp ${builtins.toFile "doc"               v2Fragment.docBlock}              $out/nix-support/v2-frag/doc
      cp ${builtins.toFile "extra-lib-dirs"    v2Fragment.extraLibDirsBlock}     $out/nix-support/v2-frag/extra-lib-dirs
      cp ${builtins.toFile "config"            v2Fragment.configBlock}           $out/nix-support/v2-frag/config
      printf '%s' ${lib.escapeShellArg v2Fragment.constraintLine} > $out/nix-support/v2-frag/constraint
      cp ${builtins.toFile "setup-constraints" (lib.concatMapStrings (s: s + "\n") v2Fragment.setupConstraints)} \
        $out/nix-support/v2-frag/setup-constraints
      cp ${pkgs.writeText "source-repo-block" v2Fragment.sourceRepoBlock} \
        $out/nix-support/v2-frag/source-repo-block
      # Flattened depends-closure pointer (the constraints scope).
      # Seeds purely from this slice's DIRECT library `depends`
      # (`libDepSlices` = `dependsSlices`); transitivity is accumulated
      # here at build time (like `transitive-deps`): each direct dep slice
      # is pinned (echoed) and its own flattened pointer folded in, so
      # following any dep's pointer reaches every transitive library dep.
      # `exe-depends` (build tools) are deliberately NOT folded in — they
      # contribute source via the repo but never enter the constraints
      # scope.
      {
        ${lib.concatMapStrings (s: ''
          echo ${s}
          if [ -f ${s}/nix-support/lib-dep-slices ]; then
            cat ${s}/nix-support/lib-dep-slices
          fi
        '') v2Fragment.libDepSlices}
        : # ensure the brace group is non-empty when there are no deps
      } | sort -u > $out/nix-support/lib-dep-slices
    ''}

    # Drop the package-db cache files from $out.  They're real files
    # `ghc-pkg recache` regenerated for this slice's specific composed
    # package.db, but downstream consumers compose a *different* set
    # of confs and run their own `recache`, so this cache is always
    # stale on arrival.  Leaving it in $out also means every dep
    # slice's `package.cache` collides at lndir time in the consumer
    # ("Keeping existing link to ..." spam scaling O(deps) per
    # consumer).  Cheaper to delete now and let downstream recreate.
    if [ -n "$ghcDir" ]; then
      rm -f $ghcDir/$storePkgDb/package.cache \
            $ghcDir/$storePkgDb/package.cache.lock
    fi

    # Clear dep-slice content out of $out/store now that this slice's
    # own unit is captured.  Downstream consumers don't read another
    # slice's $out/store directly — they walk
    # `nix-support/transitive-deps` and lndir each entry's $out/store
    # back into their own composed cabal-store.  So all the
    # lndir-composed dep symlinks (and the dep-slice unit dirs they
    # populated) are pure overhead in this slice's $out: fixupPhase
    # walks every entry, NAR serialisation `lstat`s every entry, and
    # Nix's reference scan follows them.  A deep dep graph leaves
    # 10k+ symlinks in here.
    #
    # When ghc links a shared library it bakes the composed-store
    # path into the `.so`'s DT_RUNPATH / Mach-O LC_RPATH (e.g.
    # `<this-slice>/store/.../<dep-uid>/lib`) so iserv-dyn / dyld
    # can resolve a dep's transitive `.so` deps at TH-eval time.
    # Plain "wipe the dep dirs" would leave the rpath pointing at
    # nothing — `shrink-rpath` (fixupPhase) drops the entry and
    # downstream dyld load fails with `No such file or directory`.
    # Rewrite our own ELF/Mach-O files' rpath entries to point at
    # the dep slice's actual /nix/store path (resolved through the
    # lndir symlink), then wipe the dep dirs.  shrink-rpath sees
    # entries pointing at real, populated dirs and keeps them.
    if [ -n "$ghcDir" ]; then
      # Identify the slice's own captured unit-ids — for the
      # typical known-uid case this is `expectedUnitId`; for the
      # unknown case (source-repo / local / Custom-Build packages)
      # it's the set cabal actually installed.
      ${if expectedUnitId == null then ''
        mapfile -t own_uids < $buildRoot/captured-unit-ids
      '' else ''
        own_uids=(${lib.escapeShellArg expectedUnitId})
      ''}

      # Rewrite RPATH entries that point into `$out/store/` (the
      # lndir-composed dep tree we're about to delete).  For each
      # such entry, resolve a symlinked file under it via
      # `readlink -f` and take that file's `dirname` — that's the
      # dep slice's own `/nix/store/<dep-slice>/store/.../<dep-uid>/lib`
      # path.  Entries that don't point into `$out/store/` (system
      # libs, $ORIGIN, ...) are left alone.
      ${let
        elfRewrite = ''
          rewrite_rpath_elf() {
            local f="$1"
            local old new entry resolved child tgt
            # `|| return 0` skips statically-linked ELF binaries
            # (e.g. musl `executable-static: True` exes — patchelf
            # bails out with "cannot find section `.dynamic`").
            old=$(patchelf --print-rpath "$f" 2>/dev/null) || return 0
            [ -n "$old" ] || return 0
            new=""
            local IFS=':'
            for entry in $old; do
              [ -n "$entry" ] || continue
              # Normalise the fork's dist-store spelling (baked via
              # the `$distDir/store` symlink) to the physical store
              # path before matching.
              if [[ "$entry" == "$distDir/store/"* ]]; then
                entry="$out/store/''${entry#$distDir/store/}"
              fi
              if [[ "$entry" == "$out/store/"* ]]; then
                resolved=""
                local found=0
                for child in "$entry"/*; do
                  [ -L "$child" ] || continue
                  tgt=$(readlink -f "$child")
                  [ -n "$tgt" ] || continue
                  resolved=$(dirname "$tgt"); found=1; break
                done
                if [ $found -eq 1 ]; then
                  new="''${new:+$new:}$resolved"
                fi
              else
                new="''${new:+$new:}$entry"
              fi
            done
            if [ "$old" != "$new" ]; then
              patchelf --set-rpath "$new" "$f"
            fi
          }
          rewrite_file_rpaths() { rewrite_rpath_elf "$1"; }
        '';
        machoRewrite = ''
          rewrite_rpath_macho() {
            local f="$1"
            # otool -l prints LC_RPATH commands in groups of three
            # lines; the `path <path> (offset N)` line carries the
            # rpath value.  Capture all of them, then replace each
            # one that points into $out/store via install_name_tool.
            # `|| return 0` skips non-Mach-O files (`.a` archives,
            # script wrappers etc.) without killing installPhase
            # under `set -e` + `pipefail`.
            local rpaths
            rpaths=$(otool -l "$f" 2>/dev/null \
              | awk '
                  /^Load command/ { in_rpath=0 }
                  /cmd LC_RPATH/   { in_rpath=1; next }
                  in_rpath && /path / { print $2 }
                ') || return 0
            [ -n "$rpaths" ] || return 0
            local old phys new resolved child tgt
            while IFS= read -r old; do
              [ -n "$old" ] || continue
              # Normalise the fork's dist-store spelling for matching /
              # resolution; keep `$old` verbatim — install_name_tool
              # needs the exact recorded string as its OLD argument.
              phys="$old"
              if [[ "$phys" == "$distDir/store/"* ]]; then
                phys="$out/store/''${phys#$distDir/store/}"
              fi
              if [[ "$phys" == "$out/store/"* ]]; then
                resolved=""
                local found=0
                shopt -s nullglob
                for child in "$phys"/*; do
                  [ -L "$child" ] || continue
                  tgt=$(readlink -f "$child" 2>/dev/null) || continue
                  [ -n "$tgt" ] || continue
                  resolved=$(dirname "$tgt"); found=1; break
                done
                shopt -u nullglob
                if [ $found -eq 1 ] && [ "$old" != "$resolved" ]; then
                  chmod u+w "$f" 2>/dev/null || true
                  install_name_tool -rpath "$old" "$resolved" "$f" \
                    2>/dev/null || true
                else
                  chmod u+w "$f" 2>/dev/null || true
                  install_name_tool -delete_rpath "$old" "$f" \
                    2>/dev/null || true
                fi
              fi
            done <<< "$rpaths"
          }
          rewrite_file_rpaths() { rewrite_rpath_macho "$1"; }
        '';
      in if stdenv.hostPlatform.isLinux then elfRewrite
         else if stdenv.hostPlatform.isDarwin then machoRewrite
         else ''
           rewrite_file_rpaths() { :; }
         ''}

      # Restrict the walk to files that may carry an rpath: shared
      # libraries (`*.so*` on linux, `*.dylib*` on darwin) and any
      # file in a `bin/` dir (executables).  Without this, patchelf /
      # otool also get pointed at `.hi`, `.a`, `cabal-hash.txt` etc.
      # and would need defensive error handling per file.
      rpath_candidates=(
        \( -name '*.so' -o -name '*.so.*'
        -o -name '*.dylib' -o -name '*.dylib.*'
        -o -path '*/bin/*' \)
      )
      for own_uid in "''${own_uids[@]}"; do
        [ -n "$own_uid" ] || continue
        # Per-unit content lives at `<ghcDir>/<uid>/` (mainline) or
        # `<ghcDir>/lib/<uid>/` (staged layout).
        for unit_dir in "$ghcDir/$own_uid" "$ghcDir/lib/$own_uid"; do
          [ -d "$unit_dir" ] || continue
          while IFS= read -r -d "" f; do
            rewrite_file_rpaths "$f"
          done < <(find "$unit_dir" -type f "''${rpath_candidates[@]}" -print0)
        done
      done
      if [ -d "$ghcDir/lib" ]; then
        while IFS= read -r -d "" f; do
          rewrite_file_rpaths "$f"
        done < <(find "$ghcDir/lib" -type f "''${rpath_candidates[@]}" -print0)
      fi

      # Aggressive cleanup: move keepers aside, wipe $ghcDir, then
      # restore them.  Cheaper than walking the tree.  Keepers per
      # captured unit:
      #   * `$ghcDir/<uid>/`             — per-unit lib/share/etc.
      #     (mainline layout)
      #   * `$ghcDir/lib/<uid>/`         — per-unit content in the
      #     staged layout (`libdir = pkgroot </> "lib" </> uid`,
      #     with include/, share/, the static .a etc. inside)
      #   * `$ghcDir/<pkg-db>/<uid>.conf` — pkg-db entry
      #   * `$ghcDir/lib/libHS<uid>-*.{dylib,so,a}` — the flat
      #     shared lib cabal puts in `$ghcDir/lib/` alongside the
      #     per-unit dir (both layouts).  Without this, downstream
      #     consumers can't find the dylib at link time.
      # Plus (staged layout, not per-uid): every NEW file in the flat
      # `$ghcDir/bin/` (`bindir = pkgroot </> "bin"`, shared across
      # units) — identified by diff against the `bin-before`
      # snapshot, since flat bin entries can't be attributed to a
      # unit by name.
      if [ ''${#own_uids[@]} -gt 0 ] \
         && ! { [ ''${#own_uids[@]} -eq 1 ] && [ -z "''${own_uids[0]}" ]; }; then
        side=$buildRoot/keep
        mkdir -p "$side/$storePkgDb" "$side/lib" "$side/bin" "$side/units"
        kept_tool_uids=()
        shopt -s nullglob
        for keep in "''${own_uids[@]}"; do
          [ -n "$keep" ] || continue
          if [ -e "$ghcDir/$keep" ]; then
            mv "$ghcDir/$keep" "$side/$keep"
          fi
          if [ -e "$ghcDir/lib/$keep" ]; then
            mv "$ghcDir/lib/$keep" "$side/lib/$keep"
          fi
          if [ -e "$ghcDir/$storePkgDb/$keep.conf" ]; then
            mv "$ghcDir/$storePkgDb/$keep.conf" "$side/$storePkgDb/$keep.conf"
          fi
          # Unit receipt (fork layout): must be kept for exactly the
          # units whose content the slice keeps — a receipt without its
          # unit would make a downstream improvement pass mark a
          # missing unit Installed.
          if [ -e "$ghcDir/units/$keep" ]; then
            mv "$ghcDir/units/$keep" "$side/units/$keep"
          fi
          for f in "$ghcDir/lib/libHS$keep"-*; do
            mv "$f" "$side/lib/$(basename "$f")"
          done
        done
        if [ -d "$ghcDir/bin" ]; then
          for b in "$ghcDir/bin"/*; do
            bn=$(basename "$b")
            if ! grep -qx -- "$bn" $buildRoot/bin-before 2>/dev/null; then
              mv "$b" "$side/bin/$bn"
              # ...and the exe unit's `lib/<uid>/`, which holds its
              # data-files.  A kept exe is not necessarily one of
              # `own_uids` -- a BUILD-stage tool built in-slice (alex,
              # for a cross `Cabal-syntax`) lands in this same flat bin
              # through the `build` -> `host` alias -- and its
              # `Paths_<pkg>` datadir is baked as an absolute path into
              # this output.  Wiping the dir below while shipping the
              # binary left a tool that fails when a downstream slice
              # runs it:
              #   alex: .../store/build/.../alex-3.5.4.2-.../share/
              #         AlexTemplate.hs: openFile: does not exist
              # (ghc914-sh musl64/static `ghc-lib-reinstallable-cabal`).
              if [ -f "$distDir/cache/plan.json" ]; then
                while IFS= read -r tuid; do
                  [ -n "$tuid" ] || continue
                  if [ -e "$ghcDir/lib/$tuid" ] && [ ! -e "$side/lib/$tuid" ]; then
                    mv "$ghcDir/lib/$tuid" "$side/lib/$tuid"
                    kept_tool_uids+=("$tuid")
                  fi
                done < <(jq -r --arg exe "exe:$bn" \
                  '.["install-plan"][]
                   | select(.["component-name"] == $exe)
                   | .id | sub("^(host|build):"; "")' \
                  "$distDir/cache/plan.json" 2>/dev/null)
              fi
            fi
          done
        fi
        shopt -u nullglob
        rm -rf "$ghcDir"
        mkdir -p "$ghcDir/$storePkgDb"
        shopt -s nullglob
        for keep in "''${own_uids[@]}"; do
          [ -n "$keep" ] || continue
          if [ -e "$side/$keep" ]; then
            mv "$side/$keep" "$ghcDir/$keep"
          fi
          if [ -e "$side/lib/$keep" ]; then
            mkdir -p "$ghcDir/lib"
            mv "$side/lib/$keep" "$ghcDir/lib/$keep"
          fi
          if [ -e "$side/$storePkgDb/$keep.conf" ]; then
            mv "$side/$storePkgDb/$keep.conf" "$ghcDir/$storePkgDb/$keep.conf"
          fi
          if [ -e "$side/units/$keep" ]; then
            mkdir -p "$ghcDir/units"
            mv "$side/units/$keep" "$ghcDir/units/$keep"
          fi
        done
        kept_libs=("$side/lib/libHS"*)
        if [ ''${#kept_libs[@]} -gt 0 ]; then
          mkdir -p "$ghcDir/lib"
          for f in "''${kept_libs[@]}"; do
            mv "$f" "$ghcDir/lib/$(basename "$f")"
          done
        fi
        for tuid in "''${kept_tool_uids[@]}"; do
          if [ -e "$side/lib/$tuid" ]; then
            mkdir -p "$ghcDir/lib"
            mv "$side/lib/$tuid" "$ghcDir/lib/$tuid"
          fi
        done
        kept_bins=("$side/bin"/*)
        if [ ''${#kept_bins[@]} -gt 0 ]; then
          mkdir -p "$ghcDir/bin"
          for f in "''${kept_bins[@]}"; do
            mv "$f" "$ghcDir/bin/$(basename "$f")"
          done
        fi
        shopt -u nullglob
      fi
      # When captured_uids is empty (cabal short-circuited "Up to
      # date" — a dep slice's lndir composition supplied
      # everything), leave $ghcDir alone.  `kindSpecificInstallPhase`
      # needs to find `bin/<exeName>` somewhere in `$out/store` for
      # exe / test / bench slices, and the only place it lives is
      # the lndir-composed dep slice unit dir.
    fi

    ${if expectedUnitId == null then ''
      # No specific unit-id to match against (source-repo / local
      # packages, cross builds where the cross plan's network uid
      # legitimately diverges from what real cross-cabal computes
      # due to `--with-PROG` flags entering pkgHashProgramArgs,
      # custom-build packages whose plan-nix entry spans multiple
      # cabal-side units, etc.).  Verify:
      #   * exactly ONE captured unit has pkg-name == expectedPackage
      #     (the slice's target — missing it means cabal built
      #     something other than what we asked for);
      #   * any OTHER captured units have a pkg-name in
      #     `allowedBuildToolPackages` (transitive build-tools on
      #     cross — normally none, since cabal recognises the
      #     composed cross `targetSlice` by matching uid, but if a
      #     uid mismatch slips through we accept the captured tool
      #     unit rather than fail outright; downstream slices reuse
      #     it through `composeStore`).
      expected_pkg=${lib.escapeShellArg expectedPackage}
      allowed_build_tools=${lib.escapeShellArg
        (lib.concatStringsSep " " allowedBuildToolPackages)}
      actual_uids=$(sort -u $buildRoot/captured-unit-ids)

      # Map each captured unit-id to its package name.  Prefer the
      # `.conf` file (lib units) for the authoritative pkg name —
      # cabal's OS-prefix patch shortens unit-id prefixes (e.g.
      # `bytrdr-1.0.4-...` for `byteorder`), so parsing the uid
      # alone misclassifies them.  For sublibs cabal records:
      #   name:         z-<pkg>-z-<sublib>
      #   package-name: <pkg>
      #   lib-name:     <sublib>
      # — prefer `package-name:` so a sublib slice matches the real
      # package, not the z-encoded one.  Fall back to uid parsing
      # for bin-only units (exe / test / bench — no .conf).
      planJson="$distDir/cache/plan.json"
      uid_to_pkg() {
        while IFS= read -r uid; do
          conf="$ghcDir/$storePkgDb/$uid.conf"
          if [ -f "$conf" ]; then
            name=$(awk '/^package-name:/ {print $2; exit}' "$conf")
            if [ -z "$name" ]; then
              name=$(awk '/^name:/ {print $2; exit}' "$conf")
            fi
            if [ -n "$name" ]; then
              echo "$name	$uid"
              continue
            fi
          fi
          # Bin-only (exe / test / bench) units have no `.conf` —
          # look the uid up in cabal's own `plan.json` instead.
          # Falling back to parsing the uid string would misclassify
          # OS-prefix-shortened names (e.g. `bckpck-...` for
          # `backpack`).
          if [ -f "$planJson" ]; then
            name=$(jq -r --arg id "$uid" '.["install-plan"][] | select(.id == $id) | .["pkg-name"]' "$planJson" 2>/dev/null | head -n1)
            if [ -n "$name" ] && [ "$name" != "null" ]; then
              echo "$name	$uid"
              continue
            fi
          fi
          # Last resort: parse uid (works for unprefixed exe uids
          # — typically build-tools whose pkg-name appears in
          # `allowedBuildToolPackages`).
          echo "$uid" | awk '{
            n = split($1, parts, "-")
            for (i = n; i > 0; i--) if (parts[i] ~ /^[0-9]+(\.[0-9]+)*$/) break
            if (i <= 1) { name = $1 }
            else {
              name = parts[1]
              for (j = 2; j < i; j++) name = name "-" parts[j]
            }
            print name "\t" $1
          }'
        done
      }

      pairs=$(printf '%s\n' "$actual_uids" | uid_to_pkg)
      # `+`-suffixed unit-ids are cabal backpack instantiations of
      # an indefinite library — byproducts cabal emits inline when
      # something downstream needs the instantiated form (e.g. the
      # exe slice materialises the instantiated `consumer` because
      # the indefinite consumer's slice has no compiled artifacts
      # to compose in).  v1 builds each instantiation as its own
      # derivation (lib/default.nix:369's
      # `components.library.override { inherit instantiations; }`);
      # v2 doesn't yet have a slice-per-instantiation, so these
      # ride along inside the consuming slice's $out.  Exclude
      # them from the target-unit count so the check sees the
      # slice's own target only.
      target_count=$(printf '%s\n' "$pairs" \
        | awk -v e="$expected_pkg" '$1 == e && $2 !~ /\+/' \
        | wc -l)
      unexpected=$(printf '%s\n' "$pairs" \
        | awk -v expected="$expected_pkg" -v allowed="$allowed_build_tools" '
            BEGIN {
              n = split(allowed, a, " ")
              for (i = 1; i <= n; i++) allowed_set[a[i]] = 1
            }
            $1 != expected && !($1 in allowed_set) { print $2 }
          ')
      # BUILD-stage units the fork planned in-slice (setup scopes /
      # build tools) are by-design byproducts, not divergence — see
      # the build-stage-unit-ids capture above.
      if [ -s $buildRoot/build-stage-unit-ids ] && [ -n "$unexpected" ]; then
        unexpected=$(printf '%s\n' "$unexpected" \
          | grep -vxF -f $buildRoot/build-stage-unit-ids || true)
      fi

      # `target_count > 1` used to indicate cabal split the target
      # into multiple installed units within a single slice.  With
      # the stable-haskell fork that's legitimate for multi-component
      # packages: build-type Configure/Custom packages are elaborated
      # per PACKAGE, so e.g. `rts` produces its main lib and each
      # flavour sublib in the one slice.  Distinct components
      # register distinct conf `name:`s (`z-<pkg>-z-<sublib>`), so
      # only a REPEATED name — the same component built twice under
      # two unit-ids — is the divergence this check exists to catch.
      # `target_count == 0` is OK: cabal silently produces no `.conf`
      # for indefinite backpack libraries (the slice's target is a
      # sublib with unfilled `signatures:` — no compiled artifacts to
      # install until something instantiates it), so an empty $out is
      # the correct outcome for that case.
      if [ "$target_count" -gt 1 ]; then
        dup_names=$(printf '%s\n' "$pairs" \
          | awk -v e="$expected_pkg" '$1 == e && $2 !~ /\+/ { print $2 }' \
          | while IFS= read -r uid; do
              conf="$ghcDir/$storePkgDb/$uid.conf"
              if [ -f "$conf" ]; then
                awk '/^name:/{print $2; exit}' "$conf"
              else
                echo "(bin-only)"
              fi
            done | sort | uniq -d)
        if [ -n "$dup_names" ]; then
          echo "" >&2
          echo "ERROR: slice captured $target_count non-instantiated units for the target package '$expected_pkg' with repeated component name(s):" >&2
          printf '%s\n' "$dup_names" | sed 's/^/    /' >&2
          echo "" >&2
          echo "  Captured unit-ids:" >&2
          printf '%s\n' "$actual_uids" | sed 's/^/    /' >&2
          exit 1
        fi
      fi
      if [ -n "$unexpected" ]; then
        echo "" >&2
        echo "ERROR: slice captured units for packages other than '$expected_pkg'" >&2
        echo "       and the allowed transitive build-tools:" >&2
        echo "" >&2
        echo "  Unexpected unit-ids:" >&2
        printf '%s\n' "$unexpected" | sed 's/^/    /' >&2
        echo "" >&2
        echo "  All captured unit-ids:" >&2
        printf '%s\n' "$actual_uids" | sed 's/^/    /' >&2
        exit 1
      fi
    '' else ''
      # The slice must produce exactly one unit-id: the plan-id
      # plan-nix recorded for this component.  Any divergence is a
      # fail:
      #   * Missing — cabal's slice solver picked different inputs
      #     than the project plan, so the unit cabal actually built
      #     is a different unit-id.  Typically the slice solver
      #     chose a GHC-bundled `-inplace` dep where plan-nix had a
      #     reinstalled one.
      #   * Extra — cabal built more than this slice's component.
      #     The most common case is an exe slice where cabal
      #     accidentally rebuilt the package's library alongside
      #     the exe instead of reusing the pre-installed lib slice.
      #     The lib's slice is what downstream consumers compose,
      #     so a second copy with a different unit-id would
      #     silently fork dep hashes.
      expected_uid=${lib.escapeShellArg expectedUnitId}
      actual_uids=$(sort -u $buildRoot/captured-unit-ids)
      if printf '%s\n' "$actual_uids" | grep -Fxq -- "$expected_uid"; then
        missing=""
      else
        missing="$expected_uid"
      fi
      unexpected=$(comm -13 \
        <(printf '%s\n' "$expected_uid") \
        <(printf '%s\n' "$actual_uids"))
      ${lib.optionalString (allowedSiblingUnitPrefix != null) ''
        # Local-`packages:` slice: drop same-package sibling units
        # (`<pkgid>` and `<pkgid>-<component>`) from the extras — see
        # the `allowedSiblingUnitPrefix` argument comment.
        sibling_pkgid=${lib.escapeShellArg allowedSiblingUnitPrefix}
        unexpected=$(printf '%s\n' "$unexpected" \
          | awk -v p="$sibling_pkgid" \
              'NF && $0 != p && index($0, p "-") != 1')
      ''}
      # BUILD-stage units the fork planned in-slice (setup scopes /
      # build tools) are by-design byproducts, not divergence — see
      # the build-stage-unit-ids capture above.
      if [ -s $buildRoot/build-stage-unit-ids ] && [ -n "$unexpected" ]; then
        unexpected=$(printf '%s\n' "$unexpected" \
          | grep -vxF -f $buildRoot/build-stage-unit-ids || true)
      fi
      if [ -n "$missing" ] || [ -n "$unexpected" ]; then
        echo "" >&2
        echo "ERROR: slice produced unit-ids that don't match plan-nix.json:" >&2
        echo "" >&2
        echo "  Expected (from plan-nix):" >&2
        echo "    $expected_uid" >&2
        echo "" >&2
        echo "  Actual (in this slice's \$out/store):" >&2
        printf '%s\n' "$actual_uids" | sed 's/^/    /' >&2
        if [ -n "$missing" ]; then
          echo "" >&2
          echo "  Missing (in plan but not produced):" >&2
          echo "    $missing" >&2
        fi
        if [ -n "$unexpected" ]; then
          echo "" >&2
          echo "  Unexpected (produced but not expected):" >&2
          printf '%s\n' "$unexpected" | sed 's/^/    /' >&2
        fi

        # The entry cabal produced for each `unexpected` unit-id.  The
        # plan-nix side is not available here on purpose: anything taken
        # from the project's plan would be a build input of the slice and
        # give every project its own copy of it.  `.checkAgainstPlan`
        # (below) diffs the two field by field.
        actualPlan=$distDir/cache/plan.json
        if [ -n "$unexpected" ] && [ -f "$actualPlan" ]; then
          echo "" >&2
          echo "==== slice's plan.json entries for the unexpected unit-ids ====" >&2
          for actualId in $unexpected; do
            jq -S --arg id "$actualId" \
              '.["install-plan"] | map(select(.id == $id)) | .[0]' $actualPlan >&2 || true
          done
        fi

        # The actual `cabal v2-build` was run with `-v` and its output
        # captured to `$buildRoot/build.log`.  The Setup configure call
        # cabal made for each unit appears there as a single JSON-array
        # line; the `--cid=<unit-id>` arg identifies the unit.  Dump
        # them so we can diff against plan-nix's `configure-args`.
        echo "" >&2
        echo "==== Setup configure calls cabal made for this slice ====" >&2
        grep -E '^\[".*configure' $buildRoot/build.log >&2 || true

        echo "" >&2
        echo "Unit-id hashes capture the full set of \`Setup configure\`" >&2
        echo "args (compiler, flags, dep unit-ids, program args, ...).  A" >&2
        echo "divergence usually means the slice's solver picked a" >&2
        echo "different dep version or a different unit-id of the same" >&2
        echo "version (e.g. \`-inplace\` vs reinstalled).  Pin the" >&2
        echo "transitive closure via cabal.project \`constraints:\` lines" >&2
        echo "so the slice solver matches the project plan." >&2
        echo "" >&2
        echo "For a field-by-field diff of every unit against plan-nix, build" >&2
        echo "this component's \`checkAgainstPlan\` attribute, e.g." >&2
        echo "  nix-build -A <project>.hsPkgs.<pkg>.components.library.checkAgainstPlan" >&2
        exit 1
      fi
    ''}
  '';
})
