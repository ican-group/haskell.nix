# A `build-tool-depends` executable that depends on the `ghc` library
# (ghc-lib-gen, a `ghc -F -pgmF` preprocessor), and a library and executable
# built with it (uses-gen).
#
# The stable-haskell stage2 project keeps `ghc` as its one local package, so
# under `inplace-builds: False` the units above `ghc` get bare unit ids, and
# the v2 builder refuses a build tool with a bare id (`bareBuildToolCheck` in
# builder/comp-v2-builder.nix).  A user project's `ghc` is the compiler's own
# (native) or, on `-target` cross, the native compiler's installed copy on the
# build stage -- so a tool like this one must get an ordinary hashed id, be
# built once, and be reused by the slices that run it.  `tool-id` checks the
# id in the plan; `build` and `run` check that the tool works.
{ lib, stdenv, buildPackages, project', testSrc, compiler-nix-name, evalPackages, evalSystem }:

let
  # ghc-lib-gen comes from a package repository, like a Hackage package.  A
  # project package -- local, or a source-repository-package -- would get an
  # `-inplace` id instead, and on `-target` cross a second, target build.
  # An unsigned secure repository (the shape of `hsc2hs-patched-repo` in
  # overlays/hsc2hs.nix), built on the eval platform, as plan-to-nix reads
  # it; its index lists the package at two times so any `index-state` sees
  # it.
  toolRepo =
    let
      index = evalPackages.runCommand "ghc-lib-gen-repo-contents"
        { nativeBuildInputs = [ evalPackages.gnutar evalPackages.gzip ]; } ''
        tarFlags="--format=ustar --sort=name --numeric-owner --owner=0 --group=0"
        cp -r ${./ghc-lib-gen} ghc-lib-gen-0.1.0.0
        chmod -R u+w ghc-lib-gen-0.1.0.0
        mkdir -p $out/package idx/ghc-lib-gen/0.1.0.0
        tar $tarFlags --mtime=@946684800 -cf - ghc-lib-gen-0.1.0.0 \
          | gzip -n -9 > $out/package/ghc-lib-gen-0.1.0.0.tar.gz
        cp ghc-lib-gen-0.1.0.0/ghc-lib-gen.cabal idx/ghc-lib-gen/0.1.0.0/
        sha256=$(sha256sum $out/package/ghc-lib-gen-0.1.0.0.tar.gz | cut -d' ' -f1)
        length=$(stat --printf=%s $out/package/ghc-lib-gen-0.1.0.0.tar.gz)
        printf '{"signatures":[],"signed":{"_type":"Targets","expires":null,"targets":{"<repo>/package/ghc-lib-gen-0.1.0.0.tar.gz":{"hashes":{"sha256":"%s"},"length":%s}},"version":1}}' \
          $sha256 $length > idx/ghc-lib-gen/0.1.0.0/package.json
        entries="ghc-lib-gen/0.1.0.0/ghc-lib-gen.cabal ghc-lib-gen/0.1.0.0/package.json"
        tar $tarFlags --mtime=@946684800 -C idx -cf index.tar $entries
        tar $tarFlags --mtime=@4102444800 -C idx -rf index.tar $entries
        gzip -n -9 -c index.tar > $out/01-index.tar.gz
      '';
      metadata = import ../../mk-local-hackage-repo evalPackages {
        name = "ghc-lib-gen"; index = "${index}/01-index.tar.gz"; };
    in evalPackages.runCommand "ghc-lib-gen-repo" { } ''
      mkdir -p $out
      cp -r ${index}/package $out/package
      cp -L ${metadata}/01-index.tar.gz $out/01-index.tar.gz
      cp ${metadata}/root.json ${metadata}/mirrors.json \
         ${metadata}/snapshot.json ${metadata}/timestamp.json $out/
    '';

  project = project' {
    inherit compiler-nix-name evalSystem;
    builderVersion = 2;
    src = testSrc "build-tool-ghc-lib";
    cabalProjectLocal = ''
      repository ghc-lib-gen
        url: file:${toolRepo}
        secure: True
        root-keys:
        key-threshold: 0
    '';
  };

  exe = project.hsPkgs.uses-gen.components.exes.uses-gen;

  # A stable-haskell `-target` cross compiler (boot libraries built from
  # source in a two-stage plan).
  twoStageCross =
    buildPackages.haskell-nix.compiler.${compiler-nix-name}.emptyGlobalPackageDb or false;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };

  # The bare ids only arise in the stable-haskell compilers' stage2 build.
  meta.disabled =
    !(buildPackages.haskell-nix.compiler.${compiler-nix-name}.isStableHaskell or false);

  build = project.hsPkgs.uses-gen.components.library;

  # The executable on its own: `run` only reaches it where the build
  # platform can execute it, and it must link on every target.
  inherit exe;

  # Every ghc-lib-gen unit in the plan (on `-target` cross, the build-stage
  # one) must not have a bare id (`<pkg>-<ver>-<exe>`, no hash), and natively
  # its id must be hashed.  A `-target` cross plan still names the build-stage
  # tool `-inplace`, so that is allowed there for now.  The plan comes from
  # the released planner (nix-tools-sh-0.2.8, nix-tools-static-sh.nix), whose
  # cabal (stable-haskell 7156caf47) takes every unit with a project
  # package's package id as a root of the project source closure, pre-existing
  # ones included: the build compiler's `ghc-9.14` shares its package id with
  # the injected local `ghc`, so everything above it, this tool included, is
  # in the closure and built inplace.  stable-haskell/cabal a7aa7efc9
  # (stable-haskell/cabal#535, which `nix-tools-sh/cabal.project` and
  # `v2-cabal-install` already pin) keeps only configured roots, so the
  # slices already give the tool a hashed id.  Drop the allowance once a
  # nix-tools-sh release built from that pin is in nix-tools-static-sh.nix.
  tool-id = buildPackages.runCommand "build-tool-ghc-lib-tool-id"
    { nativeBuildInputs = [ buildPackages.jq ]; } ''
    ids=$(jq -r '."install-plan"[]
                 | select(."pkg-name" == "ghc-lib-gen" and .type == "configured")
                 | .id' ${project.plan-nix}/plan.json)
    if [ -z "$ids" ]; then
      echo "no ghc-lib-gen unit in the plan" >&2
      exit 1
    fi
    for id in $ids; do
      echo "ghc-lib-gen unit: $id"
      if echo "$id" | grep -Eq -- '-[0-9a-f]{64}$'; then
        continue
      elif ${lib.boolToString twoStageCross} && echo "$id" | grep -q -- '-inplace-'; then
        continue
      fi
      echo "ghc-lib-gen's unit id $id is not hashed" >&2
      exit 1
    done
    touch $out
  '';

  run = stdenv.mkDerivation {
    name = "build-tool-ghc-lib-run";
    buildCommand = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      out_text=$(${exe}/bin/uses-gen${stdenv.hostPlatform.extensions.executable})
      echo "$out_text"
      case "$out_text" in
        "built with a tool that links ghc "*) ;;
        *) echo "unexpected output" >&2; exit 1 ;;
      esac
    '' + ''
      touch $out
    '';
    passthru = { inherit exe; };
  };
}
