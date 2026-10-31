{ stdenv, lib, writeScript, coreutils, glibc, git, openssh }:

with lib;

let
  repo = "git@github.com:ican-group/haskell.nix.git";
  sshKey = "/run/keys/buildkite-haskell-dot-nix-ssh-private";
in
  writeScript "update-pins.sh" ''
    #!${stdenv.shell}

    set -euo pipefail

    export PATH="${makeBinPath [ coreutils glibc git openssh ]}"

    source ${./git.env}

    git add flake.lock
    check_staged
    echo "Committing changes..."
    git commit --message "Update Hackage and Stackage"

    use_ssh_key ${sshKey}

    if [ "$BUILDKITE_BRANCH" = master ]; then
      git push ${repo} HEAD:master
    fi
  ''
