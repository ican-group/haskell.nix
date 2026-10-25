# haskell.nix's patched hsc2hs (overlays/hsc2hs.nix, the `usePatchedHsc2hs`
# project option) is offered to the solver from a repository of its own, and a
# package that asks for hsc2hs as a build tool gets it.
#
#   * `plan` checks the plan chose it (at eval time, from plan.json).
#   * `run` builds and runs a program whose constants come from a .hsc file
#     and checks their values.  On a cross target that runs the patched
#     hsc2hs's batch mode; before the patch the wasm and JavaScript builds
#     read the file's last constant as 0.
{ stdenv, lib, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem
, buildPackages, testCabalProjectLocal, testInputMap }:

let
  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "hsc2hs-patched";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
  };

  # The context has to go: `repo.uri` names the repository's store path.
  planJson = builtins.fromJSON (builtins.unsafeDiscardStringContext
    (builtins.readFile (project.plan-nix + "/plan.json")));
  # The hsc2hs versions this test's own package builds with.  Only its
  # `exe-depends`: a plan can hold other hsc2hs units (the stable-haskell
  # `-target` compilers plan their boot libraries' hsc2hs from the fork's
  # source-repository-package, at the fork's own version).
  byId = lib.listToAttrs (map (p: { name = p.id; value = p; }) planJson.install-plan);
  hsc2hsVersions = lib.unique (lib.concatMap (p:
      map (d: byId.${d}.pkg-version)
        (lib.filter (d: byId.${d}.pkg-name or "" == "hsc2hs") (p.exe-depends or [])))
    (lib.filter (p: p.pkg-name or "" == "hsc2hs-patched") planJson.install-plan));
  wanted = buildPackages.haskell-nix.hsc2hs-patched-version;

  exe = project.hsPkgs.hsc2hs-patched.components.exes.hsc2hs-patched;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  plan = stdenv.mkDerivation {
    name = "hsc2hs-patched-plan";
    buildCommand =
      if hsc2hsVersions == [ wanted ]
        then "touch $out"
        else ''
          echo "expected the plan to use hsc2hs-${wanted}, it has: ${toString hsc2hsVersions}" >&2
          exit 1
        '';
    meta.platforms = lib.platforms.all;
  };

  run = stdenv.mkDerivation {
    name = "hsc2hs-patched-run";
    buildCommand = ''
      cat ${haskellLib.check exe}/test-stdout
      grep -q 'hsc2hs constants ok' ${haskellLib.check exe}/test-stdout
      touch $out
    '';
    meta.platforms = lib.platforms.all;
    passthru = { inherit project; };
  };
}
