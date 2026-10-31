{ lib, options, config, pkgs, ... }:
with lib;
with lib.types;
let
  # Whether the project defines `evalPackages` itself (deprecated) rather
  # than taking the default derived from `evalSystem`.  A default has
  # priority 1500 (`mkOptionDefault`); any definition beats it.
  evalPackagesIsSet = options.evalPackages.highestPrio < 1500;
in
{
  _file = "haskell.nix/modules/project-common.nix";
  options = {
    # Used by callCabalProjectToNix and callStackToNix
    name = mkOption {
      type = nullOr str;
      default = "haskell-project"; # TODO figure out why `config.src.name or null` breaks hix;
      description = "Optional name for better error messages";
    };
    src = mkOption {
      type = either path package;
    };
    crossPlatforms = mkOption {
      type = unspecified;
      default = _p: [ ];
    };
    # Default shell arguments
    shell = mkOption {
      type = submodule [
        (import ./shell.nix { projectConfig = config; })
        { _module.args = { inherit pkgs; inherit (pkgs.haskell-nix) haskellLib; }; }
      ];
      default = { };
      description = ''
        Arguments to use for the default shell `p.shell` (these are passed to p.shellFor).
        For instance to include `cabal` and `ghcjs` support use
          shell = { tools.cabal = {}; crossPlatforms = p: [ p.ghcjs ]; }
      '';
    };
    # Default flake arguments
    flake = mkOption {
      type = submodule [
        (import ./flake.nix { projectConfig = config; })
        { _module.args = { inherit (pkgs.haskell-nix) haskellLib; }; }
      ];
      default = { };
      description = ''
        Default arguments to use for the `p.flake`.
      '';
    };
    evalSystem = mkOption {
      type = str;
      # `evalSystem` is the single knob for the platform on which `cabal` /
      # `nix-tools` (plan-to-nix, IFD) run.  The `evalPackages` option below is
      # derived from it (via the memoised `haskell-nix.evalPackages`).
      #
      # The one exception is a project that still SETS `evalPackages`
      # (deprecated): then its system is the eval system.  Reading the
      # definition does not recurse -- only `evalPackages`' *default*
      # references `config.evalSystem`, and a definition replaces it.
      default =
        if evalPackagesIsSet
        then config.evalPackages.stdenv.hostPlatform.system
        else pkgs.pkgsBuildBuild.stdenv.hostPlatform.system;
      description = ''
        Specifies the system on which `cabal` and `nix-tools` should run.
        If not specified the `pkgsBuildBuild` system will be used.
        If there are no builders for the `pkgsBuildBuild` system
        specifying a system for which there are builders will
        allow the evaluation of the haskell project to work.
      '';
    };
    evalPackages = mkOption {
      type = attrs;
      # Derived (read-only) from `evalSystem` via the fixpoint-memoised
      # `haskell-nix.evalPackages` attrset (overlays/haskell.nix) so every
      # project sharing an `evalSystem` reuses ONE nixpkgs instance (and its
      # dummy-ghc / configured-src / nix-tools artifacts) instead of importing
      # a fresh one per project.  Select the eval platform with `evalSystem`.
      #
      # Setting it is deprecated (select the eval platform with `evalSystem`)
      # but still works for now, with a warning: the definition is used as
      # given, and `evalSystem` follows it.  The default is cycle-free
      # because `evalSystem` only reads `evalPackages` when it is set.
      default = pkgs.haskell-nix.evalPackages.${config.evalSystem};
      apply = v:
        if evalPackagesIsSet
        then lib.warn
          ("haskell.nix project option `evalPackages` is deprecated; set "
           + "`evalSystem = \"${v.stdenv.hostPlatform.system}\";` instead.")
          v
        else v;
      description = ''
        Packages used to run `cabal` and `nix-tools`, derived from
        `evalSystem` via the memoised `haskell-nix.evalPackages` attrset.
        Defaults to `pkgs.pkgsBuildBuild` when `evalSystem` matches the
        `pkgsBuildBuild` system (the common case), otherwise a shared
        nixpkgs imported for `evalSystem` from the same path and overlays.
        Select the eval platform with `evalSystem` rather than setting this
        directly; setting it is deprecated and gives a warning.
      '';
    };
    evalSrc = mkOption {
      type = either path package;
      default = config.src;
      description = ''
        Allows a different version of the src to be used at eval time.
        This is useful when building the source may require a build machine.
        To avoid an eval time dependency on a build machine set `evalSrc`
        to either:
          * A version of the source built using `evalPackages`
          * A version of the source that does not require building
      '';
    };
    hsPkgs = lib.mkOption {
      type = lib.types.unspecified;
    };
    # Used by stack and cabal projects via
    # - ./lib/call-cabal-project-to-nix.nix
    # - ./lib/call-stack-to-nix.nix
    ignorePackageYaml = mkOption {
      type = bool;
      default = false;
      description = ''
        If set, prevents nix-tools from attempting to load package.yaml even if it is present.
      '';
    };
    builderVersion = mkOption {
      type = int;
      default = 1;
      description = ''
        Selects which component builder is used for per-component derivations.
          * `1` (default) — the Setup.hs-based builder (comp-builder.nix).
          * `2` — the cabal v2-build-based slicing builder
            (comp-v2-builder.nix).
        This is project-wide.  Set it on the project module to switch
        builders; there is no per-component opt-in.
      '';
    };
    v2LocalPackageSlices = mkOption {
      type = bool;
      default = false;
      description = ''
        Build v2 slices for `style: "local"` plan units in cabal
        `packages:` mode instead of `extra-packages:` mode, so each
        slice's cabal elaborates — and REGISTERS — the same
        deterministic local unit id the project plan records
        (`base-4.22.0.0`, `rts-1.0.3-threaded-nodebug`, ...), and the
        slice/plan unit-id equality check is enforced for them.

        Set by the stable-haskell stage2 boot-library project: its
        slices' registered ids become the compiler's global package db,
        which consumer projects' plan-time dummy `ghc-pkg dump` must be
        able to predict (an `extra-packages:` slice registers an
        unpredictable hashed id instead).  Only meaningful with
        `builderVersion = 2`.
      '';
    };
    v2LocalPackageSliceNames = mkOption {
      type = listOf str;
      default = [];
      description = ''
        Package names whose LIBRARY slices are built in cabal `packages:`
        mode, as `v2LocalPackageSlices` does for every local unit, but
        without that option's other project-wide effects (the solver's
        view of the compiler's global db).  Set by the stable-haskell
        boot injection for `ghc`, whose unit id GHC itself hard-codes.
        Only meaningful with `builderVersion = 2`.
      '';
    };
    silenceOrgMoveWarning = mkOption {
      type = bool;
      default = false;
      description = ''
        Hide the warning shown when the project's flake.lock, niv or npins
        pins still reference haskell.nix (or hackage.nix / stackage.nix)
        under its old GitHub owner.
      '';
    };
    useLocalGhcLib = mkOption {
      type = bool;
      default = false;
      description = ''
        Expose the GHC compiler tree (configured-src + generated, the
        `compiler/` subdir thereof) to the planner as a regular
        reinstallable package source.  Use this when the project
        depends on / constrains the `ghc` package — e.g.
        `ghc-lib-reinstallable`.

        The project-level wiring differs by builder:
          * Cabal projects (see `modules/cabal-project.nix`) inject a
            `source-repository-package` block into `cabalProjectLocal`
            so cabal hashes the wrapped repo's content into
            `pkg-src-sha256`.  Both plan-to-nix and the v2 slice see
            the same repo, so UnitIds align.
          * Stack projects (see `modules/stack-project.nix`) re-add
            the post-plan `packages.ghc.src` override that
            `modules/configuration-nix.nix` used to apply
            unconditionally — stack only supports the v1 builder for
            now, so the post-plan override is harmless (v1 doesn't
            enforce UnitId alignment).
      '';
    };
    injectStableHaskellBootPackages = mkOption {
      type = nullOr bool;
      default = null;
      description = ''
        Inject the stable-haskell GHC's boot package sources
        (source-repository-package on the configured GHC tree, exact
        version pins for the hackage-resolved boot deps, and the
        stage3-style project configuration) into the project's
        cabal.project, so cabal plans and builds rts, base, … from
        source alongside the project's own packages.

        `null` (the default) auto-detects: the injection is applied
        exactly when the selected compiler is a stable-haskell
        `-target` cross wrapper (`passthru.emptyGlobalPackageDb`),
        whose global package db ships no boot libraries.  See
        `modules/cabal-project.nix` for the wiring.
      '';
    };
  };
}
