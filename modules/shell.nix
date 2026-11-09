{ projectConfig }:
{ lib, config, pkgs, haskellLib, ... }: {
  options = {
    name = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    packages = lib.mkOption {
      type = lib.types.unspecified;
      default = ps: builtins.attrValues (haskellLib.selectLocalPackages ps);
    };
    components = lib.mkOption {
      type = lib.types.unspecified;
      default = ps: lib.concatMap haskellLib.getAllComponents (config.packages ps);
    };
    additional = lib.mkOption {
      type = lib.types.unspecified;
      default = _: [];
    };
    withHoogle = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    withHaddock = lib.mkOption {
      type = lib.types.bool;
      default = config.withHoogle;
    };
    exactDeps = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    allToolDeps = lib.mkOption {
      type = lib.types.bool;
      default = !config.exactDeps;
      description = ''
        Indicates if the shell should include all the tool dependencies
        of the haskell packages in the project.  Defaulted to `false` in
        stack projects (to avoid trying to build the tools used by
        every `stackage` package).
      '';
    };
    exposePackagesVia = lib.mkOption {
      type = lib.types.enum [ "cabal-store" "ghc-pkg" ];
      default = "cabal-store";
      description = ''
        How the v2 shell's pre-built library deps are made visible to
        tools the user runs.  One of:
          * "cabal-store" (default) — the composed store is linked
            into the cabal store (`cabal path --store-dir`) via a shellHook
            (or the explicit `haskell-nix-cabal-store-sync` command).
            `cabal v2-build` then reuses the units directly.  The
            shell's `ghc` is left plain, so `runghc`/`ghci` will not
            see the deps.
          * "ghc-pkg" — the shell's `ghc` is wrapped with
            GHC_ENVIRONMENT pointing at the composed store's
            package.db, so `ghc`/`ghci`/`runghc`/`ghc-pkg` see every
            dep directly.  No files are written outside the shell.
        Only affects `shellFor` under `builderVersion = 2`.
      '';
    };
    tools = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      default = {};
    };
    packageSetupDeps = lib.mkOption {
      type = lib.types.unspecified;
      default = true;
    };
    enableDWARF = lib.mkOption {
      type = lib.types.unspecified;
      default = false;
    };
    crossPlatforms = lib.mkOption {
      type = lib.types.unspecified;
      default = projectConfig.crossPlatforms;
    };

    # mkShell args
    inputsFrom = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
    };
    shellHook = lib.mkOption {
      type = lib.types.str;
      # Shell hook to set EM_CACHE to a writable temporary directory if not already set
      default = lib.optionalString pkgs.stdenv.hostPlatform.isGhcjs ''
        if [ -z "$EM_CACHE" ]; then
          # Create a unique temporary directory using mktemp
          EM_CACHE_DIR=$(mktemp -d -t emcache-ghcjs-XXXXXX)
          
          # Copy the default Emscripten cache contents to the temporary directory
          DEFAULT_EM_CACHE="${pkgs.pkgsBuildBuild.emscripten}/share/emscripten/cache"
          if [ -d "$DEFAULT_EM_CACHE" ]; then
            cp -r "$DEFAULT_EM_CACHE"/* "$EM_CACHE_DIR" 2>/dev/null || true
            chmod -R u+w "$EM_CACHE_DIR"
          fi
          
          export EM_CACHE="$EM_CACHE_DIR"
          echo "Set EM_CACHE to $EM_CACHE"
        else
          echo "EM_CACHE already set to $EM_CACHE"
        fi
      '';
    };

    # mkDerivation args
    buildInputs = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
    };
    nativeBuildInputs = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
    };
    passthru = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      default = {};
    };
  };
}
