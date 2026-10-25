# Test a package set
{ stdenv, lib, util, mkCabalProjectPkgSet, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages }:

with lib;

let
  modules = [
     {
       # Package has no exposed modules which causes
       #   haddock: No input file(s)
       packages.c-ffi.doHaddock = false;
     }
  ];

  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "c-ffi";
    inherit modules;
  };

  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  run = stdenv.mkDerivation {
    name = "c-ffi-test";

    buildCommand = ''
      exe="${packages.c-ffi.components.exes.c-ffi.exePath}"

      size=$(command stat --format '%s' "$exe")
      printf "size of executable $exe is $size. \n" >& 2

      # fixme: run on target platform when cross-compiled
      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.c-ffi.components.exes.c-ffi}/test-stdout
    '' + (if stdenv.hostPlatform.isMusl
      then ''
        printf "checking that executable is statically linked... " >& 2
        (${haskellLib.lddForTests} $exe 2>&1 || true) | grep -i "not a"
      ''
      else
        # Skip this on aarch as we do not have an `ldd` tool
        optionalString (!stdenv.hostPlatform.isAarch32 && !stdenv.hostPlatform.isAarch64) (''
          printf "checking that executable is dynamically linked to system libraries... " >& 2
        '' + optionalString stdenv.isLinux ''
          ${haskellLib.lddForTests} $exe | grep 'libc\.so'
        '' + optionalString stdenv.isDarwin ''
          otool -L $exe |grep .dylib
      '')) + ''

      touch $out
    '';

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isGhcjs && __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6.1" >= 0;
      disabled = broken;
    };

    passthru = {
      # Used for debugging with nix repl
      inherit project packages;
    };
  };
}
