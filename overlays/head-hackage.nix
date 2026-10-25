# Build the head.hackage package repository locally, instead of downloading the
# one GitLab publishes.
#
# Why not just download it: the published repository is regenerated on a
# schedule and is not reproducible, so its hash moves even when nothing in
# head.hackage changes.  Between two consecutive publications every one of the
# 79 patched packages had a different tarball hash while not a single `.cabal`
# file differed -- the patched tarballs are re-created each run and pick up the
# build time.  Pinning that with `--sha256` in a `repository` stanza means the
# pin goes stale about once a day, and each bump invalidates every
# `plan-to-nix` output in the tree.
#
# Building it here instead means it depends only on the `head-hackage` flake
# input (which moves when a patch changes) and the Hackage index haskell.nix
# already pins through hackage.nix.  Nothing to hand-maintain.
#
# The result is wired in as `inputMap."https://ghc.gitlab.haskell.org/head.hackage/"`
# (see modules/cabal-project.nix), the same mechanism used for foliage
# repositories such as CHaP, so a `repository` stanza naming that url is served
# from here rather than fetched.
{ sources }:

final: prev:

let
  inherit (final) lib;

  buildPkgs = final.buildPackages;

  indexStateHashes = import final.haskell-nix.indexStateHashesPath;

  # The newest index-state hackage.nix has a hash for.  `internalHackageIndexState`
  # is not usable here: it is an exact timestamp, whereas index-state-hashes.nix
  # is keyed by the daily snapshots, so it usually has no entry for it.
  # `lib/call-cabal-project-to-nix.nix` deals with this by rounding up to the
  # first cached state at or after the one asked for; we simply take the latest,
  # which is always present and is what a fresh `cabal update` would see.
  index-state = lib.last (builtins.attrNames indexStateHashes);

  # The Hackage index, pinned exactly as the rest of haskell.nix pins it: the
  # index-state comes from hackage.nix and the hash from its
  # index-state-hashes.nix.  Everything below is derived from this, so moving
  # the hackage.nix pin is all it takes to pick up newly patched versions.
  hackageIndex = buildPkgs.fetchurl {
    name = "01-index.tar.gz-at-${builtins.replaceStrings [ ":" ] [ "" ] index-state}";
    url = "https://hackage.haskell.org/01-index.tar.gz";
    downloadToTemp = true;
    postFetch = ''
      ${final.haskell-nix.nix-tools-unchecked.exes.truncate-index}/bin/truncate-index \
        -o $out -i $downloadedFile -s ${index-state}
    '';
    outputHashAlgo = "sha256";
    outputHash = indexStateHashes.${index-state};
  };

  # The package-versions head.hackage patches, taken from the names in
  # `patches/`: `<pkg>-<version>.patch` (a source patch) or `<pkg>-<version>.cabal`
  # (a .cabal-only fixup).  Deriving the list from the directory rather than
  # hard-coding it means a new patch upstream needs no change here.
  patchedPackages =
    let
      names = builtins.attrNames (builtins.readDir (sources.head-hackage + "/patches"));
      stripExt = n: lib.removeSuffix ".patch" (lib.removeSuffix ".cabal" n);
    in
    lib.unique (map stripExt names);

  # Pull each patched version's *original* tarball hash out of the pinned
  # index.  Every entry in a secure Hackage index carries a `package.json` with
  # the tarball's sha256 and length, which is what lets us fetch the originals
  # without a single hash of our own.
  #
  # This is import-from-derivation, as plan-to-nix already is throughout
  # haskell.nix: the index is a build artefact, so reading it means building it.
  srcHashesFile = buildPkgs.runCommand "head-hackage-src-hashes.nix"
    {
      nativeBuildInputs = [ buildPkgs.gnutar buildPkgs.gzip buildPkgs.jq ];
      passthru = { inherit patchedPackages; };
    } ''
    mkdir -p unpacked && cd unpacked
    # One pass over the index, not one per package: it is ~130MB compressed and
    # rescanning it 79 times is minutes of pure I/O.  tar takes all the members
    # we want in a single invocation.
    tar -xzf ${hackageIndex} \
      ${lib.concatMapStringsSep " \\\n      " (pv:
        let
          m = builtins.match "(.*)-([0-9][0-9.]*)" pv;
          pname = builtins.elemAt m 0;
          pver = builtins.elemAt m 1;
        in "'${pname}/${pver}/package.json'") patchedPackages}

    {
      echo '{'
      ${lib.concatMapStringsSep "\n      " (pv:
        let
          m = builtins.match "(.*)-([0-9][0-9.]*)" pv;
          pname = builtins.elemAt m 0;
          pver = builtins.elemAt m 1;
        in ''
          if [ ! -f '${pname}/${pver}/package.json' ]; then
            echo "head.hackage patches ${pv}, but it is not in the Hackage index at ${index-state}" >&2
            exit 1
          fi
          echo "  \"${pv}\" = \"$(jq -r '.signed.targets | to_entries[0].value.hashes.sha256' '${pname}/${pver}/package.json')\";"
        '') patchedPackages}
      echo '}'
    } > $out
  '';

  srcHashes = import srcHashesFile;

  # hackage-repo-tool will not bootstrap an empty repository, so one package has
  # to be in place first.  Pick it here rather than with `ls | head -1` in the
  # builder: that order depends on locale collation, so the choice -- and with it
  # the bootstrapped metadata -- could differ between machines.
  seedName = lib.head (lib.sort (a: b: a < b) (builtins.attrNames srcHashes));
  seedPackage = buildPkgs.fetchurl {
    name = "${seedName}.tar.gz";
    url = "https://hackage.haskell.org/package/${seedName}/${seedName}.tar.gz";
    sha256 = srcHashes.${seedName};
  };

  # The original tarballs, fetched by hash from the index.  Laid out the way
  # `cabal fetch` would leave them, which is where the overlay tool looks:
  #   <repo-cache>/<repo-name>/<pkg>/<version>/<pkg>-<version>.tar.gz
  #
  # `sourceRepoName` is deliberately not "hackage.haskell.org": cabal has a
  # built-in definition for that name, and with the repository called that its
  # `update` went to the real hackage.haskell.org instead of the `file:` url the
  # tool was given -- which only showed up once the build ran sandboxed.
  sourceRepoName = "head-hackage-upstream";

  repoCache = buildPkgs.runCommand "head-hackage-repo-cache" { } (''
    mkdir -p $out/${sourceRepoName}
  '' + lib.concatStrings (lib.mapAttrsToList (pv: sha256:
    let
      m = builtins.match "(.*)-([0-9][0-9.]*)" pv;
      pname = builtins.elemAt m 0;
      pver = builtins.elemAt m 1;
      tarball = buildPkgs.fetchurl {
        name = "${pv}.tar.gz";
        url = "https://hackage.haskell.org/package/${pv}/${pv}.tar.gz";
        inherit sha256;
      };
    in ''
      mkdir -p $out/${sourceRepoName}/${pname}/${pver}
      ln -s ${tarball} $out/${sourceRepoName}/${pname}/${pver}/${pv}.tar.gz
    '') srcHashes));

  # One fixed timestamp for everything we re-tar, taken from the head.hackage
  # input's own lastModified so it is deterministic and only moves when the
  # patches do.  Not epoch: cabal derives a repository's index-state from the
  # newest entry in its index, and an index stamped 1970 makes any project
  # asking for a present-day index-state look newer than the repository.
  repoEpoch = toString sources.head-hackage.lastModified;

  mkLocalHackageRepo = import ../mk-local-hackage-repo final;

  # `cabal update` has to succeed offline, so point the tool at a local,
  # unsigned copy of the pinned index rather than hackage.haskell.org.
  # mk-local-hackage-repo is what haskell.nix already uses for this.
  localHackage = mkLocalHackageRepo {
    name = sourceRepoName;
    index = hackageIndex;
  };

  # `tar` with a fixed mtime.
  #
  # The overlay tool already asks for reproducible output -- it passes
  # `--format=ustar --numeric-owner --owner=root --group=root --clamp-mtime
  # --mtime=<patch file>` -- but that `--mtime` does not take effect and the
  # tarballs come out stamped with the time of the run.  Two runs minutes apart
  # on identical inputs produced different directory entries:
  #
  #   arith-encode-1.0.2/   2026-08-03 10:29
  #   arith-encode-1.0.2/   2026-08-03 10:31
  #
  # That is the upstream churn, and without fixing it this derivation would not
  # be reproducible either.  GNU tar honours the last `--mtime`, so appending
  # one overrides theirs without patching their source; with it, two
  # independent runs agree byte for byte.
  deterministicTar = buildPkgs.writeShellScriptBin "tar" ''
    exec ${buildPkgs.gnutar}/bin/tar "$@" --mtime=@${repoEpoch} --clamp-mtime
  '';

