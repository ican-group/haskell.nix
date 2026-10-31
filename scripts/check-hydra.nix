{ stdenv, lib, writeScript, coreutils, time, gnutar, gzip, nix-eval-jobs, jq, gitMinimal }:

with lib;

writeScript "check-hydra.sh" ''
  #!${stdenv.shell}

  set -euo pipefail

  export PATH="${makeBinPath [ coreutils time gnutar gzip nix-eval-jobs jq gitMinimal ]}"
  export NIX_PATH=

  echo '~~~ Evaluating release.nix with' "$@"
  HYDRA_CONFIG= command time --format '%e' -o eval-time.txt \
      nix-eval-jobs \
      --option allowed-uris "https://github.com/NixOS/ https://github.com/input-output-hk/ https://github.com/ican-group/ github:NixOS/nixpkgs/ github:ican-group/hackage.nix/ github:ican-group/stackage.nix/ github:input-output-hk/flake-compat/ github:stable-haskell/iserv-proxy/ github:haskell/haskell-language-server/" \
      --flake $(pwd)#hydraJobs --force-recurse > eval.json
  EVAL_EXIT_CODE="$?"
  if [ "$EVAL_EXIT_CODE" != 0 ]
  then
    rm eval.json eval-time.txt
    echo -e "\\e[31;1mERROR: Failed to evaluate release.nix\\e[0m"
    exit 1
  fi
  EVAL_TIME=$(cat eval-time.txt)
  jq . < eval.json
  ERRORS=$(jq 'select(.error)|@text "\(.attrPath|join(".")): \(.error)"' < eval.json)
  NUM_ERRORS=$([ -z "$ERRORS" ] && echo 0 || echo "$ERRORS" | wc -l)
  rm eval.json eval-time.txt

  if [ "$NUM_ERRORS" != 0 ]
  then
    echo -e "\\e[31;1mERROR: evaluation completed in $EVAL_TIME seconds with $NUM_ERRORS errors\\e[0m"
    echo "$ERRORS"
    exit 1
  else
    echo -e "\\e[32;1mOK: evaluation completed in $EVAL_TIME seconds with no errors\\e[0m"
    exit 0
  fi
''
