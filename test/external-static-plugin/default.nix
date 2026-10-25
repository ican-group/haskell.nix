{ lib, cabalProject', testSrc, compiler-nix-name, buildPackages, evalPackages, evalSystem, haskellLib }: let
  project = cabalProject' {
    src = testSrc "external-static-plugin";
    inherit compiler-nix-name evalSystem;
    modules = [ {
      packages.prog.postInstall = ''
        test -f f1
        test -f f2
      '';
    } ];
  };
in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  meta.disabled =
    __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6" < 0
      || haskellLib.isCrossHost;

  build = project.hsPkgs.prog.components.exes.prog;
}
