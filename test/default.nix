{ haskellNix ? import ../default.nix { inherit checkMaterialization; }
, pkgs ? import nixpkgs nixpkgsArgs
, nixpkgs ? haskellNix.sources.nixpkgs-unstable
, nixpkgsArgs ? haskellNix.nixpkgsArgs // {
    # Needed for dwarf tests
    config = haskellNix.nixpkgsArgs.config // {
      permittedInsecurePackages = ["libdwarf-20210528" "libdwarf-20181024" "dwarfdump-20181024"];
    };
    overlays = haskellNix.nixpkgsArgs.overlays ++ [
      (final: prev: {
        haskell-nix = prev.haskell-nix // {
          extraPkgconfigMappings = prev.haskell-nix.extraPkgconfigMappings or {} // {
            "libsodium" = [ "libsodium-18" ];
          };
        };
        # The android `iserv-proxy-interpreter` is linked statically (qemu-user-mode
        # cannot satisfy Android's dynamic loader on the build host -- see the
        # `-optl-static` comment in `overlays/haskell.nix`), so its `dlopen` is the
        # NDK's stub, which always fails with "libdl.a is a stub --- use libdl.so
        # instead".  When GHC resolves a package's `extra-libraries` its RTS linker
        # looks for a shared object BEFORE an archive, so shipping `libsodium.so`
        # takes out every external-interpreter TH splice that touches libsodium
        # (`th-dlls` calls `sodium_init` from one).  Build only the static library
        # for android, as `overlays/android.nix` already does for
        # zlib/openssl/gmp6/libffi/libiconv.
        libsodium-18 = (final.callPackage (haskellNix.sources.nixpkgs-2311 + "/pkgs/development/libraries/libsodium") {}).overrideAttrs (old: {
          dontDisableStatic = true;
          configureFlags = (old.configureFlags or [])
            ++ final.lib.optional final.stdenv.hostPlatform.isAndroid "--disable-shared";
        });
      })
    ];
  }
, evalPackages ? import pkgs.path nixpkgsArgs
, evalSystem ? evalPackages.stdenv.hostPlatform.system
, ifdLevel ? 1000
, compiler-nix-name
, CADerivationsEnabled ? false
, checkMaterialization ? false
}:

with pkgs;

