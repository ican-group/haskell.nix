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
        libsodium-18 = (final.callPackage (haskellNix.sources.nixpkgs-2311 + "/pkgs/development/libraries/libsodium") {}).overrideAttrs (_: { dontDisableStatic = true; });
      })
    ];
  }
, evalPackages ? import pkgs.path nixpkgsArgs
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
  callTest = x: args: haskell-nix.callPackage x (args // { inherit testSrc compiler-nix-name evalPackages; });

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
    setup-deps = import ./setup-deps { inherit pkgs evalPackages compiler-nix-name; };
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
    ghc-lib-reinstallable-cabal = callTest ./ghc-lib-reinstallable/cabal.nix {};
    ghc-lib-reinstallable-stack = callTest ./ghc-lib-reinstallable/stack.nix {};
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
    snapshots = callTest ./snapshots {};
    sublib-docs = callTest ./sublib-docs { inherit util; };
    githash = callTest ./githash { inherit compiler-nix-name evalPackages; };
    c-ffi = callTest ./c-ffi { inherit util; };
    th-dlls = callTest ./th-dlls { inherit util; };
    th-dlls-minimal = callTest ./th-dlls-minimal { inherit util; };
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
