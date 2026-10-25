{ stackProject'
, stdenv, lib, gmp6, openssl, zlib, libffi
, buildPackages
, testSrc
, compiler-nix-name
, evalPackages
, evalSystem
}:

with lib;

let
  # Grab the compiler name from stack-to-nix output.
  # compiler = (stack-pkgs.extras {}).compiler.nix-name;
  compiler = "ghc984";  # fixme

  # IFD stack-to-nix
  project = { gpl ? true }: stackProject' {
    inherit evalSystem;
    src = testSrc "fully-static";
    pkg-def-extras = [];
    modules = [
      {
        # Select a non-GMP compiler, usually for software licensing reasons.
        ghc.package = mkIf (stdenv.hostPlatform.isMusl && !gpl)
            buildPackages.haskell-nix.compiler.integer-simple.${compiler};
      }
    ];
  };
  packagesGmp = (project { gpl = true; }).hsPkgs;
  packagesIntegerSimple = (project { gpl = false; }).hsPkgs;

in lib.recurseIntoAttrs {
  meta.disabled = stdenv.hostPlatform.isGhcjs || compiler-nix-name != compiler;

  ifdInputs = {
    stack-nix-gmp = (project { gpl = true; }).stack-nix;
    stack-nix-simple = (project { gpl = false; }).stack-nix;
  };
  run = stdenv.mkDerivation {
    name = "fully-static-test";

    depsBuildBuild = [ buildPackages.file ];

    buildCommand = flip concatMapStrings
      [ packagesGmp /* packagesIntegerSimple */ ]
      (packages: ''
        exe="${packages.pandoc.components.exes.pandoc.exePath}"

        printf "checking whether executable runs... " >& 2
        ${toString packages.pandoc.components.exes.pandoc.config.testWrapper} $exe --version

      '' + optionalString stdenv.hostPlatform.isMusl ''
        printf "checking whether executable is static... " >& 2
        file $exe
        file $exe | grep "statically linked"

      '') + "touch $out";

    meta = {
      # A dependency is broken on Windows, just run on unix
      platforms = platforms.unix;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit buildPackages;
      project-gmp = project { gpl = true; };
      project-integer-simple = project { gpl = false; };
      pandoc-gmp = packagesGmp.pandoc.components.exes.pandoc;
      pandoc-integer-simple = packagesIntegerSimple.pandoc.components.exes.pandoc;
    };
  };
}
