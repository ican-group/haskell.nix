{ stdenv, lib, mkCabalProjectPkgSet, cabalProject', haskellLib, util, testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "cabal-22";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  packages = project.hsPkgs;

  # Whether the project's library gets a shared object by default.  That
  # needs a compiler with a shared way of its boot libraries, and cabal only
  # plans `shared: True` by default when `GHC Dynamic` is YES.  ghc914-sh
  # ships the dyn way of its boot libraries (`enableSharedStage2` in
  # overlays/stable-haskell.nix) but its `ghc` is static (`ghcIsDynamic =
  # false`), so its plans keep `shared: False` unless something asks for it.
  #
  # `or true` so nothing changes for compilers that do not carry the passthru.
  sharedByDefault = project.pkg-set.config.ghc.package.enableShared or true
                   && project.pkg-set.config.ghc.package.ghcIsDynamic or true;

in lib.recurseIntoAttrs {
  # When using ghcjs on darwin this test fails with
  # ReferenceError: h$hs_clock_darwin_gettime is not defined
  # https://github.com/ican-group/haskell.nix/issues/925
  # Also `hspec` now depends on `ghc`, which breaks this test for cross compilation
  meta.disabled = stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm || stdenv.hostPlatform.isWindows || stdenv.hostPlatform.isMusl;
  ifdInputs = {
    inherit (project) plan-nix;
  };
  shell = util.addCabalInstall packages.project.components.library;
  run = stdenv.mkDerivation {
    name = "cabal-22-test";

    buildCommand = ''
      exe="${packages.project.components.exes.project.exePath}"

      size=$(command stat --format '%s' "$exe")
      printf "size of executable $exe is $size. \n" >& 2

      # fixme: run on target platform when cross-compiled
      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.project.components.exes.project}/test-stdout

    '' +
    # Aarch is statically linked and does not produce a .so file.
    # Musl is also statically linked, but it does make a .so file so we should check that still.
    optionalString (!stdenv.hostPlatform.isAarch32 && !stdenv.hostPlatform.isAarch64 || stdenv.hostPlatform.isDarwin) (''
      printf "checking that executable is dynamically linked to system libraries... " >& 2
    '' + optionalString (stdenv.isLinux && !stdenv.hostPlatform.isMusl) ''
      ${haskellLib.lddForTests} $exe | grep 'libc[.]so'
    '' + optionalString stdenv.isDarwin ''
      otool -L $exe | grep "libSystem.B"
    '' +
    # Only if the compiler builds shared Haskell libraries.  The check above
    # this one -- that the EXECUTABLE links the system libc dynamically -- is
    # unaffected and stays: that is true of a static-Haskell build too, and it
    # passes on ghc914-sh today.  What follows looks for a `.so`/`.dylib` of
    # the project's own library, which such a compiler never emits, and the
    # `find | grep` then fails the whole test under `set -e`.
    optionalString sharedByDefault (''
      # fixme: posix-specific
      printf "checking that dynamic library is produced... " >& 2
    '' + optionalString stdenv.isLinux ''
      sofile=$(find "${packages.project.components.library}" | grep -e '\.so$')
    '' + optionalString stdenv.isDarwin ''
      sofile=$(find "${packages.project.components.library}" | grep -e '\.dylib$')
    '' + ''
      echo "$sofile"
    '' + optionalString (!stdenv.hostPlatform.isMusl) (''
      printf "checking that dynamic library is dynamically linked to prim... " >& 2
    '' + optionalString stdenv.isLinux ''
      ${haskellLib.lddForTests} $sofile | grep libHSghc-prim
    '' + optionalString stdenv.isDarwin ''
      otool -L $sofile | grep libHSghc-
    ''))) + ''
      touch $out

      printf "checking whether benchmark ran... " >& 2
      cat ${haskellLib.check packages.project.components.benchmarks.project-bench}/test-stdout

      printf "checking whether tests ran... " >& 2
      cat ${haskellLib.check packages.project.components.tests.unit}/test-stdout
    '';

    meta.platforms = platforms.all;
    passthru = {
      inherit project;
    };
  };
}
