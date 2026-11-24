{ lib, haskellLib, ... }:

let
  inherit (lib) types;
  inherit (haskellLib.types) listOfFilteringNulls;

in
{
  imports = [
    ./component-options.nix
    ./package-options.nix
  ];

  options = {
    plugins = lib.mkOption {
      description = ''
        GHC plugins for the component, loaded through the `GHC_PLUGINS`
        environment variable of the component's ghc wrapper (for its shell, not
        its build).  Each has the plugin's `library` component, the `moduleName`
        of the plugin and its `args`.  Not used by `builderVersion = 2`.
      '';
      type = types.listOf (types.submodule {
        options = {
          library = lib.mkOption {
            description = "The library component (from `hsPkgs`) that provides the plugin.";
            type = types.unspecified;
          };

          moduleName = lib.mkOption {
            description = "The module that exports the plugin.";
            type = types.str;
          };

          args = lib.mkOption {
            description = "Arguments passed to the plugin.";
            type = types.listOf types.str;
            default = [ ];
          };
        };
      });

      default = [ ];
    };

    depends = lib.mkOption {
      description = ''
        The Haskell libraries the component depends on (`build-depends`), from
        the generated package expression.
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    pre-existing = lib.mkOption {
      description = ''
        Dependencies that come with the compiler (`pre-existing` units in
        `plan.json`) rather than from `hsPkgs`, by name.
      '';
      type = types.listOf types.str;
      default = [ ];
    };

    libs = lib.mkOption {
      description = ''
        System libraries the component links against (`extra-libraries`,
        mapped to nixpkgs packages).
      '';
      type = listOfFilteringNulls (types.either (types.nullOr types.package) (listOfFilteringNulls types.package));
      default = [ ];
    };

    frameworks = lib.mkOption {
      description = "macOS frameworks the component uses (`frameworks:`), as packages.";
      type = listOfFilteringNulls (types.nullOr types.package);
      default = [ ];
    };

    pkgconfig = lib.mkOption {
      description = ''
        The packages providing the component's `pkgconfig-depends` (one list
        of alternatives per dependency).
      '';
      type = types.listOf (listOfFilteringNulls types.package);
      default = [ ];
    };

    build-tools = lib.mkOption {
      description = ''
        Executables the component needs at build time (`build-tool-depends`
        and `build-tools`), as derivations.
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    modules = lib.mkOption {
      description = "The component's modules, from the `.cabal` file.";
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    asmSources = lib.mkOption {
      description = ''
        The component's `asm-sources`.  Used to work out the component's
        source files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    cmmSources = lib.mkOption {
      description = ''
        The component's `cmm-sources`.  Used to work out the component's
        source files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    cSources = lib.mkOption {
      description = ''
        The component's `c-sources`.  Used to work out the component's
        source files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    cxxSources = lib.mkOption {
      description = ''
        The component's `cxx-sources`.  Used to work out the component's
        source files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    jsSources = lib.mkOption {
      description = ''
        The component's `js-sources`.  Used to work out the component's
        source files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    hsSourceDirs = lib.mkOption {
      description = ''
        The component's `hs-source-dirs`.  Used to work out the component's
        source files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ "." ];
    };

    includeDirs = lib.mkOption {
      description = ''
        The component's `include-dirs`.  Used to work out the component's
        source files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    includes = lib.mkOption {
      description = "The component's `includes` (header files).";
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    mainPath = lib.mkOption {
      description = ''
        The component's `main-is`.  Used to work out the component's source
        files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    extraSrcFiles = lib.mkOption {
      description = ''
        The component's extra source files.  Used to work out the component's
        source files (with `builderVersion = 1`).
      '';
      type = listOfFilteringNulls types.unspecified;
      default = [ ];
    };

    platforms = lib.mkOption {
      description = ''
        The platforms the component can be built for, or `null` for all of
        them: the component derivation's `meta.platforms`.
      '';
      type = types.nullOr (listOfFilteringNulls types.unspecified);
      default = null;
    };
  };
}
