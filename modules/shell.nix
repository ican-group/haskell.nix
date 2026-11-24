{ projectConfig }:
{ lib, config, pkgs, haskellLib, ... }: {
  _file = "haskell.nix/modules/shell.nix";
  options = {
    name = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The name of the shell derivation.";
    };
    packages = lib.mkOption {
      type = lib.types.unspecified;
      default = ps: builtins.attrValues (haskellLib.selectLocalPackages ps);
      defaultText = lib.literalExpression "ps: builtins.attrValues (haskellLib.selectLocalPackages ps)";
      example = lib.literalExpression "ps: [ ps.my-lib ps.my-exe ]";
      description = ''
        The packages being worked on: a function from the project's
        package set to a list of packages.  The shell provides their
        dependencies, but not the packages themselves.
      '';
    };
    components = lib.mkOption {
      type = lib.types.unspecified;
      default = ps: lib.concatMap haskellLib.getAllComponents (config.packages ps);
      defaultText = lib.literalExpression "ps: lib.concatMap haskellLib.getAllComponents (config.packages ps)";
      description = ''
        Like `packages`, but selects components.  By default, all the
        components of the selected packages.  Not used with `builderVersion = 2`.
      '';
    };
    additional = lib.mkOption {
      type = lib.types.unspecified;
      default = _: [];
      defaultText = lib.literalExpression "_: [ ]";
      description = ''
        Like `packages`, but the selected packages themselves are built and
        included in the shell's package db (not just their dependencies).  Not used with `builderVersion = 2`.
      '';
    };
    includeExtraPackages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Include the libraries of the project's `extra-packages` in the
        shell's package db, as if they were listed in `additional`.  They are
        in the plan, but nothing in the project depends on them, so `cabal
        build` does not build them.
      '';
    };
    withHoogle = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Build a Hoogle index of the shell's packages and provide the
        `hoogle` command.  With `builderVersion = 2` it only provides
        `hoogle` (run `hoogle generate` for an index).
      '';
    };
    withHaddock = lib.mkOption {
      type = lib.types.bool;
      default = config.withHoogle;
      defaultText = lib.literalExpression "config.withHoogle";
      description = ''
        Include the documentation of the shell's packages.  Has no effect
        with `builderVersion = 2`.
      '';
    };
    exactDeps = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Stop the cabal solver from choosing any dependency that is not in
        the package set.  This sets `CABAL_CONFIG`, which also turns off the
        remote package servers.  Not used with `builderVersion = 2`.
      '';
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
      # A tool is a version string, a module spec for `haskell-nix.tool`
      # or a derivation.  The default `unspecified` merge cannot combine a
      # string with a derivation ("Cannot merge definitions"), `//`s a
      # `{ version = ...; }` set into a derivation, and concatenates two
      # strings ("latest" and "3.12.1.0" become "latest3.12.1.0").  So:
      #
      #  * Module priorities apply first, as for any option: only the
      #    highest-priority definitions get here, so `lib.mkForce` picks
      #    one outright.
      #  * `"latest"` and `{}` ask for no version in particular (`{}` leaves
      #    the version at its default, "latest"), and give way to any
      #    other definition, e.g. a project's (or template's)
      #    `shell.tools.cabal = "latest"` to a `shellFor { tools.cabal =
      #    ...; }`.  Several of them together merge to "latest".
      #  * A derivation wins over versions and module specs, with a
      #    warning when that throws away an actual pin.  Two different
      #    derivations are an error, not decided by definition order.
      #  * Two different version strings are an error too.  Anything else
      #    merges as before (module specs are `//`ed).
      type = lib.types.attrsOf (lib.mkOptionType {
        name = "haskell-nix-tool";
        description = "tool version, module spec or derivation";
        merge = loc: defs:
          let
            isDrv = d: lib.isDerivation d.value;
            asksForNothing = v: v == "latest" || v == {};
            drvDefs = lib.filter isDrv defs;
            pinDefs = lib.filter (d: !isDrv d && !asksForNothing d.value) defs;
            conflict = what: ds: throw (
              "The option `${lib.showOption loc}' has ${what} definitions in "
              + "${lib.options.showFiles (map (d: d.file) ds)}.  Use `lib.mkForce` "
              + "on the one to use.");
          in
            if drvDefs != [] then
              if lib.length (lib.unique (map (d: d.value.drvPath) drvDefs)) > 1
                then conflict "conflicting derivation" drvDefs
              else lib.warnIf (pinDefs != [])
                ("`${lib.showOption loc}` is a derivation here, so the version or "
                 + "module spec it is also given in "
                 + "${lib.options.showFiles (map (d: d.file) pinDefs)} is not used.  "
                 + "Drop one of them (or use `lib.mkForce`) to silence this.")
                (lib.head drvDefs).value
            # `{}` leaves the version at its default, which is "latest".
            else if pinDefs == [] then
              if lib.length (lib.unique (map (d: d.value) defs)) == 1
                then (lib.head defs).value
                else "latest"
            else if lib.all (d: lib.isString d.value) pinDefs
                 && lib.length (lib.unique (map (d: d.value) pinDefs)) > 1
              then conflict "conflicting version" pinDefs
            else lib.mergeDefaultOption loc pinDefs;
      });
      default = {};
      example = lib.literalExpression ''
        {
          cabal = "latest";
          hlint = "3.8";
          haskell-language-server = { version = "latest"; index-state = "2025-01-10T00:00:00Z"; };
        }
      '';
      description = ''
        Tools to put on `PATH`, by name.  A tool is a version, the arguments
        of [`haskell-nix.tool`](tools.md) (an attribute set, for instance
        with `version`, `index-state` or `materialized`), or a derivation
        used as it is.  See [Tools](tools.md), including how a tool given
        in more than one place is merged.
      '';
    };
    packageSetupDeps = lib.mkOption {
      type = lib.types.unspecified;
      default = true;
      description = "Set to `false` to leave out custom-setup dependencies.  Not used with `builderVersion = 2`.";
    };
    enableDWARF = lib.mkOption {
      type = lib.types.unspecified;
      default = false;
      description = "Include debug info.  Not used with `builderVersion = 2`.";
    };
    crossPlatforms = lib.mkOption {
      type = lib.types.unspecified;
      default = projectConfig.crossPlatforms;
      defaultText = lib.literalMD "the project's `crossPlatforms`";
      example = lib.literalExpression "p: [ p.ghcjs p.mingwW64 ]";
      description = ''
        Cross-compilation platforms to add to the shell (their GHC and
        cabal wrappers, such as `javascript-unknown-ghcjs-cabal`).
      '';
    };

    # mkShell args
    inputsFrom = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
      description = ''
        Other shells whose `buildInputs` and `nativeBuildInputs` are
        included (see `mkShell`).
      '';
    };
    shellHook = lib.mkOption {
      type = lib.types.str;
      defaultText = lib.literalMD "sets `EM_CACHE` for ghcjs shells; otherwise empty";
      description = "Bash statements that are run when the shell starts.";
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
      description = "Passed to `mkDerivation` (via `mkShell`).";
    };
    nativeBuildInputs = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
      description = ''
        Passed to `mkDerivation` (via `mkShell`).  Non-Haskell tools for the
        shell go here.
      '';
    };
    passthru = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      default = {};
      description = "Passed to `mkDerivation` (via `mkShell`).";
    };
  };
}
