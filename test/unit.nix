{ pkgs, evalPackages, lib, haskellLib, compiler-nix-name }:

let
  emptyConfig = {
    components = {
       benchmarks = { };
       exes = { };
       foreignlibs = { };
       library = { buildable = true; planned = true; };
       sublibs = { };
       tests = { };
    };
    package.identifier.name = "empty";
    package.buildable = true;
  };

  # Project and package sources as `appendSubDir` makes them, for the
  # `defaultFlakeComponents` tests.
  projectSrc = { origSrc = "/repo"; origSubDir = ""; };
  rootPkg = components: { identifier.name = "root"; src = projectSrc; inherit components; };
  subPkg = components: { identifier.name = "sub"; src = projectSrc // { origSubDir = "/sub"; }; inherit components; };

  componentsConfig = {
    components = {
       benchmarks = { bbb = { buildable = true; planned = true; }; };
       exes = { eee = { buildable = true; planned = true; }; };
       foreignlibs = { fff = { buildable = true; planned = true; }; };
       library = { buildable = true; planned = true; };
       sublibs = { };
       tests = { ttt = { buildable = true; planned = true; }; };
    };
    package.identifier.name = "nnn";
    package.buildable = true;
  };

  # `cabalProjectLocal` contributed by `modules/hackage-quirks.nix` for a
  # hackage-project with the given `name` and `version`.
  hackageQuirksCabalProjectLocal = { name, version }:
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = import ../modules/hackage-quirks.nix ++ [{
        options = {
          name = lib.mkOption { type = lib.types.str; };
          version = lib.mkOption { type = lib.types.str; };
          cabalProjectLocal = lib.mkOption { type = lib.types.lines; default = ""; };
          cabalProject = lib.mkOption { type = lib.types.lines; default = ""; };
          sha256map = lib.mkOption { type = lib.types.anything; default = {}; };
          modules = lib.mkOption { type = lib.types.listOf lib.types.anything; default = []; };
        };
        config = { inherit name version; };
      }];
    }).config.cabalProjectLocal;

  testRepoData = {
    url = "https://github.com/ican-group/haskell.nix.git";
    rev = "487eea1c249537d34c27f6143dff2b9d5586c657";
    sha256 = "077j5j3j86qy1wnabjlrg4dmqy1fv037dyq3xb8ch4ickpxxs123";
  };

  # Whether a derivation carrying cabal license `lic` (mapped the way the
  # component builders map it) gets past nixpkgs' check-meta.  The test
  # package set does not allow unfree packages.
  licenseEvaluates = lic: (builtins.tryEval
    (pkgs.runCommand "haskell-nix-license-check" {
      meta.license = haskellLib.cabalToNixpkgsLicense lic;
    } "touch $out").drvPath).success;
