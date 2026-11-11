# A `source-repository-package` with a `subdir:` whose package has relative
# symlinks pointing outside that subdir (#1134): `pkg/LICENSE -> ../LICENSE`
# and `pkg/src/Shared.hs -> ../../shared/Shared.hs`.  If only the subdir
# ends up in the package's source the symlinks dangle and the build fails
# ("LICENSE: copyFile: does not exist"), so the package must be built
# inside the whole repository.
#
# The repository is `./repo`, supplied through `inputMap` instead of being
# fetched.  `builtins.path` makes it a store path string, like a `fetchgit`
# result or a flake input.  Built with both the v1 and the v2 builder.
{ stdenv, lib, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages
, testCabalProjectLocal, testInputMap }:

let
  # A stable-haskell compiler only works with the v2 builder (see the
  # `builderVersion` default in modules/cabal-project.nix), so skip the v1
  # arm there.
  onlyV2 = buildPackages.haskell-nix.compiler.${compiler-nix-name}.isStableHaskell or false;

  project = builderVersion: (cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "cabal-source-repo-symlink";
    inputMap = testInputMap // {
      "https://example.invalid/symlink-repo.git/main" =
        builtins.path { path = ./repo; name = "symlink-repo"; };
    };
    cabalProjectLocal = testCabalProjectLocal;
  }).appendModule { inherit builderVersion; };

  run = builderVersion:
    let
      packages = (project builderVersion).hsPkgs;
      exe = packages.use-symlink-pkg.components.exes.use-symlink-pkg;
    in stdenv.mkDerivation {
      name = "cabal-source-repo-symlink-v${toString builderVersion}-test";

      buildCommand = ''
        printf "checking whether executable runs... " >& 2
        cat ${haskellLib.check exe}/test-stdout
        grep -q 'shared module reached through a symlink' ${haskellLib.check exe}/test-stdout

        touch $out
      '';

      meta = rec {
        platforms = lib.platforms.all;
        broken = stdenv.hostPlatform.isGhcjs && __compareVersions buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6.1" >= 0;
        disabled = broken;
      };

      passthru = {
        # Attributes used for debugging with nix repl
        inherit packages;
      };
    };
in lib.recurseIntoAttrs ({
  ifdInputs = {
    inherit (project (if onlyV2 then 2 else 1)) plan-nix;
  };
  run-v2 = run 2;
} // lib.optionalAttrs (!onlyV2) {
  run = run 1;
})
