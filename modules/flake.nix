{ projectConfig }:
{ lib, config, pkgs, haskellLib, ... }: {
  _file = "haskell.nix/modules/flake.nix";
  options = {
    packages = lib.mkOption {
      type = lib.types.unspecified;
      default = haskellLib.selectProjectPackages;
      defaultText = lib.literalExpression "haskellLib.selectProjectPackages";
      description = ''
        The packages the flake outputs are made for: a function from the
        project's package set to an attribute set of packages.  By default,
        the project's own packages.
      '';
    };
    crossPlatforms = lib.mkOption {
      type = lib.types.unspecified;
      default = projectConfig.crossPlatforms;
      defaultText = lib.literalMD "the project's `crossPlatforms`";
      example = lib.literalExpression "p: [ p.ghcjs ]";
      description = ''
        Cross-compilation platforms to add flake outputs for.  Their names
        get the platform as a prefix, for instance
        `nix build .#javascript-unknown-ghcjs:hello:exe:hello`.
      '';
    };
    variants = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      default = {};
      description = ''
        This allows flakes to easily include variations of the
        project by with different project arguments.
        Anything you can pass to `project.addModule` can be used.
        For instance to include variants using ghc 9.2.6:
        ```
          flake.variants.ghc928.compiler-nix-name = pkgs.lib.mkForce "ghc928";
        ```
        Then use it with:
        ```
          nix build .#ghc928:hello:exe:hello
        ```
      '';
    };
    doCoverage = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Specifies if the flake `ciJobs` and `hydraJobs` should include code
        coverage reports.
      '';
    };
    coverageProjectModule = lib.mkOption {
      type = lib.types.unspecified;
      default = {};
      description = ''
        Project module for use when generating coverage reports.  The
        coverage jobs turn coverage on for the project packages:

        * `builderVersion = 1`: they set `packages.X.doCoverage`.  To
          leave a package out, give it a plain definition here
          (`modules = [{ packages.X.doCoverage = false; }]`); a
          `lib.mkDefault false` is not enough.
        * `builderVersion = 2`: `doCoverage` alone is ignored (coverage
          has to be in the plan), so they add
          `package X` / `coverage: True` to `cabalProjectLocal`.  To leave a
          package out, add `package X` / `coverage: False` to
          `cabalProjectLocal` here (it comes after theirs, so it wins).
          Setting `packages.X.doCoverage = false` conflicts with the
          plan's `true`.

        Whether a project is v2 is read from the project with this module
        applied, so a module that sets `builderVersion` is honoured.
      '';
    };
    doDefaults = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Specifies if the flake should have `packages.default` and
        `apps.default` (for a bare `nix build` and `nix run`) when there is
        a package in the project directory: its executable if it has
        exactly one, and otherwise its library.  Only the flake without a
        cross or variant prefix gets them.
      '';
    };
    doHaddock = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Specifies if the flake `ciJobs` and `hydraJobs` should include a
        `haddock` group building the documentation (`.doc`) of each
        library/test component that has haddock enabled, so that broken
        documentation is caught by CI (see #1932).  Packages with an empty
        library (no exposed modules) fail with "haddock: No input file(s)";
        set `packages.<name>.doHaddock = false` for those.
      '';
    };
    ciSkip = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        Component ids (`pkg:lib:sublib`) to leave out of the flake `ciJobs`
        and `hydraJobs` (they stay in `packages`).  By default (`null`)
        these are the sub-libraries that only components which are not
        built use, such as a private library used only by test suites
        when the plan disables them (`configureArgs = "--disable-tests"`),
        see `haskellLib.subLibrariesOnlyForUnbuilt`.  Set it to `[]` to
        build them all.
      '';
    };
  };
}
