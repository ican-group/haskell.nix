# This is the nix expression to build ghc. The Glasgow Haskell Compiler. It is
# heavily inspired (and based) upon the ghc expression from nixos/nixpkgs.
# haskell.nix ships its own version of the ghc expression as it needs more
# control over the expression to isolate it against varying <nixpkgs> and
# allow us to customize it to the way haskell.nix works.
let self =
{ stdenv, lib, haskell-nix, targetPackages

# build-tools
, bootPkgs
, buildPackages
, pkgsBuildBuild
, autoconf, automake, coreutils, fetchurl, fetchpatch, perl, python3, m4, sphinx, numactl, elfutils, libcxx, libcxxabi ? throw "No libcxxabi"
, autoreconfHook
, bash

, libiconv ? null

, ncurses # TODO remove this once the cross compilers all work without

, # GHC can be built with system libffi or a bundled one.
  libffi ? null

, # we don't need LLVM for x86, aarch64, or ghcjs
  useLLVM ? with stdenv.targetPlatform; !(isx86 || isAarch64 || isGhcjs || isWasm)
, # LLVM is conceptually a run-time-only dependency, but for
  # non-x86, we need LLVM to bootstrap later stages, so it becomes a
  # build-time dependency too.
  buildLlvmPackages, llvmPackages

, # If enabled, GHC will be built with the GPL-free but slower integer-simple
  # library instead of the faster but GPLed integer-gmp library.
  enableIntegerSimple ? !(lib.any (lib.meta.platformMatch stdenv.hostPlatform) gmp.meta.platforms), gmp
, # If enabled, GHC will be built with the GPL-free native backend of the
  # bignum library that is nearly as fast as GMP
  enableNativeBignum ? !((lib.any (lib.meta.platformMatch stdenv.hostPlatform) gmp.meta.platforms) || enableIntegerSimple)

, # If enabled, use -fPIC when compiling static libs.
  enableRelocatedStaticLibs ? stdenv.targetPlatform != stdenv.hostPlatform && !stdenv.targetPlatform.isAarch32

, # Whether to build dynamic libs for the standard library (on the target
  # platform). Static libs are always built.
  enableShared ? !haskell-nix.haskellLib.isCrossTarget && !stdenv.targetPlatform.isStatic || stdenv.targetPlatform.isWasm

, enableLibraryProfiling ? true

, enableDWARF ? false

, enableIPE ? false

, enableTerminfo ? !stdenv.targetPlatform.isAndroid &&
    # Before https://gitlab.haskell.org/ghc/ghc/-/merge_requests/13932,
    # hadrian can't build terminfo correctly for cross-compilation (it
    # passes the same --with-curses-libraries to both stage0 and stage1,
    # but they need different ncurses for their respective platforms).
    (builtins.compareVersions ghc-version "9.15" >= 0
      || (stdenv.buildPlatform.config == stdenv.hostPlatform.config && stdenv.hostPlatform.config == stdenv.targetPlatform.config))
    # Terminfo does not work on older ghc cross arm and windows compilers
    && (!haskell-nix.haskellLib.isCrossTarget || !(stdenv.targetPlatform.isAarch32 || stdenv.targetPlatform.isAarch64 || stdenv.targetPlatform.isWindows) || builtins.compareVersions ghc-version "8.10" >= 0)

, # Whether to build in NUMA support
  enableNUMA ? true

, # What flavour to build. An empty string indicates no
  # specific flavour and falls back to ghc default values.
  ghcFlavour ? lib.optionalString haskell-nix.haskellLib.isCrossTarget (
    if useLLVM
      then "perf-cross"
      else "perf-cross-ncg"
    )

, # Extra flavour transformers to pass to Hadrian. For example, +debug_ghc or
  # +assertions to work on debugging the compiler.
  extraFlavourTransformers ? []

, # Whether to disable the large address space allocator
  # necessary fix for iOS: https://www.reddit.com/r/haskell/comments/4ttdz1/building_an_osxi386_to_iosarm64_cross_compiler/d5qvd67/
  disableLargeAddressSpace ? stdenv.targetPlatform.isDarwin && stdenv.targetPlatform.isAarch64 || stdenv.targetPlatform.isAndroid

, useLdGold ?
    # might be better check to see if cc is clang/llvm?
    # use gold as the linker on linux to improve link times
    # do not use ld.gold 2.3 with musl due to a ld.gold bug.
    # See: <https://sourceware.org/bugzilla/show_bug.cgi?id=22266>.
    # Note that this bug was resolved in 2017.
    ( stdenv.targetPlatform.isLinux
      # don't use gold on android.
      && !stdenv.targetPlatform.isAndroid
      # don't use gold with with musl. Still seems to be
      # affected by 22266.
      && !stdenv.targetPlatform.isMusl)
, useLdLld ? false
, ghc-version ? src-spec.version
, ghc-version-date ? null
, ghc-commit-id ? null
, src-spec
, ghc-patches ? []

# extra values we want to have available as passthru values.
, extra-passthru ? {}

# For running IFDs (used to evaluate build plans of tools involved in building GHC).
#
# Currently used for:
#   * hadrian
#   * libffi-wasm
#   * cabal (if we start using `cabal` to build GHC)
#
# We use this instead of `buildPackages` so that plan evaluation
# can work on platforms other than the `buildPlatform`.
, evalSystem ? pkgsBuildBuild.stdenv.hostPlatform.system
}@args:

# The eval platform is threaded as a system string (`evalSystem`).  Internal
# cabalProject'/tool calls pass `evalSystem` (from which the project derives its
# read-only `evalPackages` option, see modules/project-common.nix) rather than
# setting `evalPackages` directly.  Per-eval-system variants are selected via
# the compiler's `evalWith.${evalSystem}` attrset (built from `override` in the
# stable-haskell final block), not by calling `.override` at each site.

assert !(enableIntegerSimple || enableNativeBignum) -> gmp != null;

# Early check to make sure only one of these is enabled
assert enableNativeBignum -> !enableIntegerSimple;
assert enableIntegerSimple -> !enableNativeBignum;

assert !(useLdGold && useLdLld);

