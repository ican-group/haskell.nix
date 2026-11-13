{ stdenv, lib, writeScript, coreutils, glibc, git, openssh
, nix-tools, nixVersions
, gawk, bash, curl, findutils
, update-index-state-hashes, cabal-issue-8352-workaround }@args:

import ./update-external.nix
(removeAttrs args ["update-index-state-hashes"]) {
  name = "hackage";
  script = ''
    # Clone or update the Hackage Nix expressions repo.
    if [ -d hackage.nix ]; then
      cd hackage.nix
      git pull --ff-only
      cd ..
    else
      git clone git@github.com:ican-group/hackage.nix.git --depth 1
    fi

    set -x
    # Make sure the hackage index is recent.
    echo "Updating local hackage index..."
    cabal update

    echo "Running hackage-to-nix..."

    hackage-to-nix hackage.nix

    echo "Running update-index-state-hashes..."

    cd hackage.nix

    ${update-index-state-hashes}/bin/update-index-state-hashes > index-state-hashes.nix
  '';
}
