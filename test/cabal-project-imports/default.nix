# Files a `cabal.project` pulls in with `import:` must reach the plan-nix
# step even though they are neither `.cabal` nor `package.yaml` files (#2144).
#
# `cabal.project` imports `cabal.project.common`, which in turn imports
# `config/flags.config` (with the value on a continuation line; the file is
# in a directory with no `.cabal` file).  That last file is the only place
# the `from-import` flag is turned on, so the flag is set in the plan only if
# both imports were followed, and the executable prints "from-import" only if
# the build used that plan.
{ stdenv, lib, cabalProject', haskellLib, testSrc, compiler-nix-name, evalSystem, testInputMap, testCabalProjectLocal, ... }:

let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "cabal-project-imports";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };
  exe = project.hsPkgs.cabal-project-imports.components.exes.cabal-project-imports;
  # The plan's own entries (keyed by plan id) carry the solved flags.
  flagSet = lib.all
    (id: project.pkg-set.config.packages.${id}.flags.from-import or false)
    (project.pkg-set.config.package-ids-by-name.cabal-project-imports or [ "missing" ]);

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run = assert lib.assertMsg flagSet
    "cabal-project-imports: the `from-import` flag set by an imported project file did not reach the plan";
    stdenv.mkDerivation {
      name = "cabal-project-imports-test";

      buildCommand = ''
        printf "checking the executable saw the imported flag... " >& 2
        grep -q from-import ${haskellLib.check exe}/test-stdout
        echo yes >& 2
        touch $out
      '';

      meta = {
        platforms = lib.platforms.all;
      };

      passthru = {
        inherit project;
      };
    };
}
