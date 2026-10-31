{ stdenv, lib, writeScript, coreutils, glibc, git, openssh
, nix-tools, nixVersions
, gawk, bash, curl, findutils, cabal-issue-8352-workaround }@args:

import ./update-external.nix args {
  name = "stackage";
  script = ''
    # Clone or update the main Stackage Nix expressions repo.
    # The upstream LTS and Nightly package sets are in submodules, which
    # should also be updated.
    if [ -d stackage.nix ]; then
      cd stackage.nix
      git pull --ff-only
      git submodule update --init
      git submodule foreach git pull origin master
    else
      git clone git@github.com:ican-group/stackage.nix.git --depth 1
      cd stackage.nix
      git submodule update --init
      git submodule foreach git pull origin master
    fi

    echo "Running lts-to-nix for all snapshots..."

    LTS_TO_NIX=lts-to-nix ./update.sh
  '';
}
