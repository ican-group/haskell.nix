{ lib, config, pkgs, haskellLib, ... }:
with lib;
with types;
let readIfExists = src: fileName:
      # Using origSrcSubDir bypasses any cleanSourceWith.
      # `lookForCabalProject` allows us to avoid looking in source from hackage
      # for cabal.project files.  It is set in `modules/hackage-project.nix`.
      let origSrcDir = src.origSrcSubDir or src;
      in
        if (src.lookForCabalProject or true) && builtins.elem ((__readDir origSrcDir)."${fileName}" or "") ["regular" "symlink"]
          then __readFile (origSrcDir + "/${fileName}")
          else null;
in {
  _file = "haskell.nix/modules/cabal-project.nix";
  imports = [ ./replace-hackage-tarball-urls.nix ./stable-haskell-rts-comdat.nix ];
  options = {
    # Used by callCabalProjectToNix
    compiler-nix-name = mkOption {
      type = str;
      description = "The name of the ghc compiler to use eg. \"ghc884\"";
      # Map short version names to the latest GHC version.
      apply = name: pkgs.haskell-nix.resolve-compiler-name name;
    };
    compilerSelection = mkOption {
      type = unspecified;
      default = p: builtins.mapAttrs (_: x: x.evalWith.${config.evalSystem} or (x.override { evalSystem = config.evalSystem; })) p.haskell-nix.compiler;
      description = "Use GHC from pkgs.haskell instead of pkgs.haskell-nix";
    };
    index-state = mkOption {
      type = nullOr str;
      default = null;
      description = "Hackage index-state, eg. \"2019-10-10T00:00:00Z\"";
    };
    index-sha256 = mkOption {
      type = nullOr str;
      default = null;
      description = "The hash of the truncated hackage index-state";
    };
    plan-sha256 = mkOption {
      type = nullOr str;
      default = null;
      description = "The hash of the plan-to-nix output (makes the plan-to-nix step a fixed output derivation)";
    };
    materialized = mkOption {
      type = nullOr (either path package);
      default = null;
      description = "Location of a materialized copy of the nix files";
    };
    checkMaterialization = mkOption {
      type = nullOr bool;
      default = null;
      description = "If true the nix files will be generated used to check plan-sha256 and material";
    };
    cabalProjectFileName = mkOption {
      type = str;
      default = "cabal.project";
    };
    cabalProject = mkOption {
      type = nullOr lines;
      default = readIfExists config.evalSrc config.cabalProjectFileName;
    };
    # `cabalProjectLocal` / `cabalProjectFreeze` no longer
    # auto-load `cabal.project.local` / `cabal.project.freeze` from
    # the project source.  Projects that want that behaviour set
    # the option explicitly:
    #
    #   cabalProjectLocal = builtins.readFile ./cabal.project.local;
    #
    # Plain `lines` (not `nullOr lines`) so `lib.mkBefore` directives
    # from platform-conditional defaults below merge cleanly with
    # whatever the user passes.
    cabalProjectLocal = mkOption {
      type = lines;
      default = "";
    };
    cabalProjectFreeze = mkOption {
      type = lines;
      default = "";
    };
    ghc = mkOption {
      type = nullOr package;
      default = null;
      description = "Deprecated in favour of `compiler-nix-name`";
    };
    ghcOverride = mkOption {
      type = nullOr package;
      default = null;
      description = "Used when we need to set ghc explicitly during bootstrapping";
    };
    # The defaults for `nix-tools` and `cabal-install` are in `call-cabal-project-to-nix.nix`
    # to make sure it is not evaluated too strictly (which would lead to infinite recursion).
    nix-tools = mkOption {
      type = nullOr package;
      default = null;
      description = "nix-tools to use when converting the `plan.json` to nix";
    };
    configureArgs = mkOption {
      type = nullOr (separatedString " ");
      default = "";
      description = ''
        Extra arguments to pass to `cabal v2-configure`.
        `--enable-tests --enable-benchmarks` are included by default.
        If the tests and benchmarks are not needed and they
        cause the wrong plan to be chosen, then we can use
        `configureArgs = "--disable-tests --disable-benchmarks";`
      '';
    };
    sha256map = mkOption {
      type = nullOr (attrsOf (either str (attrsOf str)));
      # Default needed for haskell-language-server 1.10
      default."https://github.com/pepeiborra/ekg-json"."7a0af7a8fd38045fd15fb13445bdcc7085325460" = "sha256-fVwKxGgM0S4Kv/4egVAAiAjV7QB5PBqMVMCfsv7otIQ=";
      description = ''
        An alternative to adding `--sha256` comments into the
        cabal.project file:
          sha256map =
            { "https://github.com/jgm/pandoc-citeproc"."0.17"
              = "0dxx8cp2xndpw3jwiawch2dkrkp15mil7pyx7dvd810pwc22pm2q"; };
      '';
    };
    inputMap = mkOption {
      type = nullOr attrs;
      default = {};
      description = ''
        Specifies the contents of urls in the cabal.project file.
        The `.rev` attribute is checked against the `tag` for `source-repository-packages`.
        # FIXME is the following still relevant?
        For `revision` blocks the `inputMap.<url>` will be used and
        they `.tar.gz` for the `packages` used will also be looked up
        in the `inputMap`.
      '';
    };
    extra-hackage-tarballs = mkOption {
      type = nullOr attrs;
      default = {};
    };
    source-repo-override = mkOption {
      type = attrsOf (functionTo attrs);
      default = {};
    };
    supportHpack = mkOption {
      type = bool;
      default = false;
    };
    withBuildCompiler = mkOption {
      type = bool;
      default = false;
      description = ''
        Pass a *build*-platform dummy `ghc` + `ghc-pkg` to `make-install-plan`
        during plan-to-nix, via `--with-build-compiler` / `--with-build-hc-pkg`
        (the stable-haskell cabal fork's cross "stage" system,
        haskell/cabal#11179).

        The build dummy's `ghc --info` reports the build (native) platform and
        its `ghc-pkg dump --global` lists the build boot libraries (especially
        `ghc-internal`) as installed.  That satisfies a source project's
        `constraints: build:any.ghc-internal installed` and lets cabal resolve
        build-tool-depends (e.g. `hsc2hs`) in the build scope, reusing the
        installed build-stage `process`/`base` rather than rebuilding them —
        breaking cross build-tool cycles (e.g. the Windows
        `Win32 -> hsc2hs -> process -> Win32` cycle) without the full Hackage
        index.  Off by default; projects that don't set it get no
        `--with-build-compiler` (unchanged behaviour).
      '';
    };
    prepopulateHackageIndex = mkOption {
      type = bool;
      default = true;
      description = ''
        Whether to prepopulate the full Hackage index (~1.2 GB, truncated to the
        project's `index-state`) into the `CABAL_DIR` used for plan-to-nix.

        cabal parses this index at startup on every invocation — even with
        `active-repositories: :none` — so for projects that resolve nothing from
        Hackage (every dependency pinned as a local package or
        source-repository-package, e.g. via `replace-hackage-tarball-urls`), the
        full index is a large, needless cost (seconds natively, minutes under
        emulation).  Set this false for such projects to prepopulate an empty
        index instead, which cabal loads instantly.  Leave true (the default)
        for normal projects that resolve dependencies from Hackage.
      '';
    };

    usePatchedHsc2hs = mkOption {
      type = bool;
      default = true;
      description = ''
        Offer cabal's solver haskell.nix's patched hsc2hs as
        `hsc2hs-''${pkgs.haskell-nix.hsc2hs-patched-version}`, from a small
        package repository added to the project (`haskell-nix-hsc2hs`).
        It is stable-haskell's batch cross-compilation fork of hsc2hs with
        haskell.nix's fix to it (see overlays/hsc2hs.nix), which makes
        cross-compiled `.hsc` files much faster to process -- around 15x
        for the GHC JavaScript backend and 20x for wasm.

        It is only a candidate.  It is chosen when a plan needs hsc2hs as a
        build tool (`build-tool-depends` or the legacy `build-tools`) and
        the version satisfies the constraints on it; otherwise cabal picks
        another version as usual.  Packages that do not ask for hsc2hs keep
        using the compiler's.

        A project that sets `active-repositories` has to list
        `haskell-nix-hsc2hs` itself for the repository to be used.
      '';
    };

    # Used by mkCabalProjectPkgSet
    pkg-def-extras = mkOption {
      type = nullOr (listOf unspecified);
      default = [];
    };
    modules = mkOption {
      type = nullOr (listOf unspecified);
      default = [];
    };
    extra-hackages = mkOption {
      type = nullOr (listOf unspecified);
      default = [];
    };
    prebuilt-depends = mkOption {
      type = listOf package;
      default = [];
      description = ''
        pre-built (perhaps proprietary) Haskell packages to make available as dependencies

        See Note [prebuilt dependencies] for more details
      '';
    };
  };
  config = lib.mkMerge [
    # The patched hsc2hs (see `usePatchedHsc2hs` and overlays/hsc2hs.nix).
    # The repository is a store path, as head.hackage's is in
    # test/head-hackage.nix: plan.json records it as the package's
    # `repo.uri`, which lib/load-cabal-plan.nix fetches the tarball from.
    # Unsigned, hence no root keys and a zero threshold.
    (lib.mkIf config.usePatchedHsc2hs {
      cabalProjectLocal = lib.mkBefore ''
        repository haskell-nix-hsc2hs
          url: file:${config.evalPackages.haskell-nix.hsc2hs-patched-repo}
          secure: True
          root-keys:
          key-threshold: 0
      '';
    })
    # Musl host: every executable should be statically linked.
    # comp-builder achieves this at build time by adding
    # `--ghc-option=-optl=-static` to the per-component
    # configureFlags, which doesn't reach plan-to-nix — plan.json
    # keeps `--disable-executable-static` and the misalignment is
    # ignored.  Surface the toggle in cabal.project so plan-to-nix
    # records `--enable-executable-static` for every unit; the
    # actual build is unchanged.  Set inside `package *` because
    # cabal only propagates `executable-static` per-component when
    # the directive lives in that block.
    (lib.mkIf pkgs.stdenv.hostPlatform.isMusl {
      cabalProjectLocal = lib.mkBefore ''
        package *
          executable-static: True
      '';
    })
    # x86_64-darwin host: enable `library-for-ghci` so cabal emits a
    # merged `HS<unit>.o` per unit alongside the `.dylib`.
    # comp-builder already passes `--enable-library-for-ghci` for
    # !ghcjs / !wasm / !android (which on darwin is always),
    # so this matches the on-disk artefacts to what plan-to-nix
    # records.  Helps TH-eval via `ghc-iserv-dyn` find a merged
    # `.o` to load directly, bypassing dyld dylib weirdness under
    # Rosetta (Hydra builds x86_64-darwin on aarch64-darwin
    # hardware).  Scoped to x86_64 — aarch64-darwin runs natively.
    (lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin
            && pkgs.stdenv.hostPlatform.isx86_64) {
      cabalProjectLocal = lib.mkBefore ''
        package *
          library-for-ghci: True
      '';
    })
    # Android host: link every exe statically so qemu-user can run
    # it on the build host.  A dynamic Android binary references
    # `/system/bin/linker[64]` at runtime; qemu-arm fails with
    # `Could not open '/system/bin/linker': No such file or
    # directory` because the build host doesn't ship one.
    # `lib/check.nix` papers over this by re-overriding the test
    # exe with `setupBuildFlags = ["--ghc-option=-optl-static"]`;
    # surfacing the same flags at the project level here keeps
    # plan-to-nix's recorded configure-args matching the artefact.
    # `-optl-static` makes the exe self-contained, `-optl-ldl`
    # pulls in libdl that GHC's RTS still references even under
    # static linking, and on aarch32 `-optl-no-pie` disables PIE
    # so the static link doesn't trip `dynamic STT_GNU_IFUNC`
    # relocation errors.
    (lib.mkIf pkgs.stdenv.hostPlatform.isAndroid {
      cabalProjectLocal = lib.mkBefore ''
        package *
          ghc-options: -optl-static -optl-ldl${
            lib.optionalString pkgs.stdenv.hostPlatform.isAarch32 " -optl-no-pie"
          }
      '';
    })
    # wasm 9.12+: real wasm-ghc reports `target RTS linker only
    # supports shared libraries: YES` and no `Support shared
    # libraries` field at all.  cabal interprets the absence of
    # `Support shared libraries` as "no shared support" and
    # records `--disable-shared` in plan-nix, but TH-eval / dyld
    # on wasm 9.12+ requires `.so` files for every transitively
    # reachable lib (the RTS linker only loads shared libs).
    # Forcing `shared: True` at the project level keeps plan-nix's
    # recorded UnitIds matching what a downstream cabal v2-build
    # against the real wasm GHC would compute.
    #
    # Not for stable-haskell compilers.  Their plans are two-stage, and
    # `package *` reaches the Build stage too, where the native compiler
    # has no dyn way: the Build-stage build tools then need `.dyn_hi`
    # files the Build-stage boot libraries don't have.  The fork's
    # cabal (nix-tools-sh, and the v2 builder's cabal) instead defaults
    # `shared` on per stage from the stage compiler's `target RTS linker
    # only supports shared libraries`, so the wasm Host gets shared
    # libraries without any project configuration.
    (lib.mkIf (
      let ghc = (config.compilerSelection pkgs.buildPackages).${config.compiler-nix-name};
      in pkgs.stdenv.hostPlatform.isWasm
         && builtins.compareVersions ghc.version "9.12" >= 0
         && !(ghc.isStableHaskell or false)
    ) {
      cabalProjectLocal = lib.mkBefore ''
        package *
          shared: True
      '';
    })
    # Not when the stable-haskell boot-package injection below is active: it
    # already makes `compiler` (lib:ghc), `utils/genprimopcode` and
    # `utils/deriveConstants` LOCAL `packages:` of the project.  Exposing the
    # same tree again as source-repository-packages gives plan.json units
    # with `style: local` but `pkg-src: source-repo`, a shape
    # lib/load-cabal-plan.nix assigns no `src` -- so the package fell back to
    # `modules/package.nix`'s `mirror://hackage/ghc-9.14.tar.gz` (build
    # 2203736, tests.ghc-lib-reinstallable-cabal).
    (lib.mkIf (config.useLocalGhcLib && !(
      let shGhc = (config.compilerSelection pkgs.buildPackages).${config.compiler-nix-name};
      in if config.injectStableHaskellBootPackages != null
           then config.injectStableHaskellBootPackages
           else shGhc.emptyGlobalPackageDb or false)) (
    let
      ghc = (config.compilerSelection pkgs.buildPackages).${config.compiler-nix-name};
      ghcFullSrc = pkgs.buildPackages.symlinkJoin {
        name = ghc.name + "-full-src";
        # `generated-light` builds hadrian's generated sources (primops,
        # deriveConstants, config) without compiling all of GHC, so realising
        # this source-repository-package during plan-to-nix (needed for the v2
        # UnitId) does not force a full compiler build via IFD.
        #
        # A cabalProject-built compiler (ghc914-sh) has NEITHER output -- it
        # generates those sources during its own build -- and `x or y` still
        # evaluates `y`, so an unguarded selection aborts evaluation rather
        # than falling through.  Contribute the tree only when there is one.
        paths = [ ghc.configured-src ]
          ++ lib.optional (ghc ? generated-light || ghc ? generated)
               (ghc.generated-light or ghc.generated);
      };
      ghcSrc = ghcFullSrc + "/compiler";
      ghcMinRepoUrl = "file://${ghcSrc}";
      # `lib:ghc`'s `build-tool-depends` (when the `build-tool-depends`
      # flag is on) names `genprimopcode` and `deriveConstants`, which
      # live in the GHC source tree (not on hackage).  Expose them as
      # reinstallable source-repository-packages too, so cabal can
      # satisfy those exe build-tool goals from the same tree.
      genprimopcodeSrc = ghcFullSrc + "/utils/genprimopcode";
      deriveConstantsSrc = ghcFullSrc + "/utils/deriveConstants";
      genprimopcodeUrl = "file://${genprimopcodeSrc}";
      deriveConstantsUrl = "file://${deriveConstantsSrc}";
    in {
      # When `useLocalGhcLib = true`, expose the GHC compiler tree
      # (configured + generated) as a `source-repository-package` in
      # the project's cabal.project (via cabalProjectLocal), pointing
      # at the `compiler/` subdir of `(configured-src + generated)`.
      #
      # `inputMap` short-circuits haskell.nix's source-repo fetch so
      # we don't go through `builtins.fetchGit` (which fails in pure
      # eval mode without a sha256).  haskell.nix then re-wraps
      # `inputMap.<url>` in its own minimal git repo at
      # `lib/call-cabal-project-to-nix.nix` -- the wrapper produces
      # deterministic content (same rsync + git init + commit), so
      # cabal's `pkg-src-sha256` is stable across evaluations.
      #
      # Why source-repository-package and not `packages:`:
      #   * `packages:` makes cabal treat the package as *inplace* --
      #     v2-build registers `<pkg>-<ver>-inplace` in dist-newstyle
      #     but doesn't copy anything to the cabal-store layout.
      #   * source-repository-package takes the regular reinstallable
      #     path: cabal hashes the wrapped repo's content into
      #     `pkg-src-sha256`, builds the package, and installs it
      #     like any other reinstallable dep.
      #
      # `allow-boot-library-installs: True` is needed at project
      # level so plan-to-nix's cabal-install doesn't reject ghc's
      # source instance.
      cabalProjectLocal = lib.mkBefore ''
        -- Added by `useLocalGhcLib = true`: expose the GHC compiler
        -- tree (configured + generated) as a source-repository-package
        -- so cabal treats `lib:ghc` like a regular reinstallable
        -- package (installed to the cabal-store, not inplace).
        source-repository-package
          type: git
          location: ${ghcMinRepoUrl}
          subdir: .
          tag: minimal
        source-repository-package
          type: git
          location: ${genprimopcodeUrl}
          subdir: .
          tag: minimal
        source-repository-package
          type: git
          location: ${deriveConstantsUrl}
          subdir: .
          tag: minimal
        allow-boot-library-installs: True
      '';
      # Key by `<url>/<ref>` (the first lookup form in
      # `lib/call-cabal-project-to-nix.nix:fetchPackageRepo`) so we
      # short-circuit the `.rev` check that the bare-`<url>` form
      # applies — the local source isn't a git derivation and has
      # no `.rev` attribute.  Strip string context from the key
      # because nix forbids attribute names that carry references
      # to store paths.
      inputMap = {
        ${builtins.unsafeDiscardStringContext "${ghcMinRepoUrl}/minimal"} = ghcSrc;
        ${builtins.unsafeDiscardStringContext "${genprimopcodeUrl}/minimal"} = genprimopcodeSrc;
        ${builtins.unsafeDiscardStringContext "${deriveConstantsUrl}/minimal"} = deriveConstantsSrc;
      };
    }
    ))
    # Projects using a stable-haskell compiler (`passthru.isStableHaskell`,
    # e.g. ghc914-sh) default to the v2 (cabal v2-build slicing) builder.
    # v1 cannot work with the fork's boot packages: its
    # `cabal-install-plan-to-nix` requires `Cabal ^>=3.16` while the boot
    # Cabal is 3.17.x, and the boot libs register `-inplace` unit-ids
    # that v1's Setup.hs-based machinery never learns about.  `mkDefault`
    # so a project can still opt out explicitly; empty-global-db
    # (two-stage `-target` cross) projects hard-set 2 below regardless.
    (lib.mkIf
      ((config.compilerSelection pkgs.buildPackages).${config.compiler-nix-name}.isStableHaskell or false)
      { builderVersion = lib.mkDefault 2; })
    # ...and, like every v2 project, plan with the stable-haskell nix-tools
    # bundle.  Its `make-install-plan` links the same cabal-install fork the
    # v2 builder (`haskell-nix.v2-cabal-install`) builds slices with, and
    # the two have to agree: a UnitId is a hash of cabal-install's own
    # rendering of a unit's build inputs, so a plan made by mainline cabal
    # 3.16 names UnitIds no 3.17-built slice reproduces, and a v2 slice of
    # any ordinary hackage package then fails its plan-nix check.  The fork
    # is also what understands the stable-haskell compilers' cross "stage"
    # system (--with-build-compiler, build:/host: constraints).
    #
    # v1 projects keep the mainline bundle (the default, in
    # lib/call-cabal-project-to-nix.nix): nothing in a v1 build reproduces a
    # cabal-install UnitId, and the fork's plan for a mainline single-stage
    # cross project does not line up with the native project's
    # (iserv-proxy's `network` -> `hsc2hs` build tool stops resolving).
    #
    # `mkDefault` so an explicit per-project `nix-tools` still wins, and
    # `mkIf` rather than an option `default` for the same reason
    # `builderVersion` above uses one -- the option default is forced too
    # eagerly by the module system and recurses.
    (lib.mkIf
      (config.builderVersion == 2
       || ((config.compilerSelection pkgs.buildPackages).${config.compiler-nix-name}.isStableHaskell or false))
      { nix-tools = lib.mkDefault config.evalPackages.haskell-nix.nix-tools-unchecked-sh; })
    # stable-haskell `-target` cross compilers (ghc914-sh for a cross
    # target) ship NO boot libraries: the compiler's target package db is
    # empty and the plan-time dummy `ghc-pkg dump` is empty too (see
    # `emptyGlobalPackageDb` in lib/call-cabal-project-to-nix.nix).  Every
    # project using such a compiler therefore builds the boot packages
    # (rts, base, …) from source as part of its own plan.  This block
    # injects the boot package sources and the project configuration the
    # stable-haskell GHC's own stage3 (cross) project uses.
    (let
      shGhc = (config.compilerSelection pkgs.buildPackages).${config.compiler-nix-name};
      shBootInject =
        if config.injectStableHaskellBootPackages != null
          then config.injectStableHaskellBootPackages
          else shGhc.emptyGlobalPackageDb or false;
    in lib.mkIf shBootInject (let
      # The configured GHC source tree.  The BUILD-platform tree is what
      # the `packages:` entries point at (same tree the compiler itself is
      # built from); the eval-platform copy is only read (below) for the
      # boot dep versions, so plan-time text stays eval-light.
      shSrc = shGhc.configured-src;
      # `shGhc` is already the compiler variant selected for this project's
      # `evalSystem` (via `compilerSelection` → `evalWith.${evalSystem}`), so its
      # plain `configured-src-eval` is the eval-platform tree for this project.
      shSrcEval = shGhc.configured-src-eval;
      # (name, version) pairs of the boot deps the stable-haskell stage2
      # project pins as direct hackage tarball URLs.  The same versions are
      # pinned here as exact version constraints, resolved from the
      # project's normal hackage index (the URL form would require
      # `replace-hackage-tarball-urls` on every user project).  Commented
      # URLs in the project file are skipped.
      shUrlBootPkgs = lib.concatMap (line:
          let m = builtins.match ".*(https://hackage[.]haskell[.]org/package/[^/]+/(.*)-([0-9][0-9.]*)[.]tar[.]gz).*" line;
          in lib.optional (m != null && builtins.match "[[:space:]]*--.*" line == null)
            { name = builtins.elemAt m 1; version = builtins.elemAt m 2; })
        (lib.splitString "\n" (builtins.readFile "${shSrcEval}/cabal.project.stage2.merged"));
      # In-tree boot packages, as subdirs of the configured tree.  Mirrors
      # the packages: stanza of the tree's cabal.project.stage3 (the cross
      # project): everything not resolvable from hackage.  utils/ghc-iserv
      # is included for the external TH interpreter; utils/genprimopcode
      # and utils/deriveConstants satisfy lib:ghc's build-tool-depends
      # (build-stage units, they run on the build machine).
      #
      # These are injected as LOCAL `packages:` entries (absolute store
      # paths), NOT as a source-repository-package: cabal hashes an SRP by
      # listing its package sources sdist-style, which fails on
      # ghc-internal's compiler-generated virtual modules
      # (GHC.Internal.Prim & co have no source files, and upstream
      # deliberately leaves them out of `autogen-modules` — see the
      # commented block in ghc-internal.cabal.in).  Local packages skip
      # that hashing and get `<pkg>-<ver>-inplace` unit ids — exactly the
      # arrangement the native ghc914-sh stage2 build (also all-local)
      # already exercises under the v2 builder.
      shSubdirs = [
        "rts-headers" "rts-fs" "rts"
        "compiler"
        "libraries/base"
        "libraries/ghc-bignum"
        "libraries/ghc-boot"
        "libraries/ghc-boot-th"
        "libraries/ghc-compact"
        "libraries/ghc-experimental"
        "libraries/ghc-heap"
        "libraries/ghc-internal"
        "libraries/ghc-platform"
        "libraries/ghc-prim"
        "libraries/ghci"
        "libraries/integer-gmp"
        "libraries/system-cxx-std-lib"
        "libraries/template-haskell"
        "utils/genprimopcode"
        "utils/deriveConstants"
      ]
      # utils/ghc-iserv builds the TARGET's external interpreter, and GHC runs
      # it on the BUILD machine (it resolves it as $topdir/../bin/ghc-iserv).
      # That only works when the build platform can execute target binaries --
      # true for musl64/static (same arch), false for e.g. android or windows,
      # where cross TH goes through iserv-proxy + an emulator instead.  Build it
      # only where it is usable: otherwise it is dead weight, and worse, GHC
      # would find it and fail with "Exec format error" rather than falling
      # back to the proxy.  The compiler assembly links it if and only if the
      # package set has it, so this one predicate governs both.
      ++ lib.optional (pkgs.stdenv.buildPlatform.canExecute tp) "utils/ghc-iserv";
      # Package names of the boot subdirs injected above; `compiler` builds
      # package `ghc`, everything else is named after its directory.
      bootPkgNames =
        map (d: let b = baseNameOf d; in if b == "compiler" then "ghc" else b) shSubdirs
        ++ lib.optional (tp.isWindows or false) "Win32";
      tp = pkgs.stdenv.hostPlatform;
      isWasm = tp.isWasm or false;
      # Where each injected boot subdir comes from: the configured tree,
      # except system-cxx-std-lib on Android.  Its .cabal names the C++
      # runtime for the interpreter as
      #   if os(windows) || os(linux)
      #     extra-libraries: stdc++
      # and to cabal the ghc914-sh Android target IS `os(linux)` (its plan
      # says `"os":"linux"`), so Android gets `stdc++` too.  That is wrong
      # twice over there: Android's C++ runtime is libc++ (bionic's
      # libstdc++ is only operator new/delete), and bionic ships it as a
      # `libstdc++.so`, which GHC's RTS linker prefers to an archive -- and
      # the statically linked Android `iserv-proxy-interpreter` cannot
      # dlopen anything, so every splice that pulls in system-cxx-std-lib
      # (th-dlls, via double-conversion) died with
      #   libdl.a is a stub --- use libdl.so instead
      # Keep the Windows half, which is what it was added for (a wine hang
      # on `__cxa_guard_acquire`), and name nothing on Android, as before.
      shSubdirSrc = d:
        if d == "libraries/system-cxx-std-lib" && (tp.isAndroid or false)
          then androidCxxStdLibSrc
          else "${shSrc}/${d}";
      androidCxxStdLibSrc = pkgs.buildPackages.runCommand "system-cxx-std-lib-android-src" { } ''
        cp -r ${shSrc}/libraries/system-cxx-std-lib $out
        chmod -R u+w $out
        sed -i 's/^\([[:space:]]*if\) os(windows) || os(linux)[[:space:]]*$/\1 os(windows)/' \
          $out/system-cxx-std-lib.cabal
        # A sed that silently matched nothing would leave Android exactly as
        # broken as before.
        if grep -q 'os(linux)' $out/system-cxx-std-lib.cabal; then
          echo "system-cxx-std-lib: could not drop the os(linux) C++ runtime" >&2
          cat $out/system-cxx-std-lib.cabal >&2
          exit 1
        fi
      '';
      # libffi contradicts itself on Android, and the link says so:
      #
      #   ld.lld: error: undefined hidden symbol: open_temp_exec_file
      #   >>> referenced by tramp.c ... (ffi_tramp_init)
      #
      # `configure.ac` enables static trampolines for `aarch64*-*-linux-*` and
      # `*arm*-*-linux-*`, both of which an Android triple matches, so
      # `src/tramp.c` compiles `ffi_tramp_init` and it calls
      # `open_temp_exec_file ()`.  `src/closures.c` only defines that function
      # under `FFI_MMAP_EXEC_WRIT`, which it auto-defines for
      # `__linux__ && !defined(__ANDROID__)` — Android is excluded on purpose,
      # since it may forbid mapping a page writable and executable at once.
      #
      # Turn the trampolines off rather than force the mmap side on: the
      # exclusion is the deliberate half, and static trampolines are exactly
      # the feature that wants a file-backed executable mapping.
      #
      # `configure-options:` rather than a `configureFlags` module, because
      # libffi-clib is `build-type: Configure` (cabal forwards the value to
      # ./configure) and because it round-trips through plan.json's
      # `configure-args` into the v2 slice's own cabal.project — so the slice
      # and plan-nix agree on libffi-clib's UnitId.  One line, indented for the
      # `package libffi-clib` stanza it is appended to.  It carries its own
      # newline and indentation for two reasons: an interpolation is inserted
      # verbatim, so Nix's indented-string stripping never reaches it; and
      # appending to the previous line instead of occupying its own leaves the
      # project text byte-identical on every non-Android target, which keeps
      # their plan-nix hashes (and so the whole cross world) untouched.
      libffiAndroidConfigureOptions =
        lib.optionalString (tp.isAndroid or false)
          "\n  configure-options: --disable-exec-static-tramp";
      # Windows target boot libraries `time`, `process` and `directory` gain a
      # `Win32` build-depends under `if os(windows)`.  The `-target` wrapper
      # keeps `targetPrefix = ""` (so `isCross` is false), which makes the
      # plan-time solver evaluate `os()` against the native BUILD platform — it
      # therefore never adds those Win32 edges and the whole-project plan
      # contains no Win32 unit.  Each per-slice re-solve, however, runs the real
      # cross GHC (`--info` reports Windows), so `os(windows)` fires there and
      # the slice fails with "unknown package: Win32" because Win32 is in no
      # slice's package universe.  Win32 is not in the GHC source tree
      # (`libraries/Win32` is absent), so — mirroring the compiler's own
      # `cabal.project.stage3`, which lists the Win32 hackage tarball — inject
      # its hackage source as a LOCAL `packages:` entry (a store path, so no
      # `replace-hackage-tarball-urls` is required) to force Win32 into the plan
      # for every slice that needs it.  Version matches stage3's pin.  Lazily
      # bound: only forced when referenced under the `tp.isWindows` guard below,
      # so non-Windows targets never evaluate `hackageTarball`.
      win32Src = pkgs.haskell-nix.hackageTarball {
        name = "Win32"; version = "2.14.2.1";
      };
      # Extra fields appended inside `package` stanzas below.  Built with
      # explicit "\n  " (two-space) indentation — nix's `''` indentation
      # stripping applies to nested `''` strings separately, which would
      # push these lines to column 0 and change their cabal scope from the
      # stanza to the whole project.
      rtsWasmExtras = lib.optionalString isWasm ("\n"
        + "  -- GHC's wasm backend uses JSFFI, but the rts C sources still\n"
        + "  -- include ffi.h; nixpkgs' wasi toolchain ships no libffi, so\n"
        + "  -- point at the libffi-wasm build (same one hadrian wasm\n"
        + "  -- bindists use).\n"
        + "  extra-include-dirs: ${shGhc.libffi-wasm.dev}/include\n"
        + "  extra-lib-dirs: ${shGhc.libffi-wasm.out}/lib");
      # Whether to build the dynamic/shared way for the TARGET's boot
      # libraries.  This must key off the target platform (`tp`), NOT
      # `shGhc.enableShared`: `shGhc` is the BUILD compiler (selected from
      # `pkgs.buildPackages` — the `-target` wrapper keeps `targetPrefix=""`),
      # so its `enableShared` reflects the build host (darwin/linux, True) and
      # would wrongly enable the dyn way for a static-only target.  Windows
      # GHC is static-only: the dynamic RTS way fails to link (Cmm symbols are
      # referenced as PE `__imp_` dllimports that the static objects don't
      # export), so exclude it here as well as the static/musl targets — the
      # same set the cross compiler's own `enableShared` should cover.
      # The JS (ghcjs) backend is likewise static-only: emscripten's
      # `wasm-ld` rejects the ELF soname flag (`-h <soname>`) GHC emits
      # when linking a boot lib's shared `.so`, so a `shared: True` rts-fs
      # slice fails with `wasm-ld: error: unknown argument: -h`.  Exclude it.
      # Android is excluded for the same reason as the rest, it just takes
      # one more step to see: the android block above puts
      # `ghc-options: -optl-static -optl-ldl` in `package *`, so EVERY link
      # in the project is a static link -- which is what android wants for
      # its executables, and is why `lib/check.nix` used to force the same
      # flags.  A `-shared` link cannot also be `-optl-static`: `ld.lld` in
      # static mode will not accept a `.so`, so the rts way sub-libraries
      # die resolving the shared names of their own dependencies,
      #
      #   Linking DynWay library...
      #   ld.lld: error: unable to find library -lHSrts-fs-1.0.0.0-...-ghc9.14
      #   ld.lld: error: unable to find library -lHSlibffi-clib-3.5.2-...-ghc9.14
      #
      # even though both `.so`s were built and correctly registered (their
      # confs carry `dynamic-library-dirs: ${pkgroot}/lib`, and the files are
      # there).  Nothing is missing; the link mode is simply contradictory.
      # That is `rts-lib-*-aarch64-unknown-linux-android` and, through it,
      # both android clusters -- around a hundred jobs.
      #
      # Nothing on android wants the dyn way anyway: the executables are
      # static by construction, `GHC Dynamic` is NO, and cross TH goes
      # through iserv-proxy loading static objects.  The alternative --
      # narrowing `-optl-static` so it reaches only executable links -- is
      # not expressible in a cabal.project `package` stanza, and
      # `executable-static: True` (the musl spelling) means something
      # different again on the fork, which turns it into `-static-external`.
      targetSupportsShared =
        !(tp.isStatic or false) && !(tp.isMusl or false) && !(tp.isWindows or false)
        && !(tp.isGhcjs or false) && !(tp.isAndroid or false);
      crossLinkFields = lib.optionalString (!isWasm) "\n  executable-dynamic: False";
      # `shared:` is meant for the TARGET's boot libraries only, so it goes in
      # a `package host:*` stanza.  A plain `package *` has no stage and
      # reaches the BUILD stage too -- the tools cabal builds to run on the
      # build machine -- whose units link against the build compiler's own
      # boot libraries.  Those arrive as PRE-EXISTING installs with no dynamic
      # way, so `-dynamic-too` there cannot work:
      #
      #   Wanted module build ways(library 'grammar'): [DynWay,StaticWay]
      #   grammar/src/Happy/Grammar/ExpressionWithHole.hs:1:8: error: [GHC-47808]
      #       Failed to load dynamic interface file for Prelude:
      #         .../base-4.22.0.0/Prelude.dyn_hi: does not exist
      #
      # It used to be `package *`, turned back off per package for a
      # hand-kept list of build-stage-only tools (alex, happy, c2hs, ...).
      # The list could never be complete: any package can land in the build
      # stage -- `hspec-discover` via `build-tool-depends`, `Cabal-syntax`
      # via a custom `Setup` -- and those failed the same way on
      # aarch64-multiplatform (eval 2827: `tests.setup-deps-boot-cabal`'s
      # entropy Setup, `tests.cabal-22`'s hspec-discover), while naming a
      # package that ALSO has host units would have taken the host's dyn way
      # away.  The fork's cabal (plan time and slice time, ad937de5b)
      # accepts stage-qualified stanzas, which override `package *` and are
      # overridden by per-package ones; the build stage keeps the build
      # compiler's own default (no `GHC Dynamic`, no `dyn` way: off).
      hostStageFields = lib.optionalString (!isWasm)
        "\n\npackage host:*\n  shared: ${if targetSupportsShared then "True" else "False"}";
      # Sourced from `pkgs.haskell-nix.haskellLib` (not the file's own
      # `haskellLib` module argument, which callers of this module don't
      # actually provide — it was declared but never forced before now).
      shPlanUnitStage = pkgs.haskell-nix.haskellLib.planUnitStage;
    in {
      # The boot packages resolve in the HOST stage against an empty
      # installed set, while build-tool-depends / setup-depends resolve in
      # the BUILD stage against the (fully populated) native compiler — a
      # two-stage plan (the fork's `--with-build-compiler`).
      withBuildCompiler = true;
      # rts needs per-file Cmm options (`cmm-options:` stanzas) that only
      # the v2 (cabal v2-build slicing) builder applies — v1's standalone
      # Setup.hs links a mainline Cabal that drops them.  Hard-set (not
      # mkDefault) so an explicit `builderVersion = 1` fails loudly
      # instead of building a subtly broken rts.
      builderVersion = 2;
      # Slice lib:ghc in local-`packages:` mode, so it registers the plan's
      # deterministic id `ghc-9.14` rather than an extra-packages hashed
      # `ghc-9.14-<hash>`.  GHC resolves `GHC.Driver.Plugins` through its
      # baked-in `cProjectUnitId` -- the bare `ghc-9.14` -- when it
      # typechecks a `-fplugin`, so with the hashed id every plugin died
      # with
      #   Failed to load interface for 'GHC.Driver.Plugins'.
      #   no unit id matching 'ghc-9.14' was found
      # (musl64 / static `tests.external-static-plugin`).
      #
      # Only `ghc`.  2d3479a18 did this for every injected package via
      # `v2LocalPackageSlices` and was reverted (6c78576c0): Backpack
      # instantiations have no local-mode elaboration, local test/bench
      # slices collided with their own package's composed units, and that
      # option also changes how every slice's solver sees the global db.
      # `ghc` has no Backpack, tests or benchmarks, and is the one package
      # whose id the compiler hard-codes.
      v2LocalPackageSliceNames = [ "ghc" ];
      cabalProjectLocal = lib.mkBefore ''
        -- Added by the stable-haskell boot-package injection (see the
        -- `injectStableHaskellBootPackages` option): the compiler ships no
        -- target boot libraries, so the plan builds them from source.
        --
        -- The two `haskell.nix:boot-*` marker pairs below delimit the parts
        -- of this injection that are right for a SLICE build but wrong for
        -- the v2 SHELL, which strips/rewrites them (`shellProjectLocal` in
        -- builder/shell-for-v2.nix).  A slice starts from nothing and must
        -- build the boot libraries; the shell starts from the composed
        -- store, which already holds them -- with the very unit-ids the
        -- slices computed.  Left in, they make the shell's cabal treat
        -- every boot library as a LOCAL package and rebuild it, which then
        -- denies `improveInstallPlanWithStoreUnits` its `depOk` guard for
        -- everything downstream (the sibling library the shell was supposed
        -- to reuse included).
        --
        -- Keep each marker on its own line and byte-identical to the
        -- pattern the shell matches.  They survive `replaceSourceRepos`,
        -- which rewrites only `source-repository-package` blocks and
        -- concatenates the surrounding text verbatim.
        -- >>> haskell.nix:boot-packages
        packages:
        ${lib.concatMapStrings (d: "  ${shSubdirSrc d}\n        ") shSubdirs}
        ${lib.optionalString (tp.isWindows or false) "  ${win32Src}\n        "}
        -- <<< haskell.nix:boot-packages
        -- The boot libraries injected above are REBUILT in this slice, while
        -- every other boot library comes from the compiler -- whose stage2
        -- built them with `profiling-detail: none` (`bootLibProfiling` in
        -- overlays/stable-haskell.nix).  The two must agree.
        --
        -- Cabal's default for a library is `exported-functions`, i.e.
        -- `-fprof-auto-exported`, and the SCC that puts on a binding BLOCKS
        -- the worker/wrapper split.  So a boot library rebuilt here at the
        -- default detail has NO `$w` workers in its profiled interface, while
        -- the compiler's copy of the same library does.  Mixing them is fatal:
        -- `containers` (compiler-provided, never rebuilt in a slice) carries
        -- an unfolding referring to `GHC.Internal.Read.$wparens`, and against
        -- a slice-built `ghc-internal` GHC dies with
        --
        --   Can't find interface-file declaration for variable $wparens
        --     Probable cause: bug in .hi-boot file, or inconsistent .hi file
        --   Cannot continue after interface file error
        --
        -- which took out every `*.build-profiled` job that rebuilds a boot
        -- library (libsodium -> exe-dlls, and friends).  Only the PROFILED way
        -- is affected, which is why the vanilla jobs stayed green.
        --
        -- Setting the detail here is a no-op unless the project enables
        -- profiling, so this costs nothing for ordinary builds.
        ${lib.concatMapStrings (p: ''
        package ${p}
          profiling-detail: none
        '') bootPkgNames}
        -- Forked boot packages that live outside the GHC tree.
        source-repository-package
          type: git
          location: https://github.com/stable-haskell/Cabal.git
          tag: f2e0a89e15cf6604cec9d93e26a4b3caf459b076
          subdir: Cabal Cabal-syntax

        -- hsc2hs with batch cross-compilation support (a build-stage tool).
        source-repository-package
          type: git
          location: https://github.com/stable-haskell/hsc2hs.git
          tag: d07eea1260894ce5fe456f881fbc62366c9eb1b7

        -- Mirrors cabal.project.stage2.common: the boot packages' bounds
        -- predate base-4.22 etc.
        allow-newer: hsc2hs:*, Win32:*, array:*, binary:*, bytestring:*,
                     containers:*, deepseq:*, directory:*, exceptions:*,
                     file-io:*, filepath:*, haskeline:*, hpc:*,
                     libffi-clib:*, mtl:*, os-string:*, parsec:*, pretty:*,
                     process:*, semaphore-compat:*, stm:*, terminfo:*,
                     text:*, time:*, transformers:*, template-haskell-lift:*,
                     template-haskell-quasiquoter:*, unix:*, xhtml:*

        constraints:
          -- Build-stage dependencies come installed from the native
          -- compiler (mirrors cabal.project.stage3).
          build:any.ghc-internal installed
          -- The solver otherwise believes these are installed for the
          -- target although they only exist in the build compiler's db
          -- (mirrors cabal.project.stage3).  In the v2 shell every one of
          -- these IS installed -- in the composed store -- so the shell
          -- rewrites ` source` to ` installed` between these markers.
          -- >>> haskell.nix:boot-pins
          , Cabal source, Cabal-syntax source, array source, base source
          , binary source, bytestring source, containers source
          , deepseq source, directory source, exceptions source
          , file-io source, filepath source, ghc-bignum source, hpc source
          , integer-gmp source, mtl source, os-string source, parsec source
          , pretty source, process source, rts source, rts-headers source
          , rts-fs source, stm source, system-cxx-std-lib source
          , template-haskell source, text source, time source
          , transformers source, unix source, xhtml source, Win32 source
          -- <<< haskell.nix:boot-pins
          -- Exact versions of the hackage-resolved boot deps, matching the
          -- compiler's own stage2 pins.
          ${lib.concatMapStrings (p: ", ${p.name} ==${p.version}\n  ") shUrlBootPkgs}

        package libffi-clib
          ghc-options: -no-rts -optc-Wno-error${libffiAndroidConfigureOptions}

        package ghc
          flags: +build-tool-depends +internal-interpreter

        package ghc-bin
          flags: +internal-interpreter

        package ghci
          flags: +internal-interpreter${lib.optionalString isWasm " +use-system-libffi"}

        package ghc-internal
          flags: +bignum-native
          ghc-options: -no-rts

        -- directory / file-io / process / unix each carry an automatic
        -- `os-string` flag (default False) that selects, in their .cabal
        -- and their .hsc/.hs sources, between the modern `os-string`
        -- package and filepath's pre-1.5 bundled `System.OsString.*`.
        -- With filepath-1.5.4.0 (which no longer bundles those modules)
        -- only the `+os-string` branch compiles, but `allow-newer` relaxes
        -- the `else` branch's `filepath < 1.5.0.0` bound so the solver
        -- otherwise keeps the default False and the build fails with
        -- "hidden package os-string" / "could not find module
        -- System.OsString.…".  Force the flag to match how the compiler's
        -- own stage2 (cabal.project.stage2) resolves these packages.
        package directory
          flags: +os-string

        package file-io
          flags: +os-string

        package process
          flags: +os-string

        package unix
          flags: +os-string

        -- Win32 (windows cross only; ignored where Win32 isn't in the plan)
        -- carries the same `os-string` flag: its System.Win32.WindowsString.*
        -- modules import System.OsString.Windows / .Internal.Types from the
        -- `os-string` package, hidden unless the flag pulls it into
        -- build-depends.  With filepath-1.5.4.0 the default-False branch fails
        -- ("hidden package os-string" / "Could not load module
        -- System.OsString.Windows"), so force it like directory/process/unix.
        package Win32
          flags: +os-string

        -- wasm: `+dynamic` (-DDYNAMIC), as the fork's own wasm build does
        -- (`if arch(wasm32)` / `constraints: rts +dynamic` in
        -- cabal.project.stage3).  Hadrian defines DYNAMIC for the dyn way
        -- only, but cabal cannot set C flags per way, and the dyn way needs
        -- it: without it rts/Schedule.c leaves the bytecode interpreter out
        -- ("bytecode interpreter is unsupported in static RTS on wasm") and
        -- Template Haskell, run by dyld on the dyn rts, dies on the first
        -- BCO.  On the host side it is harmless: `GHC Dynamic` comes from
        -- the rts the (native) ghc binary links, not this one.
        package rts
          ghc-options: -no-rts
          flags: ${if isWasm then "+use-system-libffi -tables-next-to-code +dynamic" else "+tables-next-to-code"}${rtsWasmExtras}

        -- `text`'s `simdutf` flag (default True) compiles the bundled
        -- simdutf C++ and links every `text`-using library against
        -- libc++.  The fork's own boot-library build turns it off for
        -- every target (`package text / flags: -simdutf` in
        -- cabal.project.common), and consumer projects -- which build
        -- these same boot libraries from source -- have to agree, or
        -- `text` is a different unit here than in the compiler.
        --
        -- On wasm it is not merely an inconsistency.  wasm boot libs are
        -- built with `shared: True` (the dyn way is what the wasm TH
        -- interpreter dlopens; see `target RTS linker only supports
        -- shared libraries` in lib/dummy-ghc.nix), and nixpkgs' wasi
        -- libc++ is a non-PIC archive, so the DynWay link of `text`
        -- fails on every C++ object it pulls in:
        --   wasm-ld: error: libc++.a(private_typeinfo.cpp.o):
        --     relocation R_WASM_MEMORY_ADDR_SLEB cannot be used against
        --     symbol `typeinfo for __cxxabiv1::__shim_type_info`;
        --     recompile with -fPIC
        -- which took out `text` and everything downstream of it on both
        -- wasi32 clusters.  text 2.1.3 special-cases `arch(javascript)`
        -- for its pure-Haskell path but not `arch(wasm32)`, so the flag
        -- is the only lever.
        package text
          flags: -simdutf

        package rts-headers
          ghc-options: -no-rts

        package rts-fs
          ghc-options: -no-rts
        ${lib.optionalString ((tp.isMusl or false) && lib.elem "utils/ghc-iserv" shSubdirs) ''

        -- The external interpreter runs on the BUILD machine and loads
        -- code at run time, so it must not be a fully static executable:
        -- musl's static libc has no dlopen and no symbol table for dlsym,
        -- so the musl `executable-static: True` (-fully-static on the
        -- fork) left it failing on the first library it touched --
        --   <no location info>: error: Dynamic loading not supported
        --   ghc-iserv: Failed to lookup symbol: memcmp
        -- Haskell libraries stay static; only libc is linked dynamically.
        --
        -- Link the C++ runtime in up front too.  system-cxx-std-lib names
        -- `stdc++`, so a splice touching a C++-using package makes the
        -- interpreter dlopen nixpkgs' libstdc++.so -- whose RUNPATH names
        -- only musl's lib dir, not its own, so musl cannot find its
        -- libgcc_s.so.1 dependency:
        --   Error loading shared library libgcc_s.so.1: No such file or
        --   directory (needed by .../libstdc++.so)
        -- Already loaded through ghc-iserv's own RUNPATH, both resolve.
        --
        -- pkgsStatic (`static`) is the exception: it has no libgcc_s, so
        -- there ghc-iserv links only libc dynamically -- musl-static still
        -- ships libc.so and ld-musl -- which is what hadrian's static
        -- cross ghc-iserv does too.
        package ghc-iserv
          executable-static: False${lib.optionalString (!(tp.isStatic or false))
            "\n  ghc-options: -optl-Wl,--no-as-needed -optl-lstdc++ -optl-lgcc_s"}
        ''}
        package *
          library-for-ghci: False${crossLinkFields}${hostStageFields}
      '';
      inputMap = {
        "https://github.com/stable-haskell/Cabal.git/f2e0a89e15cf6604cec9d93e26a4b3caf459b076" =
          pkgs.haskell-nix.sources.ghc914-sh-cabal;
        # Patched, as the compiler's own hsc2hs is (overlays/hsc2hs.nix).
        "https://github.com/stable-haskell/hsc2hs.git/d07eea1260894ce5fe456f881fbc62366c9eb1b7" =
          pkgs.haskell-nix.hsc2hs-patched-src;
      };
      # rts/configure AC_PATH_PROGs programs that are not cabal-level
      # dependencies (DERIVE_CONSTANTS, GENAPPLY, NM, OBJDUMP, PYTHON).
      # The v2 builder runs configure through cabal (no preConfigure
      # hooks), so they must be on the rts slices' PATH — build-tools feed
      # the slice's extraNativeBuildInputs.  The tools come from the
      # compiler's passthru (built natively; nm/objdump handle TARGET
      # objects).
      modules = [ ({ config, lib, ... }: let
        # The four rts WAY sub-libraries (built as v2 slices).  Not every
        # target has all four (the JS backend builds only nonthreaded-nodebug),
        # so look them up tolerantly.
        rtsSublibs = lib.filter (x: x != null)
          (map (n: config.hsPkgs.rts.components.sublibs.${n} or null)
            [ "nonthreaded-nodebug" "threaded-nodebug"
              "nonthreaded-debug" "threaded-debug" ]);
        # rts:nonthreaded-nodebug's own dependency closure — excluded to
        # avoid a circular additional-prebuilt-depends edge (mirrors the
        # stage2 boot-lib module in overlays/stable-haskell.nix).
        rtsClosure = [ "rts" "libffi-clib" "rts-fs" "rts-headers" ];
        # Every package that transitively links base carries ghc-internal.conf
        # in its per-component package db, and GHC 9.14's unit wiring then
        # demands all rts WAY sub-libs be resolvable when GHC runs (mkUnitState
        # panics "The RTS for rts:nonthreaded-nodebug is missing …" otherwise).
        # A native compiler satisfies this from its own global db; a two-stage
        # from-source cross project has an EMPTY target global db, so every
        # HOST slice must compose the ways itself — including the user's own
        # packages, not just the boot libs.  Enumerate the plan's HOST-stage
        # package names from plan-json (a fixed input; reading `config.packages`
        # for the list would recurse through these very settings).  BUILD-stage
        # units (alex / happy / genprimopcode / … — build tools run natively
        # with the build compiler, whose global db already has the rts ways)
        # are excluded: they have no host package definition here and don't
        # need the ways.
        pkgsNeedingRts = lib.filter (n: !(lib.elem n rtsClosure))
          (lib.unique (map (u: u.pkg-name)
            (lib.filter (u: u.type == "configured" && u ? pkg-name
                            && shPlanUnitStage u == "host")
              config.plan-json.install-plan)));
        # ── TH on the JS backend: ghci in every consumer's dep db ─────────
        # GHC's JS external interpreter resolves the `ghci` package BY NAME
        # in the home unit state at Template-Haskell time
        # (GHC/Runtime/Interpreter/JS.hs lookupPackageName) and links
        # GHCi.Server.defaultServer from its unit closure.  `ghci` is never
        # a build-depends, so no slice's dep db contains it, and the
        # two-stage wrapper's target global db is EMPTY — the lookup fails
        # ("couldn't find \"ghci\" package").  Populating the compiler's
        # GLOBAL db with a separately-built ghci closure does NOT work:
        # its unit-ids can never match the project's own boot-lib builds,
        # so the interpreter session loads ghc-internal's jsbits twice
        # (server closure + splice deps) and node dies
        # "Identifier 'h$base_o_rdonly' has already been declared".
        # Instead, compose THE PROJECT'S OWN ghci slice (its closure — the
        # very units the splice code links — propagates with it) into every
        # host package's starting store db, exactly like the rts ways
        # above.  Unit-ids agree by construction; nothing loads twice.
        # wasm's interpreter does the same lookup (GHC/Runtime/Interpreter/
        # Wasm.hs: `Just ghci_unit_id`), so it needs the same composition.
        ghciPrebuilt = lib.optionals ((tp.isGhcjs or false) || isWasm)
          (lib.filter (x: x != null)
            [ (config.hsPkgs.ghci.components.library or null) ]);
        # ghci's own dependency closure (by package name, a verified
        # superset — see the registered confs' depends) must NOT receive
        # the prebuilt, else additional-prebuilt-depends edges form a drv
        # cycle (ghci's slice depends on these very slices).  None of them
        # run TH splices — they all build before ghci exists.
        ghciClosure = [
          "ghci" "rts" "rts-fs" "rts-headers" "libffi-clib"
          "ghc-prim" "ghc-bignum" "integer-gmp" "ghc-internal" "base"
          "ghc-boot-th" "ghc-heap" "ghc-platform" "ghc-boot" "ghc-compact"
          "ghc-experimental" "template-haskell" "Cabal-syntax" "Cabal"
          "array" "binary" "bytestring" "containers" "deepseq" "directory"
          "exceptions" "file-io" "filepath" "hpc" "mtl" "os-string"
          "parsec" "pretty" "process" "semaphore-compat" "stm" "text"
          "time" "transformers" "unix"
        ];
        # `rtsWasmExtras` (above) puts libffi-wasm's include/lib dirs on the
        # rts slices' command line -- and that is not enough on its own.  By
        # the time a slice materialises its cabal.project, those dirs are
        # plain strings: the project text travels through plan-to-nix's IFD,
        # which round-trips it through a FILE and so drops nix's string
        # context.  The FLAG survives; the DEPENDENCY does not.  The store
        # path is then simply absent from the build sandbox, and the rts dies
        # compiling Interpreter.c with
        #   include/rts/ghc_ffi.h:28:10: fatal error: 'ffi.h' file not found
        # while `-I<libffi-wasm-dev>/include` sits right there in the response
        # file.  (Confirmed: the hash does not appear anywhere in the slice's
        # .drv.)  Naming it as a component `lib` re-attaches the dependency
        # from the nix side, where the context still exists.
        #
        # `libs` is the correct knob precisely because it feeds
        # `extraBuildInputs` -- hence the slice's `buildInputs`, hence the
        # sandbox -- and nothing that cabal hashes.  The emitted
        # `extra-lib-dirs:` / `extra-include-dirs:` block is built from
        # `perPackageOptionOf "extraLibDirs"`, i.e. from the PLAN, not from
        # `libs` (`extraLibDirsBlockFor` in builder/comp-v2-builder.nix), so
        # no unit-id moves and the slice still matches plan-nix.
        rtsWasmLibs = lib.optionalAttrs isWasm {
          libs = [ shGhc.libffi-wasm.dev shGhc.libffi-wasm.out ];
        };
      in {
        packages =
          (lib.optionalAttrs (config.packages ? rts) {
            rts.components = {
              library = { build-tools = shGhc.bootPkgTools or []; } // rtsWasmLibs;
              sublibs = lib.genAttrs
                [ "nonthreaded-nodebug" "threaded-nodebug"
                  "nonthreaded-debug" "threaded-debug" ]
                (_: { build-tools = shGhc.bootPkgTools or []; } // rtsWasmLibs);
            };
          })
          # Package-level (inherited by all component types) so the rts ways
          # land in every slice's starting store db.  `rts` is excluded, so
          # this never collides with the `rts.components` block above.
          # One genAttrs computing BOTH contributions (`//` between two
          # genAttrs would drop the rts ways for ghci recipients): every
          # host package gets the rts ways; packages outside ghci's closure
          # additionally get the ghci slice (ghcjs only).
          // lib.genAttrs
               (lib.filter (n: config.packages ? ${n}) pkgsNeedingRts)
               (n: { additional-prebuilt-depends =
                       rtsSublibs
                       ++ lib.optionals (!(lib.elem n ghciClosure)) ghciPrebuilt; }
                   # ghc-internal's configure guards its JS-specific
                   # sizeof/offset checks with `test "$host" =
                   # "javascript-ghcjs"`, but cabal's runConfigureScript
                   # passes --host=javascript-unknown-ghcjs (the full
                   # triple), so the whole block silently skips and
                   # HsBaseConfig.h ships `#undef SIZEOF_STRUCT_STAT` etc.
                   # The jsbits then die at Template-Haskell time with
                   # "ReferenceError: SIZEOF_STRUCT_STAT is not defined"
                   # (h$base_sizeof_stat, first splice ever run).  Accept
                   # both spellings.  Upstream fix belongs in
                   # stable-haskell/ghc libraries/ghc-internal/configure.ac.
                   // lib.optionalAttrs (n == "ghc-internal" && (tp.isGhcjs or false)) {
                     prePatch = ''
                       sed -i 's|test "$host" = "javascript-ghcjs"|test "$host" = "javascript-ghcjs" -o "$host" = "javascript-unknown-ghcjs"|' \
                         configure
                     '';
                   });
      }) ];
    }))
  ];
}
