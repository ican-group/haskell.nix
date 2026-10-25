{ stdenv, lib, pkgs, mkStackPkgSet, haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem }:

with lib;

let
  project = pkgs.haskell-nix.stackProject' {
    src = testSrc "stack-simple";
    stackYaml = "stack-${compiler-nix-name}.yaml";
    inherit evalSystem;
  };

  packages = project.hsPkgs;

in pkgs.lib.recurseIntoAttrs {
  meta.disabled = !builtins.pathExists ./stack-${compiler-nix-name}.yaml;
  stack-simple-exe = (haskellLib.check packages.stack-simple.components.exes.stack-simple-exe) // {
      # Attributes used for debugging with nix repl
      inherit pkgSet packages;
  };
  stack-simple-test = packages.stack-simple.checks.stack-simple-test;
  stack-simple-checks = packages.stack-simple.checks;
  # Shells for stack project don't work.
  # stack-simple-shell = project.shellFor { tools = { cabal = "3.6.2.0"; }; };
}
