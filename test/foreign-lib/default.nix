# A package with a `foreign-library` (native-shared) that depends on the
# package's own library.  Builds the flib with both builders, then links a
# small C program against the produced shared library and runs it.
{ lib, stdenv, buildPackages, project', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  mkProject = builderVersion: project' {
    inherit compiler-nix-name evalSystem builderVersion;
    src = testSrc "foreign-lib";
  };

  # A stable-haskell `-target` cross compiler hard-sets `builderVersion = 2`
  # (see test/check-datadir for the details), so there is no v1 arm there.
  onlyV2 = buildPackages.haskell-nix.compiler.${compiler-nix-name}.emptyGlobalPackageDb or false;

  project = mkProject 1;
  projectV2 = mkProject 2;

  # Cabal only implements `native-shared` foreign libraries on GHC, so the
  # boot libraries need a dyn way.  ghc914-sh ships none on purpose
  # (`enableSharedStage2` in overlays/stable-haskell.nix), and both builders
  # then fail with "Perhaps you haven't installed the "dyn" libraries for
  # package base".  Same gate as test/cabal-22.
  ghcSupportsShared = projectV2.pkg-set.config.ghc.package.enableShared or true;

  libName = "libhsflib${stdenv.hostPlatform.extensions.sharedLibrary}";

  mkRun = suffix: flib: stdenv.mkDerivation {
    name = "foreign-lib-test${suffix}";

    buildCommand = ''
      lib="${flib}/lib/${libName}"
      if [ ! -e "$lib" ]; then
        echo "expected $lib, but the foreign-lib component contains:" >&2
        find ${flib} >&2
        exit 1
      fi

    ''
    # The linker checks the undefined symbols of the Haskell libraries the
    # foreign library depends on, so it must find their own dependencies
    # (libHSbase needs libHSghc-internal and the rts).  A native GNU ld
    # follows each library's RUNPATH for that; a cross ld does not, and
    # fails with "undefined reference to `ghczminternal_...'".  Pass the
    # absolute RUNPATH entries as -rpath-link (the `$ORIGIN` ones are
    # relative to the store unit and not needed here).
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      rpathLink=$(${stdenv.cc.bintools.targetPrefix}readelf -d "$lib" \
        | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p' | tr ':' '\n' \
        | sed -n 's|^/|-Wl,-rpath-link,/|p' | tr '\n' ' ')
    '' + ''
      $CC ${./c-test/main.c} -o main -L${flib}/lib -lhsflib -Wl,-rpath,${flib}/lib ''${rpathLink:-}
    '' + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      ./main
    '' + ''
      touch $out
    '';

    passthru = { inherit flib; };
  };

in lib.recurseIntoAttrs ({
  ifdInputs = {
    plan-nix-v2 = projectV2.plan-nix;
  } // lib.optionalAttrs (!onlyV2) {
    inherit (project) plan-nix;
  };

  run-v2 = mkRun "-v2" projectV2.hsPkgs.foreign-lib.components.foreignlibs.hsflib;

  # Shared Haskell libraries are not available on these targets (fully static
  # musl, JS / wasm backends), and Windows `native-shared` flibs need
  # `options: standalone` plus a .dll/.dll.a import-library pair to link
  # against.
  meta.disabled = !ghcSupportsShared
               || stdenv.hostPlatform.isMusl || stdenv.hostPlatform.isGhcjs
               || stdenv.hostPlatform.isWasm || stdenv.hostPlatform.isWindows
               || stdenv.hostPlatform.isAndroid;
}
// lib.optionalAttrs (!onlyV2) {
  run = mkRun "" project.hsPkgs.foreign-lib.components.foreignlibs.hsflib;
})
