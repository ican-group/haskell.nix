{ projectConfig }:
{ lib, config, pkgs, haskellLib, ... }: {
  options = {
    packages = lib.mkOption {
      type = lib.types.unspecified;
      default = haskellLib.selectProjectPackages;
    };
    crossPlatforms = lib.mkOption {
      type = lib.types.unspecified;
      default = projectConfig.crossPlatforms;
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
        Project module for use when generating coverage reports.
        The project packages will have `packages.X.doCoverage`
        turned on by default.
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
  };
}
