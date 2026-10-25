# Test building with the reinstallable GHC library (cabal)
{ stdenv, lib, haskell-nix, haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages }:

with lib;

let
  ghcVersion = buildPackages.haskell-nix.compiler.${compiler-nix-name}.version;

  project = haskell-nix.cabalProject {
    inherit compiler-nix-name evalSystem;
    src = testSrc "ghc-lib-reinstallable";
    # Expose the GHC compiler tree as a `source-repository-package`
    # so cabal can install `lib:ghc` like any other reinstallable
    # dep.  Required since the unconditional `packages.ghc.src`
    # override was removed from `modules/configuration-nix.nix`.
    useLocalGhcLib = true;
    cabalProjectLocal = ''
      constraints: ghc ==${ghcVersion}
    '';
    # Configure packages for os-string (only needed for GHC 9.12+)
    modules = lib.optional (builtins.compareVersions ghcVersion "9.12" >= 0) {
      packages.directory.components.library.configureFlags = ["-f os-string"];
      packages.file-io.components.library.configureFlags = ["-f os-string"];
      packages.unix.components.library.configureFlags = ["-f os-string"];
      packages.process.components.library.configureFlags = ["-f os-string"];
    };
  };

  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  meta = {
    disabled =
      stdenv.hostPlatform.isAndroid
      || stdenv.hostPlatform.isGhcjs
      || (stdenv.hostPlatform.isMusl && stdenv.hostPlatform.is32bit)
      # aarch64-multiplatform{,-musl}: cross from x86_64 to
      # aarch64-linux currently breaks the local-ghc-lib slicing.
      || (haskellLib.isCrossHost
          && stdenv.hostPlatform.isLinux
          && stdenv.hostPlatform.isAarch64)
      || stdenv.hostPlatform.isWasm
      || stdenv.hostPlatform.isWindows;
  };

  ifdInputs = {
    inherit (project) plan-nix;
  };

  # Build the executable
  build = packages.ghc-lib-reinstallable.components.exes.ghc-lib-reinstallable;

  # Run test
  run = stdenv.mkDerivation {
    name = "ghc-lib-reinstallable-cabal-test";

    buildCommand = ''
      exe="${packages.ghc-lib-reinstallable.components.exes.ghc-lib-reinstallable.exePath}"

      printf "checking whether executable was built... " >& 2
      test -f "$exe" && echo "OK" >& 2

      size=$(command stat --format '%s' "$exe" 2>/dev/null || stat -f '%z' "$exe")
      printf "size of executable $exe is $size. \n" >& 2

      # Check that it runs (skip on cross-compilation)
      ${optionalString (!haskellLib.isCrossHost) ''
        printf "checking whether executable runs... " >& 2
        cat ${haskellLib.check packages.ghc-lib-reinstallable.components.exes.ghc-lib-reinstallable}/test-stdout
        echo "OK" >& 2
      ''}

      printf "Successfully built executable depending on GHC library\n" >& 2
      touch $out
    '';

    meta.platforms = lib.platforms.unix;

    passthru = {
      # Used for debugging with nix repl
      inherit project packages;
    };
  };
}
