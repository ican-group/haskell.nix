{ stdenv, lib, haskellLib, buildPackages, cabalProject', testSrc, compiler-nix-name, evalSystem, ... }:

with lib;

# `build-tool-depends` on a Hackage package whose library the shell also
# provides (`markdown-unlit` here).  A v1 shell exposes such a package
# through the GHC package db, and cabal's solver never lets an installed
# package provide an executable: `cabal build` inside the shell fails with
#
#   rejecting: tool-user:markdown-unlit:exe.markdown-unlit-0.6.0/installed-...
#   (does not contain executable 'markdown-unlit', which is required by tool-user)
#
# unless it can fetch and build the tool from source.  A v2 shell instead
# links the dependency's library *and* executable units into the cabal
# store, so cabal plans the tool from the index and then reuses the
# shell's pre-built unit.  This test runs `cabal v2-build` in a v2 shell,
# offline, and checks that cabal neither failed nor built `markdown-unlit`.
let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "shell-for-build-tool-depends";
    shell.tools.cabal = {};
    builderVersion = 2;
  };

  env = project.shellFor {
    packages = ps: [ ps.tool-user ];
    withHoogle = false;
  };

in recurseIntoAttrs {
  ifdInputs = { inherit (project) plan-nix; };
  inherit env;

  run = stdenv.mkDerivation {
    name = "shell-for-build-tool-depends-test";
    passthru = { inherit project; };

    nativeBuildInputs = env.nativeBuildInputs;
    buildInputs = env.buildInputs;

    buildCommand = ''
      export HOME=$PWD/home
      # The sandbox has no network: seed `~/.cabal` with the project's
      # offline dot-cabal (the hackage index plan-to-nix solved against).
      # The v2 solver plans `markdown-unlit` from the index and only then
      # swaps in the shell's pre-built units.
      export CABAL_DIR=$HOME/.cabal
      mkdir -p "$HOME/.cabal"
      cp -R ${project.dotCabalDir}/. "$HOME/.cabal/"
      chmod -R u+w "$HOME/.cabal"

      cp -r ${testSrc "shell-for-build-tool-depends"}/. ./project
      chmod -R +w project
      cd project
      # The shell's hook, as a user gets it on entering the shell: it
      # links the composed store (including the tool's exe unit) into
      # `~/.cabal/store` and writes `cabal.project.local`.
      source ${buildPackages.writeText "v2-shell-hook" env.shellHook}

      echo "=== cabal v2-build tool-user ==="
      cabal --config-file=$HOME/.cabal/config v2-build -v2 --offline tool-user 2>&1 | tee build.log

      echo "=== verifying cabal reused the shell's markdown-unlit ==="
      if grep -qE "Building (executable 'markdown-unlit'|library) for markdown-unlit-" build.log; then
        echo "FAIL: cabal built markdown-unlit instead of reusing the shell's" >&2
        exit 1
      fi
      [ "$(cabal --config-file=$HOME/.cabal/config list-bin -v0 --offline tool-user | xargs sh -c '"$0"')" = "markdown-unlit ran" ] \
        || { echo "FAIL: tool-user did not print the expected output" >&2; exit 1; }

      touch $out
    '';

    meta = {
      platforms = platforms.unix;
      # The tool has to run on the build machine; this test is about the
      # native shell.
      disabled = haskellLib.isCrossHost;
    };
  };
}
