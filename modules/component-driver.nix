{ config, options, pkgs, lib, haskellLib, buildModules, ... }:
let
  builder = haskellLib.weakCallPackage pkgs ../builder {
    inherit haskellLib;
    ghc = config.ghc.package;
    compiler-nix-name = config.compiler.nix-name;
    inherit (config) nonReinstallablePkgs hsPkgs compiler evalPackages builderVersion crossTemplateHaskellSupport v2LocalPackageSlices v2LocalPackageSliceNames cabalProjectLocal withBuildCompiler;
  };

  # Packages listed in `nonReinstallablePkgs` are forced to the copy shipped
  # with the compiler (see the `genAttrs ... (_: null)` shadow in `config.hsPkgs`
  # below).  If the project's plan pins such a package to a *different* version
  # (via a local package, source-repository-package or extra-hackage) that
  # override is silently discarded and the build later fails with an opaque
  # `installed package ... is broken due to missing package <pkg>-<ver>` error.
  # Warn about that here rather than leaving the user to debug the broken
  # package-db (see #1657).  The detection lives in `haskellLib` (and is unit
  # tested); it only considers `nonReinstallablePkgs`, and only fires when the
  # planned version differs from the compiler-shipped one, so a normal project
  # (planned version == shipped version) never triggers this.
  shadowedNonReinstallable = haskellLib.shadowedNonReinstallablePkgs {
    inherit (config) nonReinstallablePkgs;
    packages = config.packages;
    compilerPackages = config.compiler.packages;
  };

  warnShadowedNonReinstallable = value: lib.foldr (name: acc:
    lib.warn ''
      haskell.nix: package '${name}' is listed in `nonReinstallablePkgs`, but this
      project pins it to version ${config.packages.${name}.package.identifier.version} (the compiler ships ${config.compiler.packages.${name}}).
      The pinned version will be ignored and the compiler's copy used instead, which
      usually surfaces later as an opaque
        `installed package ... is broken due to missing package ${name}-...`
      error.  To use your version, set `nonReinstallablePkgs` in a project module to an
      explicit list that omits '${name}'.  The option replaces rather than merges (the
      last definition wins), so a plain assignment is enough — but do not derive the
      new list from `config.nonReinstallablePkgs`, that is self-referential and will
      loop.${lib.optionalString (lib.elem name config.bootPkgs) ''
          '${name}' is also in `bootPkgs`, which shadows it the same way, so
        set `bootPkgs` using `lib.mkForce` and an explicit list that omits it too.''}  Otherwise drop the
      override to keep using the compiler's copy.'' acc)
    value shadowedNonReinstallable;

in

{
  # Selects which component builder produces the primary derivation
  # (1 = Setup.hs / comp-builder, 2 = cabal v2-build / comp-v2-builder).
  # Propagated from the project-level `builderVersion`.
  options.builderVersion = lib.mkOption {
    type = lib.types.int;
    default = 1;
  };
  # Propagated from the project-level `crossTemplateHaskellSupport`.
  # When false, the v2 cabal-slice builder uses the unwrapped ghc
  # for all slices in this project — needed for projects that
  # the wrapper itself depends on (iserv-proxy).
  options.crossTemplateHaskellSupport = lib.mkOption {
    type = lib.types.bool;
    default = true;
  };
  # Propagated from the project-level `withBuildCompiler`: the project
  # is planned as a two-stage build (the fork's `--with-build-compiler`
  # / `--with-build-hc-pkg`).  The v2 shell needs to know so it can put
  # the matching `with-build-compiler:` / `with-build-hc-pkg:` fields in
  # the `cabal.project.local` it writes -- otherwise a `cabal build` in
  # the shell has no build-stage compiler and resolves that stage out of
  # hackage instead of the native compiler's installed packages.
  options.withBuildCompiler = lib.mkOption {
    type = lib.types.bool;
    default = false;
  };
  # Propagated from the project-level `v2LocalPackageSlices`: build v2
  # slices for `style: "local"` plan units in cabal `packages:` mode so
  # each slice registers the plan's deterministic local unit id (see
  # modules/project-common.nix and builder/comp-v2-builder.nix).
  options.v2LocalPackageSlices = lib.mkOption {
    type = lib.types.bool;
    default = false;
  };
  # Propagated from the project-level `v2LocalPackageSliceNames`: the same
  # local-`packages:` slicing, for the named packages only.
  options.v2LocalPackageSliceNames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
  };
  # Project-level `cabalProjectLocal`, threaded into pkg-set's
  # module config so the v2 shell can write it out as a
  # `cabal.project.local` (or `cabal.project.<prefix>local` for
  # cross) at shell startup.  Set in `overlays/haskell.nix` by
  # inheriting from the project module's `config.cabalProjectLocal`.
  options.cabalProjectLocal = lib.mkOption {
    type = lib.types.nullOr lib.types.lines;
    default = null;
  };
  # Project-level `cabalProject` (the cabal.project text, read from
  # the project src when not set explicitly), threaded like
  # `cabalProjectLocal` above.  Only consumed (together with
  # `cabalProjectLocal`) by `builder/v2-project-globals.nix` to tell a
  # project-wide `documentation: True` apart from a plain
  # `ghc-options: -haddock`; null means "text unknown" there, not
  # "empty project".
  options.cabalProject = lib.mkOption {
    type = lib.types.nullOr lib.types.lines;
    default = null;
  };
  # Packages in that are `pre-existing` in the cabal plan
  options.preExistingPkgs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
  };
  # This has a slightly modified option type. We will *overwrite* any previous
  # setting of nonRelocatablePkgs, instead of merging them.  Otherwise you
  # have no chance of removing packages retroactively.  We might improve this
  # by implementing a logic that would allow +xxx to be added, -xxx to be removed
  # and if it's not a list of -/+ prefixed strings, be assumed to be overwriting.
  # This seems ugly.
  options.nonReinstallablePkgs = lib.mkOption {
    type = (lib.types.listOf lib.types.str) // {
      merge = _loc: defs: lib.last (lib.getValues defs);
    };
  };

  options.reinstallableLibGhc = lib.mkOption {
    type = lib.types.bool;
    default = !pkgs.stdenv.hostPlatform.isGhcjs;
    description = "Is lib:ghc reinstallable?";
  };
  options.setup-depends = lib.mkOption {
    type = lib.types.listOf lib.types.unspecified;
    default = [];
    description = "pkgs to globally provide to Setup.hs builds";
  };
  options.prebuilt-depends = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [];
    description = ''
      pre-built (perhaps proprietary) Haskell packages to make available as dependencies

      See Note [prebuilt dependencies] for more details
    '';
  };

  # Dependencies (with reinstallable-lib:ghc)
  #
  #              .--------.           .------------------.
  #              | pretty | < ------- | template-haskell |
  #              '--------'           '------------------'
  #                   v                          |
  #              .---------.     .-------.       |
  #              | deepseq | - > | array |       |
  #              '---------'     '-------'       v
  #                    v            v         .-------------.
  # .----------.  .----------.  .------.   .- | ghc-boot-th |
  # | ghc-heap |  | ghc-prim |  | base |< -'  '-------------'
  # '----------'  '----------'  '------'  .----------------.
  #       |          v           |  |     | integer-simple |
  #       |       .-----.        |  '-- > |-------or-------|
  #       '---- > | rts | < -----'        | integer-gmp    |
  #               '-----'                 '----------------'
  #
  # without reinstallable-lib:ghc, this is significantly larger.

  config.nonReinstallablePkgs = if config.preExistingPkgs != []
   then ["rts"] ++ config.preExistingPkgs
    # GHC 9.14+ rts.conf depends on libffi-clib at the ghc-pkg level, but
    # cabal doesn't include it in preExistingPkgs (it's a C library wrapper
    # that cabal doesn't track as a Haskell dependency).  Adding it here
    # ensures make-config-files.nix copies its .conf from the compiler's
    # package DB so the per-component DB is consistent.  Harmless for
    # compilers that don't have libffi-clib (the find glob matches nothing).
    ++ lib.optionals (builtins.compareVersions config.compiler.version "9.14" >= 0) [
      "libffi-clib"]
    ++ lib.optionals (builtins.compareVersions config.compiler.version "8.11" < 0 && pkgs.stdenv.hostPlatform.isGhcjs) [
      "ghcjs-prim" "ghcjs-th"]
   else
    [ "rts" "ghc-prim" "integer-gmp" "integer-simple" "base"
      "deepseq" "array" "ghc-boot-th" "pretty" "template-haskell"
      # ghcjs custom packages
      "ghcjs-prim" "ghcjs-th"
    ]
    ++ lib.optionals (builtins.compareVersions config.compiler.version "8.11" >= 0) [
      "ghc-bignum"]
    ++ lib.optionals (builtins.compareVersions config.compiler.version "9.1" >= 0) [
      "system-cxx-std-lib"]
    ++ lib.optionals (builtins.compareVersions config.compiler.version "9.9" >= 0) [
      "ghc-internal"]
    ++ lib.optionals (!config.reinstallableLibGhc) ([
      "ghc-boot"
      "ghc" "Cabal" "Win32" "array" "binary" "bytestring" "containers"
      "directory" "filepath" "ghc-boot" "ghc-compact" "ghc-prim"
      # "ghci" "haskeline"
      "hpc"
      "mtl" "parsec" "process" "text" "time" "transformers"
      "unix" "xhtml" "terminfo"
    ]
    ++ lib.optionals (builtins.compareVersions config.compiler.version "8.11" >= 0) [
      # stm and exceptions are needed by the GHC package since 9.0.1
      "stm" "exceptions"]
    ++ lib.optionals (builtins.compareVersions config.compiler.version "9.8.1" >= 0) [
      "semaphore-compat"]
    ++ lib.optionals (builtins.compareVersions config.compiler.version "9.9" >= 0) [
      "os-string"]
    )
    ++ lib.optionals (!config.reinstallableLibGhc || __elem config.compiler.nix-name ["ghc865"]) [
      "ghc-heap"
    ];

  options.bootPkgs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
  };

  config.bootPkgs =  [
      "rts" "ghc-boot-th"
      "ghcjs-prim"
   ] ++ lib.optional (!config.reinstallableLibGhc) "ghc"
    ++ lib.optionals (
      !__elem config.compiler.nix-name ["ghc865" "ghc881" "ghc882" "ghc883" "ghc884" "ghc8101" "ghc8102" "ghc8103" "ghc8104" "ghc8105" "ghc8106" "ghc8107"]) [
      "ghc-bignum" ]
    ++ lib.optionals (
      !__elem config.compiler.nix-name ["ghc865" "ghc881" "ghc882" "ghc883" "ghc884" "ghc8101" "ghc8102" "ghc8103" "ghc8104" "ghc8105" "ghc8106" "ghc8107" "ghc901" "ghc902"]) [
      "system-cxx-std-lib" ];

  options.hsPkgs = lib.mkOption {
    type = lib.types.unspecified;
  };

  config.hsPkgs = warnShadowedNonReinstallable (
    { inherit (builder) shellFor makeConfigFiles ghcWithPackages ghcWithHoogle;
      buildPackages = buildModules.config.hsPkgs; # TODO perhaps remove this
      pkgsBuildBuild = buildModules.config.hsPkgs;
    } //
    lib.mapAttrs
      # `hasPackageDefinition` (see modules/package.nix) separates a real
      # package from a `packages.<pkg-name>` record that exists only to carry
      # by-name overrides onto the plan's UnitID-keyed packages.  Callers
      # already null-check every by-name lookup -- e.g. `lookupDepPkg` in
      # builder/comp-v2-builder.nix, whose own comment notes that a
      # multi-sublib library's bare `hsPkgs.happy-lib` is "present but null"
      # -- so null is what they expect here.  Without it they get a record
      # that throws on first use, and the throw names an option
      # (`packages.alex.package.identifier.version'), not the lookup.
      (name: pkg: if !(options.packages.${name}.isDefined or true) || pkg == null || !(pkg.hasPackageDefinition or true) then null else builder.build-package config pkg)
      (config.packages // lib.genAttrs (config.nonReinstallablePkgs ++ config.bootPkgs) (_: null)));
}
