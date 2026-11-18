{ stdenv, lib, stackProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem }:

with lib;

let
  project = stackProject' {
    inherit evalSystem;
    src = testSrc "ghc-options";
  };
  packages = project.hsPkgs;

  # stack.yaml's `$everything`, `$locals` and `$targets` ghc-options reach
  # the project package in stack's order, followed by its own entry, while
  # a snapshot package gets only `$everything` (see #827).
  ghcOptionsOf = name: project.pkg-set.config.packages.${name}.ghcOptions;
  ghcOptionsOk =
    ghcOptionsOf "test-ghc-options" == [
      "-DSTACK_EVERYTHING"
      "-ddump-to-file -ddump-hi -DSTACK_LOCALS"
      "-DSTACK_TARGETS"
      "-DTEST_GHC_OPTION -DSTACK_BUILD"
    ]
    && ghcOptionsOf "random" == [ "-DSTACK_EVERYTHING" ];

in lib.recurseIntoAttrs {
  # This test is somehow broken for ghcjs
  meta.disabled = stdenv.hostPlatform.isGhcjs || compiler-nix-name != "ghc984";

  ifdInputs = {
    inherit (project) stack-nix;
  };
  run = assert lib.assertMsg ghcOptionsOk
    "stack.yaml ghc-options were not applied as expected: test-ghc-options: ${
      builtins.toJSON (ghcOptionsOf "test-ghc-options")}, random: ${
      builtins.toJSON (ghcOptionsOf "random")}";
    stdenv.mkDerivation {
    name = "callStackToNix-test";

    buildCommand = ''
      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.test-ghc-options.components.exes.test-ghc-options-exe}/test-stdout

      touch $out
    '';

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isGhcjs && __elem compiler-nix-name ["ghc961"];
      disabled = broken;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit project packages;
    };
  };
}
