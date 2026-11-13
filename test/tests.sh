#! /usr/bin/env nix-shell
#! nix-shell -I "nixpkgs=channel:nixos-24.11" -i bash -p bash jq nix gnused

set -euo pipefail

# check if Nix has the `ca-derivations` experimental features (code 0) is enabled
NIX_CA_DERIVATIONS=$(jq -e '."experimental-features".value|any(. == 0)' <<< $(nix show-config --json)) || true
NIX_BUILD_ARGS="${NIX_BUILD_ARGS:-}"

cd $(dirname $0)

if   [[ "$#" -lt 1 ]]; then
  echo "Please pass a compiler-nix-name to use.  For example: ./test/tests.sh ghc884"
  exit 1
elif [[ "$#" -gt 1 ]]; then
  TESTS="$2"
else
  TESTS="all"
fi

GHC=$1

printf "*** Cleaning package build directories..." >& 2
rm -rvf */cabal.project.local */.ghc.environment* */dist */dist-newstyle */.stack-work
echo >& 2

if [ "$TESTS" == "nix-build" ] || [ "$TESTS" == "all" ]; then
  printf "*** Running the nix-build tests...\n" >& 2
  nix build $NIX_BUILD_ARGS \
      --accept-flake-config \
      -I . -I .. \
      --option restrict-eval true \
      --option allowed-uris "https://github.com/NixOS https://github.com/input-output-hk https://github.com/ican-group" \
      --no-link --keep-going -f default.nix \
      --argstr compiler-nix-name "$GHC" \
      --arg CADerivationsEnabled $NIX_CA_DERIVATIONS
  echo >& 2
fi

if [ "$TESTS" == "unit-tests" ] || [ "$TESTS" == "all" ]; then
  printf "*** Running the unit tests... " >& 2
  # Running nix build first avoids `error: path '/nix/store/X-hackage-to-nix-ghcjs-overlay.drv' is not valid`
  nix-build ./default.nix --argstr compiler-nix-name "$GHC" -A unit.tests
  res=$(nix-instantiate --eval --json --strict ./default.nix --argstr compiler-nix-name "$GHC" -A unit.tests)
  num_failed=$(jq length <<< "$res")
  if [ "$num_failed" -eq 0 ]; then
    printf "PASSED\n" >& 2
  else
    printf "$num_failed FAILED\n" >& 2
    jq . <<< "$res"
    exit 1
  fi
fi

