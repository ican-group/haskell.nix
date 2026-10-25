{ stdenv, lib, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  project = cabalProject' {
    src = testSrc "ghcjs-overlay";
    # `evalSystem` is the knob for the eval platform and `evalPackages` is
    # derived from it, so passing `evalSystem` alone keeps the two from being
    # specified independently.
    inherit compiler-nix-name evalSystem;
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };
  packages = project.hsPkgs;

in lib.recurseIntoAttrs {
  # The point of this test is that the ghcjs overlay is in use: its
  # `double-conversion ==2.0.2.0` is the overlay's copy, patched for the JS
  # backend, and hackage's build of that version is what the test would
  # otherwise get.  test/head-hackage.nix drops the overlay from
  # `active-repositories` for a stable-haskell `-target` compiler -- whose
  # from-source boot libraries and boot-dep pins the overlay contradicts -- so
  # under such a compiler there is no overlay here to test.
  # Only where the overlay was actually in play: on any other target
  # `active-repositories` never named it, so this test was already resolving
  # double-conversion from hackage there and keeps doing so.
  meta.disabled = stdenv.hostPlatform.isGhcjs
    && (buildPackages.haskell-nix.compiler.${compiler-nix-name}.emptyGlobalPackageDb or false);
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run = stdenv.mkDerivation {
    name = "ghcjs-overlay-test";

    # Double conversion needs updating for wasm
    meta.disabled = stdenv.hostPlatform.isWasm;

    buildCommand = ''
      exe="${packages.ghcjs-overlay-test.components.exes.ghcjs-overlay-test.exePath}"
      size=$(command stat --format '%s' "$exe")
      printf "size of executable $exe is $size. \n" >& 2
      # fixme: run on target platform when cross-compiled
      printf "checking whether executable runs... " >& 2
      cat ${haskellLib.check packages.ghcjs-overlay-test.components.exes.ghcjs-overlay-test}/test-stdout
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
    meta.platforms = platforms.all;
    passthru = {
      inherit project;
    };
  };
}