in
{
  haskell-nix = prev.haskell-nix // {

    # The tool head.hackage's CI uses to turn `patches/` into a repository.
    # Built with haskell.nix against a nixpkgs GHC -- it is a small build tool,
    # so there is no reason to build a compiler for it.  `overlays/bootstrap.nix`
    # builds alex and happy the same way.
    #
    # The repository carries no cabal.project, and its bounds predate current
    # Hackage (`base < 4.17`, `text ^>= 1.2`), hence both overrides.
    hackage-overlay-repo-tool =
      (final.haskell-nix.cabalProject' {
        # Patched so its `cabal update` accepts the unsigned local mirror of
        # the pinned index; see the patch header for why.
        src = buildPkgs.applyPatches {
          name = "hackage-overlay-repo-tool-src";
          src = sources.hackage-overlay-repo-tool;
          patches = [ ./patches/hackage-overlay-repo-tool/local-repo-no-signatures.patch ];
        };
        name = "hackage-overlay-repo-tool";
        compiler-nix-name = "ghc967";
        compilerSelection = p: p.haskell.compiler;
        # The tool's own plan is pinned to the same internal index-state the
        # other build tools (alex, happy) use, so it is stable and materializable.
        index-state = final.haskell-nix.internalHackageIndexState;
        cabalProject = ''
          packages: .
        '';
        cabalProjectLocal = ''
          allow-newer: tool:*
        '';
      }).hsPkgs.tool.components.exes.tool;

    # The tool's own output.  Its `package/*.tar.gz` are reproducible (see the
    # tar wrapper), but its TUF metadata is not: it is signed with keys generated
    # during this build, so root/mirrors/snapshot/timestamp differ every time.
    # `head-hackage-repo` below keeps the packages and replaces the metadata.
    head-hackage-patched-repo = buildPkgs.runCommand "head-hackage-patched"
      {
        nativeBuildInputs = [
          # `deterministicTar` must come before gnutar on PATH.
          deterministicTar
          buildPkgs.gnutar
          buildPkgs.gzip
          buildPkgs.gnupatch
          buildPkgs.haskellPackages.hackage-repo-tool
          # The tool's last step syncs its staging directory over the target.
          buildPkgs.rsync
          final.haskell-nix.hackage-overlay-repo-tool
          final.haskell-nix.nix-tools-unchecked.exes.cabal
          # cabal insists on finding a compiler even for `fetch`.  haskell.nix's
          # `cabal-issue-8352-workaround` dummy-ghc is not enough here: cabal
          # invokes it as `-package-env=- --supported-languages`, which the stub
          # does not parse ("Unknown argument").  A real GHC costs nothing extra
          # -- this is the same one the overlay tool above is built with.
          buildPkgs.haskell.compiler.ghc967
        ];
        passthru = { inherit patchedPackages srcHashesFile seedName; };
      } ''
      export HOME=$(mktemp -d)


      # Signing keys.  These are generated per build rather than pinned: the
      # repository is consumed over `file:` from the store, so the signatures
      # are not a trust boundary, and the `repository` stanza that reads it
      # uses `key-threshold: 0` with no root-keys (the same arrangement as the
      # existing `ghcjs-overlay` entry in test/cabal.project.local).
      hackage-repo-tool create-keys --keys=$HOME/keys

      # hackage-repo-tool refuses to bootstrap an empty repository, so seed it
      # with one package, exactly as head.hackage's ci/build-repo.sh does.
      mkdir -p repo/package
      cp ${seedPackage} repo/package/${seedName}.tar.gz
      hackage-repo-tool bootstrap --keys=$HOME/keys --repo=./repo

      # Everything the tool needs is already local: the patches from the flake
      # input, the originals in the pre-populated cache, and the pinned index
      # served over `file:` so its `cabal update` needs no network.
      mkdir -p tmp/patches.cache template
      cp -R ${sources.head-hackage}/patches tmp/patches
      chmod -R u+w tmp/patches
      cp -R ${repoCache} cache
      chmod -R u+w cache

      tool \
        --patches=./tmp/patches \
        --repo-cache=./cache \
        --keys=$HOME/keys \
        --repo-name=${sourceRepoName} \
        --repo-url=file:${localHackage} \
        --template=template \
        ./repo

      cp -r repo $out
    '';

    # The repository as consumed.  Packages come from the tool; the TUF metadata
    # is regenerated unsigned, so the whole output is reproducible.
    #
    # mk-local-hackage-repo exists for exactly this and says so: "We will create
    # a completely unsigned bare repository.  Using signing keys within nix would
    # be pointless as we'd have to hardcode them to produce the same output
    # reproducibly."  Signing stays only as the bootstrap step the overlay tool
    # insists on, and nothing downstream checks it -- the `repository` stanza
    # reading this uses `root-keys:` with `key-threshold: 0`.
    head-hackage-repo =
      let
        patched = final.haskell-nix.head-hackage-patched-repo;
        # hackage-repo-tool writes the index tar itself, stamping each entry
        # with the time of the build, so `01-index.tar.gz` differs run to run
        # even though its contents do not.  Verified with `nix-build --check`:
        # across two builds the extracted files and the entry order were
        # identical and only the mtimes moved (14:09 vs 14:11).
        #
        # Re-tar with a fixed mtime, feeding the original listing back in so the
        # order is preserved exactly.  Order matters in a Hackage index -- later
        # entries supersede earlier ones, which is how `.cabal` revisions work --
        # so this must not sort.
        index = buildPkgs.runCommand "head-hackage-01-index.tar.gz"
          { nativeBuildInputs = [ buildPkgs.gnutar buildPkgs.gzip ]; } ''
          mkdir idx
          tar -xzf ${patched}/01-index.tar.gz -C idx
          tar -tzf ${patched}/01-index.tar.gz > order.txt
          tar -cf index.tar --format=ustar --numeric-owner --owner=root \
              --group=root --mtime=@${repoEpoch} --no-recursion -C idx -T order.txt
          # -n: keep gzip's own timestamp and name fields out of the header.
          gzip -n -9 -c index.tar > $out
        '';

        # A derivation without `outputHash`, so mk-local-hackage-repo's
        # cross-check against one is skipped.
        metadata = mkLocalHackageRepo {
          name = "head.hackage.ghc.haskell.org";
          inherit index;
        };
      in
      buildPkgs.runCommand "head-hackage.ghc.haskell.org"
        { passthru = { inherit (patched) patchedPackages srcHashesFile seedName; }; } ''
        mkdir -p $out
        cp -r ${patched}/package $out/package
        # -L: mk-local-hackage-repo symlinks the index it was handed, and the
        # result should stand on its own.
        cp -L ${metadata}/01-index.tar.gz $out/01-index.tar.gz
        cp ${metadata}/root.json ${metadata}/mirrors.json \
           ${metadata}/snapshot.json ${metadata}/timestamp.json $out/
      '';
  };
}
