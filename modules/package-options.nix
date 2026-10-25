{ lib, haskellLib, ... }:
{
  options = {
    preUnpack = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
    };

    postUnpack = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    prePatch = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    postPatch = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    preConfigure = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    postConfigure = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    preBuild = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    postBuild = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    preCheck = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    # Wrapper for test executable run in checkPhase
    testWrapper = lib.mkOption {
      type = haskellLib.types.listOfFilteringNulls lib.types.str;
      default = [ ];
      description = "A command to run for executing tests in checkPhase, which takes the original test command as its arguments.";
      example = "echo";
    };

    postCheck = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    preInstall = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    postInstall = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    preHaddock = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    postHaddock = lib.mkOption {
      type = lib.types.nullOr haskellLib.types.uniqueStr;
      default = null;
    };

    hardeningDisable = lib.mkOption {
      type = haskellLib.types.listOfFilteringNulls lib.types.str;
      default = [ ];
    };

    ghcOptions = lib.mkOption {
      type = haskellLib.types.listOfFilteringNulls lib.types.str;
      default = [ ];
    };

    additional-prebuilt-depends = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = ''
        Per-component additional pre-built Haskell packages to make available
        as dependencies (adds their .conf files to this component's package DB).
        Merged with the project-wide prebuilt-depends from cabal-project.nix.
        Uses a different name from `prebuilt-depends` to avoid conflicting with
        the top-level option of the same name in component-driver.nix.
      '';
    };

    configureOptions = lib.mkOption {
      description = ''
        Arguments that correspond to cabal.project's
        `configure-options:` stanza.  Populated automatically from
        `--configure-option=X` entries in plan.json's configure-args
        (see `modules/install-plan/configure-args.nix`) and can also
        be set directly via `modules`.

        Unlike `configureFlags` (which flows through Setup.hs configure
        in the v1 builder), `configureOptions` round-trips through
        cabal.project for v2-style builds: v2 emits a per-package
        `configure-options:` block so cabal records the value in
        the UnitId hash and downstream consumers compute matching
        UnitIds.  For `build-type: Simple` packages cabal wraps each
        entry as `--configure-option=X` and Setup.hs silently drops
        it; for `build-type: Configure` packages cabal forwards it
        to the ./configure script.  v1 ignores this option entirely.
      '';
      type = haskellLib.types.listOfFilteringNulls lib.types.str;
      default = [ ];
    };

    extraLibDirs = lib.mkOption {
      description = ''
        Per-package `extra-lib-dirs:` paths.  Populated automatically
        from `--extra-lib-dirs=X` entries in plan.json's configure-args
        (see `modules/install-plan/configure-args.nix`); v2 round-trips
        these back through the slice's cabal.project so the unit-id
        cabal computes for the slice includes the same
        `pkgHashExtraLibDirs` inputs as plan-nix.  v1 reads
        `configureFlags` directly and ignores this option.
      '';
      type = haskellLib.types.listOfFilteringNulls lib.types.str;
      default = [ ];
    };

    extraIncludeDirs = lib.mkOption {
      description = ''
        Per-package `extra-include-dirs:` paths.  Populated automatically
        from `--extra-include-dirs=X` entries in plan.json's
        configure-args.  See `extraLibDirs` for the rationale.
      '';
      type = haskellLib.types.listOfFilteringNulls lib.types.str;
      default = [ ];
    };

    programOptions = lib.mkOption {
      description = ''
        Per-program option arguments that correspond to cabal.project's
        `<prog>-options:` stanzas (e.g. `c2hs-options:`,
        `hsc2hs-options:`).  Populated automatically from
        `--<prog>-option=X` entries in plan.json's configure-args
        (see `modules/install-plan/configure-args.nix`) and can also
        be set directly via `modules`.

        v2 emits each (prog, options) pair as a `package <pkg>` block
        with a `<prog>-options:` line so cabal-install threads the
        values through to the program's ProgramDb at build time —
        `configure-options:` would be silently dropped here because
        it only applies to `build-type: Configure` packages.  v1
        reads `configureFlags` directly (which retains the
        `--<prog>-option=...` form) and ignores this option.
      '';
      type = lib.types.attrsOf (haskellLib.types.listOfFilteringNulls lib.types.str);
      default = { };
    };

    contentAddressed = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Build content addressed derivation, requires Nix to have experimental feature
        `ca-derivations` enabled.
      '';
    };

    planned = lib.mkOption {
      description = "Set to true by `plan-to-nix` for any component that was included in the `plan.json` file.";
      # This is here so that (rather than in componentOptions) so it can be set project wide for stack projects
      type = lib.types.bool;
      default = false;
    };
  };
}