in
lib.runTests {
  # Free licenses must stay free under nixpkgs' check-meta, which treats a
  # license in a list (what `cabalToNixpkgsLicense` returns) without `free` as
  # unfree.  Cabal turns the legacy unversioned `license: LGPL` into
  # `LicenseRef-LGPL` (cpphs, polyparse).
  testLicenseLegacyLGPLEvaluates = {
    expr = licenseEvaluates "LicenseRef-LGPL";
    expected = true;
  };
  testLicenseCompoundEvaluates = {
    expr = licenseEvaluates "BSD-3-Clause AND MIT AND ISC";
    expected = true;
  };
  # ...while a license that really is unfree is refused, so the checks above
  # go through check-meta rather than passing vacuously.
  testLicenseUnfreeIsRefused = {
    expr = licenseEvaluates "CC-BY-NC-4.0";
    expected = false;
  };
  # `NONE` (no license declared) is named, not `null`, so a refusal reports
  # it as such rather than as "unfree license ('unknown')".
  testLicenseNoneIsNamed = {
    expr = map (l: l.shortName) (haskellLib.cabalToNixpkgsLicense "NONE");
    expected = [ "NONE" ];
  };

  # The stack quirk's old-version constraints (`pantry <0.9`, ...) must not
  # apply to `version = "latest"`: `compareVersions "latest" "2.11.1"` is -1,
  # and with them no recent stack solves, so the solver fell back to a
  # placeholder release instead of the newest stack (#1748).  Only the
  # bounds that keep the solver off the placeholder releases remain.
  testStackQuirkSkipsLatest = {
    expr = hackageQuirksCabalProjectLocal { name = "stack"; version = "latest"; };
    expected = "constraints: stack >=2.1 && <9.9.9\n";
  };
  testStackQuirkKeepsPinnedOldVersion = {
    expr = hackageQuirksCabalProjectLocal { name = "stack"; version = "2.9.3"; };
    expected = "constraints: pantry <0.9, optparse-applicative <0.18, http-download <0.2.1\n";
  };

  # `extraPackageUnitIds` finds the units only `extra-packages` brought into
  # a plan (#1955): `lens`, but not its dependency `free` (needed only by
  # `lens`), `text` (needed by a local library), `alex` (a local build
  # tool), `Cabal` (a local setup dependency), `happy` (an inplace unit) or
  # the pre-existing `base`.
  testExtraPackageUnitIds = {
    expr = haskellLib.extraPackageUnitIds {
      install-plan = [
        { type = "pre-existing"; id = "base-4"; pkg-name = "base"; depends = []; }
        { type = "configured"; style = "local"; id = "app-0-inplace"; pkg-name = "app";
          components = {
            lib = { depends = [ "base-4" "text-2" ]; exe-depends = [ "alex-3" ]; };
            setup = { depends = [ "Cabal-3" ]; };
          }; }
        { type = "configured"; style = "global"; id = "text-2"; pkg-name = "text"; depends = [ "base-4" ]; }
        { type = "configured"; style = "global"; id = "alex-3"; pkg-name = "alex"; depends = [ "base-4" ]; }
        { type = "configured"; style = "global"; id = "Cabal-3"; pkg-name = "Cabal"; depends = [ "base-4" ]; }
        { type = "configured"; style = "inplace"; id = "happy-2-inplace"; pkg-name = "happy"; depends = [ "base-4" ]; }
        { type = "configured"; style = "global"; id = "lens-5"; pkg-name = "lens"; depends = [ "free-5" "text-2" ]; }
        { type = "configured"; style = "global"; id = "free-5"; pkg-name = "free";
          components.lib.depends = [ "base-4" ]; }
      ];
    };
    expected = [ "lens-5" ];
  };

  # No `extra-packages`, nothing found.
  testExtraPackageUnitIdsNone = {
    expr = haskellLib.extraPackageUnitIds {
      install-plan = [
        { type = "pre-existing"; id = "base-4"; pkg-name = "base"; depends = []; }
        { type = "configured"; style = "local"; id = "app-0-inplace"; pkg-name = "app"; depends = [ "text-2" ]; }
        { type = "configured"; style = "global"; id = "text-2"; pkg-name = "text"; depends = [ "base-4" ]; }
      ];
    };
    expected = [ ];
  };

  # `shadowedNonReinstallablePkgs` flags names in `nonReinstallablePkgs` that the
  # project pins to a version different from the compiler-shipped one (#1657).

  # Fires only for the pinned-to-a-different-version entry.
  testShadowedNonReinstallableFires = {
    expr = haskellLib.shadowedNonReinstallablePkgs {
      nonReinstallablePkgs = [ "base" "bytestring" "ghc-prim" ];
      compilerPackages = { base = "4.18.0.0"; bytestring = "0.11.4.0"; ghc-prim = "0.10.0"; };
      packages = { bytestring = { package.identifier.version = "0.12.0.0"; }; };
    };
    expected = [ "bytestring" ];
  };

  # A normal project (planned version == shipped version) yields nothing.
  testShadowedNonReinstallableSilentWhenMatching = {
    expr = haskellLib.shadowedNonReinstallablePkgs {
      nonReinstallablePkgs = [ "base" "bytestring" ];
      compilerPackages = { base = "4.18.0.0"; bytestring = "0.11.4.0"; };
      packages = { bytestring = { package.identifier.version = "0.11.4.0"; }; };
    };
    expected = [ ];
  };

  # Nothing is flagged when no `nonReinstallablePkgs` entry is overridden
  # (absent, or present but shadowed to null).
  testShadowedNonReinstallableIgnoresUnpinned = {
    expr = haskellLib.shadowedNonReinstallablePkgs {
      nonReinstallablePkgs = [ "base" "rts" ];
      compilerPackages = { base = "4.18.0.0"; rts = "1.0.2"; };
      packages = { rts = null; };
    };
    expected = [ ];
  };

  # A by-name override record (no package definition) is skipped without
  # touching its undefined `package.identifier.version`.
  testShadowedNonReinstallableIgnoresOverrideOnly = {
    expr = haskellLib.shadowedNonReinstallablePkgs {
      nonReinstallablePkgs = [ "base" "Cabal" ];
      compilerPackages = { base = "4.18.0.0"; Cabal = "3.10.1.0"; };
      packages = { Cabal = {
        hasPackageDefinition = false;
        package.identifier.version = throw "option used but not defined";
      }; };
    };
    expected = [ ];
  };

  # identity function for applyComponents
  test-applyComponents-id = {
    expr = haskellLib.applyComponents (_componentId: component: component) emptyConfig;
    expected = emptyConfig.components;
  };

  # map a component to its component name and check these are correct
  test-applyComponents-library = {
    expr = haskellLib.applyComponents (componentId: _component: componentId.cname) emptyConfig;
    expected = emptyConfig.components // { library = "empty"; };
  };

  test-applyComponents-components = {
    expr = haskellLib.applyComponents (_componentId: component: component) componentsConfig;
    expected = componentsConfig.components;
  };

  # mkFlakeHaddock collects the `doc` output of every component that produces
  # haddock (a library/test with doHaddock enabled exposes a `doc` attr), keyed
  # by component-id, and skips components without docs — exes/benchmarks and
  # haddock-disabled libraries (see #1932).
  testMkFlakeHaddock =
    let
      mkComp = id: extra: { passthru.identifier.component-id = id; } // extra;
    in {
      expr = haskellLib.mkFlakeHaddock {
        pkgA.components = {
          library = mkComp "pkgA:lib:pkgA" { doc = "DOC-libA"; };
          exes.e = mkComp "pkgA:exe:e" { };            # no doc -> skipped
          # v2 slice without documentation: `doc` throws, `docEnabled` is false.
          sublibs.v2 = mkComp "pkgA:lib:v2" { doc = throw "no docs"; docEnabled = false; };
          # v2 slice with documentation.
          sublibs.v2doc = mkComp "pkgA:lib:v2doc" { doc = "DOC-v2"; docEnabled = true; };
          sublibs.s = mkComp "pkgA:lib:s" { doc = "DOC-subA"; };
          tests.t = mkComp "pkgA:test:t" { doc = "DOC-testA"; };
          foreignlibs = { };
          benchmarks = { };
        };
        pkgB.components = {
          library = mkComp "pkgB:lib:pkgB" { };        # haddock disabled -> no doc -> skipped
          sublibs = { }; exes = { }; tests = { };
          foreignlibs = { }; benchmarks = { };
        };
      };
      expected = {
        "pkgA:lib:pkgA" = "DOC-libA";
        "pkgA:lib:s" = "DOC-subA";
        "pkgA:lib:v2doc" = "DOC-v2";
        "pkgA:test:t" = "DOC-testA";
      };
    };

  # A project with no haddock-producing components yields an empty group,
  # matching what `doHaddock = false` produces.
  testMkFlakeHaddockEmpty = {
    expr = haskellLib.mkFlakeHaddock {
      pkgB.components.library.passthru.identifier.component-id = "pkgB:lib:pkgB";
    };
    expected = { };
  };

  # mkFlakeCiJobs surfaces the haddock group so hydra builds documentation.
  testMkFlakeCiJobsHaddock = {
    expr = (haskellLib.mkFlakeCiJobs { roots = "ROOTS"; } {
      packages = { }; checks = { }; coverage = { }; devShells = { };
      checkedProject = { };
      haddock = { "pkgA:lib:pkgA" = "DOC"; };
    }).haddock;
    expected = { "pkgA:lib:pkgA" = "DOC"; };
  };

  # The haddock arg defaults to {} so any other caller of mkFlakeCiJobs keeps
  # working, and an empty group is left out so the jobs match a project that
  # has not opted in.
  testMkFlakeCiJobsHaddockDefault = {
    expr = (haskellLib.mkFlakeCiJobs { roots = "ROOTS"; } {
      packages = { }; checks = { }; coverage = { }; devShells = { };
      checkedProject = { };
    }) ? haddock;
    expected = false;
  };

  # `defaultFlakeComponents` picks the flake's `packages.default` and
  # `apps.default` like bare `cabal build`/`cabal run` in the project
  # directory: only the single package whose source is that directory
  # counts (#1777).
  testDefaultFlakeComponentsLibAndExe = {
    expr = haskellLib.defaultFlakeComponents projectSrc {
      root = rootPkg { library = "LIB"; exes.e = "EXE"; };
      sub = subPkg { exes.s = "SUB-EXE"; };
    };
    expected = { package = "EXE"; app = "EXE"; };
  };

  # More than one executable: `cabal run` would need a target, so no app,
  # and the library is the default package.
  testDefaultFlakeComponentsTwoExes = {
    expr = haskellLib.defaultFlakeComponents projectSrc {
      root = rootPkg { library = "LIB"; exes = { a = "A"; b = "B"; }; };
    };
    expected = { package = "LIB"; app = null; };
  };

  # A library-only package (no `exes` attr at all) is still a default package.
  testDefaultFlakeComponentsLibOnly = {
    expr = haskellLib.defaultFlakeComponents projectSrc {
      root = rootPkg { library = "LIB"; };
    };
    expected = { package = "LIB"; app = null; };
  };

  # No package in the project directory: nothing is chosen, even though
  # there is exactly one package.
  testDefaultFlakeComponentsNoRoot = {
    expr = haskellLib.defaultFlakeComponents projectSrc {
      sub = subPkg { library = "LIB"; exes.s = "S"; };
    };
    expected = { package = null; app = null; };
  };

  # Two packages claiming the project directory: ambiguous, nothing chosen.
  testDefaultFlakeComponentsAmbiguous = {
    expr = haskellLib.defaultFlakeComponents projectSrc {
      a = rootPkg { exes.a = "A"; } // { identifier.name = "a"; };
      b = rootPkg { exes.b = "B"; } // { identifier.name = "b"; };
    };
    expected = { package = null; app = null; };
  };

  # A package planned from `plan.json` has one `hsPkgs` entry per unit,
  # each with only its own components; they count as one package.
  testDefaultFlakeComponentsPerUnit = {
    expr = haskellLib.defaultFlakeComponents projectSrc {
      "root-0.1-inplace" = rootPkg { library = "LIB"; };
      "root-0.1-inplace-e" = rootPkg { exes.e = "EXE"; };
    };
    expected = { package = "EXE"; app = "EXE"; };
  };

  # The same, with two executables in separate units: no single app.
  testDefaultFlakeComponentsPerUnitTwoExes = {
    expr = haskellLib.defaultFlakeComponents projectSrc {
      "root-0.1-inplace" = rootPkg { library = "LIB"; };
      "root-0.1-inplace-a" = rootPkg { exes.a = "A"; };
      "root-0.1-inplace-b" = rootPkg { exes.b = "B"; };
    };
    expected = { package = "LIB"; app = null; };
  };

  # Two entries holding the same executable (a custom `selectPackages`
  # that keeps both copies) are not one choice.
  testDefaultFlakeComponentsDuplicateExe = {
    expr = haskellLib.defaultFlakeComponents projectSrc {
      host = rootPkg { library = "LIB"; exes.e = "EXE"; };
      other = rootPkg { exes.e = "EXE2"; };
    };
    expected = { package = "LIB"; app = null; };
  };

  # A project in a subdirectory of its source (`src.origSubDir`): the
  # package in that subdirectory is the root one, not the one at the top.
  testDefaultFlakeComponentsProjectSubDir = {
    expr = haskellLib.defaultFlakeComponents
      { origSrc = "/repo"; origSubDir = "/proj"; } {
        top = { identifier.name = "top"; src = { origSrc = "/repo"; origSubDir = ""; }; components.exes.t = "TOP"; };
        proj = { identifier.name = "proj"; src = { origSrc = "/repo"; origSubDir = "/proj"; }; components.exes.p = "PROJ"; };
        nested = { identifier.name = "nested"; src = { origSrc = "/repo"; origSubDir = "/proj/n"; }; components.exes.n = "N"; };
      };
    expected = { package = "PROJ"; app = "PROJ"; };
  };

  # A plain path `src` (no `origSrc`) matches packages cut from it.
  testDefaultFlakeComponentsPlainSrc = {
    expr = haskellLib.defaultFlakeComponents "/repo" {
      root = { identifier.name = "root"; src = { origSrc = "/repo"; origSubDir = ""; }; components.exes.e = "EXE"; };
    };
    expected = { package = "EXE"; app = "EXE"; };
  };

  # Without a project `src` (a hand-made project passed to `mkFlake`)
  # nothing is chosen.
  testDefaultFlakeComponentsNoSrc = {
    expr = haskellLib.defaultFlakeComponents null {
      root = rootPkg { exes.e = "EXE"; };
    };
    expected = { package = null; app = null; };
  };

  # `mkFlake` adds the defaults to `packages` and `apps` only, so CI does
  # not get the same job twice, and a `default` the caller passes wins.
  testMkFlakeDefaults =
    let
      exe = { passthru.identifier.component-id = "root:exe:e"; exePath = "/bin/e"; meta = { }; };
      project = {
        args.src = projectSrc;
        hsPkgs.root = rootPkg { exes.e = exe; };
      };
      flake = haskellLib.mkFlake project {
        selectPackages = ps: ps;
        checks = { }; checkedProject = { };
      };
      flakeWithDefault = haskellLib.mkFlake project {
        selectPackages = ps: ps;
        packages = { default = "MINE"; };
        defaultApp = null;
      };
    in {
      expr = {
        packages = builtins.attrNames flake.packages;
        app = flake.apps.default.program;
        ciPackages = builtins.attrNames flake.ciJobs.packages;
        userDefault = flakeWithDefault.packages.default;
        noApp = flakeWithDefault.apps ? default;
        off = (haskellLib.mkFlake project {
          selectPackages = ps: ps;
          doDefaults = false;
        }).packages ? default;
      };
      expected = {
        packages = [ "default" "root:exe:e" ];
        app = "/bin/e";
        ciPackages = [ "root:exe:e" ];
        userDefault = "MINE";
        noApp = false;
        off = false;
      };
    };

  # testing that the tests work
  testId = {
    expr = lib.id 1;
    expected = 1;
  };

  # `dependToLib` returns the library component of a dependency package.
  testDependToLibResolvesLibrary = {
    expr = haskellLib.dependToLib { identifier.name = "foo"; components.library = "the-lib"; };
    expected = "the-lib";
  };

  # A sublib `depends` value is already the derivation (no `components`), so it
  # is passed through unchanged.
  testDependToLibPassesSublibThrough = {
    expr = haskellLib.dependToLib "already-a-derivation";
    expected = "already-a-derivation";
  };

  # A package with `components` but no `library` (unplanned or unbuildable) must throw
  # rather than silently vanish or give an opaque `attribute 'library' missing`
  # (see #1379).  `runTests` can only assert that evaluation fails; the message
  # wording is checked out of band.
  testDependToLibThrowsForUnplannedPackage = {
    expr = (builtins.tryEval
      (haskellLib.dependToLib { identifier.name = "foo"; components = { }; })).success;
    expected = false;
  };

  # The shared message names the package (used by v1 and the v2 builder).
  testUnplannedLibraryMessageNamesPackage = {
    expr = lib.hasInfix "package 'foo' is not available" (haskellLib.unplannedLibraryMessage "foo");
    expected = true;
  };

  testParseBlock1 = {
    expr = __toJSON (haskellLib.parseSourceRepositoryPackageBlock "cabal.project" {} {} "" ''
        type: git
        location: https://github.com/ican-group/haskell.nix.git
        tag: 487eea1c249537d34c27f6143dff2b9d5586c657
        --sha256: 077j5j3j86qy1wnabjlrg4dmqy1fv037dyq3xb8ch4ickpxxs123
      -- end of block
    '');
    expected = __toJSON {
      followingText = "-- end of block\n";
      indentation = "";
      sourceRepo = testRepoData // { subdirs = ["."]; };
    };
  };

  testParseBlock2 = {
    expr = __toJSON (haskellLib.parseSourceRepositoryPackageBlock "cabal.project" {} {} "" ''
        type: git
        location: https://github.com/ican-group/haskell.nix.git
        tag: 487eea1c249537d34c27f6143dff2b9d5586c657
        --sha256: 077j5j3j86qy1wnabjlrg4dmqy1fv037dyq3xb8ch4ickpxxs123
        subdir: dir
      -- end of block
    '');
    expected = __toJSON {
      followingText = "-- end of block\n";
      indentation = "";
      sourceRepo = testRepoData // { subdirs = ["dir"]; };
    };
  };

  testParseBlock3 = {
    expr = __toJSON (haskellLib.parseSourceRepositoryPackageBlock "cabal.project" {} {} "" ''
        type: git
        location: https://github.com/ican-group/haskell.nix.git
        tag: 487eea1c249537d34c27f6143dff2b9d5586c657
        --sha256: 077j5j3j86qy1wnabjlrg4dmqy1fv037dyq3xb8ch4ickpxxs123
        subdir: dir1 dir2
      -- end of block
    '');
    expected = __toJSON {
      followingText = "-- end of block\n";
      indentation = "";
      sourceRepo = testRepoData // { subdirs = ["dir1" "dir2"]; };
    };
  };

  testParseBlock4 = {
    expr = __toJSON (haskellLib.parseSourceRepositoryPackageBlock "cabal.project" {} {} "" ''
        type: git
        location: https://github.com/ican-group/haskell.nix.git
        tag: 487eea1c249537d34c27f6143dff2b9d5586c657
        --sha256: 077j5j3j86qy1wnabjlrg4dmqy1fv037dyq3xb8ch4ickpxxs123
        subdir:
          dir1
          dir2
      -- end of block
    '');
    expected = __toJSON {
      followingText = "-- end of block\n";
      indentation = "";
      sourceRepo = testRepoData // { subdirs = ["dir1" "dir2"]; };
    };
  };

  # A commented-out `-- --sha256:` line must be dropped (not appended to the
  # previous field), and a `--` inside a value (no leading whitespace) is not
  # a comment.
  testParseBlockComments = {
    expr = __toJSON (haskellLib.parseSourceRepositoryPackageBlock "cabal.project" {} {} "" ''
        type: git
        location: https://github.com/foo--bar/haskell.nix.git
        tag: 487eea1c249537d34c27f6143dff2b9d5586c657 -- trailing comment
        -- --sha256: 0000000000000000000000000000000000000000000000000000
        --sha256: 077j5j3j86qy1wnabjlrg4dmqy1fv037dyq3xb8ch4ickpxxs123
      -- end of block
    '');
    expected = __toJSON {
      followingText = "-- end of block\n";
      indentation = "";
      sourceRepo = testRepoData // {
        url = "https://github.com/foo--bar/haskell.nix.git";
        subdirs = ["."];
      };
    };
  };

  # Verify that parseBlockLines (called inside parseSourceRepositoryPackageBlock)
  # preserves string context on parsed attribute values like `location`.
  # This is critical for repository blocks where the URL may contain
  # interpolated store paths (e.g. `url: file:${CHaP}`).
  testParseBlockLinesPreservesContext =
    let
      storePath = builtins.toFile "test-context" "test";
      storePathStr = builtins.unsafeDiscardStringContext storePath;
      # Interpolate a store path into the block to give it context.
      # pkgs.lib.splitString (used inside parseSourceRepositoryPackageBlock)
      # preserves this context, but builtins.match (used in parseBlockLines)
      # would strip it without our fix.
      blockWithContext = ''
          type: git
          location: file:${storePath}
          tag: 487eea1c249537d34c27f6143dff2b9d5586c657
          --sha256: 077j5j3j86qy1wnabjlrg4dmqy1fv037dyq3xb8ch4ickpxxs123
        rest of file
      '';
      result = haskellLib.parseSourceRepositoryPackageBlock "cabal.project" {} {} "" blockWithContext;
      urlContext = builtins.getContext result.sourceRepo.url;
    in {
      expr = urlContext ? ${storePathStr};
      expected = true;
    };

  # Verify that parseSourceRepositoryPackages preserves string context
  # from the project file through builtins.split into initialText.
  testParseSourceRepoPackagesPreservesContext =
    let
      storePath = builtins.toFile "test-context" "test";
      storePathStr = builtins.unsafeDiscardStringContext storePath;
      projectFile = ''
        packages: ./*.cabal
        repository test-repo
          url: file:${storePath}
          secure: True
      '';
      result = haskellLib.parseSourceRepositoryPackages "cabal.project" {} {} projectFile;
      initialTextContext = builtins.getContext result.initialText;
    in {
      expr = initialTextContext ? ${storePathStr};
      expected = true;
    };

  # #1090: a cabal.project with CRLF line endings must parse identically to one
  # with LF endings (no stray "\r" left on extracted values).
  testParseIndexStateCRLF = {
    expr = haskellLib.parseIndexState (builtins.replaceStrings [ "\n" ] [ "\r\n" ] ''
      index-state: 2021-07-20T00:00:00Z
      packages: ./*.cabal
    '');
    expected = "2021-07-20T00:00:00Z";
  };

  testParseSourceRepoPackagesCRLF =
    let
      lf = ''
        packages: ./*.cabal

        source-repository-package
          type: git
          location: https://github.com/ican-group/haskell.nix.git
          tag: 487eea1c249537d34c27f6143dff2b9d5586c657
          --sha256: 077j5j3j86qy1wnabjlrg4dmqy1fv037dyq3xb8ch4ickpxxs123
      '';
      crlf = builtins.replaceStrings [ "\n" ] [ "\r\n" ] lf;
      sourceRepos = f: __toJSON (haskellLib.parseSourceRepositoryPackages "cabal.project" {} {} f).sourceRepos;
    in {
      expr = sourceRepos crlf;
      expected = sourceRepos lf;
    };

  # A v2 slice's config fields come from its own plan unit's
  # configure-args only (no project-wide baseline), sorted so the fragment
  # text is canonical.
  testV2PragmasOfOwnUnit =
    let
      globals = import ../builder/v2-project-globals.nix { inherit lib; } {
        planJson = [];
      };
    in {
      expr = globals.pragmasOf [
        "--prefix=./dist-newstyle/store/host/x86_64-unknown-linux"
        "--enable-coverage" "--disable-shared" "--enable-optimization"
        "--disable-debug-info" "--ghc-option=-O2" "--disable-shared"
      ];
      expected = [
        "coverage: True" "debug-info: 0" "optimization: True" "shared: False"
      ];
    };

  testParseRepositoryBlock =
    let
      # The Cabal2Nix output in hackage-to-nix is imported into a lambda
      # and connot be easily compared.
      removeNix = x: x // {
        hackage =
          lib.mapAttrs (_packageName: vers:
            lib.mapAttrs (_ver: data: data // {
              revisions =
                lib.mapAttrs (_rev: x: x // { nix = __typeOf x.nix; }) data.revisions;
            }) vers
          ) x.hackage;
      };
      result = rec {
      expr = __toJSON (removeNix (haskellLib.parseRepositoryBlock evalPackages "cabal.project" {} {}
        evalPackages.haskell-nix.nix-tools-unchecked ''
          ghcjs-overlay
            url: https://raw.githubusercontent.com/input-output-hk/hackage-overlay-ghcjs/bfc363b9f879c360e0a0460ec0c18ec87222ec32
            secure: True
            root-keys:
            key-threshold: 0
            --sha256: sha256-tyeqsCew1ptGCrNAIrw5R2sz+oSqWbWrd/wDAPh1hMs=
          -- end of block
      ''));
      expected = __toJSON {
        name = "ghcjs-overlay";
        repoContents = "/nix/store/2gimg55rlc60pjiimpww10zflyf1bqh9-ghcjs-overlay";
        repo = {
          ghcjs-overlay = "/nix/store/2gimg55rlc60pjiimpww10zflyf1bqh9-ghcjs-overlay";
        };
        hackage = {
          Cabal = {
            "3.2.1.0" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "2b5309e942658e3b16e6938115867538e70a647d98e3dc967f2be20d6b886e61";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "2b5309e942658e3b16e6938115867538e70a647d98e3dc967f2be20d6b886e61";
                };
              };
              sha256 = "826970f742b63d751f6fe3be7f862b7b1e419ddfafef3014c01de54f12874a4a";
            };
          };
          basement = {
            "0.0.12"= {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "600669787199915545f99754496f13f955203b94dbb31de50093362c03367bb7";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "600669787199915545f99754496f13f955203b94dbb31de50093362c03367bb7";
                };
              };
              sha256 = "cf8f96fd92438739a516881abb7e14747118e82a12634d44acc83173fb87f535";
            };
          };
          clock = {
            "0.8.2" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "2a8441d9f531bb51bb1806e56e9e9a43e5f0214faea4f31219c15120128ca43a";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "2a8441d9f531bb51bb1806e56e9e9a43e5f0214faea4f31219c15120128ca43a";
                };
              };
              sha256 = "57715a01df74568c638f1138b53642094de420bafd519e9f53ec7fe92876121e";
            };
          };
          cryptonite = {
            "0.29" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "231db2acdaefc978865af9b72a6e65c4ebc70238174a7ad9076d68900f3d866d";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "231db2acdaefc978865af9b72a6e65c4ebc70238174a7ad9076d68900f3d866d";
                };
              };
              sha256 = "f104836bdaeed5243ff7e9fc0757d7255778f0af22976eef2b7789e7e1094283";
            };
          };
          double-conversion = {
            "2.0.2.0" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "698f94e66b6263a1049b56ede47aa48e224c764f345c3130265742513443595b";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "698f94e66b6263a1049b56ede47aa48e224c764f345c3130265742513443595b";
                };
              };
              sha256 = "67c83bf4619624ef6b950578664cbcd3bc12eaed0d7a387997db5e0ba29fb140";
            };
          };
          foundation = {
            "0.0.26.1" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "9a2f63a33dc6b3c1425c4755522b8e619d04fdfcfef72e358155b965b28745a8";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "9a2f63a33dc6b3c1425c4755522b8e619d04fdfcfef72e358155b965b28745a8";
                };
              };
              sha256 = "3c588f6bcf875762ac18b03b17a7ee3c0c60c8e2c884c0192269b0a97e89d526";
            };
          };
          network = {
            "3.1.2.1" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "ed4b1bb733613df5a2ebecd5533d08f20bacb0dc59ed207fd4b4670fe718713f";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "ed4b1bb733613df5a2ebecd5533d08f20bacb0dc59ed207fd4b4670fe718713f";
                };
              };
              sha256 = "21869fd942cb9996ba26ba9418cdd44ac869f81caba08e5a2b2cdfe792ae4518";
            };
            "3.1.2.5" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "433a5e076aaa8eb3e4158abae78fb409c6bd754e9af99bc2e87583d2bcd8404a";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "433a5e076aaa8eb3e4158abae78fb409c6bd754e9af99bc2e87583d2bcd8404a";
                };
              };
              sha256 = "ee914e9b43bfb0f415777eb0473236803b14a35d48f6172079260c92c6ceb335";
            };
          };
          terminal-size = {
            "0.3.2.1" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "7b2d8e0475a46961d07ddfb91dee618de70eff55d9ba0402ebeac1f9dcf9b18b";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "7b2d8e0475a46961d07ddfb91dee618de70eff55d9ba0402ebeac1f9dcf9b18b";
                };
              };
              sha256 = "8e4fbfea182f3bf5769744196ca88bb2cb1c80caa617debe34336f90db27131e";
            };
          };
          unix-compat = {
            "0.5.3" = {
              revisions = {
                default = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "9c6d68f9afb5baa6be55e8415dd401835ce0d4dfc2090f1c169fcd61c152ebac";
                };
                r0 = {
                  nix = "lambda";
                  revNum = 0;
                  sha256 = "9c6d68f9afb5baa6be55e8415dd401835ce0d4dfc2090f1c169fcd61c152ebac";
                };
              };
              sha256 = "2fe56781422d5caf47dcbbe82c998bd33f429f8c7093483fad36cd2d31dbdceb";
            };
          };
        };
      };
    };
    in result;
}
