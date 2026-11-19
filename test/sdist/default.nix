# `hsPkgs.<pkg>.sdist` is the tarball `cabal sdist` makes for a package.  It
# must contain the files the .cabal file lists (`extra-source-files`,
# `extra-doc-files`, `data-files` globs, modules) and nothing else, and must
# not read the `cabal.project` that sits in the package directory (it lists a
# package that does not exist).  `LICENSE` is a symlink to `../LICENSE`, outside
# the package directory, and must be packed as the file it points to.
# Building it needs no compiler.
{ stdenv, lib, project', testSrc, compiler-nix-name, evalPackages, evalSystem, testInputMap, testCabalProjectLocal, buildPackages }:

let
  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "sdist";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  inherit (project.hsPkgs.sdist-test) sdist;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  run = stdenv.mkDerivation {
    name = "sdist-test";
    nativeBuildInputs = [ buildPackages.gnutar buildPackages.gzip ];

    buildCommand = ''
      tar -tzf ${sdist.tarball} | sort > files
      cat files
      cat > expected <<EOF
      sdist-test-0.1.0.0/
      sdist-test-0.1.0.0/LICENSE
      sdist-test-0.1.0.0/README.md
      sdist-test-0.1.0.0/data/
      sdist-test-0.1.0.0/data/included.txt
      sdist-test-0.1.0.0/sdist-test.cabal
      sdist-test-0.1.0.0/share/
      sdist-test-0.1.0.0/share/one.dat
      sdist-test-0.1.0.0/src/
      sdist-test-0.1.0.0/src/SdistTest.hs
      EOF
      sort expected | diff -u - files
      tar -xOzf ${sdist.tarball} sdist-test-0.1.0.0/LICENSE | grep -q 'Shared licence text'
      grep -q 'file source-dist ${sdist.tarball}' ${sdist}/nix-support/hydra-build-products
      touch $out
    '';

    meta.platforms = lib.platforms.all;

    passthru = {
      # Used for debugging with nix repl
      inherit project sdist;
    };
  };
}