let
  src = src-spec.file or (fetchurl { inherit (src-spec) url sha256; });

  inherit (stdenv) buildPlatform hostPlatform targetPlatform;
  inherit (haskell-nix.haskellLib) isCrossTarget;

  ghc = if bootPkgs.ghc.isHaskellNixCompiler or false
    then bootPkgs.ghc.evalWith.${evalSystem} or (bootPkgs.ghc.override { inherit evalSystem; })
    else bootPkgs.ghc;

  ghcHasNativeBignum = builtins.compareVersions ghc-version "9.0" >= 0;
  hadrianHasNativeBignumFlavour = builtins.compareVersions ghc-version "9.6" >= 0;

  bignumSpec =
    assert ghcHasNativeBignum -> !enableIntegerSimple;
    assert !ghcHasNativeBignum -> !enableNativeBignum;
    if ghcHasNativeBignum then ''
      BIGNUM_BACKEND = ${if enableNativeBignum then "native" else "gmp"}
    '' else ''
      INTEGER_LIBRARY = ${if enableIntegerSimple then "integer-simple" else "integer-gmp"}
    '';

  nodejs = pkgsBuildBuild.nodejs_24;

  libffi-wasm = pkgsBuildBuild.runCommand "libffi-wasm" {
      nativeBuildInputs = [
        (pkgsBuildBuild.haskell-nix.tool "ghc912" "libffi-wasm" {
          src = pkgsBuildBuild.haskell-nix.sources.libffi-wasm;
          inherit evalSystem;
        })
        targetPackages.buildPackages.llvmPackages.clang
        targetPackages.buildPackages.llvmPackages.llvm
        pkgsBuildBuild.binaryen
      ];
      outputs = ["out" "dev"];
      NIX_NO_SELF_RPATH = true;
    } ''
      mkdir cbits
      cp ${pkgsBuildBuild.haskell-nix.sources.libffi-wasm}/cbits/* cbits/
      libffi-wasm
      wasm32-unknown-wasi-clang -Wall -Wextra -mcpu=mvp -Oz -DNDEBUG -Icbits -c cbits/ffi.c -o cbits/ffi.o
      wasm32-unknown-wasi-clang -Wall -Wextra -mcpu=mvp -Oz -DNDEBUG -Icbits -c cbits/ffi_call.c -o cbits/ffi_call.o
      wasm32-unknown-wasi-clang -Wall -Wextra -mcpu=mvp -Oz -DNDEBUG -Icbits -c cbits/ffi_closure.c -o cbits/ffi_closure.o

      mkdir -p $dev/include
      cp cbits/*.h $dev/include
      mkdir -p $out/lib
      llvm-ar -r $out/lib/libffi.a cbits/*.o

      wasm32-unknown-wasi-clang -Wall -Wextra -mcpu=mvp -Oz -DNDEBUG -Icbits -fPIC -fvisibility=default -shared -Wl,--keep-section=target_features,--strip-debug cbits/*.c -o libffi.so
      wasm-opt --low-memory-unused --debuginfo -Os libffi.so -o $out/lib/libffi.so
    '';

  # The `node` wrapper below hands GHC's wasm dyld exactly ONE search directory,
  # and the dyld resolves bare names (`libdl.so`, `libc.so`, …) inside it.  Our
  # wasilibc installs its libraries per target, in `lib/wasm32-wasi/`, because
  # that is the sysroot layout clang expects — so a plain join leaves `lib/`
  # holding nothing but that subdirectory and Template Haskell dies with
  # `findSystemLibrary(libdl.so): not found`.  Flatten instead, covering both
  # layouts (wasilibc used to install straight into `lib/`), and leave the
  # sysroot itself alone so the compile and link paths keep working.
  lib-wasm = pkgsBuildBuild.runCommand "lib-wasm" { } ''
    mkdir -p $out/lib
    for d in ${targetPackages.wasilibc}/lib ${targetPackages.wasilibc}/lib/wasm32-wasi ${libffi-wasm}/lib; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        # -f skips the per-target subdirectory and its `wasm32-wasip1` alias.
        [ -f "$f" ] || continue
        ln -sfn "$f" "$out/lib/$(basename "$f")"
      done
    done
  '';

  # TODO check if this possible fix for segfaults works or not.
  targetLibffi =
    # on native platforms targetPlatform.{libffi, gmp} do not exist; thus fall back
    # to the non-targetPlatform version in those cases.
    let targetLibffi = targetPackages.libffi or libffi; in
    # we need to set `dontDisableStatic` for musl for libffi to work.
    if stdenv.targetPlatform.isMusl
      then targetLibffi.overrideAttrs (_old: { dontDisableStatic = true; })
    else if stdenv.targetPlatform.isWasm
      then libffi-wasm
    else targetLibffi;

  # Directory passed to --with-ffi-libraries.  hadrian configures the
  # stage0 (build platform) in-tree libraries with the same TARGET
  # --with-ffi-libraries dir as stage1 (the same hadrian bug class as the
  # --with-curses-libraries one noted at `enableTerminfo` above).  On
  # Linux build hosts the same-arch ELF libffi happens to satisfy the
  # stage0 link, but when cross-compiling from darwin, ld64 finds the ELF
  # libffi.so, ignores it as wrong-format, and stops searching — leaving
  # ffi_call & co undefined in stage0 executables linked against the
  # in-tree rts/ghci.  Joining the build-platform libffi.dylib into the
  # same directory fixes both sides: ld64 prefers the .dylib, while the
  # target's GNU ld only ever looks for libffi.so/libffi.a.
  targetLibffiLibDir =
    if haskell-nix.haskellLib.isCrossTarget && stdenv.buildPlatform.isDarwin && libffi != null
    then pkgsBuildBuild.symlinkJoin {
        name = "libffi-${targetPlatform.config}-with-build-dylib";
        paths = [ (lib.getLib targetLibffi) (lib.getLib libffi) ];
      } + "/lib"
    else "${lib.getLib targetLibffi}/lib";

  targetGmp = targetPackages.gmp or gmp;

  targetIconv = targetPackages.libiconv or libiconv;

  targetNumactl = targetPackages.numactl or numactl;

  # TODO(@Ericson2314) Make unconditional
  targetPrefix = lib.optionalString
    (targetPlatform != hostPlatform) (
      if useHadrian && targetPlatform.isGhcjs
        then "javascript-unknown-ghcjs-"
        else "${targetPlatform.config}-");

  buildMK = ''
    BuildFlavour = ${ghcFlavour}
    ifneq \"\$(BuildFlavour)\" \"\"
    include mk/flavours/\$(BuildFlavour).mk
    endif
    DYNAMIC_GHC_PROGRAMS = ${if enableShared then "YES" else "NO"}
  '' + bignumSpec + ''
    EXTRA_HADDOCK_OPTS += --quickjump --hyperlinked-source
  '' + lib.optionalString (targetPlatform != hostPlatform) ''
    CrossCompilePrefix = ${targetPrefix}
  '' + lib.optionalString isCrossTarget ''
    Stage1Only = ${if targetPlatform.system == hostPlatform.system then "NO" else "YES"}
  '' + lib.optionalString (isCrossTarget || targetPlatform.isMusl) ''
    HADDOCK_DOCS = NO
  '' + ''
    BUILD_SPHINX_HTML = NO
    BUILD_SPHINX_PDF = NO
  '' + lib.optionalString enableRelocatedStaticLibs ''
    GhcLibHcOpts += -fPIC
    GhcRtsHcOpts += -fPIC
    GhcRtsCcOpts += -fPIC
  '' + lib.optionalString (enableRelocatedStaticLibs && targetPlatform.isx86_64 && !targetPlatform.isWindows) ''
    GhcLibHcOpts += -fexternal-dynamic-refs
    GhcRtsHcOpts += -fexternal-dynamic-refs
  '' + lib.optionalString enableDWARF ''
    GhcLibHcOpts += -g3
    GhcRtsHcOpts += -g3
  '' + lib.optionalString targetPlatform.useAndroidPrebuilt ''
    EXTRA_CC_OPTS += -std=gnu99
  '' + lib.optionalString (!enableTerminfo) ''
    WITH_TERMINFO=NO
  ''
  # musl doesn't have a system-linker. Only on x86, and on x86 we need it, as
  # our elf linker for x86_64 is broken. The i686 one seems also to not exist.
  # So it's really _just_ x86_64.
  + lib.optionalString (targetPlatform.isAndroid || (targetPlatform.isMusl && !targetPlatform.isx86_64)) ''
    compiler_CONFIGURE_OPTS += --flags=-dynamic-system-linker
  ''
  # While split sections are now enabled by default in ghc 8.8 for windows,
  # the seem to lead to `too many sections` errors when building base for
  # profiling.
  #
  # It appears that loading split sections through iserv on qemu-aarch64, is
  # particularly slow. Let's disable them for now.
  + lib.optionalString (targetPlatform.isWindows || targetPlatform.isAndroid) ''
    SplitSections = NO
  '' + lib.optionalString (!enableLibraryProfiling) ''
    BUILD_PROF_LIBS = NO
  '' + lib.optionalString (disableLargeAddressSpace) ''
    libraries/base_CONFIGURE_OPTS += --configure-option=--with-libcharset=no
  '';

  # `--with` flags for libraries needed for RTS linker
  configureFlags = [
        "--datadir=$doc/share/doc/ghc"
    ] ++ lib.optionals (enableTerminfo && !targetPlatform.isGhcjs && !targetPlatform.isWasm && !targetPlatform.isAndroid) ["--with-curses-includes=${lib.getDev targetPackages.ncurses}/include" "--with-curses-libraries=${lib.getLib targetPackages.ncurses}/lib"
    ] ++ lib.optionals (targetLibffi != null && !targetPlatform.isGhcjs && !targetPlatform.isWasm) ["--with-system-libffi" "--with-ffi-includes=${lib.getDev targetLibffi}/include" "--with-ffi-libraries=${targetLibffiLibDir}"
    ] ++ lib.optionals (targetPlatform.isWasm) [
        "--with-system-libffi"
    ] ++ lib.optionals (!enableIntegerSimple && !targetPlatform.isGhcjs && !targetPlatform.isWasm) [
        "--with-gmp-includes=${lib.getDev targetGmp}/include" "--with-gmp-libraries=${lib.getLib targetGmp}/lib"
    ] ++ lib.optionals (targetPlatform == hostPlatform && hostPlatform.libc != "glibc" && !targetPlatform.isWindows) [
        "--with-iconv-includes=${lib.getDev libiconv}/include" "--with-iconv-libraries=${lib.getLib libiconv}/lib"
    ] ++ lib.optionals (targetPlatform != hostPlatform && !targetPlatform.isGhcjs && !targetPlatform.isWasm) [
        "--with-iconv-includes=${lib.getDev targetIconv}/include" "--with-iconv-libraries=${lib.getLib targetIconv}/lib"
    ] ++ lib.optionals (targetPlatform != hostPlatform) [
        "--enable-bootstrap-with-devel-snapshot"
    ] ++ lib.optionals (disableLargeAddressSpace) [
        "--disable-large-address-space"
    ] ++ lib.optionals useLdGold [
        "CFLAGS=-fuse-ld=gold"
        "CONF_GCC_LINKER_OPTS_STAGE1=-fuse-ld=gold"
        "CONF_GCC_LINKER_OPTS_STAGE2=-fuse-ld=gold"
        "CONF_LD_LINKER_OPTS_STAGE2=-fuse-ld=gold" # See: <https://gitlab.haskell.org/ghc/ghc/-/issues/22550#note_466656>
    ] ++ lib.optionals useLdLld [
        "LD=${llvmPackages.bintools}/bin/ld.lld"
        "CFLAGS=-fuse-ld=lld"
        "CONF_GCC_LINKER_OPTS_STAGE1=-fuse-ld=lld"
        "CONF_GCC_LINKER_OPTS_STAGE2=-fuse-ld=lld"
    ] ++ lib.optionals enableDWARF [
        "--enable-dwarf-unwind"
        "--with-libdw-includes=${lib.getDev elfutils}/include"
        "--with-libdw-libraries=${lib.getLib elfutils}/lib"
    ] ++ lib.optionals (targetPlatform.isDarwin && builtins.compareVersions ghc-version "9.6" >= 0) [
        # From https://github.com/NixOS/nixpkgs/commit/6454fb1bc0b5884d0c11c98a8a99735ef5a0cae8
        # Darwin uses llvm-ar. GHC will try to use `-L` with `ar` when it is `llvm-ar`
        # but it doesn’t currently work because Cabal never uses `-L` on Darwin. See:
        # https://gitlab.haskell.org/ghc/ghc/-/issues/23188
        # https://github.com/haskell/cabal/issues/8882
        "fp_cv_prog_ar_supports_dash_l=no"
    ] ++ lib.optionals (targetPlatform.isDarwin) [
        "--without-libcharset"
    ] ++ lib.optional (targetPlatform.isGhcjs) "--target=javascript-unknown-ghcjs" # TODO use configurePlatforms once triple is updated in nixpkgs
    ;

  # Splicer will pull out correct variations
  # Always include ncurses in libDeps because hadrian builds terminfo
  # unconditionally for stage0 regardless of enableTerminfo.
  libDeps = platform: lib.optionals (!targetPlatform.isGhcjs && !targetPlatform.isWasm && !targetPlatform.isAndroid) [ (lib.getLib targetPackages.ncurses) (lib.getDev targetPackages.ncurses) ]
    ++ lib.optional (!targetPlatform.isGhcjs) targetLibffi
    ++ lib.optional (!enableIntegerSimple && !targetPlatform.isGhcjs && !targetPlatform.isWasm) gmp
    ++ lib.optional (platform.libc != "glibc" && !targetPlatform.isWindows && !targetPlatform.isWasm) libiconv
    ++ lib.optional (enableNUMA && platform.isLinux && !platform.isAarch32 && !platform.isAndroid) numactl
    ++ lib.optional enableDWARF (lib.getLib elfutils);

  toolsForTarget =
    if targetPlatform.isGhcjs
      then [ buildPackages.emscripten ]
    else if hostPlatform == buildPlatform
      then [ targetPackages.stdenv.cc ] ++ lib.optionals useLLVM ([llvmPackages.llvm] ++ lib.optional (!targetPlatform.useAndroidPrebuilt) llvmPackages.clang)
    else assert targetPlatform == hostPlatform; # build != host == target
      [ stdenv.cc ] ++ lib.optional useLLVM buildLlvmPackages.llvm;

  targetCC = builtins.head toolsForTarget;

  useHadrian = builtins.compareVersions ghc-version "9.4" >= 0;
  # Indicates if we are installing by copying the hadrian stage1 output
  # I think we want to _always_ just install stage1. For now let's do this
  # for musl only; but I'd like to stay far away from the unnecessary
  # bindist logic as we can. It's slow, and buggy, and doesn't provide any
  # value for us.
  installStage1 = useHadrian && (with haskell-nix.haskellLib; isCrossTarget || isNativeMusl);

  hadrianProject =
    let
      compiler-nix-name =
        if builtins.compareVersions ghc-version "9.15" > 0
          then "ghc984"
        else if builtins.compareVersions ghc-version "9.4.7" < 0
          then "ghc928"
        else if pkgsBuildBuild.haskell.compiler ? ghc967
          then "ghc967"
        else if pkgsBuildBuild.haskell.compiler ? ghc966
          then "ghc966"
        else if pkgsBuildBuild.haskell.compiler ? ghc964
          then "ghc964"
        else "ghc962";
    in
    pkgsBuildBuild.haskell-nix.cabalProject' ({
      inherit compiler-nix-name;
      name = "hadrian";
      compilerSelection = p: p.haskell.compiler;
      inherit evalSystem;
      # TODO remove: keeps GHC rebuilds from being triggered every
      # time the v2 code path changes while v2 is still evolving.
      builderVersion = 1;
      modules = [{
        reinstallableLibGhc = false;
        # Apply the patches in a way that does not require using something
        # like `srcOnly`. The problem with `pkgs.srcOnly` was that it had to run
        # on a platform at eval time.
        packages.hadrian.prePatch = ''
          cd ..
        '';
        packages.hadrian.patches = ghc-patches;
        packages.hadrian.postPatch = ''
          cd hadrian
        '';
      }];
      src = haskell-nix.haskellLib.cleanSourceWith {
        src = {
          outPath = pkgsBuildBuild.srcOnly {
            stdenv = pkgsBuildBuild.stdenvNoCC;
            name = "hadrian";
            inherit src;
          };
          filterPath = { path, ... }: path;
        };
        subDir = "hadrian";
        includeSiblings = true;
      };
      # When building the plan we do not need a patched version
      # of the source and `pkgsBuildBuild.srcOnly` requires introduces
      # a dependency on a build machine.
      evalSrc = haskell-nix.haskellLib.cleanSourceWith {
        src = {
          name = "hadrian";
          outPath = src;
          filterPath = { path, ... }: path;
        };
        subDir = "hadrian";
        includeSiblings = true;
      };
    } // lib.optionalAttrs (builtins.compareVersions ghc-version "9.6" < 0) {
      index-state = "2024-10-17T00:00:00Z";
    });

  hadrian = hadrianProject.hsPkgs.hadrian.components.exes.hadrian;

  # For a description of hadrian command line args
  # see https://gitlab.haskell.org/ghc/ghc/blob/master/hadrian/README.md
  # For build flavours and flavour transformers
  # see https://gitlab.haskell.org/ghc/ghc/blob/master/hadrian/doc/flavours.md
  hadrianArgs = "--flavour=${
        (if targetPlatform.isGhcjs || targetPlatform.isWasm then "quick" else "default")
          + lib.optionalString (!enableShared) "+no_dynamic_libs+no_dynamic_ghc"
          + lib.optionalString useLLVM "+llvm"
          + lib.optionalString enableDWARF "+debug_info"
          + lib.optionalString ((enableNativeBignum && hadrianHasNativeBignumFlavour) || targetPlatform.isGhcjs || targetPlatform.isWasm) "+native_bignum"
          + lib.optionalString (targetPlatform.isGhcjs || targetPlatform.isWasm) "+no_profiled_libs"
          + lib.optionalString enableIPE "+ipe"
          + lib.concatStrings extraFlavourTransformers
      } --docs=no-sphinx -j --verbose"
      # This is needed to prevent $GCC from emitting out of line atomics.
      # Those would then result in __aarch64_ldadd1_sync and others being referenced, which
      # we don't handle in the RTS properly yet. Until we figure out how to _properly_ deal
      # with the RTS_SYMBOLS in GHC, we are better off disableing the out of line atomics.
      + lib.optionalString ( hostPlatform.isAarch64 && targetPlatform.isLinux && targetPlatform.isAarch64)
        " '*.*.ghc.c.opts += -optc-mno-outline-atomics'"
      # For cross compilers only the RTS should be built with -mno-outline-atomics
      + lib.optionalString (!hostPlatform.isAarch64 && targetPlatform.isLinux && targetPlatform.isAarch64)
        " '*.rts.ghc.c.opts += -optc-mno-outline-atomics'"
      # PIC breaks GHC annotations on windows (see test/annotations for a test case)
      + lib.optionalString (enableRelocatedStaticLibs && !targetPlatform.isWindows && !targetPlatform.isWasm)
        " '*.*.ghc.*.opts += -fPIC' '*.*.cc.*.opts += -fPIC'"
      # C options for wasm
      + lib.optionalString targetPlatform.isWasm (
          " 'stage1.*.ghc.*.opts += -optc-Wno-error=int-conversion -optc-O3 -optc-mcpu=lime1 -optc-mreference-types -optc-msimd128 -optc-DXXH_NO_XXH3'"
        + " 'stage1.*.ghc.cpp.opts += -optc-fno-exceptions'")
      # `-fexternal-dynamic-refs` causes `undefined reference` errors when building GHC cross compiler for windows
      + lib.optionalString (enableRelocatedStaticLibs && targetPlatform.isx86_64 && !targetPlatform.isWindows)
        " '*.*.ghc.*.opts += -fexternal-dynamic-refs'"
      # With the latest nixpkgs mixing `struct utimbuf` and `struct _utimbuf` causes an error without this
      + lib.optionalString (targetPlatform.isWindows) (
        if builtins.compareVersions ghc-version "9.10" >= 0
          then " '*.ghc-internal.ghc.*.opts += -optc-Wno-incompatible-pointer-types'"
          else " '*.base.ghc.*.opts += -optc-Wno-incompatible-pointer-types'")
      # The fact that we need to set this here is pretty idiotic. GHC should figure this out on it's own.
      # Either have a runtime flag/setting to disable it or if dlopen fails, remember that it failed and
      # fall back to non-dynamic. We only have dynamic linker with musl if host and target arch match.
      + lib.optionalString (targetPlatform.isAndroid || (targetPlatform.isMusl && haskell-nix.haskellLib.isCrossTarget))
        " '*.ghc.cabal.configure.opts += --flags=-dynamic-system-linker'"
      # The following is required if we build on aarch64-darwin for aarch64-iOS. Otherwise older
      # iPhones/iPads/... won't understand the compiled code, as the compiler will emit LDSETALH
      # FIXME: we should have iOS as an argument to this derivation, and then make this, as well as
      #        disableLargeAddress space conditional on iOS = true.
      + lib.optionalString (stdenv.targetPlatform.isDarwin && stdenv.targetPlatform.isAarch64)
        " '*.*.ghc.c.opts += -optc-mcpu=apple-a7 -optc-march=armv8-a+norcpc'"
      + lib.optionalString (targetPlatform.isAndroid && targetPlatform.isAarch32)
        " 'stage1.*.ghc.c.opts += -optc-march=armv7-a -optc-mfloat-abi=softfp -optc-mfpu=vfpv3-d16'"
      + lib.optionalString (targetPlatform.isAndroid && targetPlatform.isAarch64)
        " 'stage1.*.ghc.c.opts += -optc-march=armv8-a'"
      # For GHC versions in the 9.x range that don't support the +native_bignum flavour transformer yet
      + lib.optionalString ((enableNativeBignum && !hadrianHasNativeBignumFlavour))
        " --bignum=native"
      ;

  # When installation is done by copying the stage1 output the directory layout
  # is different.
  rootDir =
    if installStage1
      then ""
      else "lib/${targetPrefix}ghc-${ghc-version}/";
  libDir =
    if installStage1
      then "lib"
      else "lib/${targetPrefix}ghc-${ghc-version}" + lib.optionalString (useHadrian) "/lib";
  packageConfDir = "${libDir}/package.conf.d";
  docDir = "share/doc/ghc/html";

  # This work around comes from nixpkgs/pkgs/development/compilers/ghc
  #
  # Sometimes we have to dispatch between the bintools wrapper and the unwrapped
  # derivation for certain tools depending on the platform.
  bintoolsFor = {
    # GHC needs install_name_tool on all darwin platforms.
    install_name_tool = targetCC.bintools.bintools;
    strip =
      # TODO(@sternenseemann): also use wrapper if linker == "bfd" or "gold"
      if stdenv.targetPlatform.isAarch64
      then targetCC.bintools
      else targetCC.bintools.bintools;
  };

in
haskell-nix.haskellLib.makeCompilerDeps (stdenv.mkDerivation (rec {
  version = ghc-version;
  name = "${targetPrefix}ghc-${version}" + lib.optionalString (useLLVM) "-llvm";

  inherit src configureFlags;
  patches = ghc-patches;

  # configure was run by configured-src already.
  phases = [ "unpackPhase" "patchPhase" "autoreconfPhase"
             "configurePhase" "buildPhase"
             "checkPhase" "installPhase"
             "fixupPhase"
             "installCheckPhase"
             "distPhase"
             ];

  # GHC is a bit confused on its cross terminology.
  preConfigure =
    # This code is only included when cross compiling as it breaks aarch64-darwin native compilation
    lib.optionalString (targetPlatform != hostPlatform) ''
        for env in $(env | grep '^TARGET_' | sed -E 's|\+?=.*||'); do
        export "''${env#TARGET_}=''${!env}"
        done
    ''
    # Use emscripten and the `config.sub` saved by `postPatch`
    + lib.optionalString (targetPlatform.isGhcjs) (''
        export CC="${targetCC}/bin/emcc"
        export CXX="${targetCC}/bin/em++"
        export LD="${targetCC}/bin/emcc"
    '' + (
      # Including AR and RANLIB here breaks tests.js-template-haskell for GHC <9.12
      # `LLVM ERROR: malformed uleb128, extends past end`
      let emnm =
        if builtins.pathExists (targetCC + "/share/emscripten/emnm")
        then "${targetCC}/share/emscripten/emnm"
        else "${targetCC}/share/emscripten/tools/emnm.py";
      in if builtins.compareVersions ghc-version "9.12" >= 0
        then ''
          export AR="${targetCC}/bin/emar"
          export NM="${emnm}"
          export RANLIB="${targetCC}/bin/emranlib"
        ''
        else ''
          export NM="${emnm}"
        ''
    ) + ''
        export EM_CACHE=$(mktemp -d)
        if [ -d ${targetCC}/share/emscripten/cache ]; then
          cp -r ${targetCC}/share/emscripten/cache/* $EM_CACHE/
          chmod +w -R $EM_CACHE
        fi
        mv config.sub.ghcjs config.sub
    '')
    + lib.optionalString (targetPlatform.isWasm) ''
        export CC="${targetCC}/bin/${targetCC.targetPrefix}cc"
        export CXX="${targetCC}/bin/${targetCC.targetPrefix}c++"
        export LD="${buildPackages.llvmPackages.lld}/bin/wasm-ld"
        export AS="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}as"
        export AR="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}ar"
        export NM="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}nm"
        export RANLIB="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}ranlib"
        export READELF="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}readelf"
        export STRIP="${bintoolsFor.strip}/bin/${bintoolsFor.strip.targetPrefix}strip"
        export NIX_CFLAGS_COMPILE_FOR_BUILD+=" -I${lib.getDev libffi}/include -L${lib.getLib libffi}/lib"
        export NIX_CFLAGS_COMPILE_FOR_TARGET+=" -I${lib.getDev targetLibffi}/include -L${lib.getLib targetLibffi}/lib"
        ${if ghc-version == "9.12.2"
          then ''
            substituteInPlace compiler/GHC.hs --replace-fail "panic \"corrupted wasi-sdk installation\"" "pure \"${targetPackages.wasilibc}\""
          '' else ''
            substituteInPlace compiler/GHC.hs --replace-fail "last <\$> Loader.getGccSearchDirectory logger dflags \"libraries\"" "pure \"${targetPackages.wasilibc}\""
          ''}
    ''
    # GHC is a bit confused on its cross terminology, as these would normally be
    # the *host* tools.
    + lib.optionalString (!targetPlatform.isGhcjs && !targetPlatform.isWasm) (''
        export CC="${targetCC}/bin/${targetCC.targetPrefix}cc"
        export CXX="${targetCC}/bin/${targetCC.targetPrefix}c++"
    ''
    # Use gold to work around https://sourceware.org/bugzilla/show_bug.cgi?id=16177
    + ''
        export LD="${if useLdLld then
                        "${targetPackages.llvmPackages.bintools}/bin/${targetPackages.llvmPackages.bintools.targetPrefix}ld.lld"
                     else
                       "${targetCC.bintools}/bin/${targetCC.bintools.targetPrefix}ld${lib.optionalString useLdGold ".gold"}"}"
        export AS="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}as"
        export AR="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}ar"
        export NM="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}nm"
        export RANLIB="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}ranlib"
        export READELF="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}readelf"
        export STRIP="${bintoolsFor.strip}/bin/${bintoolsFor.strip.targetPrefix}strip"
    '' + lib.optionalString (stdenv.targetPlatform.linker == "cctools") ''
        export OTOOL="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}otool"
        if [ -f ${targetCC}/bin/${targetCC.targetPrefix}install_name_tool ]; then
            export INSTALL_NAME_TOOL="${targetCC}/bin/${targetCC.targetPrefix}install_name_tool"
        else
          export INSTALL_NAME_TOOL="${bintoolsFor.install_name_tool}/bin/${bintoolsFor.install_name_tool.targetPrefix}install_name_tool"
        fi
    '') + lib.optionalString (targetPlatform == hostPlatform && useLdGold)
    # set LD explicitly if we want gold even if we aren't cross compiling
    ''
        export LD="${targetCC.bintools}/bin/ld.gold"
    '' + lib.optionalString (targetPlatform == hostPlatform && useLdLld) ''
        export LD="${llvmPackages.bintools}/bin/ld.lld"
    '' + lib.optionalString (targetPlatform.isWindows) ''
        export DllWrap="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}dllwrap"
        export Windres="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}windres"
    '' + ''
        echo -n "${buildMK}" > mk/build.mk
        sed -i -e 's|-isysroot /Developer/SDKs/MacOSX10.5.sdk||' configure
    '' + lib.optionalString useLLVM ''
        export LLC="${llvmPackages.llvm}/bin/llc"
        export OPT="${llvmPackages.llvm}/bin/opt"
    '' + lib.optionalString (!stdenv.isDarwin) ''
        export NIX_LDFLAGS+=" -rpath $out/lib/${targetPrefix}ghc-${ghc-version}"
    '' + lib.optionalString stdenv.isDarwin ''
        export NIX_LDFLAGS+=" -no_dtrace_dof"
    '' +
    # we really want "+armv7-a,+soft-float,+neon" as features, but llvm will
    # fail with those :facepalm:
    lib.optionalString targetPlatform.useAndroidPrebuilt ''
        sed -i -e '5i ,("armv7a-unknown-linux-androideabi", ("e-m:e-p:32:32-i64:64-v128:64:128-a:0:32-n32-S64", "cortex-a8", ""))' llvm-targets
    '' + lib.optionalString targetPlatform.isMusl ''
        echo "patching llvm-targets for musl targets..."
        echo "Cloning these existing '*-linux-gnu*' targets:"
        grep linux-gnu llvm-targets | sed 's/^/  /'
        echo "(go go gadget sed)"
        sed -i 's,\(^.*linux-\)gnu\(.*\)$,\0\n\1musl\2,' llvm-targets
        echo "llvm-targets now contains these '*-linux-musl*' targets:"
        grep linux-musl llvm-targets | sed 's/^/  /'

        echo "And now patching to preserve '-musleabi' as done with '-gnueabi'"
        # (aclocal.m4 is actual source, but patch configure as well since we don't re-gen)
        for x in configure aclocal.m4; do
            substituteInPlace $x \
            --replace '*-android*|*-gnueabi*)' \
                        '*-android*|*-gnueabi*|*-musleabi*)'
        done
    '' + lib.optionalString (src-spec.version != ghc-version) ''
        substituteInPlace configure --replace 'RELEASE=YES' 'RELEASE=NO'
        substituteInPlace configure.ac --replace 'RELEASE=YES' 'RELEASE=NO'
        echo '${ghc-version}' > VERSION
    '' + lib.optionalString (ghc-version-date != null) ''
        substituteInPlace configure --replace 'RELEASE=YES' 'RELEASE=NO'
        substituteInPlace configure.ac --replace 'RELEASE=YES' 'RELEASE=NO'
        echo '${ghc-version-date}' > VERSION_DATE
    '' + lib.optionalString (ghc-commit-id != null) ''
        echo '${ghc-commit-id}' > GIT_COMMIT_ID
    ''
      # The official ghc 9.2.3 tarball requires booting.
      + lib.optionalString (ghc-version == "9.2.3" || ghc-version == "9.8.20230704" || src-spec.needsBooting or false) ''
        python3 ./boot
    '' + lib.optionalString (builtins.compareVersions ghc-version "9.14" > 0) ''
        mkdir -p libraries/ghc-boot-th-next
        cp libraries/ghc-boot-th/ghc-boot-th.cabal.in libraries/ghc-boot-th-next/ghc-boot-th-next.cabal.in
        substituteInPlace libraries/ghc-boot-th-next/ghc-boot-th-next.cabal.in \
          --replace-fail "ghc-boot-th" "ghc-boot-th-next"
    '';

  configurePlatforms = [ "build" "host" ] ++ lib.optional (!targetPlatform.isGhcjs) "target";

  enableParallelBuilding = true;
  postPatch = ''
    patchShebangs .
  '' + lib.optionalString (targetPlatform.isWasm) ''
    substituteInPlace utils/jsffi/dyld.mjs \
      --replace \
        "${nodejs}/bin/node --disable-warning=ExperimentalWarning ${
           if builtins.compareVersions ghc-version "9.13" < 0
             then "--experimental-wasm-type-reflection"
             else "--max-old-space-size=65536"} --no-turbo-fast-api-calls --wasm-lazy-validation" \
        "${pkgsBuildBuild.writeShellScriptBin "node" ''
            SCRIPT=$1
            shift
            LIB_WASM=$1
            shift
            exec ${nodejs}/bin/node \
              --disable-warning=ExperimentalWarning \
              ${
                 if builtins.compareVersions ghc-version "9.13" < 0
                   then "--experimental-wasm-type-reflection"
                   else "--max-old-space-size=65536"} \
              --wasm-lazy-validation \
              "$SCRIPT" \
              "${lib-wasm}/lib" \
              "$@"
          ''
        }/bin/node"
  '';

  outputs = [ "out" "doc" "generated" ];

  # Make sure we never relax`$PATH` and hooks support for compatibility.
  strictDeps = true;

  # Don’t add -liconv to LDFLAGS automatically so that GHC will add it itself.
  dontAddExtraLibs = true;

  nativeBuildInputs = [
    perl autoconf automake m4 python3 sphinx
    ghc bootPkgs.alex bootPkgs.happy bootPkgs.hscolour
    autoreconfHook ]
  ++ lib.optional useLdLld llvmPackages.bintools
  ++ lib.optional (targetPlatform.isWasm) nodejs;

  # For building runtime libs
  depsBuildTarget = toolsForTarget;

  buildInputs = [ perl bash ] ++ (libDeps hostPlatform);

  depsTargetTarget = lib.optionals (!targetPlatform.isGhcjs) (map lib.getDev (libDeps targetPlatform));
  depsTargetTargetPropagated = lib.optionals (!targetPlatform.isGhcjs) (map (lib.getOutput "out") (libDeps targetPlatform))
    # Needs to be propagated for `ffi.h`
    ++ lib.optional targetPlatform.isWasm (lib.getDev targetLibffi);

  # required, because otherwise all symbols from HSffi.o are stripped, and
  # that in turn causes GHCi to abort
  stripDebugFlags = [ "-S" ] ++ lib.optional (!targetPlatform.isDarwin) "--keep-file-symbols";

  # See #63511 - the only unstripped file is the debug rts which isn't meant to
  # be stripped.
  stripDebugList = [ "lib/${name}/bin" ];

  checkTarget = "test";

  hardeningDisable = [ "format" "stackprotector" ]
                   ++ lib.optional stdenv.targetPlatform.isAarch32 "pic"
                   ++ lib.optional (stdenv.targetPlatform.isMusl && builtins.elem "pie" (targetCC.defaultHardeningFlags or [])) "pie"
                   ++ lib.optional enableDWARF "fortify";

  postInstall = lib.optionalString (enableNUMA && targetPlatform.isLinux && !targetPlatform.isAarch32 && !targetPlatform.isAndroid) ''
    # Patch rts.conf to ensure libnuma can be found

    for file in $(find "$out/lib" -name "rts*.conf"); do
      if grep -q numa $file; then
        substituteInPlace $file \
          --replace "library-dirs:" "library-dirs: ${targetNumactl}/lib" \
          --replace "include-dirs:" "include-dirs: ${targetNumactl}/include"
        "$out/bin/${targetPrefix}ghc-pkg" recache
      fi
    done
  ''
  # GHC's configure is regenerated here via autoreconfHook using the host
  # autoconf. As of autoconf 2.72.90, AC_PROG_CC prefers C23 if available, so it
  # appends the newest C standard flag the compiler accepts (e.g. -std=gnu23 with
  # clang 21, which supports but does not default to C23) to $CC. GHC then bakes
  # $CC verbatim into the "C compiler command" / "C++ compiler command" /
  # "Haskell CPP command" settings fields, tries to exec a binary literally named
  # "cc -std=gnu23", and fails with "could not execute". Move the std flag out of
  # each command field into its matching flags field.
  #
  # Earlier autoconf (<= 2.72) only prefers C11, which clang already defaults to,
  # so no flag is appended and the settings fields are unaffected. The gate keeps
  # existing GHC derivations byte-for-byte identical on those.
  # autoconf NEWS (2.72.90, 2026-02-03):
  # https://raw.githubusercontent.com/autotools-mirror/autoconf/master/NEWS
  + lib.optionalString (builtins.compareVersions autoconf.version "2.72.90" >= 0) ''
    for settingsFile in "$out/lib/settings" "$out/lib/ghc-"*"/lib/settings"; do
      [ -f "$settingsFile" ] || continue
      perl -0777 -i -pe '
        for my $base ("C compiler", "C++ compiler", "Haskell CPP") {
          my $std = "";
          s/(\Q"$base command"\E,\s*"[^"]*?) (-std=\S+?)"/$std=$2;"$1\""/ge;
          s/(\Q"$base flags"\E,\s*")/"$1$std "/e if $std ne "";
        }
      ' "$settingsFile"
    done
  '' + ''
    # Install the bash completion file.
    install -D -m 444 utils/completion/ghc.bash $out/share/bash-completion/completions/${targetPrefix}ghc

    # Patch scripts to include "readelf" and "cat" in $PATH.
    for i in "$out/bin/"*; do
      test ! -h $i || continue
      egrep --quiet '^#!' <(head -n 1 $i) || continue
      # The ghcprog fixup is for musl (where runhaskell script just needs to point to the correct
      # ghc program to work).
      sed -i \
        -e '2i export PATH="$PATH:${lib.makeBinPath (lib.optionals (!targetPlatform.isGhcjs) [ targetPackages.stdenv.cc.bintools coreutils ])}"' \
        -e 's/ghcprog="ghc-/ghcprog="${targetPrefix}ghc-/' \
        $i
    done

    ${
      # Save generated files needed when building:
      # * The reinstallable `ghc` package (see overlays/ghc-packages.nix)
      # * The `ghcjs` package (see lib/ghcjs-project.nix).
      if useHadrian
        then
          ''
            mkdir -p $generated/includes
            if [[ -f _build/stage1/lib/ghcplatform.h ]]; then
              cp _build/stage1/lib/ghcplatform.h $generated/includes
            fi
            if [[ -f _build/stage1/compiler/build/GHC/PlatformConstants.hs ]]; then
              mkdir -p $generated/compiler/stage2/build/GHC/Platform
              cp _build/stage1/compiler/build/GHC/Platform/Constants.hs $generated/compiler/stage2/build/GHC/Platform
            fi
            mkdir -p $generated/compiler/stage2/build
            if [[ -f _build/stage1/compiler/build/GHC/Settings/Config.hs ]]; then
              mkdir -p $generated/compiler/stage2/build/GHC/Settings
              cp _build/stage1/compiler/build/GHC/Settings/Config.hs $generated/compiler/stage2/build/GHC/Settings
            fi
            if [[ -f compiler/GHC/CmmToLlvm/Version/Bounds.hs ]]; then
              mkdir -p $generated/compiler/GHC/CmmToLlvm/Version
              cp compiler/GHC/CmmToLlvm/Version/Bounds.hs $generated/compiler/GHC/CmmToLlvm/Version/Bounds.hs
            fi
            cp _build/stage1/compiler/build/*.hs-incl $generated/compiler/stage2/build || true
          ''
          # Save generated files for needed when building ghc-boot
          # NB: the `Version.hss` guard below is a long-standing typo — it
          # never matches, so this output ships without ghc-boot's
          # `Version.hs`.  Left un-fixed deliberately: this string is part
          # of the GHC derivation, so correcting it would rebuild every
          # hadrian GHC.  All consumers prefer `generated-light` (which
          # copies `Version.hs` correctly) via
          # `ghc.generated-light or ghc.generated`.
          + ''
            mkdir -p $generated/libraries/ghc-boot/dist-install/build/GHC/Platform
            if [[ -f _build/stage1/libraries/ghc-boot/build/GHC/Version.hss ]]; then
              cp _build/stage1/libraries/ghc-boot/build/GHC/Version.hs $generated/libraries/ghc-boot/dist-install/build/GHC/Version.hs
            fi
            if [[ -f _build/stage1/libraries/ghc-boot/build/GHC/Platform/Host.hs ]]; then
              cp _build/stage1/libraries/ghc-boot/build/GHC/Platform/Host.hs $generated/libraries/ghc-boot/dist-install/build/GHC/Platform/Host.hs
            fi
          ''
          # Convert ${pkgroot} relative paths to /nix/store paths
          + ''
            for f in "$out/${packageConfDir}/"*.conf; do
              sed -i -e "s|\''${pkgroot}/../lib/|$out/${rootDir}lib/|" \
                     -e "s|\''${pkgroot}/../share/|$out/${rootDir}share/|" \
                     -e "s|\''${pkgroot}/../../../share/doc/|$doc/share/doc/|" $f
            done
          ''
        else
          ''
            mkdir -p $generated/includes/dist-derivedconstants/header
            cp includes/dist-derivedconstants/header/GHCConstantsHaskell*.hs \
               $generated/includes/dist-derivedconstants/header
            if [[ -f includes/ghcplatform.h ]]; then
              cp includes/ghcplatform.h $generated/includes
            elif [[ -f includes/dist-install/build/ghcplatform.h ]]; then
              cp includes/dist-install/build/ghcplatform.h $generated/includes
            fi
            mkdir -p $generated/compiler/stage2/build
            cp compiler/stage2/build/Config.hs $generated/compiler/stage2/build || true
            if [[ -f compiler/stage2/build/GHC/Platform/Constants.hs ]]; then
              mkdir -p $generated/compiler/stage2/build/GHC/Platform
              cp compiler/stage2/build/GHC/Platform/Constants.hs $generated/compiler/stage2/build/GHC/Platform
            fi
            if [[ -f compiler/stage2/build/GHC/Settings/Config.hs ]]; then
              mkdir -p $generated/compiler/stage2/build/GHC/Settings
              cp compiler/stage2/build/GHC/Settings/Config.hs $generated/compiler/stage2/build/GHC/Settings
            fi
            cp compiler/stage2/build/*.hs-incl $generated/compiler/stage2/build || true
            mkdir -p $generated/rts/build
            cp rts/build/config.hs-incl $generated/rts/build || true

            # Save generated files for needed when building ghc-boot
            mkdir -p $generated/libraries/ghc-boot/dist-install/build/GHC/Platform
            if [[ -f libraries/ghc-boot/dist-install/build/GHC/Version.hs ]]; then
              cp libraries/ghc-boot/dist-install/build/GHC/Version.hs $generated/libraries/ghc-boot/dist-install/build/GHC/Version.hs
            fi
            if [[ -f libraries/ghc-boot/dist-install/build/GHC/Platform/Host.hs ]]; then
              cp libraries/ghc-boot/dist-install/build/GHC/Platform/Host.hs $generated/libraries/ghc-boot/dist-install/build/GHC/Platform/Host.hs
            fi
        ''
    }

    # Sanity checks for https://github.com/input-output-hk/haskell.nix/issues/660
    if ! "$out/bin/${targetPrefix}ghc" --version; then
      echo "ERROR: Missing file $out/bin/${targetPrefix}ghc"
      exit 1
    fi
    if ! "$out/bin/${targetPrefix}ghc-pkg" --version; then
      echo "ERROR: Missing file $out/bin/${targetPrefix}ghc-pkg"
      exit 1
    fi
    if [[ ! -d "$out/${packageConfDir}" ]]; then
      echo "ERROR: Missing directory $out/${packageConfDir}"
      exit 1
    fi
    if (( $(ls -1 "$out/${packageConfDir}" | wc -l) < 30 )); then
      echo "ERROR: Expected more files in $out/${packageConfDir}"
      exit 1
    fi
    '';

  passthru = {
    inherit bootPkgs targetPrefix libDir llvmPackages enableShared enableTerminfo useLLVM useLdLld hadrian hadrianProject;

    # The plan-nix derivations that must be realised (via IFD) to evaluate
    # this compiler.  `haskell-nix.roots` links them (and, when the eval
    # system differs from the build system, the `evalWith` variant's) so CI
    # pushes them to the binary cache and later evaluations substitute the
    # plans instead of building them mid-eval.
    plan-nixes = lib.optionalAttrs useHadrian { hadrian = hadrianProject.plan-nix; };

    # Our Cabal compiler name
    haskellCompilerName = "ghc-${version}";

    # This uses a similar trick to `pkgs.srcOnly` to get the configured src
    # We could add `configured-src` as an output of the ghc derivation, but
    # having it as its own derivation means it can be accessed quickly without
    # building GHC.
    # Plain value for THIS compiler's eval platform (its `evalSystem`): the
    # source tree built on the eval host, from which plan-to-nix reads bundled
    # `.cabal` files.  Consumers select `ghc.evalWith.${evalSystem}.raw-src`
    # (attribute selection is memoised) rather than calling a function; the eval
    # nixpkgs comes from the memoised per-system `haskell-nix.evalPackages`.
    raw-src = let evalPackages = pkgsBuildBuild.haskell-nix.evalPackages.${evalSystem};
      in evalPackages.stdenv.mkDerivation {
      name = name + "-raw-src";
      inherit
        version
        patches
        src;
      installPhase = ''
        cp -r . $out
      '';
      phases = [ "unpackPhase" "patchPhase" "installPhase"];
    };
    configured-src = stdenv.mkDerivation ({
      name = name + "-configured-src";
      inherit
        buildInputs
        version
        nativeBuildInputs
        patches
        src
        strictDeps
        depsBuildTarget
        depsTargetTarget
        depsTargetTargetPropagated
        postPatch
        preConfigure
        configurePlatforms
        configureFlags
        outputs
        ;

      # Including all the outputs (not just $out) causes `mkDerivation` to use the nixpkgs multiple-outputs.sh hook.
      # This hook changes the arguments passed to `configure`.
      installPhase = ''
        cp -r . $out
        mkdir $doc
        mkdir $generated
      '';
      phases = [ "unpackPhase" "patchPhase" "autoreconfPhase"
                 "configurePhase" "installPhase"];
     } // lib.optionalAttrs useHadrian {
      postConfigure = ''
        for a in libraries/*/*.cabal.in utils/*/*.cabal.in compiler/ghc.cabal.in; do
          ${hadrian}/bin/hadrian ${hadrianArgs} "''${a%.*}"
        done
      '' + lib.optionalString (stdenv.isDarwin && (__tryEval libcxxabi).success) ''
        substituteInPlace mk/system-cxx-std-lib-1.0.conf \
          --replace 'dynamic-library-dirs:' 'dynamic-library-dirs: ${libcxx}/lib ${libcxxabi}/lib'
        find . -name 'system*.conf*'
        cat mk/system-cxx-std-lib-1.0.conf
      '' + lib.optionalString (stdenv.isDarwin && !(__tryEval libcxxabi).success) ''
        substituteInPlace mk/system-cxx-std-lib-1.0.conf \
          --replace 'dynamic-library-dirs:' 'dynamic-library-dirs: ${libcxx}/lib'
        find . -name 'system*.conf*'
        cat mk/system-cxx-std-lib-1.0.conf
      '' + lib.optionalString (installStage1 && haskell-nix.haskellLib.isNativeMusl) ''
        substituteInPlace hadrian/cfg/system.config \
          --replace 'cross-compiling       = YES' \
                    'cross-compiling       = NO'
      '';
    } // lib.optionalAttrs targetPlatform.isGhcjs {
      # Backup the config.sub that knows what `ghcjs` is in case
      # `autoreconfPhase` replaces it
      postPatch = ''
        cp config.sub config.sub.ghcjs
      '';
    });

    # Lightweight replacement for the `generated` *output*.
    #
    # The `generated` output above is harvested from `_build/stage1` *after a
    # full GHC build*, so anything that consumes `ghc.generated` at evaluation
    # time (e.g. `useLocalGhcLib = true` / the `ghc-lib-reinstallable` test,
    # whose source-repository-package is `configured-src + generated` and must
    # be realised during plan-to-nix to compute the v2 UnitId) forces the whole
    # compiler to be built via IFD.
    #
    # None of the files we actually keep need the built compiler: they are
    # exactly hadrian's `compilerDependencies` (hadrian/src/Rules/Generate.hs),
    # whose generators (`genprimopcode`, `deriveConstants`, template
    # substitution) run in `stage0Boot` — i.e. with the *boot* compiler.  So we
    # ask hadrian to build only those file targets, which skips the stage1
    # library compile entirely (minutes instead of hours) and is independently
    # cacheable.
    generated-light = stdenv.mkDerivation ({
      name = name + "-generated";
      inherit
        buildInputs
        version
        patches
        src
        strictDeps
        depsBuildTarget
        depsTargetTarget
        depsTargetTargetPropagated
        nativeBuildInputs
        postPatch
        preConfigure
        configurePlatforms
        configureFlags
        ;
      # The main GHC derivation sets these at its top level, but this is a
      # separate `mkDerivation` that inherits an explicit list of attributes,
      # so it has to ask for them again.  Without them `LANG` is unset in the
      # sandbox, glibc reports the ASCII codeset, and hadrian's locale-encoded
      # `readFile'` of `primops.txt` dies on the `“safe”` in the
      # `keepAlive#` docs:
      #
      #   primops.txt: hGetContents: invalid argument
      #     (cannot decode byte sequence starting from 226)
      #
      # Narrow in practice, which is why it took a while to show up: only a
      # hadrian older than 9.8 decodes the file in-process at all (9.8's
      # `Builder.hs` swapped `readFile'` + `Stdin` for `FileStdin`, handing
      # the subprocess a raw fd), and only 9.6/9.8 still have non-ASCII in
      # `primops.txt.pp` (9.10 spells the quotes with ASCII).  So it hit
      # exactly ghc96x on Linux; Darwin passed because its locale encoding is
      # UTF-8 even with `LANG` unset.
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
      phases = [ "unpackPhase" "patchPhase" "autoreconfPhase"
                 "configurePhase" "buildPhase" "installPhase" ];
      # Same as `configured-src`: generate the `.cabal` files from the
      # `.cabal.in` templates so hadrian can set the packages up.
      postConfigure = ''
        for a in libraries/*/*.cabal.in utils/*/*.cabal.in compiler/ghc.cabal.in; do
          ${hadrian}/bin/hadrian ${hadrianArgs} "''${a%.*}"
        done
      '';
      buildPhase = ''
        runHook preBuild
        # Only the generated-source targets — hadrian builds their prerequisites
        # (genprimopcode / deriveConstants, both stage0Boot) but NOT lib:ghc.
        #
        # The set of `primop-*.hs-incl` files differs between GHC versions (GHC
        # 9.14.1 dropped them entirely; older GHCs have ~20).  Rather than
        # hardcode a version-specific list, read the authoritative set from
        # hadrian's own `compilerDependencies` (Rules/Generate.hs), so this
        # works for every GHC we build.
        primopIncls=$(grep -oE 'primop-[A-Za-z0-9-]+\.hs-incl' hadrian/src/Rules/Generate.hs 2>/dev/null | sort -u)
        echo "generated-light: primop includes:"; echo "$primopIncls" | sed 's/^/  /'
        # NB: `-j1`.  genprimopcode is occasionally invoked without its mode
        # argument under hadrian's parallel scheduler; serialising is reliable
        # and cheap (each genprimopcode/deriveConstants run is sub-second).
        ${hadrian}/bin/hadrian ${hadrianArgs} -j1 \
          _build/stage1/compiler/build/GHC/Platform/Constants.hs \
          _build/stage1/compiler/build/GHC/Settings/Config.hs \
          _build/stage1/libraries/ghc-boot/build/GHC/Version.hs \
          _build/stage1/libraries/ghc-boot/build/GHC/Platform/Host.hs \
          $(for f in $primopIncls; do echo "_build/stage1/compiler/build/$f"; done)
        runHook postBuild
      '';
      # Same layout as the `generated` output's population block above, but
      # written to `$out`.  (The `.hss` typo in that block means the output
      # never actually contained ghc-boot's `Version.hs`; this copies it.)
      installPhase = ''
        mkdir -p $out/includes
        if [[ -f _build/stage1/lib/ghcplatform.h ]]; then
          cp _build/stage1/lib/ghcplatform.h $out/includes
        fi
        mkdir -p $out/compiler/stage2/build/GHC/Platform
        if [[ -f _build/stage1/compiler/build/GHC/Platform/Constants.hs ]]; then
          cp _build/stage1/compiler/build/GHC/Platform/Constants.hs $out/compiler/stage2/build/GHC/Platform
        fi
        if [[ -f _build/stage1/compiler/build/GHC/Settings/Config.hs ]]; then
          mkdir -p $out/compiler/stage2/build/GHC/Settings
          cp _build/stage1/compiler/build/GHC/Settings/Config.hs $out/compiler/stage2/build/GHC/Settings
        fi
        if [[ -f compiler/GHC/CmmToLlvm/Version/Bounds.hs ]]; then
          mkdir -p $out/compiler/GHC/CmmToLlvm/Version
          cp compiler/GHC/CmmToLlvm/Version/Bounds.hs $out/compiler/GHC/CmmToLlvm/Version/Bounds.hs
        fi
        cp _build/stage1/compiler/build/*.hs-incl $out/compiler/stage2/build || true
        mkdir -p $out/libraries/ghc-boot/dist-install/build/GHC/Platform
        if [[ -f _build/stage1/libraries/ghc-boot/build/GHC/Version.hs ]]; then
          cp _build/stage1/libraries/ghc-boot/build/GHC/Version.hs $out/libraries/ghc-boot/dist-install/build/GHC/Version.hs
        fi
        if [[ -f _build/stage1/libraries/ghc-boot/build/GHC/Platform/Host.hs ]]; then
          cp _build/stage1/libraries/ghc-boot/build/GHC/Platform/Host.hs $out/libraries/ghc-boot/dist-install/build/GHC/Platform/Host.hs
        fi
      '';
    } // lib.optionalAttrs (stdenv.buildPlatform.libc == "glibc") {
      # `en_US.UTF-8` only resolves if the locale archive is on hand.
      LOCALE_ARCHIVE = "${buildPackages.glibcLocales}/lib/locale/locale-archive";
    } // lib.optionalAttrs targetPlatform.isGhcjs {
      postPatch = ''
        cp config.sub config.sub.ghcjs
      '';
    });

    # Used to detect non haskell-nix compilers (accidental use of nixpkgs compilers can lead to unexpected errors)
    isHaskellNixCompiler = true;

    # The same GHC, but with debug enabled (if it can be)
    dwarf = lib.makeOverridable self (args // {
      enableDWARF = stdenv.targetPlatform.isLinux
        && builtins.compareVersions ghc-version "8.10.2" >= 0;
    });

    # The same GHC, but without the large (1TB) address space reservation
    smallAddressSpace = lib.makeOverridable self (args // {
      disableLargeAddressSpace = true;
    });
  } // extra-passthru // {
    buildGHC = extra-passthru.buildGHC.evalWith.${evalSystem} or (extra-passthru.buildGHC.override { inherit evalSystem; });
  };

  meta = {
    homepage = "https://haskell.org/ghc";
    description = "The Glasgow Haskell Compiler";
    maintainers = [];
    inherit (ghc.meta) license platforms;
  };

  # Needed for `haddock` to work on source that includes non ASCII chars
  LANG = "en_US.UTF-8";
  LC_ALL = "en_US.UTF-8";
} // lib.optionalAttrs targetPlatform.isGhcjs {
  # Backup the config.sub that knows what `ghcjs` is in case
  # `autoreconfPhase` replaces it
  postPatch = ''
    cp config.sub config.sub.ghcjs
  '';
} // lib.optionalAttrs (stdenv.buildPlatform.libc == "glibc") {
  LOCALE_ARCHIVE = "${buildPackages.glibcLocales}/lib/locale/locale-archive";
} // lib.optionalAttrs targetPlatform.useAndroidPrebuilt {
  dontStrip = true;
  dontPatchELF = true;
  noAuditTmpdir = true;
} // {
  # ghc install on macOS wants to run `xattr -r -c`
  # The macOS version fails because it wants python 2.
  # The nix version of xattr does not support those args.
  # Luckily setting the path to something that does not exist will skip the step.
  preBuild = lib.optionalString stdenv.buildPlatform.isDarwin ''
    export XATTR=$(mktemp -d)/nothing
  ''
  # We need to point at a stand in `windows.h` header file so that the RTS headers can
  # work on the hostPlatform.  We also need to work around case sensitive file system issues.
  + lib.optionalString stdenv.targetPlatform.isWindows ''
    export NIX_CFLAGS_COMPILE_${
        # We want this only to apply to the non windows hostPlatform (the
        # windows gcc cross compiler has a full `windows.h`).
        # This matches the way `suffixSalt` is calculated in nixpkgs.
        # See https://github.com/NixOS/nixpkgs/blob/8411006d6bcd7f6e6a8a1a80ce8fcdccdd16c6ab/pkgs/build-support/cc-wrapper/default.nix#L58
        lib.replaceStrings ["-" "."] ["_" "_"] stdenv.hostPlatform.config
      }+=" -I${../windows/include}"
    if [[ -f libraries/base/include/winio_structs.h ]]; then
      substituteInPlace libraries/base/include/winio_structs.h --replace Windows.h windows.h
    fi
    if [[ -f rts/win32/ThrIOManager.c ]]; then
      substituteInPlace rts/win32/ThrIOManager.c --replace rts\\OSThreads.h rts/OSThreads.h
    fi
  '';
  # Same hack as 'preBuild'
  preInstall = lib.optionalString stdenv.buildPlatform.isDarwin ''
    export XATTR=$(mktemp -d)/nothing
  '';
} // lib.optionalAttrs useHadrian {
  preUnpack = ''
    mkdir -p $out/build
    cd $out/build
  '';
  postConfigure = lib.optionalString (stdenv.isDarwin && (__tryEval libcxxabi).success) ''
    substituteInPlace mk/system-cxx-std-lib-1.0.conf \
      --replace 'dynamic-library-dirs:' 'dynamic-library-dirs: ${libcxx}/lib ${libcxxabi}/lib'
    find . -name 'system*.conf*'
    cat mk/system-cxx-std-lib-1.0.conf
  '' + lib.optionalString (stdenv.isDarwin && !(__tryEval libcxxabi).success) ''
    substituteInPlace mk/system-cxx-std-lib-1.0.conf \
      --replace 'dynamic-library-dirs:' 'dynamic-library-dirs: ${libcxx}/lib'
    find . -name 'system*.conf*'
    cat mk/system-cxx-std-lib-1.0.conf
  '' + lib.optionalString (installStage1 && haskell-nix.haskellLib.isNativeMusl) ''
    substituteInPlace hadrian/cfg/system.config \
      --replace 'cross-compiling       = YES' \
                'cross-compiling       = NO'
  '';
  buildPhase = ''
    runHook preBuild
  '' + lib.optionalString (!enableShared && targetPlatform.isAndroid && targetPlatform.isAarch64)
  # This is rather idiotic, but we need to create the dynamic (.so) files because
  # hadrian expects them in the src/Rules/Rts.hs:160 or thereabout.
  ''
      mkdir -p _build/stage1/lib/aarch64-android-ghc-${ghc-version}/
      touch _build/stage1/lib/aarch64-android-ghc-${ghc-version}/libHSrts-1.0.2_thr_debug-ghc${ghc-version}.so
      touch _build/stage1/lib/aarch64-android-ghc-${ghc-version}/libHSrts-1.0.2_thr-ghc${ghc-version}.so
      touch _build/stage1/lib/aarch64-android-ghc-${ghc-version}/libHSrts-1.0.2_debug-ghc${ghc-version}.so
      touch _build/stage1/lib/aarch64-android-ghc-${ghc-version}/libHSrts-1.0.2-ghc${ghc-version}.so
  '' + lib.optionalString (!enableShared && targetPlatform.isAndroid && targetPlatform.isAarch32)
  # This is rather idiotic, but we need to create the dynamic (.so) files because
  # hadrian expects them in the src/Rules/Rts.hs:160 or thereabout.
  ''
      mkdir -p _build/stage1/lib/arm-android-ghc-${ghc-version}/
      touch _build/stage1/lib/arm-android-ghc-${ghc-version}/libHSrts-1.0.2_thr_debug-ghc${ghc-version}.so
      touch _build/stage1/lib/arm-android-ghc-${ghc-version}/libHSrts-1.0.2_thr-ghc${ghc-version}.so
      touch _build/stage1/lib/arm-android-ghc-${ghc-version}/libHSrts-1.0.2_debug-ghc${ghc-version}.so
      touch _build/stage1/lib/arm-android-ghc-${ghc-version}/libHSrts-1.0.2-ghc${ghc-version}.so
  ''
  + ''
    ${hadrian}/bin/hadrian ${hadrianArgs}
  '' + lib.optionalString (installStage1 && !stdenv.targetPlatform.isGhcjs && builtins.compareVersions ghc-version "9.8" < 0) ''
    ${hadrian}/bin/hadrian ${hadrianArgs} stage1:lib:libiserv
  '' + lib.optionalString targetPlatform.isMusl ''
    ${hadrian}/bin/hadrian ${hadrianArgs} stage1:lib:terminfo
  '' + lib.optionalString (installStage1 && !haskell-nix.haskellLib.isCrossTarget) ''
    ${hadrian}/bin/hadrian ${hadrianArgs} stage2:exe:iserv
    ${hadrian}/bin/hadrian ${hadrianArgs} _build/stage1/${
        lib.optionalString (builtins.compareVersions ghc-version "9.9" < 0) "lib/"}bin/ghc-iserv-prof
    pushd _build/stage1/bin
    for exe in *; do
      mv $exe ${targetPrefix}$exe
    done
    popd
  '' + ''
    runHook postBuild
  '';

  # Hadrian's installation only works for native compilers, and is broken for cross compilers.
  # However Hadrian produces mostly relocatable installs anyway, so we can simply copy
  # stage1/{bin, lib, share} into the destination as the copy phase.

  installPhase =
    if installStage1
      then ''
        cp -r _build/stage1/bin $out
        # let's assume that if we find a non-prefixed genprimop,
        # we also find a non-prefixed deriveConstants
        if [ -f _build/stageBoot/bin/genprimopcode ]; then
          cp _build/stageBoot/bin/genprimopcode $out/bin
          cp _build/stageBoot/bin/deriveConstants $out/bin
        else
          cp _build/stageBoot/bin/${targetPrefix}genprimopcode $out/bin
          ln -s $out/bin/${targetPrefix}genprimopcode $out/bin/genprimopcode
          cp _build/stageBoot/bin/${targetPrefix}deriveConstants $out/bin
          ln -s $out/bin/${targetPrefix}deriveConstants $out/bin/deriveConstants
        fi
        cp -r _build/stage1/lib $out
        mkdir $doc
        cp -r _build/stage1/share $doc
        runHook postInstall
        cd $out
        rm -rf $out/build
      ''
      # there appears to be a bug in GHCs configure script not properly passing dllwrap, and windres to the
      # generated settings file. Hence we patch it back in here.
      + lib.optionalString (targetPlatform.isWindows) ''
        substituteInPlace $out/lib/settings \
          --replace ',("dllwrap command", "/bin/false")' ',("dllwrap command", "${targetCC.bintools.targetPrefix}dllwrap")' \
          --replace ',("windres command", "/bin/false")' ',("windres command", "${targetCC.bintools.targetPrefix}windres")'
      ''
      else ''
        runHook preInstall
        ${hadrian}/bin/hadrian ${hadrianArgs} binary-dist-dir
        cd _build/bindist/ghc-*
        ./configure --prefix=$out ${lib.concatStringsSep " " configureFlags}${
          # Pre-answer GHC's C++ standard library probe on Darwin.
          #
          # FP_FIND_CXX_STD_LIB (m4/fp_find_cxx_std_lib.m4) links a test object
          # with `"$CC" -o actest actest.o -lc++ -lc++abi -L"$d" 2>/dev/null`.
          # autoconf >= 2.72 appends the C23 option to CC when the compiler needs
          # one, so in *this* configure run CC is two words
          # ("…/bin/cc -std=gnu23"); the quoted "$CC" is then executed as a single
          # filename, every candidate library set "fails" (the exec error being
          # what 2>/dev/null discards), and configure aborts with
          # "Failed to find C++ standard library" — after the whole compiler has
          # already been built.  The source tree's own configure is unaffected
          # because its CC stays one word, which is why only this second,
          # bindist configure broke, and only for some GHC versions.
          #
          # A non-empty CXX_STD_LIB_LIBS makes the macro skip the probe entirely.
          # The matching *_DIRS variables are deliberately left unset: a
          # successful probe ends up with them empty too (it maps its `-L.` answer
          # to ""), and the dynamic-library-dirs of system-cxx-std-lib-1.0.conf
          # are filled in just below.
          lib.optionalString stdenv.isDarwin " CXX_STD_LIB_LIBS='c++ c++abi'"}
        ${lib.optionalString (stdenv.isDarwin && (__tryEval libcxxabi).success) ''
          substituteInPlace mk/system-cxx-std-lib-1.0.conf \
            --replace 'dynamic-library-dirs:' 'dynamic-library-dirs: ${libcxx}/lib ${libcxxabi}/lib'
          substituteInPlace lib/package.conf.d/system-cxx-std-lib-1.0.conf \
            --replace 'dynamic-library-dirs:' 'dynamic-library-dirs: ${libcxx}/lib ${libcxxabi}/lib'
        ''}
        ${lib.optionalString (stdenv.isDarwin && !(__tryEval libcxxabi).success) ''
          substituteInPlace mk/system-cxx-std-lib-1.0.conf \
            --replace 'dynamic-library-dirs:' 'dynamic-library-dirs: ${libcxx}/lib'
          substituteInPlace lib/package.conf.d/system-cxx-std-lib-1.0.conf \
            --replace 'dynamic-library-dirs:' 'dynamic-library-dirs: ${libcxx}/lib'
        ''}
        mkdir -p utils
        cp -r ../../../utils/completion utils
        make install
        cd ../../..
        runHook postInstall
        cd $out
        rm -rf $out/build
      '';
}));
in self