if [ "$TESTS" == "runghc" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking that a nix-shell works for runghc...\n" >& 2
  nix-shell $NIX_BUILD_ARGS \
      --pure ./default.nix \
      --argstr compiler-nix-name "$GHC" \
      -A with-packages.test-shell \
      --run 'runghc with-packages/Point.hs'
  echo >& 2
fi

if [ "$TESTS" == "cabal" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking that a nix-shell works for cabal...\n" >& 2
  nix-shell $NIX_BUILD_ARGS \
      --pure ./default.nix \
      --argstr compiler-nix-name "$GHC" \
      -A with-packages.test-shell \
      --run 'echo CABAL_CONFIG=$CABAL_CONFIG && type -p ghc && cd with-packages && CABAL_DIR=$(mktemp -d) cabal new-build'
  echo >& 2
fi

if [ "$TESTS" == "cabal-doExactConfig" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking that a nix-shell works for cabal (doExactConfig component)...\n" >& 2
  nix-shell $NIX_BUILD_ARGS \
      --pure ./default.nix \
      --argstr compiler-nix-name "$GHC" \
      -A with-packages.test-shell-dec \
      --run 'echo CABAL_CONFIG=$CABAL_CONFIG && echo GHC_ENVIRONMENT=$GHC_ENVIRONMENT && cd with-packages && CABAL_DIR=$(mktemp -d) cabal new-build'
  echo >& 2
fi

if [ "$TESTS" == "tests-benchmarks" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking that a nix-shell works for a project with test-suite build-tools and benchmarks...\n" >& 2
  printf "!!! This is expected to fail until https://github.com/ican-group/haskell.nix/issues/231 is resolved! \n" >& 2
  nix-shell $NIX_BUILD_ARGS \
      --pure ./default.nix \
      --argstr compiler-nix-name "$GHC" \
      -A cabal-22.shell \
      --run 'cd cabal-22 && CABAL_DIR=$(mktemp -d) cabal new-build all --enable-tests --enable-benchmarks' \
      || true
  echo >& 2
fi

if [ "$TESTS" == "multi-target" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking that a nix-shell works for a multi-target project...\n" >& 2
  TEST_CABAL_DIR=$(mktemp -d)
  nix-shell $NIX_BUILD_ARGS \
      --pure ./default.nix \
      --argstr compiler-nix-name "$GHC" \
      -A cabal-simple.test-shell \
      --run "cd cabal-simple && CABAL_DIR=$TEST_CABAL_DIR cabal update && CABAL_DIR=$TEST_CABAL_DIR cabal build"
  echo >& 2
fi

# These tests still use manually generated `pkgs`.  They were left that way
# so that we would still be testing that workflow.
SHELL_FOR_GHC="ghc967"
if [ "$TESTS" == "shellFor-single-package" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking shellFor works for a cabal project, multiple packages...\n" >& 2
  nix-shell $NIX_BUILD_ARGS \
      --pure ./default.nix \
      --argstr compiler-nix-name $SHELL_FOR_GHC \
      -A shell-for.env \
      --run 'cd shell-for && CABAL_DIR=$(mktemp -d) cabal new-build all'
  echo >& 2
fi

if [ "$TESTS" == "shellFor-multiple-package" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking shellFor works for a cabal project, single package...\n" >& 2
  nix-shell $NIX_BUILD_ARGS \
      --pure ./default.nix \
      --argstr compiler-nix-name $SHELL_FOR_GHC \
      -A shell-for.envPkga \
      --run 'cd shell-for && CABAL_DIR=$(mktemp -d) cabal new-build --project-file=single.project all'
  echo >& 2
fi

if [ "$TESTS" == "shellFor-hoogle" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking shellFor has a working hoogle index...\n" >& 2
  nix-shell $NIX_BUILD_ARGS \
      --pure ./default.nix \
      --argstr compiler-nix-name $SHELL_FOR_GHC \
      -A shell-for.env \
      --run 'hoogle ConduitT | grep Data.Conduit'
  echo >& 2
fi

if [ "$TESTS" == "shellFor-not-depends" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking shellFor does not depend on given packages...\n" >& 2
  drva=$(nix-instantiate ./default.nix --argstr compiler-nix-name $SHELL_FOR_GHC -A shell-for.env)
  echo "-- hello" >> shell-for/pkga/PkgA.hs
  drvb=$(nix-instantiate ./default.nix --argstr compiler-nix-name $SHELL_FOR_GHC -A shell-for.env)
  sed -i -e '/-- hello/d' shell-for/pkga/PkgA.hs
  if [ "$drva" != "$drvb" ]; then
      printf "FAIL\nShell derivations\n$drva\n$drvb\n are not identical.\n" >& 2
      exit 1
  else
      printf "PASS\n" >& 2
  fi
fi

if [ "$TESTS" == "maintainer-scripts" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking the maintainer scripts...\n" >& 2
  nix build $NIX_BUILD_ARGS \
      --accept-flake-config \
      --no-link \
      --keep-going \
      -f ../build.nix \
      --argstr compiler-nix-name "$GHC" \
          maintainer-scripts
  echo >& 2
fi

if [ "$TESTS" == "plan-extra-hackages" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking that plan construction works with extra Hackages...\n" >& 2
  nix build $NIX_BUILD_ARGS \
      --accept-flake-config \
      --no-link \
      -f ./default.nix \
      --argstr compiler-nix-name "$GHC" \
      extra-hackage.run.project.plan-nix
  echo >& 2
fi

if [ "$TESTS" == "build-extra-hackages" ] || [ "$TESTS" == "all" ]; then
  printf "*** Checking that package with extra Hackages can be build...\n" >& 2
  nix build $NIX_BUILD_ARGS \
      --accept-flake-config \
      --no-link \
      -f ./default.nix \
      --argstr compiler-nix-name "$GHC" \
      extra-hackage.run.project.hsPkgs.external-package-user.components.exes.external-package-user
  echo >& 2
fi

if [ "$TESTS" == "hix" ] || [ "$TESTS" == "all" ]; then
  printf "*** End-2-end test of hix project initialization and flakes development shell ...\n" >& 2
  HASKELL_NIX=$(pwd)/..
  cd "$(mktemp -d)"
  mkdir "from-source" && pushd "from-source"
  nix-shell -p cabal-install ghc --run "cabal update; cabal unpack hello"
  cd hello-*
  nix run "$HASKELL_NIX#hix" -- init
  nix flake update
  nix flake lock --override-input haskellNix "$HASKELL_NIX"
  nix develop \
      --accept-flake-config \
      -c cabal build
  popd
  cd "$HASKELL_NIX/test"
  echo >& 2
fi

if [ "$TESTS" == "template" ] || [ "$TESTS" == "all" ]; then
  printf "*** End-2-end test of templates#haskell-nix project initialization and flakes development shell ...\n" >& 2
  HASKELL_NIX=$(pwd)/..
  cd "$(mktemp -d)"
  mkdir "from-template" && pushd "from-template"
  nix-shell -p cabal-install --run "cabal update; cabal unpack hello"
  cd hello-*
  nix flake init --template "templates#haskell-nix" --impure
  nix flake update
  nix develop \
      --override-input haskellNix "$HASKELL_NIX" \
      --accept-flake-config \
      -c cabal build
  popd
  cd "$HASKELL_NIX/test"
  echo >& 2
fi

if [ "$TESTS" == "docs" ] || [ "$TESTS" == "all" ]; then
  printf "*** Test examples in documentation ...\n" >& 2
  pushd ../docs/
  ./tests.sh
  popd
fi

printf "\n*** Finished successfully\n" >& 2