let
  inherit (import ../ci-lib.nix { inherit lib; }) filterAttrsOnlyRecursive;
  isDisabled = d: d.meta.disabled or false;

  # Set recurseForDerivations for both children and grand-children values in
  # the input association list, but only if the key is "ifdInputs".
  #
  # withIfdInputs :: AttrSet -> AttrSet
  #
  # The values in the input attribute set must be attribute sets themselves.
  #
  # >>> withIfdInputs { ifdInputs = { plan-nix = { a = true; b = "hello"; }; }; cat = 2; }
  # { ifdInputs = {
  #     plan-nix = {
  #       a = true;
  #       b = "hello";
  #       recurseForDerivations = true;
  #     };
  #     recurseForDerivations = true;
  #   };
  #   cat = 2;
  # }
  #
  # >>> withIfdInputs { dog = "hello"; }
  # { dog = "hello"; }
  #
  # >>> withIfdInputs { }
  # { }
  withIfdInputs =
    builtins.mapAttrs
      (name: val:
        if name == "ifdInputs"
        then
          pkgs.lib.recurseIntoAttrs
            (builtins.mapAttrs (_: v: pkgs.haskell-nix.withInputs v) val)
        else val
      );

  util = import ./util.nix { cabal-install = pkgs.buildPackages.haskell-nix.nix-tools-unchecked.exes.cabal; };

  # Map the values in an association list over the withIfdInputs function.
  #
  # addIfdInputsToVal :: AttrSet -> AttrSet
  #
  # The values in the input association list must be attribute sets themselves.
  addIfdInputsToVal = builtins.mapAttrs (_: val: withIfdInputs val);

  # Keep only the attribute with the key "ifdInputs" and "meta".
  # Meta is needed for `meta.disabled` to work at this level.
  #
  # filterAttrsIfdInputs :: AttrSet -> AttrSet
  #
  # >>> filterAttrsIfdInputs { ifdInputs = 1; foobar = 2 }
  # { ifdInputs = 1 }
  #
  # >>> filterAttrsIfdInputs { foobar = "hello" }
  # { }
  filterAttrsIfdInputs = pkgs.lib.filterAttrs (n: _: n == "ifdInputs" || n == "meta");

  # Remove all keys and values in a attribute set where the key
  # doesn't equal "ifdInputs".  Set the "recurseForDerivations"
  # key in the resulting value.
  #
  # filterNonIfdInputsSetRecurse :: AttrSet -> AttrSet
  #
  # >>> filterNonIfdInputsSetRecurse { ifdInputs = 1; foobar = 2 }
  # { ifdInputs = 1; recurseForDerivations = true }
  #
  # >>> filterNonIfdInputsSetRecurse { foobar = "hello" }
  # { recurseForDerivations = true; }
  filterNonIfdInputsSetRecurse = attrs:
    pkgs.lib.recurseIntoAttrs (filterAttrsIfdInputs attrs);

  # Filter all out all the keys/values for child values of this attribute set
  # where the key is not equal to "ifdInputs".
  #
  # filterNonIfdInputsValues :: AttrSet -> AttrSet
  #
  # The values in the input AttrSet must be attribute sets themselves.
  #
  # >>> filterNonIfdInputsValues { foo = { ifdInputs = 1; cat = 2; }; bar = { dog = "hello"; }; }
  # { foo = {
  #     ifdInputs = 1;
  #     recurseForDerivations = true;
  #   };
  #   bar = {
  #     recurseForDerivations = true;
  #   };
  # }
  #
  # >>> filterNonIfdInputsValues { }
  # { }
  filterNonIfdInputsValues = attrs:
    builtins.mapAttrs (_: d: filterNonIfdInputsSetRecurse d) attrs;

  # Call filterNonIfdInputsValues on the input attribute set, but only
  # if ifdLevel is less than 3.  Otherwise, just return the attribute set.
  #
  # filterNonIfdInputsValuesLTLevel3 :: AttrSet -> AttrSet
  #
  # >>> filterNonIfdInputsValuesLTLevel3 2 { cabal-doctests = { ifdInputs = {...}; run = ""; }; cabal-simple = { run = ""; }; }
  # { cabal-doctests = {
  #     ifdInputs = {...};
  #     recurseForDerivations = true;
  #   };
  #   cabal-simple = {
  #     recurseForDerivations = true;
  #   };
  # }
  #
  # >>> filterNonIfdInputsValuesLTLevel3 1000 { cabal-doctests = { ifdInputs = {...}; run = "..."; }; cabal-simple = { run = "..."; }; }
  # { cabal-doctests = {
  #     ifdInputs = {...};
  #     run = "...";
  #     recurseForDerivations = true;
  #   };
  #   cabal-simple = {
  #     run = "...";
  #     recurseForDerivations = true;
  #   };
  # }
  #
  # >>> filterNonIfdInputsValuesLTLevel3 0 { }
  # { }
  filterNonIfdInputsValuesLTLevel3 = ifdLevel: attrs:
    if ifdLevel < 3
    then filterNonIfdInputsValues attrs
    else attrs;

  testSrcRoot = evalPackages.haskell-nix.haskellLib.cleanGit { src = ../.; subDir = "test"; };
  testSrc = subDir: haskell-nix.haskellLib.cleanSourceWith { src = testSrcRoot; inherit subDir; };
  # Use the following reproduce issues that may arise on hydra as a
  # result of building a snapshot not a git repo.
  # testSrcRoot = pkgs.copyPathToStore ./.;
  # testSrc = subDir: testSrcRoot + "/${subDir}";
  testSrcRootWithGitDir = evalPackages.haskell-nix.haskellLib.cleanGit { src = ../.; subDir = "test"; includeSiblings = true; keepGitDir = true; };
  testSrcWithGitDir = subDir: haskell-nix.haskellLib.cleanSourceWith { src = testSrcRootWithGitDir; inherit subDir; includeSiblings = true; };
  headHackage = import ./head-hackage.nix {
    inherit evalPackages;
    # A stable-haskell `-target` compiler registers no target boot libraries
    # (`emptyGlobalPackageDb`), so every project using one builds them from
    # source with the boot-dep versions pinned by
    # `injectStableHaskellBootPackages`.  Those pins and the ghcjs overlay's
    # `:override` are mutually exclusive -- see head-hackage.nix.  Keyed on the
    # capability rather than the compiler name, like the `? dwarf` guard in
    # test/cabal-simple-debug, so the next such compiler needs no edit.
    #
    # Also gated on the host actually being ghcjs.  The lines this rewrites sit
    # inside `if os(ghcjs)` blocks, so dropping them changes nothing for any
    # other target -- but it would still change the cabal.project.local TEXT,
    # and with it every one of those targets' plan-nix hashes, for no reason.
    bootLibsFromSource = stdenv.hostPlatform.isGhcjs
      && (buildPackages.haskell-nix.compiler.${compiler-nix-name}.emptyGlobalPackageDb or false);
  };
  testCabalProjectLocal = headHackage.cabalProjectLocal;
  # inputMap entries are consulted only for `source-repository-package` urls a
  # project actually names, so carrying the cabal-doctest fork here is inert
  # for every test except the one that pulls it in (gi-gtk, via haskell-gi's
  # custom Setup.hs).  It lives here rather than as a new gi-gtk argument
  # because callPackage applies its third argument unconditionally and the
  # tests have closed argument sets -- see the note just below.
  #
  # Read through `evalPackages.haskell-nix.sources` (overlays/haskell.nix
  # re-exports the flake inputs there) rather than `haskellNix.sources`: the
  # hydraJobs path comes via ci.nix, which does not pass `haskellNix`, so that
  # attribute would fall back to `import ../default.nix` and die on
  # `builtins.currentSystem` under pure eval.  plan-to-nix runs on the eval
  # platform, which is why it is evalPackages and not pkgs.
  testInputMap = headHackage.inputMap // {
    "https://github.com/stable-haskell/cabal-doctest.git" =
      evalPackages.haskell-nix.sources.cabal-doctest;
  };

  # `evalSystem` / `testCabalProjectLocal` / `testInputMap` are passed only to
  # tests that ask for them.  callPackage's third argument is applied
  # unconditionally, and a test with a closed argument set rejects anything it
  # does not declare -- "function 'anonymous lambda' called with unexpected
  # argument 'testCabalProjectLocal'" -- which broke every test that does not
  # use cabal.project.local.  `evalSystem` (the platform plan-to-nix runs on) is
  # optional for the same reason: a project selects the eval platform with
  # `evalSystem` rather than the now read-only `evalPackages` option (see
  # modules/project-common.nix), but not every test builds a project.  The other
  # three have always been passed to everything and every test declares them, so
  # they stay unconditional.
  callTest = x: args:
    let
      optionalArgs = { inherit evalSystem testCabalProjectLocal testInputMap; };
    in
    haskell-nix.callPackage x (args
      // { inherit testSrc compiler-nix-name evalPackages; }
      // builtins.intersectAttrs (builtins.functionArgs (import x)) optionalArgs);

  # Run unit tests with: nix-instantiate --eval --strict -A unit.tests
  # An empty list means success.
  unitTests =
    let
      tests = haskell-nix.callPackage ./unit.nix { inherit compiler-nix-name evalPackages; };
      testsFailedEcho = lib.concatMapStringsSep "\n" (t: "echo ${t.name} failed") tests;
      testsFinalLine = if builtins.length tests == 0 then "\ntouch $out" else "\nexit 1";
      testsScript = testsFailedEcho + testsFinalLine;
    in
    runCommand "unit-tests" { passthru = { inherit tests; }; } testsScript;

  # All tests.
  allTests = {
    cabal-simple = callTest ./cabal-simple { inherit util; };
    dummy-ghc-info = callTest ./dummy-ghc-info {};
    check-datadir = callTest ./check-datadir {};
    pkgconf-pc-version = callTest ./pkgconf-pc-version {};
    cabal-simple-debug = callTest ./cabal-simple-debug { inherit util; };
    cabal-simple-prof = callTest ./cabal-simple-prof { inherit util; };
    cabal-sublib = callTest ./cabal-sublib { inherit util; };
    cabal-sublib-shell = callTest ./cabal-sublib-shell {};
    with-packages = callTest ./with-packages { inherit util; };
    builder-haddock = callTest ./builder-haddock {};
    stack-simple = callTest ./stack-simple {};
    stack-compiler = callTest ./stack-compiler {};
    stack-local-resolver = callTest ./stack-local-resolver {};
    stack-local-resolver-subdir = callTest ./stack-local-resolver-subdir {};
    stack-remote-resolver = callTest ./stack-remote-resolver {};
    stack-symlink-yaml = callTest ./stack-symlink-yaml {};
    shell-for-setup-deps = callTest ./shell-for-setup-deps {};
    setup-deps = import ./setup-deps { inherit pkgs evalPackages evalSystem compiler-nix-name testCabalProjectLocal testInputMap; };
    setup-deps-boot-cabal = callTest ./setup-deps-boot-cabal {};
    callStackToNix = callTest ./call-stack-to-nix {};
    callCabalProjectToNix = callTest ./call-cabal-project-to-nix { inherit evalPackages; };
    cabal-source-repo = callTest ./cabal-source-repo {};
    cabal-source-repo-comments = callTest ./cabal-source-repo-comments {};
    buildable = callTest ./buildable {};
    project-flags-cabal = callTest ./project-flags/cabal.nix {};
    project-flags-stack = callTest ./project-flags/stack.nix {};
    ghc-options-cabal = callTest ./ghc-options/cabal.nix {};
    ghc-options-stack = callTest ./ghc-options/stack.nix {};
    exe-only = callTest ./exe-only { inherit util; };
    stack-source-repo = callTest ./stack-source-repo {};
    stack-inputMap = callTest ./stack-inputMap { inherit testSrcRoot; };
    ghc-lib-reinstallable-cabal = callTest ./ghc-lib-reinstallable/cabal.nix {};
    ghc-lib-reinstallable-stack = callTest ./ghc-lib-reinstallable/stack.nix {};
    generated-light = callTest ./generated-light {};
    cabal-doctests = callTest ./cabal-doctests { inherit util; };
    extra-hackage = callTest ./extra-hackage {};
    ghcjs-overlay = callTest ./ghcjs-overlay {};
    hls-cabal = callTest ./haskell-language-server/cabal.nix {};
    hls-stack = callTest ./haskell-language-server/stack.nix {};
    cabal-hpack = callTest ./cabal-hpack { inherit util; };
    index-state = callTest ./index-state {};
    sha256map = callTest ./sha256map {};
    # fully-static = callTest ./fully-static { inherit (pkgs) buildPackages; };
    shell-for = callTest ./shell-for {};
    cabal-22 = callTest ./cabal-22 { inherit util; };
    coverage = callTest ./coverage {};
    coverage-golden = callTest ./coverage-golden {};
    coverage-no-libs = callTest ./coverage-no-libs {};
    v2-slice-sharing = callTest ./v2-slice-sharing {};
    hsc2hs-patched = callTest ./hsc2hs-patched {};
    snapshots = callTest ./snapshots {};
    sublib-docs = callTest ./sublib-docs { inherit util; };
    githash = callTest ./githash { inherit compiler-nix-name evalPackages; };
    c-ffi = callTest ./c-ffi { inherit util; };
    th-dlls = callTest ./th-dlls { inherit util; };
    th-dlls-minimal = callTest ./th-dlls-minimal { inherit util; };
    elf-comdat-functions = lib.recurseIntoAttrs {
      # Exercise the native ELF loader once. The production fix is scoped
      # separately to the source-built i386 musl RTS in cross projects.
      meta.disabled = compiler-nix-name != "ghc914-sh"
        || !stdenv.hostPlatform.isLinux
        || !stdenv.hostPlatform.isx86_64
        || stdenv.hostPlatform.libc != "glibc"
        || stdenv.buildPlatform.config != stdenv.hostPlatform.config;
      run = import ./elf-comdat-functions.nix {
        pkgs = pkgs.pkgsBuildBuild;
        compiler = pkgs.pkgsBuildBuild.haskell-nix.compiler.${compiler-nix-name};
      };
    };
    qemu-linux-user = lib.recurseIntoAttrs {
      # Exercise the build-host emulator once, independent of the Haskell target.
      meta.disabled = !pkgs.pkgsBuildBuild.stdenv.hostPlatform.isLinux
        || !pkgs.pkgsBuildBuild.stdenv.hostPlatform.isx86_64
        || lib.versionOlder pkgs.pkgsBuildBuild.qemu.version "9.1"
        || lib.versionAtLeast pkgs.pkgsBuildBuild.qemu.version "12";
      run = import ./qemu-linux-user.nix { pkgs = pkgs.pkgsBuildBuild; };
    };
    qemu-arm32-personality = lib.recurseIntoAttrs {
      meta.disabled = !pkgs.pkgsBuildBuild.stdenv.hostPlatform.isLinux
        || lib.versionOlder pkgs.pkgsBuildBuild.qemu.version "9.1"
        || lib.versionAtLeast pkgs.pkgsBuildBuild.qemu.version "12";
      run = import ./qemu-arm32-personality.nix { pkgs = pkgs.pkgsBuildBuild; };
    };
    mingw-stdio = lib.recurseIntoAttrs {
      meta.disabled = !stdenv.hostPlatform.isWindows
        || !stdenv.hostPlatform.isx86_64
        || !pkgs.pkgsBuildBuild.stdenv.hostPlatform.isLinux
        || !pkgs.pkgsBuildBuild.stdenv.hostPlatform.isx86_64;
      run = import ./mingw-stdio { inherit pkgs; };
    };
    external-static-plugin = callTest ./external-static-plugin {};
    exe-dlls = callTest ./exe-dlls { inherit util; };
    exe-lib-dlls = callTest ./exe-lib-dlls { inherit util; };
    ca-derivations = callTest ./ca-derivations { inherit CADerivationsEnabled; };
    ca-derivations-include = callTest ./ca-derivations-include { inherit CADerivationsEnabled; };
    test-only = callTest ./test-only { inherit util; };
    annotations = callTest ./annotations { inherit util; };
    cabal-project-nix-path = callTest ./cabal-project-nix-path {};
    plugin = callTest ./plugin {};
    supported-languages = callTest ./supported-langauges {};
    js-template-haskell = callTest ./js-template-haskell {};
    gi-gtk = callTest ./gi-gtk { inherit util; };
    literate-haskell = callTest ./literate-haskell {};
    backpack = callTest ./backpack {};
    unit = unitTests;
  };

  # This is the same as allTests, but filter out all the key/vaules from the
  # tests other than the "ifdInputs" key if the input ifdLevel is less than 3.
  allTestsRemoveIfdLTLevel3 = ifdLevel:
    filterNonIfdInputsValuesLTLevel3 ifdLevel allTests;

  # This is the same as allTestsRemoveIfdLTLevel3, but make sure
  # recurseForDerivations is set on all child values under the
  # ifdInputs key.
  allTestsWithIfdInputs = ifdLevel:
    addIfdInputsToVal (allTestsRemoveIfdLTLevel3 ifdLevel);

  # This is the same as allTestsWithIfdInputs, but returns an empty attribute set
  # if the input ifdLevel is 0 or 1.
  #
  # Here is the result based on the input ifdLevel:
  #
  # - input ifdLevel is 0 or 1: {}
  # - input ifdLevel is 2: filter out everything from the children of allTests
  #   except for the ifdInputs attribute
  # - input ifdLevel is 3 or greater: return allTests
  optionalIfdTests = ifdLevel:
    pkgs.lib.optionalAttrs (ifdLevel > 1) (allTestsWithIfdInputs ifdLevel);
in filterAttrsOnlyRecursive (_: v: !(isDisabled v))
  (pkgs.lib.recurseIntoAttrs (optionalIfdTests ifdLevel))

## more possible test cases
# 1. fully static linking
# 2. cabal 2.4 stuff
# 3. cross-compiling
