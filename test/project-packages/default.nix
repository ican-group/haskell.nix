# `projectPackages` and `localPackages` set package options for the project's
# own (respectively all local) packages only, without naming them (#298, #519).
#
# Nothing in the project files sets `ghc-options`, so the executable only
# builds (`Main.hs` has no `main` without `TEST_GHC_OPTION`) if the option
# given through `projectPackages` reaches the project package.  The Hackage
# dependency `data-default-class` must not get it.
{ stdenv, lib, cabalProject', haskellLib, testSrc, compiler-nix-name, evalSystem, testInputMap, testCabalProjectLocal, ... }:

let
  marker = "-DTEST_GHC_OPTION";
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "project-packages";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
    modules = [
      { projectPackages = { ghcOptions = [ marker ]; }; }
      # The function form (given the package's `pkgs` like any module), from
      # a second module, which must be merged in too.
      {
        localPackages = { pkgs, lib, ... }: {
          doHaddock = lib.mkForce (!(pkgs ? stdenv));
        };
      }
    ];
  };
  packages = project.hsPkgs;
  inherit (project.pkg-set.config) package-ids-by-name;
  configsOf = name: map (id: project.pkg-set.config.packages.${id})
    (package-ids-by-name.${name} or []);
  projectConfigs = configsOf "project-packages";
  hackageConfigs = configsOf "data-default-class";
  hasMarker = p: lib.elem marker (p.ghcOptions or []);

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run =
    assert lib.assertMsg (projectConfigs != [] && lib.all hasMarker projectConfigs)
      "project-packages: `projectPackages` did not set ghcOptions on project-packages";
    assert lib.assertMsg (lib.all (p: !p.doHaddock) projectConfigs)
      "project-packages: `localPackages` did not set doHaddock on project-packages";
    assert lib.assertMsg (hackageConfigs != []
        && !(lib.any hasMarker hackageConfigs)
        && lib.all (p: p.doHaddock) hackageConfigs)
      "project-packages: `projectPackages`/`localPackages` reached the Hackage package data-default-class";
    stdenv.mkDerivation {
      name = "project-packages-test";

      buildCommand = ''
        printf "checking whether executable runs... " >& 2
        cat ${haskellLib.check packages.project-packages.components.exes.project-packages}/test-stdout

        touch $out
      '';

      meta = {
        platforms = lib.platforms.all;
      };

      passthru = {
        # Attributes used for debugging with nix repl
        inherit project packages;
      };
    };
}
