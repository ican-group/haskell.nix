# The hsc2hs haskell.nix prefers: stable-haskell's batch cross-compilation
# fork (the `ghc914-sh-hsc2hs` lazy input) with our fix to its assembly parser.
#
# In `--cross-compile` mode upstream hsc2hs computes every `#const`, `#size`,
# `#enum`, ... by compiling a small C program per value (a binary search, so
# several per value).  The fork compiles all of them in one `cc -S` and reads
# the values back out of the assembly, falling back to the old way for any it
# cannot read.  For a 28-constant .hsc file that took the GHC JavaScript
# backend from 117s (about 570 emcc runs) to 7.5s, wasm32 from 24s to 1.2s and
# the gcc / clang ELF and PE targets from 8-14s to under 1s.
#
# The patch is what makes the wasm and JavaScript numbers possible, and it is
# a correctness fix as much as a speed-up.  Unpatched, the fork could read
# nothing on those targets (clang's wasm assembly writes values as
# `.int64`/`.int32`) and, worse, read the last constant of every file as 0:
# that label picked up the data of the trailing `.custom_section.*` sections,
# and the parser's fallback for data it could not combine was a plain 0.  It
# also could not read gcc's `.zero 8`, so every zero-valued constant fell back
# on gcc targets.  See the patch for details.
#
# Two things are provided:
#
#   * `hsc2hs-patched-src`, used wherever haskell.nix builds that fork itself
#     (the stable-haskell compilers' own hsc2hs, and the source-repository
#     package the `-target` boot injection plans with).
#
#   * `hsc2hs-patched-repo`, a package repository holding the same source as
#     `hsc2hs-${hsc2hs-patched-version}`.  modules/cabal-project.nix adds it
#     to every project (see the `usePatchedHsc2hs` option), so whenever a plan
#     needs hsc2hs as a build tool cabal's solver can pick it -- and, being a
#     repository rather than a source-repository-package, it only gets picked
#     when the version suits: a package asking for hsc2hs >= 0.69 still gets
#     one from Hackage.
final: prev:

let
  inherit (final) lib;
  buildPkgs = final.buildPackages;

  # Hackage's newest release is 0.68.10, which the fork is based on.  One more
  # component sorts above it and below any future 0.68.11 / 0.69.
  version = "0.68.10.1";
  name = "hsc2hs-${version}";

  # Fixed times for the tarball members and the index entries.
  #
  # A project's `index-state` applies to this repository too, and cabal is
  # strict about it both ways: an entry newer than the index-state is hidden,
  # and a repository whose newest entry is older than the index-state is an
  # error ("Latest known index-state for 'haskell-nix-hsc2hs' ... is older than
  # the requested index-state").  No single time suits every project, so the
  # index lists the package twice, identically: at `earlyEpoch`, so it is
  # visible at any index-state, and again at `lateEpoch` (cabal reads the
  # second as a revision that changes nothing), so the repository is never
  # older than the index-state asked for.
  earlyEpoch = "946684800";  # 2000-01-01T00:00:00Z
  lateEpoch = "4102444800";  # 2100-01-01T00:00:00Z

  mkLocalHackageRepo = import ../mk-local-hackage-repo final;

in
{
  haskell-nix = prev.haskell-nix // rec {
    hsc2hs-patched-version = version;

    hsc2hs-patched-src = buildPkgs.applyPatches {
      name = "hsc2hs-patched-src";
      src = final.haskell-nix.sources.ghc914-sh-hsc2hs;
      patches = [ ./patches/hsc2hs/batch-cross-wasm-and-zero-values.patch ];
    };

    # The package tarball and the two index entries for it.  The index entry
    # needs the tarball's hash (`package.json`), so both are made together.
    hsc2hs-patched-repo-contents = buildPkgs.runCommand "${name}-repo-contents"
      { nativeBuildInputs = [ buildPkgs.gnutar buildPkgs.gzip ]; } ''
      cp -r ${hsc2hs-patched-src} ${name}
      chmod -R u+w ${name}
      # The fork's .cabal names the version it is based on and a Hackage
      # revision number, neither of which applies to this package.
      sed -i -e 's/^\([Vv]ersion:[[:space:]]*\).*$/\1${version}/' \
             -e '/^x-revision:/d' ${name}/hsc2hs.cabal
      if ! grep -q '^[Vv]ersion:[[:space:]]*${version}$' ${name}/hsc2hs.cabal; then
        echo "could not set the version of hsc2hs.cabal to ${version}" >&2
        exit 1
      fi

      tarFlags="--format=ustar --sort=name --numeric-owner --owner=0 --group=0"
      mkdir -p $out/package
      tar $tarFlags --mtime=@${earlyEpoch} -cf - ${name} | gzip -n -9 > $out/package/${name}.tar.gz

      mkdir -p idx/hsc2hs/${version}
      cp ${name}/hsc2hs.cabal idx/hsc2hs/${version}/hsc2hs.cabal
      sha256=$(sha256sum $out/package/${name}.tar.gz | cut -d' ' -f1)
      length=$(stat --printf=%s $out/package/${name}.tar.gz)
      printf '{"signatures":[],"signed":{"_type":"Targets","expires":null,"targets":{"<repo>/package/%s.tar.gz":{"hashes":{"sha256":"%s"},"length":%s}},"version":1}}' \
        ${name} $sha256 $length > idx/hsc2hs/${version}/package.json
      entries="hsc2hs/${version}/hsc2hs.cabal hsc2hs/${version}/package.json"
      tar $tarFlags --mtime=@${earlyEpoch} -C idx -cf index.tar $entries
      tar $tarFlags --mtime=@${lateEpoch} -C idx -rf index.tar $entries
      gzip -n -9 -c index.tar > $out/01-index.tar.gz
    '';

    # An unsigned secure repository, the same shape as `head-hackage-repo`
    # (overlays/head-hackage.nix).  A `repository` stanza reading it uses
    # `root-keys:` with `key-threshold: 0`.
    hsc2hs-patched-repo =
      let
        contents = hsc2hs-patched-repo-contents;
        metadata = mkLocalHackageRepo {
          name = "haskell-nix-hsc2hs";
          index = "${contents}/01-index.tar.gz";
        };
      in buildPkgs.runCommand "haskell-nix-hsc2hs-repo" { } ''
        mkdir -p $out
        cp -r ${contents}/package $out/package
        # -L: mk-local-hackage-repo symlinks the index it was handed.
        cp -L ${metadata}/01-index.tar.gz $out/01-index.tar.gz
        cp ${metadata}/root.json ${metadata}/mirrors.json \
           ${metadata}/snapshot.json ${metadata}/timestamp.json $out/
      '';
  };
}
