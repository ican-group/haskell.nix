# Create a local hackage repo, we can use as a repository in a cabal config
#
# This will include:
# - 01-index.tar.gz (the index file)
# - root.json and
# - mirrors.json as metadata items.
# - snapshot.json that records the index, root and mirrors.
# - timestamp.json that will record the snapshot.json
#
# This is all part of The Update Framework (TUF) and the specific implementation
# cabal-install (via hackage-security) does of it.
#
# We will create a completely unsigned bare repository.  Using signing keys within
# nix would be pointless as we'd have to hardcode them to produce the same output
# reproducibly.
#
pkgs:
{ name, index }:

pkgs.pkgsBuildBuild.runCommand "hackage-repo-${name}" { preferLocalBuild = true; } ''
mkdir -p $out
export expires="4000-01-01T00:00:00Z"

ln -sf ${index} $out/01-index.tar.gz
export index_md5=$(md5sum ${index} | awk '{ print $1 }')
export index_sha256=$(sha256sum ${index} | awk '{ print $1 }')
${
  # When possible check the hash we calculate here against the `outputHash`
  # of the index derivation (when the `extra-hackages` feature is used the index
  # may not have an outputHash).
  pkgs.lib.optionalString (index ? outputHash) ''
    if [[ "$(${pkgs.pkgsBuildBuild.nix}/bin/nix-hash --type sha256 --to-base16 ${index.outputHash})" != "$index_sha256" ]]; then
      echo "ERROR See https://github.com/ican-group/haskell.nix/issues/884"
      exit 1
    fi
''}
export index_length=$(stat --printf="%s" ${index})

substituteAll ${./root.json} $out/root.json
export root_md5=$(md5sum $out/root.json | awk '{ print $1 }')
export root_sha256=$(sha256sum $out/root.json | awk '{ print $1 }')
export root_length=$(stat --printf="%s" $out/root.json)

substituteAll ${./mirrors.json} $out/mirrors.json
export mirrors_md5=$(md5sum $out/mirrors.json | awk '{ print $1 }')
export mirrors_sha256=$(sha256sum $out/mirrors.json | awk '{ print $1 }')
export mirrors_length=$(stat --printf="%s" $out/mirrors.json)

substituteAll ${./snapshot.json} $out/snapshot.json
export snapshot_md5=$(md5sum $out/snapshot.json | awk '{ print $1 }')
export snapshot_sha256=$(sha256sum $out/snapshot.json | awk '{ print $1 }')
export snapshot_length=$(stat --printf="%s" $out/snapshot.json)

substituteAll ${./timestamp.json} $out/timestamp.json
''
