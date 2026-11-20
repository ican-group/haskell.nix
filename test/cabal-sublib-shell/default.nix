{ stdenv, lib, pkgs, haskellLib, haskell-nix, buildPackages, runCommand
, cabalProject', testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap }:

with lib;

# The v1 (Setup.hs-based) builder used to synthesize ghc-pkg confs
# for public sublibraries that were missing `package-name:` and
# `lib-name:`.  With that missing, an unpatched cabal-install's
# solver treats the installed sublib unit as unusable and rebuilds
# the sublib from source inside the project.  This rebuild defeats
# the whole point of using the shell's pre-built deps.
#
# Structure:
#   - provider: has a main library and a `visibility: public` sublib `slib`.
#   - consumer: an executable that depends on `provider` and `provider:slib`.
#
# Test: spin up the project's shell, drop into it, run `cabal v2-build
# consumer` with the shell's own `cabal`, and inspect the build log.  If
# cabal built `provider` or the `slib` sublib from source, the sibling bug
# is present.  Two cases:
#   - v2 (`builderVersion = 2`): the shell's default cabal (whatever
#     `shell.tools.cabal = {}` resolves to; see `builder/shell-for-v2.nix`'s
#     `cabalTool`), reusing the shell's composed cabal store.
#   - v1 (`builderVersion = 1`, native, non-stable-haskell compilers only):
#     the shell's GHC package db, with `tools.cabal = "v2-cabal-install"`
#     (`project.v2-cabal-install`), because Hackage cabal-install cannot let
#     an installed package satisfy a sublib dependency (haskell/cabal#6039).
#     There is no composed store; the shared build script's comments about
#     one only apply to v2.  (They stay as they are so the v2 case's
#     derivation is unchanged.)
let
  mkCase = builderVersion: let
  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "cabal-sublib-shell";
    # Don't `readFile ../cabal.project.local` here — the only
    # thing this test depends on from `test/cabal.project.local`
    # would be the head.hackage repository definition, which the
    # test's sandboxed `cabal v2-build` then tries to bootstrap
    # over https.  The unpatched cabal in the shell isn't built
    # with TLS support, so the bootstrap fails with
    # `user error (https not supported)`.  The provider /
    # consumer packages this test uses don't need anything from
    # `test/cabal.project.local`.
    cabalProjectLocal =
      lib.optionalString (haskellLib.isCrossHost && stdenv.hostPlatform.isAarch64) ''
        constraints: text -simdutf, text source
      '';
    # v2: the shell's default cabal (see `cabalTool` in
    # builder/shell-for-v2.nix).  v1 picks its cabal in `env` below.
    shell.tools = lib.optionalAttrs (builderVersion == 2) { cabal = {}; };
    modules = [
      { packages.provider.doHaddock = false; }
    ];
    inherit builderVersion;
  };

  env = project.shellFor ({
    packages = ps: [ ps.consumer ];
    withHoogle = false;
  } // lib.optionalAttrs (builderVersion == 1) {
    # Upstream cabal-install's solver does not consider installed
    # sublibraries (haskell/cabal#6039): with the hackage cabal a v1
    # shell's pre-built `provider` is rejected for lacking `slib`, and
    # `provider` is rebuilt from source.  haskell.nix's cabal-install
    # (`"v2-cabal-install"`, the same derivation as
    # `project.v2-cabal-install`) lets installed units satisfy sublib
    # dependencies, so the v1 shell's package db is reused.
    tools.cabal = "v2-cabal-install";
  });

  # v1 has no slice tarball; an sdist-shaped tarball of the same source
  # is all the local repository needs.
  providerTarball =
    if builderVersion == 2
      then project.hsPkgs.provider.components.library.passthru.pkgTarball
      else runCommand "provider-0.1.0.0.tar.gz" {} ''
        cp -r ${testSrc "cabal-sublib-shell"}/provider provider-0.1.0.0
        tar -czf $out provider-0.1.0.0
      '';

  in {
  ifdInputs = { inherit (project) plan-nix; };
  inherit env;

  run = stdenv.mkDerivation {
    name = "cabal-sublib-shell-test${lib.optionalString (builderVersion == 1) "-v1"}";
    passthru = { inherit project; };

    nativeBuildInputs = env.nativeBuildInputs;
    # The host libraries the shell hands the cc wrapper, as `nix develop`
    # does: on windows the rts links `-lpthread`, which only resolves with
    # `mingw_w64_pthreads` (from the slices' `runtimeLibs`) here
    # (`x86_64-w64-mingw32-ld.bfd: cannot find -lpthread`).
    buildInputs = env.buildInputs;

    buildCommand = ''
      export HOME=$PWD/home
      # Seed a writable `~/.cabal` from the project's own offline dot-cabal:
      # the same prepopulated hackage index plan-to-nix solved against.  The
      # sandbox has no network, and this project's compiler ships an empty
      # global package db (`emptyGlobalPackageDb`), so without an
      # index the solver cannot resolve the boot deps the stable-haskell
      # boot-package injection pulls in -- it fails with
      # `unknown package: unix (dependency of Cabal)`.  The composed store
      # does hold those units, but cabal only consults it AFTER solving
      # (`improveInstallPlanWithStoreUnits`), so it is no substitute for an
      # index at solve time.
      export CABAL_DIR=$HOME/.cabal
      mkdir -p "$HOME/.cabal"
      cp -R ${project.dotCabalDir}/. "$HOME/.cabal/"
      chmod -R u+w "$HOME/.cabal"
      ${lib.optionalString (builderVersion == 1) ''
        # The v1 shell's cabal-install need not be the one that wrote the
        # index cache, and the cache is a read-only symlink into the store;
        # drop it so cabal can regenerate it.
        rm -f "$HOME"/.cabal/packages/*/01-index.cache
      ''}

      # Stage consumer, point cabal at a local repo containing
      # provider's tarball so the solver can see provider as a
      # hackage candidate in addition to the installed unit.
      cp -r ${testSrc "cabal-sublib-shell"}/consumer ./consumer
      chmod -R +w consumer
      repoDir=$PWD/repo
      mkdir -p "$repoDir"
      cp ${providerTarball} \
         "$repoDir/provider-0.1.0.0.tar.gz"

      cd consumer
      # Run the v2 shell's shellHook exactly as a user gets it on
      # entering the shell, rather than replaying individual steps.
      # It seeds ~/.cabal/store from the composed store, writes the
      # cross `cabal.project.<targetPrefix>local` (pulled in via the
      # `import:` below — cabal doesn't auto-discover the prefixed
      # name), and sets a writable EM_CACHE for emcc on ghcjs.  The
      # hook is written to be *sourced* (it uses `return`), so source
      # it from the project dir.
      source ${buildPackages.writeText "v2-shell-hook" env.shellHook}
      cat > cabal.project <<EOF
      packages: .
      ${lib.optionalString (project.pkg-set.config.ghc.package.targetPrefix or "" != "") ''
      import: cabal.project.${project.pkg-set.config.ghc.package.targetPrefix}local
      ''}
      EOF
      # Append (not overwrite): dot-cabal's config already declares
      # hackage.haskell.org and any extra hackage repos, each with its index
      # prepopulated under `$CABAL_DIR/packages`.
      cat >> "$HOME/.cabal/config" <<EOF
      repository local
        url: file+noindex://$repoDir
      EOF

      echo "=== cabal v2-build consumer (${if builderVersion == 1 then "haskell.nix cabal-install" else "unpatched cabal"}) ==="
      ${project.pkg-set.config.ghc.package.targetPrefix}cabal --config-file=$HOME/.cabal/config v2-build -v2 consumer 2>&1 | tee build.log

      echo "=== verifying solver reused provider ==="
      if grep -q 'Building library for provider-' build.log; then
        echo "FAIL: cabal rebuilt provider's library instead of reusing the shell's" >&2
        exit 1
      fi
      if grep -q "Building library 'slib' for provider-" build.log; then
        echo "FAIL: cabal rebuilt provider's 'slib' sublibrary instead of reusing the shell's" >&2
        exit 1
      fi
      ${lib.optionalString (builderVersion == 1) ''
        # The log checks above pass vacuously if cabal words its output
        # differently.  So also check the plan itself: every `provider`
        # unit (the library and `slib`) must come from the shell's
        # package db (`pre-existing`), not be configured for a build.
        ${buildPackages.jq}/bin/jq -r \
          '."install-plan"[] | select(."pkg-name" == "provider") | "\(.type) \(.id)"' \
          dist-newstyle/cache/plan.json | tee provider-units
        if [ "$(grep -c '^pre-existing ' provider-units || true)" -lt 2 ] \
           || grep -qv '^pre-existing ' provider-units; then
          echo "FAIL: plan.json does not take provider and its slib from the shell's package db" >&2
          exit 1
        fi
      ''}
      touch $out
    '';

    meta = { platforms = platforms.unix; };
  };
  };

  v2 = mkCase 2;
  v1 = mkCase 1;

  # A stable-haskell compiler only works with the v2 builder (see the
  # `builderVersion` default in modules/cabal-project.nix), so there is no
  # v1 shell to test there.  The v1 case is native-only.
  onlyV2 = buildPackages.haskell-nix.compiler.${compiler-nix-name}.isStableHaskell or false;

  hasV1 = !onlyV2 && !haskellLib.isCrossHost;

in lib.recurseIntoAttrs ({
  # CI only pre-builds a test's top-level `ifdInputs`, so the v1 case's
  # plan-nix (a separate IFD) is listed here too.
  ifdInputs = v2.ifdInputs // lib.optionalAttrs hasV1 {
    v1-plan-nix = v1.ifdInputs.plan-nix;
  };
  inherit (v2) env run;
} // lib.optionalAttrs hasV1 {
  v1 = lib.recurseIntoAttrs v1;
})
