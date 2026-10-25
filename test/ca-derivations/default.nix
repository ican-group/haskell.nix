# Test if derivations are content addressed building two derivations producing
# the same outputs and checking if the path stores are equals
{ stdenv, pkgs, lib, mkCabalProjectPkgSet, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, CADerivationsEnabled }:

with lib;

let

  cabalProject = ''
    packages: .
    allow-newer: aeson:*
  '' + lib.optionalString (__elem compiler-nix-name ["ghc96020230302" "ghc961"]) ''
    allow-newer: *:ghc-prim, *:template-haskell
  '';

  srcPlain = testSrc "cabal-simple";

  # we alter the source adding an Haskell comment since they are ignored by ghc
  srcWithComment = pkgs.runCommand "src-with-comment" { } ''
    mkdir $out
    install ${srcPlain}/* $out
    echo " -- Altering source without altering executable..." >> $out/Main.hs
  '';

  projectPlain = project' {
    inherit compiler-nix-name evalSystem cabalProject;
    src = srcPlain;
    modules = [{ contentAddressed = true; }];
  };

  projectWithComment = project' {
    inherit compiler-nix-name evalSystem cabalProject;
    src = srcWithComment;
    modules = [{ contentAddressed = true; }];
  };

  exe-plain = projectPlain.hsPkgs.cabal-simple.components.exes.cabal-simple.exePath;
  exe-withComment = projectWithComment.hsPkgs.cabal-simple.components.exes.cabal-simple.exePath;

in
lib.recurseIntoAttrs {

  meta.disabled = !CADerivationsEnabled;

  run = stdenv.mkDerivation {
    name = "ca-derivations-test";

    buildCommand = ''
      [ "${exe-plain}" != "${exe-withComment}" ] && exit 1
      touch $out
    '';

    meta.platforms = platforms.all;

    passthru = {
      # Used for debugging with nix repl
      inherit projectWithComment projectPlain;
    };
  };

}
