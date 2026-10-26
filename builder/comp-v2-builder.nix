# v2 component builder.  Built once per component when the project's
# `builderVersion = 2`; `hspkg-builder.nix` then exposes the result
# at `hsPkgs.<pkg>.components.<kind>.<n>` as the primary derivation.
# Set `builderVersion = 1` on the project module to use the legacy
# Setup.hs-based comp-builder.nix instead.
#
# Compared to the overlay (test/cabal-store-compose/phase5/add-v2.nix)
# this lives inside the module system's evaluation so it reads
# ghc-options / configure-options / flags / patches / libs / build-tools
# directly from config.packages rather than via a project wrapper.
#
# Scope matches the overlay: library, executable, test-suite, and
# benchmark components.  See the overlay for the longer explanation
# of why we pick each cabal.project shape, target selector, and
# binary-extraction path per kind.
{ lib, stdenv, runCommand, buildCabalStoreSlice, composeStore, ghc, hsPkgs, pkgs, haskellLib
# Optional cross-TH plumbing for the host platform.  Currently
# only set by overlays/windows.nix and exposes `wrapGhc :: ghc -> ghc`.
, templateHaskell ? null
# Host-platform iserv-proxy executables (see builder/default.nix), used by
# the `-pgmi` bridge for the profiled external interpreter.
, iservProxyExes ? null
# Project-level switch (see modules/project-common.nix): build slices
# for `style: "local"` plan units in cabal `packages:` mode instead of
# `extra-packages:` mode, so the slice's cabal elaborates the SAME
# deterministic local unit id the project plan records
# (`base-4.22.0.0`, `rts-1.0.3-threaded-nodebug`, ...).  Set by the
# stable-haskell stage2 boot-lib project, whose registered ids become
# the compiler's global package db — consumer plan-time dummy dumps
# must be able to predict them (an extra-packages slice registers an
# unpredictable `<pkgid>-<hash>` id instead).
, v2LocalPackageSlices ? false
# The same local-`packages:` slicing for the named packages only (see
# modules/project-common.nix).
, v2LocalPackageSliceNames ? [] }:

{ componentId, component, package, name, src, flags ? {}, patches ? [], cabalFile ? null, pkgSet
, cabal-generator ? null # "hpack" if the package ships only `package.yaml`
                         # and needs hpack run to produce the .cabal file
                         # before tarball / build.  Mirrors v1's
                         # comp-builder.nix handling.
, packageIdsByName ? {}  # { <canonical-pkg-name> = [<plan-id>...]; }
, planJson ? []          # plan.json's `install-plan` — used to walk
                         # the transitive lib-dep closure for the
                         # cabal.project `constraints:` block.
, planJsonByPlanId ? {}  # `planJson` indexed by `id` — pre-built once
                         # at the project level, shared across slices.
                         # HOST twins win id collisions.
, planJsonByPlanIdBuild ? null
                         # the BUILD-twin-preferring variant, used by
                         # the custom-setup machinery (setup scopes are
                         # build-stage under the fork).  Defaults to
                         # `planJsonByPlanId` when the project doesn't
                         # provide it.
, planV2Globals ? {}     # { projectConfigPragmas; perPkgConfigBlocks;
                         #   docEnabledNames; flagsByName; }
                         # derived once from the plan (see
                         # `builder/v2-project-globals.nix`), shared across slices.
, homeDependIds    ? []  # [{ name; version; }] — sibling-component LIB deps from plan-json
, homeBuildToolIds ? []  # [{ name; version; }] — sibling-component EXE deps from plan-json
, nonReinstallablePkgs ? []
                         # `config.nonReinstallablePkgs` — the packages the
                         # compiler provides (rts, base, array, …).  Used to
                         # keep boot libs out of two-stage build-tool source
                         # staging (they have no real hackage src).
, prePatch ? null, postPatch ? null, ... }@allArgs:

let
  pkgName = package.identifier.name;
  pkgVersion = package.identifier.version;
  ghcPkgVersion = ghc.version;

  # Project-global data computed once from the plan (see
  # `builder/v2-project-globals.nix`), not per slice.
  docEnabledNames      = planV2Globals.docEnabledNames or {};
  planFlagsByName      = planV2Globals.flagsByName or {};
  projectConfigPragmas = planV2Globals.projectConfigPragmas or "";
  perPkgConfigBlocks   = planV2Globals.perPkgConfigBlocks or {};

  # Resolve a dependency package record in `hsp` (`hsPkgs` or
  # `hsPkgs.pkgsBuildBuild`) by name, disambiguating by version.
  #
  # When the cabal plan holds more than one version of a package — e.g.
  # a GHC boot library like `text-2.0.2` alongside a cabal-reinstalled
  # `text-2.1.4` — the bare `hsp.<name>` redirect is ambiguous and
  # throws "Multiple versions for <name>".  The `<name>-<version>`
  # redirect is unique, so prefer it whenever we know the version and
  # fall back to the bare name only when we don't (or when there's no
  # version-specific redirect, e.g. on `pkgsBuildBuild`).
  # When falling back to the bare name with a known version, the record
  # found must actually BE that version: plan `targets` hold one entry
  # per package NAME (what `cabal build <name>` targets), so with two
  # versions in the plan (a pre-existing boot `Cabal-3.17.0.1-inplace`
  # alongside a configured setup-dep `Cabal-3.16.1.0`) the bare-name
  # redirect points at the *other* version — and a pre-existing unit has
  # no buildable definition behind it (only the `planned.nix` stub, with
  # `src = null`).  Returning null instead lets every caller's
  # null-filter skip the dep; the correct slice reaches the consumer
  # through an id-keyed path (`directDepSlices`, `setupDepSlices`).
  lookupDepPkg = hsp: name: version:
    let byNV = if version != null then hsp."${name}-${version}" or null else null;
        byName = hsp.${name} or null;
    in if byNV != null then byNV
       else if version == null || byName == null
            || (byName.identifier.version or null) == version
       then byName
       else null;

  # Cross-compile detection — drives:
  #   * whether home-build-tool source goes in the slicing repo
  #     (no on cross — see `depTransitives` and `externalDepIds`).
  #   * whether the slice's cabal v2-build gets explicit
  #     `--configure-option=--with-PROG=PATH` flags for transitive
  #     build-tool exes (yes on cross — see `withProgFlags`).
  #   * whether the slice runs the unit-id mismatch check
  #     (no on cross — `expectedUnitId` returns null; cross plan
  #     unit-ids legitimately diverge from what cabal computes
  #     against the real cross GHC).
  isCross = (ghc.targetPrefix or "") != "";
  # The stable-haskell `-target` cross wrapper is morally cross but keeps
  # `targetPrefix = ""` (it is the native compiler + `-target`), so
  # `isCross` above is false for it.  Its empty target global db is the
  # reliable signal that boot libraries are planned from source and that
  # hashed unit-ids computed against the REAL wrapper legitimately diverge
  # from the plan-time dummy ghc's — used only by the unit-id check below.
  isTwoStageCross = ghc.emptyGlobalPackageDb or false;

  # Plan-nix entry for this slice's own unit (looked up via the
  # unit-id `modules/install-plan/planned.nix` recorded on the
  # `package.identifier`).  We use it to detect source-repo packages
  # (`pkg-src.type == "source-repo"`) so the slice's cabal.project
  # can use the same source-repository-package shape the project's
  # plan-nix was built from.  Reproducing the project's
  # `cabal.project` shape is what makes the slice's `pkg-src-sha256`
  # and therefore the slice's UnitId match plan-nix.
  thisPlanEntry =
    let uid = package.identifier.unit-id or null;
    in if uid == null then null else planJsonByPlanId.${uid} or null;
  isSourceRepoPkg =
    thisPlanEntry != null
    && (thisPlanEntry.pkg-src or {}).type or null == "source-repo";

  # When this package comes from a `source-repository-package` (e.g.
  # `lib:ghc` via `useLocalGhcLib`), the slice's solver must see it as a
  # source-repo, not a hackage tarball — otherwise cabal hashes a
  # different `pkg-src-sha256` and forks the UnitId.  Wrap the fetched
  # source in a minimal git repo (mirrors lib/call-cabal-project-to-nix.nix)
  # and emit a `source-repository-package` block.  Each source-repo
  # package emits its OWN block into its fragment; the build-time
  # composer collects them across the closure (and skips them from
  # `extra-packages:`).
  minimalSourceRepo = pkgs.runCommand "v2-source-repo-${pkgName}-${pkgVersion}"
    { nativeBuildInputs = [ pkgs.rsync pkgs.gitMinimal ];
      preferLocalBuild = true;
    }
    ''
      mkdir $out
      rsync -a --prune-empty-dirs --chmod=u+w "${src}/" "$out/"
      cd $out
      git init -b minimal
      git add --force .
      GIT_COMMITTER_NAME='No One' GIT_COMMITTER_EMAIL= \
        git commit -m "Minimal Repo For Haskell.Nix" --author 'No One <>'
    '';
  # Skipped for local-`packages:` mode slices: their target is staged
  # as a local source dir instead, which is what gives the fork's
  # deterministic (bare pkgid) elaboration — an srp block would make
  # cabal elaborate the package BuildAndInstall with a hashed id.
  ownSourceRepoBlock = lib.optionalString (isSourceRepoPkg && !isLocalPackageSlice) ''
    source-repository-package
      type: git
      location: file://${minimalSourceRepo}
      subdir: .
      tag: minimal
  '';

  # Helpers mirroring add-v2.nix ----------------------------------

  # `pkgSet` is keyed by both canonical package names (`foo`) and
  # the plan-id-keyed entries the install plan generates per
  # configuration (`foo-0.1.0.0-inplace`,
  # `foo-0.1.0.0-inplace-foo-exe`, ...).  Per-plan-unit settings
  # sourced from plan.json's `configure-args` (see
  # modules/install-plan/configure-args.nix) land on the plan-id
  # entries.  Use `package-ids-by-name` (from
  # modules/install-plan/override-package-by-name.nix) to walk
  # every plan id for a given canonical name.
  cfgsForCanonical = pname:
    map (id: pkgSet.${id})
      (lib.filter (id: pkgSet ? ${id})
        (packageIdsByName.${pname} or [ pname ]));

  componentEntries = cfg:
    let comps = cfg.components or {};
    in lib.optional (comps ? library) { name = "library"; comp = comps.library; }
       ++ lib.mapAttrsToList (n: c: { name = "sublib:${n}"; comp = c; }) (comps.sublibs or {})
       ++ lib.mapAttrsToList (n: c: { name = "exe:${n}";    comp = c; }) (comps.exes or {})
       ++ lib.mapAttrsToList (n: c: { name = "test:${n}";   comp = c; }) (comps.tests or {})
       ++ lib.mapAttrsToList (n: c: { name = "bench:${n}";  comp = c; }) (comps.benchmarks or {});

  # Plan-json flags for the matching source-repo unit, when this
  # package is built from a `source-repository-package`.  haskell.nix's
  # module-system flag overrides (e.g. `packages.<pkg>.flags.release =
  # true`) are applied per-component AFTER plan computation, so they
  # don't reach cabal-install when it computes the project plan — but
  # they *would* reach cabal-install when the slice rebuilds via the
  # same `source-repository-package` block.  Honouring them in the
  # slice would compute a different `pkgHashFlagAssignment` than
  # plan-nix and fork the UnitId.  For source-repo packages we
  # therefore use plan-json's flags as the source of truth,
  # reproducing the assignment cabal-install actually saw at plan
  # time.  Hackage / repo-tar / local packages keep the module-flag
  # behaviour (matches what they got at plan time too).
  # `planFlagsByName` (project-global) maps each source-repo package to
  # its plan-json flags; non-source-repo packages are absent → `null`.
  flagBlockFor = pname:
    let
      moduleFlags = lib.foldl' (acc: cfg: acc // (cfg.flags or {})) {} (cfgsForCanonical pname);
      planFlags = planFlagsByName.${pname} or null;
      flagAttrs = if planFlags != null then planFlags else moduleFlags;
      toToken = n: v: (if v then "+" else "-") + n;
      flagTokens = lib.mapAttrsToList toToken flagAttrs;
    in if flagTokens == []
       then ""
       else "package ${pname}\n  flags: ${lib.concatStringsSep " " flagTokens}\n";

  # Collect values for `field` across every cfg (canonical +
  # plan-id-keyed) for the package — at both the package level
  # (where `configure-args.nix` sets per-plan-unit overrides) and
  # the component level (where user-set values via `modules` land).
  # Errors if components or plan units disagree — cabal.project's
  # `package X\n  <field>:` stanza applies to all components, so we
  # can't faithfully reproduce per-component differentiation here.
  perPackageOptionOf = field: pname:
    let
      cfgs = cfgsForCanonical pname;
      pkgLevel = lib.imap0
        (i: cfg: { name = "pkg-${toString i}"; opts = cfg.${field} or []; })
        cfgs;
      compLevel = lib.concatMap (cfg:
        map (e: { name = e.name; opts = e.comp.${field} or []; })
          (componentEntries cfg)
      ) cfgs;
      tagged  = pkgLevel ++ compLevel;
      nonEmpty = lib.filter (e: e.opts != []) tagged;
      distinctSets = lib.unique (map (e: e.opts) nonEmpty);
    in
      if lib.length distinctSets <= 1
      then (if nonEmpty == [] then [] else (builtins.head nonEmpty).opts)
      else throw (
        "comp-v2-builder: package ${pname} has differing ${field} "
        + "across components / plan units:\n"
        + lib.concatMapStrings (e:
            "  " + e.name + ": " + builtins.toJSON e.opts + "\n"
          ) nonEmpty
        + "cabal.project's `package ${pname}` stanza applies to all "
        + "components; v2 cannot faithfully reproduce per-component "
        + "values.  Unify them or fall back to the v1 builder."
      );

  ghcOptionsOf       = perPackageOptionOf "ghcOptions";
  configureOptionsOf = perPackageOptionOf "configureOptions";
  extraLibDirsOf     = perPackageOptionOf "extraLibDirs";
  extraIncludeDirsOf = perPackageOptionOf "extraIncludeDirs";

  # `programOptions` is `{ <prog> = [<args>...]; }`, not a list, so
  # `perPackageOptionOf` (which compares list values for equality)
  # doesn't apply.  Merge across all configs / components for a
  # canonical package — duplicate options per program are deduped
  # via `lib.unique`.
  programOptionsOf = pname:
    let
      cfgs = cfgsForCanonical pname;
      mapsFromPkg = map (cfg: cfg.programOptions or {}) cfgs;
      mapsFromComp = lib.concatMap (cfg:
        map (e: e.comp.programOptions or {}) (componentEntries cfg)
      ) cfgs;
      merged = lib.foldl' (acc: m:
        lib.foldl' (acc: prog:
          acc // { ${prog} = lib.unique ((acc.${prog} or []) ++ m.${prog}); }
        ) acc (builtins.attrNames m)
      ) {} (mapsFromPkg ++ mapsFromComp);
    in merged;

  # Has plan-nix flagged this canonical package (any of its units)
  # as documentation-enabled?  Mirrors `docEnabled` above but for
  # arbitrary pkg-names rather than this slice's own unit.  Looked up
  # in the project-global `docEnabledNames` set (computed once).
  pkgDocEnabled = pname: docEnabledNames ? ${pname};

  # `documentation: True` widens `pkgHashConfigInputs` (sets the
  # haddock-* booleans on ElaboratedConfiguredPackage) AND adds
  # `--ghc-option=-haddock` to the unit's configure-args.  When
  # we emit a `documentation: True` block here we therefore must
  # also strip `-haddock` from the per-pkg ghc-options block —
  # otherwise the slice would get `-haddock` twice in
  # `pkgHashGhcOptions` and the UnitId would diverge from plan-nix.
  ghcOptionsBlockFor = pname:
    let raw = ghcOptionsOf pname;
        opts = if pkgDocEnabled pname
               then lib.filter (o: o != "-haddock") raw
               else raw;
    in if opts == [] then ""
       else "package ${pname}\n  ghc-options: ${lib.concatStringsSep " " opts}\n";

  # Per-package `documentation: True` block.  Emitted when this
  # package's plan-nix entry has `--ghc-option=-haddock` (the
  # signal that `documentation: True` was set in the project's
  # cabal.project).  See `docEnabled` above for the full
  # rationale.
  documentationBlockFor = pname:
    if pkgDocEnabled pname
      then "package ${pname}\n  documentation: True\n"
      else "";

  configureOptionsBlockFor = pname:
    let opts = configureOptionsOf pname;
    in if opts == [] then ""
       else "package ${pname}\n  configure-options: ${lib.concatStringsSep " " opts}\n";

  # Per-package `extra-lib-dirs:` / `extra-include-dirs:` blocks.
  # plan-nix picks these up from cabal.project (e.g. when the user
  # adds `package <pkg>\n  extra-lib-dirs: <path>` to
  # `cabalProjectLocal` to point cabal at a C library that lives
  # outside the standard `lib/` layout — `mingw-w64` import libs
  # in `bin/`, for instance).  cabal hashes the paths into
  # `pkgHashExtraLibDirs` / `pkgHashExtraIncludeDirs`, so the slice
  # must re-emit the same entries here or its unit-id diverges from
  # plan-nix's and downstream consumers can't find the slice in the
  # cabal-store.
  extraLibDirsBlockFor = pname:
    let
      libs = extraLibDirsOf pname;
      incs = extraIncludeDirsOf pname;
      lines =
        lib.concatMapStrings (p: "  extra-lib-dirs: ${p}\n")     libs
        + lib.concatMapStrings (p: "  extra-include-dirs: ${p}\n") incs;
    in if libs == [] && incs == [] then ""
       else "package ${pname}\n${lines}";

  # Per-package `<prog>-options:` lines.  cabal-install auto-generates
  # one such field per program in its `ProgramDb` (see
  # `Distribution.Simple.Program.Db.programDbOptions`), so any
  # `<prog>-options:` the user wrote in cabal.project round-trips
  # through plan-nix's `--<prog>-option=` form back into the slice's
  # cabal.project here.  `build-type: Simple` packages only honour
  # `<prog>-options:` (not `configure-options:`), so this is the
  # form cabal-install actually threads to the program's argument
  # list at build time.
  programOptionsBlockFor = pname:
    let progs = programOptionsOf pname;
        lines = lib.concatStringsSep "\n" (map (prog:
          "  ${prog}-options: ${lib.concatStringsSep " " progs.${prog}}"
        ) (builtins.attrNames progs));
    in if progs == {} then ""
       else "package ${pname}\n${lines}\n";

  # The per-package `flagBlockFor`/`ghcOptionsBlockFor`/… functions
  # above are applied to THIS package only (via `v2Fragment`); the
  # per-closure assembly across `sliceCanonicalNames` now happens at
  # build time in build-cabal-slice.nix from the fragments.

  # Resolve version-conditional patches (a `patches` entry may be a
  # function `{ version }: drv-or-null`, same convention v1 uses).
  resolvedPatches = lib.filter (p: p != null) (map (p:
    if builtins.isFunction p
      then p { inherit (package.identifier) version; }
      else p
  ) patches);
  # Honour `prePatch`/`postPatch` (pkg-level hooks) around patching.
  # Hadrian, for example, uses `prePatch = "cd .."` to apply GHC-repo-
  # relative patches from outside the hadrian/ subdir.
  prePatchHook  = lib.optionalString (prePatch  != null) prePatch;
  postPatchHook = lib.optionalString (postPatch != null) postPatch;
  # Package tarball with patches applied.  Runs the pre/post hooks
  # inside the staged source dir so relative `cd ..` tricks work.
  patchApplyScript = lib.optionalString
    (resolvedPatches != [] || prePatch != null || postPatch != null) ''
    chmod -R u+w $target
    ( cd $target
      ${prePatchHook}
      ${lib.concatMapStrings (p: ''
        echo "Applying patch: ${builtins.baseNameOf (toString p)}" >&2
        patch -p1 < ${p}
      '') resolvedPatches}
      ${postPatchHook}
    )
  '';
  cabalFileOverride = lib.optionalString (cabalFile != null) ''
    chmod -R u+w $target
    cp ${builtins.toFile "${pkgName}.cabal" cabalFile} $target/${pkgName}.cabal
  '';
  # Local packages with `cabal-generator: hpack` ship `package.yaml`
  # without a generated `.cabal`.  Mirror v1's comp-builder.nix:
  # run hpack inside the package source dir so the tarball carries
  # a real `.cabal` for cabal-install to extract.  Skip when an
  # explicit `cabalFile` override is set (e.g. an X-revision from
  # `package-description-override`) since that already provides the
  # .cabal we want.
  hpackScript = lib.optionalString
    (cabalFile == null && cabal-generator == "hpack" && package.isLocal) ''
    chmod -R u+w $target
    ( cd $target
      ${pkgs.buildPackages.haskell-nix.nix-tools-unchecked}/bin/hpack
    )
  '';
  # When `prePatch`/`postPatch` hooks are defined for a local package
  # we stage the parent directory as well, so hooks like
  # `prePatch = "cd .."` (hadrian) can reach sibling files.  The
  # final tarball still contains only the package's own subdir.
  pkgHasHook = prePatch != null || postPatch != null;
  # `cabalFile` (X-revised .cabal from `package-description-override`)
  # is intentionally NOT a trigger for repacking: revisions are
  # carried by the slicing repo's `00-index.tar.gz` instead, leaving
  # the tarball bytes equal to upstream hackage so cabal computes
  # the same `pkgHashSourceHash` here as it would against real
  # hackage.  Patches and pre/postPatch hooks still go through the
  # repack path because they actually change source bytes.
  pkgUntouched =
    !package.isLocal && resolvedPatches == [] && prePatch == null && postPatch == null;
  pkgTarball =
    if pkgUntouched && lib.hasSuffix ".tar.gz" (src.name or "") then src
    else if pkgUntouched then
      # Non-local src that is not provably a tarball — e.g. a
      # source-repository-package SUBDIR (Cabal-syntax inside the
      # stable-haskell Cabal SRP), which is a DIRECTORY.  The slicing
      # repo symlinks pkgTarball as `<name>-<ver>.tar.gz` and runs
      # `tar -xOzf` on it, so passing the directory through fails
      # "Cannot read: Is a directory".  Normalize: pack a directory
      # into a real tarball (deterministic flags, `<name>-<ver>/`
      # top-level dir per the tarball convention); pass a file through
      # unchanged.  Hackage fetches keep the direct `src` path above
      # (their .name ends in .tar.gz), so their slice hashes don't move.
      runCommand "v2-tar-${pkgName}-${pkgVersion}"
        { preferLocalBuild = true; }
        ''
          if [ -d ${src} ]; then
            workDir=$(mktemp -d)
            mkdir -p $workDir/${pkgName}-${pkgVersion}
            cp -rL ${src}/. $workDir/${pkgName}-${pkgVersion}/
            chmod -R u+w $workDir
            tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
                -czf $out -C $workDir ${pkgName}-${pkgVersion}
          else
            cp ${src} $out
          fi
        ''
    else runCommand "v2-tar-${pkgName}-${pkgVersion}"
           { preferLocalBuild = true; }
           # `cp -L` resolves symlinks against `${src}` at copy time.
           # Local source trees often have symlinks like
           # `lib/wallet/specifications -> ../../specifications`
           # (cardano-wallet) pointing outside the per-package subdir;
           # without `-L`, those symlinks survive into the tarball and
           # cabal-install 3.16+ rejects them at extract time as
           # [Cabal-7125] "Unsafe link target in tar archive".  Using
           # `-L` against the nix-store source resolves the targets
           # while we still have access to them, inlining the content.
           (if package.isLocal && pkgHasHook
            then ''
              workDir=$(mktemp -d)
              # Copy the full enclosing source (includes siblings) so
              # patches that reach outside the package dir still apply.
              srcParent=$(dirname ${src})
              pkgSubDir=$(basename ${src})
              cp -rL --no-preserve=mode $srcParent/. $workDir/
              chmod -R u+w $workDir
              target=$workDir/$pkgSubDir
              ${cabalFileOverride}
              ${patchApplyScript}
              ${hpackScript}
              # Rename the package subdir to match the tarball convention
              # so cabal sees `<name>-<version>/` when unpacking.
              mv $target $workDir/${pkgName}-${pkgVersion}
              tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
                  -czf $out -C $workDir ${pkgName}-${pkgVersion}
            ''
            else ''
              workDir=$(mktemp -d)
              target=$workDir/${pkgName}-${pkgVersion}
              mkdir -p $target
              ${if package.isLocal
                then "cp -rL ${src}/. $target/"
                else "tar -xzf ${src} --strip-components=1 -C $target"}
              ${cabalFileOverride}
              ${patchApplyScript}
              ${hpackScript}
              tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
                  -czf $out -C $workDir ${pkgName}-${pkgVersion}
            '');

  # Direct haskell library deps of this component.  Drop the
  # same-package self-reference that `lookupDependency` adds for
  # Custom build-type packages (a bare package record pointing at
  # ourselves), but keep sibling-component v2 slices that share
  # this package's name — those are sublibs (or sibling libraries)
  # that we genuinely depend on.  Slices are flagged via
  # `passthru.isSlice`; bare package records are not.
  directLibDeps = lib.filter (d:
    d ? identifier
    && ( (d.passthru.isSlice or false)        # sibling component, keep
         || d.identifier.name != pkgName       # external dep, keep
         # For a sublib, a same-pkg `hsPkgs.<pkg>` entry resolves to
         # the *main lib* (not this sublib), so it's a real upstream
         # dep we need composed in.  For the main lib slice itself
         # the same entry would be self-referential — drop it there.
         || isSublib
       )
  ) (component.depends or []);

  # Cabal's solver plans *every* library, sublib, and exe of every
  # package it sees — their build-depends all have to be solvable, not
  # just the ones we target.  Tests/benches are gated behind stanzas
  # and stay off by default, so their deps don't matter (unless we're
  # building a test/bench slice).  Gather deps from every sibling
  # component that the solver will plan, so the slicing repo has all
  # the tarballs cabal might need.
  #
  # Uses hsPkgs.<name>.components.<kind>.<n>.config.depends because
  # that's where plan.nix populates the resolved dep list — pkgSet
  # (the module config) doesn't carry it.
  # Cabal's solver plans every component of every package it sees,
  # so when the slice targets `:pkg:foo:lib:bar` the solver also has
  # to satisfy the deps of `foo`'s *other* components (library's
  # sublibs, exes, custom-setup's `setup-depends`, etc.).
  #
  # The current component's own deps come through
  # `component.depends` as pkg-derivation refs; sibling-component
  # deps come through `homeDependIds` as `{ name; version; }`
  # pairs (resolved from plan-json by hspkg-builder — kept as raw
  # strings so we don't have to force module options that could
  # reach back into our own construction).
  externalDeps = lib.filter
    (d: d ? identifier && d.identifier.name != pkgName)
    (component.depends or []);
  # Flattened `{ name; version; }` list of the solver's required
  # package-pins — current-component deps + sibling deps.  Each
  # entry has a top-level `.name`, so `uniqueWithName` partitions
  # by name and only falls back to a per-bucket scan for collisions.
  #
  # Sibling `exe-depends` (build-tools) are included on both native
  # and cross: cabal's solver requires the build-tool package (and
  # its lib closure) to be in the slicing repo's index just to
  # resolve `build-tool-depends: <pkg>:<exe>` as a plan goal —
  # `--with-PROG=PATH` only kicks in at build time, after the
  # solver has succeeded.  Leaving them out fails the solver with
  # `unknown package: <pkg>:<exe>:exe.<exe> (dependency of …)`.
  #
  # On NATIVE the plan-nix unit-ids match what the slice's cabal
  # computes, so cabal recognises the pre-installed tool in the
  # cabal-store and doesn't re-build.  On CROSS the unit-ids
  # diverge (cross GHC info ≠ build-platform GHC info), so cabal
  # would otherwise plan a from-source rebuild; `withProgFlags`
  # below adds `--configure-option=--with-<exe>=<bb-slice>/bin/<exe>`
  # per transitive build-tool so cabal short-circuits the build.
  # The post-install "exactly one captured unit-id" check then
  # verifies cabal really did skip the tool's build.
  externalDepIds = haskellLib.uniqueWithName
    (map (d: { name = d.identifier.name; version = d.identifier.version; }) externalDeps
     ++ lib.filter (nv: nv.name != pkgName)
          (homeDependIdsInClosure ++ homeBuildToolIds));

  # An entry in `component.depends` is either a dep package record
  # (has `.components`, e.g. `hsPkgs.provider`) or a v2 slice
  # itself (sublib components arrive this way under
  # `builderVersion = 2`, since `hsPkgs.<pkg>.components.sublibs.<n>`
  # is already a slice).  Handle both: prefer the package's
  # library when available, otherwise fall back to `d` itself if
  # it's already a slice.  This also avoids an `hsPkgs.<name>`
  # re-lookup, which can blow the eval stack on large projects
  # (ghc / hadrian).  The component IS the v2 slice when
  # `builderVersion = 2`.
  directDepSlices = haskellLib.uniqueWithName (map (d:
    let
      depLib = d.components.library or null;
      asSlice = if d.passthru.isSlice or false then d else null;
      slice = if depLib != null then depLib else asSlice;
    in if slice == null
        then throw ("comp-v2-builder: ${pkgName}:${componentKindLabel}:${componentName} depends on ${d.identifier.name}, which has no v2 slice"
          # A package record without a library: unplanned or unbuildable (#1379).
          + lib.optionalString (d ? components) (".  " + haskellLib.unplannedLibraryMessage d.identifier.name))
        else slice
  ) directLibDeps);

  # Packages with pre-2.0 Cabal-version share a single UnitId across
  # all their components (the pre-per-component install model), so
  # composing the library's v2 slice into the starting store for an
  # exe/test/bench would make cabal think the *exe* is also already
  # installed — it prints "Up to date" and skips the build.  For
  # those packages we fall back to building lib + exe together in
  # the same slice.
  #
  # `package.specVersion` is Cabal's parsed `cabal-version:` field.
  useSharedUnit =
    let v = package.specVersion or "0"; in
    builtins.compareVersions v "2.0" < 0;

  # For non-library components of modern Cabal-version packages,
  # compose the same-package library's v2 slice into the starting
  # store so cabal reuses it instead of rebuilding.  For shared-unit
  # (pre-2.0) packages we skip the pre-install (collides at UnitId)
  # but still want the library's transitive dep tarballs in the
  # slicing repo, so the solver can plan the library's `build-depends`
  # when cabal pulls it in via `extra-packages:`.
  ownLibPkg = lookupDepPkg hsPkgs pkgName pkgVersion;
  ownLibV2 =
    if isLibrary || ownLibPkg == null
       || !(ownLibPkg ? components)
       || !(ownLibPkg.components ? library)
       || ownLibPkg.components.library == null
    then null
    else ownLibPkg.components.library;
  # Compose the package's own library slice into the starting store
  # for non-library components (exe / test / bench).  Sublibs pick
  # up the main lib through `directDepSlices` instead — only when
  # the sublib's `component.depends` actually references it (via
  # the `hsPkgs.<pkg>` package record).  Going through that path
  # avoids adding a sublib → main edge for sublibs that don't
  # depend on the main lib (e.g. `attoparsec:internal`); doing it
  # unconditionally would create a sublib ↔ main cycle whenever
  # the main lib re-exports the sublib.
  ownLibSlice =
    if isLibrary then null else ownLibV2;

  # Build-tool-depends: any of this component's `build-tools` that
  # resolved to a v2 exe slice (under `builderVersion = 2` this is
  # the common case for haskell-nix-provided tools like alex/happy).
  # Composing them into the starting store lets cabal's solver find
  # them as "already installed" — without that, the solver fails to
  # resolve `build-tool-depends: alex:alex` etc.
  buildToolSlices = lib.filter
    (t: t != null
        && t ? passthru
        && (t.passthru.isSlice or false))
    extraNativeBuildInputs;

  # Transitive build-tool slices: every exe unit in this slice's
  # `allDepClosure` (which already follows `exe-depends`) whose slice
  # we can resolve via `hsPkgs.<pkg>.components.exes.<exe>`.  Without
  # composing these in, cabal's solver in the slice sees the exe in
  # `extra-packages:` (because it landed in `libConstraintPins` via
  # the same `allDepClosure` walk), can't find a matching unit-id in
  # the cabal-store, and rebuilds the whole package — wasted work
  # since our standalone slice already produced the prebuilt unit.
  # Concretely: typed-protocols transitively reaches `hsc2hs` via a
  # lib dep's `exe-depends`; before this, hsc2hs got rebuilt inside
  # every typed-protocols / consumer slice.
  # `{ name; pkgName; targetSlice; buildSlice }` records for every
  # transitive build-tool exe reached in `allDepClosure`.  Two slices
  # per tool serve different roles on cross:
  #
  #   * `targetSlice` — the v2 slice built FOR THIS PROJECT'S target
  #     (cross) hsPkgs.  Its plan-nix-computed unit-id matches what
  #     this slice's cabal v2-build will compute for the tool
  #     (same dummy-ghc / real-ghc parity verified by
  #     `tests.dummy-ghc-info`).  Composed into the starting
  #     cabal-store so cabal recognises the tool as already
  #     installed and skips re-building.  The slice's binary
  #     targets the cross platform — it isn't directly runnable on
  #     the build host — but cabal only needs the unit-id-keyed dir
  #     to be present in the store; actual invocation goes through
  #     `--with-PROG=PATH` via `withProgFlags` below.
  #
  #   * `buildSlice` — the v2 slice built for the build-build
  #     platform (`hsPkgs.pkgsBuildBuild`).  Its binary is runnable
  #     on the build host.  Used for `--with-PROG=PATH` so cabal
  #     invokes a working binary when processing `.hsc` / `.x` /
  #     `.y` files in the slice.
  #
  # On NATIVE the two are the same slice (pkgsBuildBuild == hsPkgs).
  # Empty for two-stage (stable-haskell -target cross) plans: build tools
  # are BUILD-stage inplace units the consuming slice's cabal builds
  # itself (see load-cabal-plan's lookupDependencies) — there are no
  # per-tool slices whose unit ids a consumer's re-plan would recognise.
  transitiveBuildToolEntries =
    lib.optionals (!isTwoStagePlan) transitiveBuildToolEntries';
  transitiveBuildToolEntries' =
    let raw = lib.concatMap (e:
      let p   = e.entry;
          pn  = p.pkg-name or "";
          cn  = p.component-name or "";
          cnPrefix = "exe:";
          isExe = lib.hasPrefix cnPrefix cn;
          exeName = builtins.substring (builtins.stringLength cnPrefix)
                      (builtins.stringLength cn - builtins.stringLength cnPrefix) cn;
          targetPkg = lookupDepPkg hsPkgs pn (p.pkg-version or null);
          targetExes = if targetPkg != null && targetPkg ? components
                         && targetPkg.components ? exes
                       then targetPkg.components.exes else {};
          targetSlice = targetExes.${exeName} or null;
          buildPkg = lookupDepPkg hsPkgs.pkgsBuildBuild pn (p.pkg-version or null);
          buildExes = if buildPkg != null && buildPkg ? components
                        && buildPkg.components ? exes
                      then buildPkg.components.exes else {};
          buildSlice = buildExes.${exeName} or null;
      in if pn != "" && pn != pkgName && isExe
            && targetSlice != null && buildSlice != null
         then [ { name = exeName; pkgName = pn; inherit targetSlice buildSlice; } ]
         else []
    ) allDepClosure;
    in haskellLib.uniqueWithName raw;

  # Slices composed into the starting cabal-store.  Cross-target
  # slices on cross (so cabal recognises the matching unit-id);
  # build-build slices on native (which is the same drv).
  transitiveBuildToolSlices = map (e: e.targetSlice) transitiveBuildToolEntries;

  # Cross-only: `--with-PROG=PATH` flags appended to `cabal v2-build`
  # for each transitive build-tool, pointing cabal at the build-build
  # binary (the composed `targetSlice` is the cross-target which
  # can't run on the build host).  Both the slice's cabal v2-build
  # and the v2 shell's cabal use these flags so the runtime
  # invocation path is consistent.
  #
  # `cabal v2-build` accepts `--with-PROG=PATH` for any program
  # registered in its built-in `ProgramDb` (cabal source:
  # `Distribution.Simple.Program.Builtin.builtinPrograms`).  For
  # programs not in that list cabal's `userSpecifyPath` silently
  # ignores the flag (`Map.update` over `unconfiguredProgs` is a
  # no-op when the program isn't known), so we have to wrap those
  # in `--configure-option=` and let per-package `Setup configure`
  # apply them after `build-tool-depends` registration extends the
  # package-local `ProgramDb`.
  #
  # Split the build-tool entries on this distinction so each flag
  # reaches cabal in the form cabal actually honours:
  #
  #   * built-in (alex / happy / c2hs / hsc2hs / cpphs / ...):
  #     emit `--with-NAME=PATH` directly to `cabal v2-build`.
  #     Wrapping these in `--configure-option=` would make cabal
  #     forward them to Setup configure, where they reach Setup's
  #     ProgramDb correctly — but cabal v2-build's own program
  #     resolution (used for the per-slice tool invocations like
  #     "Running alex…") wouldn't see the override and would fall
  #     back to the cross-target binary in the bundled cabal-store.
  #     Concretely: language-c's alex preprocess step would run
  #     the cross-target alex (Exec format error on x86_64).
  #   * non-built-in (arbitrary `pkga-exe`-style entries):
  #     cabal v2-build rejects these CLI flags as
  #     `unrecognized 'v2-build' option` — wrap them in
  #     `--configure-option=` so cabal threads them through to
  #     per-package Setup configure, which DOES accept arbitrary
  #     `--with-PROG=PATH` once the package declares the program
  #     in `build-tool-depends`.
  #
  # We don't emit these as a `package *  configure-options:` block
  # in cabal.project — that would enter EVERY package's
  # `pkgHashConfigureOptions`, forking UnitIds for packages that
  # don't declare the build-tool against what their own slices
  # computed.  Keeping the flag at the cabal-CLI level lets
  # cabal apply it only where the program is actually invoked.
  cabalBuiltinPrograms = [
    "ghc" "runghc" "ghc-pkg" "ghcjs" "ghcjs-pkg" "jhc" "uhc"
    "hpc" "hscolour" "doctest" "haddock" "happy" "alex"
    "hsc2hs" "c2hs" "cpphs" "gcc" "gpp" "ar" "strip" "ld"
    "tar" "cpp" "pkg-config"
  ];
  withProgFlags =
    lib.optionalString isCross
      (lib.concatMapStrings (e:
        let withFlag = "--with-${e.name}=${e.buildSlice}/bin/${e.name}";
        in if lib.elem e.name cabalBuiltinPrograms
           then " ${withFlag}"
           else " --configure-option=${withFlag}"
      ) transitiveBuildToolEntries);

  # Package names whose presence in the slice's plan / captured-unit
  # set is tolerated — CROSS ONLY.  On cross this is a safety net:
  # normally cabal recognises each transitive build-tool's
  # `targetSlice` (matching unit-id) and neither plans nor builds it,
  # but a uid mismatch can slip through legitimately (`--with-PROG`
  # flags enter the real cabal's pkgHashProgramArgs but not
  # plan-nix's), and we accept the in-slice tool build rather than
  # fail.  On NATIVE the check is strict: the fork writes a unit
  # receipt for every store install and its plan-improvement pass
  # flips receipt-backed units (including executables, which the
  # solver can never see as installed) to Installed — so a pre-built
  # tool appearing in the slice's will-build set means its re-solved
  # unit id diverged from the composed slice's, which is a real bug
  # to fix, never to tolerate.
  allowedBuildToolPackages =
    lib.optionals isCross
      (lib.unique (map (e: e.pkgName) transitiveBuildToolEntries));

  # Cross-only: entries fed to `build-cabal-slice.nix`'s
  # `buildToolBinOverlays`.  After the slice composes its starting
  # cabal-store from dep slices (including each tool's cross-target
  # `targetSlice` — needed for cabal's unit-id-keyed lookup), this
  # list tells the slice to overwrite the host-arch `<unit>/bin/<name>`
  # entry with the build-platform binary from `${buildSlice}/bin/${name}`.
  # See `build-cabal-slice.nix` for the rationale.  Empty on native.
  buildToolBinOverlays =
    lib.optionals isCross
      (map (e: { inherit (e) name buildSlice; }) transitiveBuildToolEntries);

  # Look up the v2 slice for a home-dep (sibling-component
  # gathered via plan.json).  Prefer the library, fall back to a
  # sublib, then to any exe — mirrors `depTransitiveTarballsOf`
  # below.  Sublib fallback covers packages whose `.cabal` only
  # defines named sublibraries (no main library) — e.g.
  # `cardano-wallet-ui` exports `cardano-wallet-ui:common` and
  # `cardano-wallet-ui:shelley` but has no main `library`.
  # Returns null when none is present (boot / pre-existing pkgs).
  # Prefer the exact plan-unit id when hspkg-builder supplied one: a
  # name+version lookup goes through the plan-`targets` name redirects,
  # which for a package that ALSO has a pre-existing boot twin (parsec,
  # Cabal) point at that other, unbuildable unit — the id is exact
  # (same reasoning as `setupDepSlices`).
  homeDepSliceOf = nv:
    let byId = if (nv.id or null) != null then hsPkgs.${nv.id} or null else null;
    in sliceOfPkgRecord
         (if byId != null then byId
          else lookupDepPkg hsPkgs nv.name (nv.version or null));
  sliceOfPkgRecord = dPkg:
    let depLib = if dPkg != null
                    && (dPkg ? components)
                    && (dPkg.components ? library)
                    && (dPkg.components.library != null)
                 then dPkg.components.library else null;
        sublibsMap = if dPkg != null && (dPkg ? components) && (dPkg.components ? sublibs)
                     then dPkg.components.sublibs else {};
        anySublib = lib.findFirst (v: v != null) null
          (lib.attrValues sublibsMap);
        # Exe-only fallback (build-tool packages like hsc2hs / alex /
        # happy): look up the slice on the CROSS hsPkgs so the
        # composed unit-id matches what this slice's cabal computes
        # for the tool (cross dummy-ghc parity, see
        # `transitiveBuildToolEntries`).  The slice's cross-target
        # binary isn't runnable on the build host, but cabal only
        # needs the unit-id-keyed dir to be present in the
        # cabal-store; `withProgFlags` provides the build-build
        # binary cabal actually invokes.
        exesMap = if dPkg != null && (dPkg ? components) && (dPkg.components ? exes)
                  then dPkg.components.exes else {};
        anyExe = lib.findFirst (v: v != null) null
          (lib.attrValues exesMap);
    in if depLib != null then depLib
       else if anySublib != null then anySublib
       else anyExe;
  # Two-stage (stable-haskell -target cross) plans build their build-tools
  # as BUILD-stage inplace units inside each consuming slice's own cabal
  # (load-cabal-plan gives such plans EMPTY `build-tools` — see its
  # `lookupDependencies`).  Resolving a build-tool exe id here through the
  # `anyExe` fallback yields the HOST exe slice, which itself lib-depends on
  # THIS package's host library — e.g. process's `exe-depends: hsc2hs` →
  # host hsc2hs slice → host process slice → eval-time infinite recursion.
  # So drop the build-tool-ONLY ids (those that are not also genuine lib
  # deps) from the store-composition set for two-stage plans; the runnable
  # tool comes from `homeDepExeSlices` (pkgsBuildBuild) instead.
  # Sibling lib deps INSIDE this component's own dependency closure —
  # `allDepClosure` is seeded from this component's unit alone (see
  # `ourPlanUnits`), so membership by name partitions `homeDependIds`:
  # in-closure sibling deps compose as built slices below (their units
  # ARE needed to build the target — e.g. a test component's own deps,
  # which arrive only via `homeDependIds`); out-of-closure ones are
  # solver-only and travel source-staged via `metadataSourceFrags`.
  componentClosureNames =
    lib.unique (map (e: e.entry.pkg-name or "") allDepClosure);
  # Keep a sibling dep as a BUILT slice when it is in this component's
  # own closure, and ALSO when the metadata path could not stage it (no
  # hackage sdist — GHC-boot universes): only deps that actually moved
  # to the source-only index may leave the built-slice path, or the
  # slice's solve hits "unknown package: <sibling dep>".
  homeDependIdsInClosure =
    lib.filter (nv:
      lib.elem nv.name componentClosureNames
      || !(lib.elem nv.name metadataStagedNames)) homeDependIds;

  homeLibDepNames =
    map (d: d.identifier.name) externalDeps
    ++ map (nv: nv.name) homeDependIds;
  buildToolOnlyNames = lib.filter (n: !(lib.elem n homeLibDepNames))
    (map (nv: nv.name) homeBuildToolIds);
  homeStoreDepIds =
    if isTwoStagePlan
    then lib.filter (nv: !(lib.elem nv.name buildToolOnlyNames)) externalDepIds
    else externalDepIds;
  homeDepSlices = lib.filter (s: s != null)
    (map homeDepSliceOf homeStoreDepIds);

  # Complete set of this component's *direct library* `depends` slices —
  # the constraints scope.  `directDepSlices` alone (from
  # `component.depends`) is empty for test/bench components, whose deps
  # arrive via `homeDependIds`; that gap meant a reinstalled lib reached
  # only through a sibling/own-lib edge never got a `source` constraint.
  # So we also fold in the home *library* deps (not build tools) and, for
  # non-library components, the package's own library.  Following these
  # slices' pointers at build time reaches every transitive library dep,
  # so each is pinned `<pkg> ==<ver>, <pkg> source` — and `source` is what
  # forces cabal off a GHC-bundled `-inplace` unit when a boot library is
  # reinstalled at the *same* version (e.g. `text-2.1.4`).  `exe-depends`
  # (build tools) are deliberately excluded here: they contribute source
  # (via the repo) but no constraints.
  homeLibDepSlices = lib.filter (s: s != null)
    (map homeDepSliceOf (lib.filter (nv: nv.name != pkgName) homeDependIdsInClosure));
  dependsSlices = haskellLib.uniqueWithName
    (directDepSlices
     ++ homeLibDepSlices
     ++ lib.optional (ownLibSlice != null) ownLibSlice);

  # Custom-setup deps that plan-nix resolved to SOURCE packages need their
  # slices composed in like library deps.  This happens when a package's
  # `setup-depends` excludes the GHC-bundled Cabal (e.g. entropy's
  # `Cabal < 3.17` against a compiler bundling 3.17): the plan picks a
  # from-hackage Cabal, so the slice's per-package setup solver has the
  # `<pkg>:setup.Cabal ==<ver>` pin (ownSetupConstraints) but — without
  # the dep slice's repo fragment and store unit — no candidate that can
  # satisfy it, failing with "rejecting: <pkg>:setup.Cabal-<bundled>
  # /installed-inplace".  Installed (pre-existing) setup deps need
  # nothing.  These go in `depSlices` (store + slicing repo) but NOT
  # `dependsSlices`: a `Cabal source` constraint there would force
  # from-source Cabal onto the slice's regular library scope, diverging
  # from the plan.
  # Resolved by the plan unit id directly (`hsPkgs.${id}` is keyed for
  # every install-plan entry): a name+version lookup would go through
  # the plan-`targets` name redirects, which for a package that ALSO has
  # a pre-existing boot unit (Cabal!) point at that other, unbuildable
  # unit — the id is exact.
  #
  # The whole setup CLOSURE (`setupDepClosureIds`, walked on the
  # BUILD-twin index), not just the direct `setup-depends`: the setup
  # solve needs every transitive setup dep's source in the slicing repo
  # and its unit composable, including build-stage-only units no lib
  # edge reaches (the gi-* codegen setups' haskell-gi-overloading-1.0,
  # while the host libs use 0.0).  For ids whose slice is the HOST twin
  # that's still the right compose — same name+version+source; the
  # setup scope re-solves and builds its build-stage copy in-slice
  # (tolerated by the unit-id checks) with the source it needs.
  setupDepSlices = lib.filter (s: s != null) (map (id:
    let q = planJsonByPlanIdBuild'.${id} or null;
    in if q == null || (q.type or "") != "configured" || !(q ? pkg-name)
       then null
       else sliceOfPkgRecord (hsPkgs.${id} or null)
  ) setupDepClosureIds);

  # The slice's *direct* dep slices.  Transitive closure is
  # reconstructed at build time from each slice's
  # `$out/nix-support/transitive-deps` file (see
  # `build-cabal-slice.nix`), so we deliberately don't expand it
  # here — keeping the nix-side eval cheap and the buildInputs list
  # short.
  # v1's `additional-prebuilt-depends` mechanism (comp-builder.nix):
  # extra component derivations whose registrations must be present in
  # the package db even though the plan has no dependency edge — GHC
  # 9.14's unit wiring demands every rts WAY sublib be resolvable as
  # soon as ghc-internal.conf is in scope (see the
  # `additional-prebuilt-depends` module in overlays/stable-haskell.nix,
  # which sets it for the stage2 boot libs).  For v2, compose their
  # slices into the starting store db.  They contribute no constraints
  # and no `extra-packages:` entry — they are never solver goals, the
  # db presence is all GHC needs.
  additionalPrebuiltSlices = lib.filter
    (d: d != null && (d.passthru.isSlice or false))
    (component.additional-prebuilt-depends or []);

  depSlices = haskellLib.uniqueWithName
    (directDepSlices
     ++ additionalPrebuiltSlices
     ++ lib.optional (ownLibSlice != null) ownLibSlice
     # On cross, `buildToolSlices` are the *build-build* (pkgsBuildBuild)
     # tool slices.  Propagating them would walk their `repo-frag`
     # (source `.tar.gz` + index `.cabal`) into this cross slice's
     # slicing repo, giving cabal a second candidate for each tool
     # (e.g. a build-build `hsc2hs` alongside the cross one) and forking
     # dependent unit-ids — a package's build-tool exe-dep can resolve
     # to the build-build unit, which feeds the consumer's UnitId but
     # never appears in its Setup configure args.  The cross store unit
     # comes from `transitiveBuildToolSlices` (the cross `targetSlice`)
     # and the runnable binary from `buildToolBinOverlays` /
     # `withProgFlags` (both reference `buildSlice` directly), so the
     # build-build slices must stay out of `propagatedBuildInputs` here.
     ++ lib.optionals (!isCross) buildToolSlices
     ++ transitiveBuildToolSlices
     ++ homeDepSlices
     ++ setupDepSlices);


  # native-build inputs from the target component's config.  The GHC
  # JavaScript backend links no host C libraries (its cbits/RTS go through
  # emscripten inside the toolchain) and nixpkgs gives the ghcjs platform no
  # `stdenv.cc`, so *referencing* any of these from the target pkg-set throws
  # "no C compiler provided for this platform".  Empty them for ghcjs at the
  # source, so every downstream use (extraBuildInputs, the propagatedBuildInputs
  # `propagated`, the cabal.project extra-lib-dirs emission) is native-free.
  isJsTarget = stdenv.hostPlatform.isGhcjs;
  libs       = lib.optionals (!isJsTarget) (lib.flatten (component.libs or []));
  frameworks = lib.optionals (!isJsTarget) (component.frameworks or []);
  pkgconfig  = lib.optionals (!isJsTarget) (map pkgs.lib.getDev (builtins.concatLists (component.pkgconfig or [])));

  # Paths post-injected into this lib slice's registered `.conf` so
  # GHC's runtime linker can dlopen each `extra-libraries:` entry
  # under TH eval / `-fexternal-interpreter`.  Mirrors v1's
  # `make-config-files.nix:flagsAndConfig "extra-lib-dirs"` — same
  # set (component.libs' `lib/` outputs), but injected post-register
  # instead of pre-configure to keep the slice's unit-id equal to
  # plan-nix's (configure-time `--extra-lib-dirs` lands in
  # `pkgHashExtraLibDirs` and would diverge).  See
  # `build-cabal-slice.nix:confLibraryDirs` for the rewrite.
  confLibraryDirs =
    map (p: "${lib.getLib p}/lib") libs
    ++ lib.optionals stdenv.hostPlatform.isWindows
         # Windows ships DLLs / import libs under `bin/` rather
         # than `lib/`.  Mirrors v1's runtime `[ -d $bin ]` check
         # in `make-config-files.nix:81-90`.
         (map (p: "${lib.getBin p}/bin") libs);
  buildTools = component.build-tools or [];
  resolvedBuildTools = lib.concatMap (p:
    let resolved = if builtins.isFunction p
          then p { inherit (package.identifier) version; }
          else p;
    in if resolved == null then []
       else if resolved.isHaskell or false
         then builtins.attrValues (resolved.components.exes or {})
       else [ resolved ]
  ) (lib.filter (p: p != null) buildTools);

  # Resolve a home-dep {name;version} (sibling-component from
  # plan-json, includes setup-depends) to the same "pkg record"
  # shape that component.depends gives us.
  homeDepPkgOf = nv:
    let byId = if (nv.id or null) != null then hsPkgs.${nv.id} or null else null;
    in if byId != null then byId
       else lookupDepPkg hsPkgs nv.name (nv.version or null);
  homeDepPkgs = lib.filter (p: p != null) (map homeDepPkgOf homeDependIdsInClosure);

  # SysLibs of a component — the same shape we feed to
  # `extraBuildInputs` and `cabal.project`'s `extra-include-dirs:`.
  sysLibsOf = c:
    (lib.flatten (c.libs or []))
    ++ (c.frameworks or [])
    ++ (map pkgs.lib.getDev (builtins.concatLists (c.pkgconfig or [])));

  # Walk the lib-dep tree to collect every transitive `libs` /
  # `frameworks` / `pkgconfig` entry (deduped by canonical pkg
  # name).  Mostly redundant now that `depSlices` are in
  # `propagatedBuildInputs` (see `build-cabal-slice.nix`) — stdenv's
  # chain already carries each slice's own `propagated` sysLibs to
  # consumers, and normal nixpkgs deps like `lmdb` / `liburing` /
  # `gmp` carry `__spliced` so they auto-swap to the consumer's
  # pkg-set under cross-compilation.  We keep the manual walk as a
  # belt-and-braces backup that covers cases the chain misses
  # (e.g. a sublib's pkgconfig dep that the main lib's slice
  # doesn't propagate).
  transitiveDepLibs =
    # The GHC JavaScript backend (javascript-unknown-ghcjs) has no C toolchain
    # — nixpkgs gives that platform no `stdenv.cc` — so merely *realizing* a
    # native C lib / framework / pkgconfig dep from the target pkg-set throws
    # "no C compiler provided for this platform".  When cross-compiling to JS
    # from a darwin build host this walk would drag every native C dep in the
    # flattened plan closure (glib/gtk via gi-*, ncurses via terminfo,
    # hfsevents via fsnotify, …) into the slice's `__impureHostDeps`, failing
    # the whole eval.  A JS slice never links native C libs, and this walk is a
    # redundant belt-and-braces backup anyway (see the note above), so skip it
    # for ghcjs; the `depSlices` propagatedBuildInputs chain still covers the
    # native platforms.  (`stdenv` here is the component's *target* stdenv —
    # `pkgs.stdenv` would be the darwin build host and never match.)
    if stdenv.hostPlatform.isGhcjs then [] else
    let
      go = acc: deps:
        lib.foldl' (acc: d:
          let
            name = d.identifier.name or "";
            libComp = d.components.library.config or null;
            childSysLibs = if libComp == null then [] else sysLibsOf libComp;
            childDeps    = if libComp == null then [] else (libComp.depends or []);
          in if name == "" || lib.elem name acc.seen
             then acc
             else let acc' = {
                        seen = acc.seen ++ [ name ];
                        libs = acc.libs ++ childSysLibs;
                      };
                  in go acc' childDeps
        ) acc deps;
    in (go { seen = [ pkgName ]; libs = []; }
         (directLibDeps ++ homeDepPkgs)).libs;

  # When the host needs a wrapped ghc for cross-TH (windows), the
  # wineIservWrapper symlinks `*.dll` files out of every path in
  # `pkgsHostTarget` into REMOTE_ISERV before launching wine.  For
  # `iserv-proxy-interpreter.exe`'s own runtime DLLs to be visible
  # there, the libs that linked it (mingw_w64_pthreads, gmp, ...)
  # must appear in our slice's buildInputs.  `templateHaskell.iservRuntimeLibs`
  # carries that list.
  iservRuntimeLibs =
    if templateHaskell != null && templateHaskell.iservRuntimeLibs or null != null
    then templateHaskell.iservRuntimeLibs
    else [];
  # Direct sysLibs plus the transitive closure walked above.  The
  # transitive set is mostly redundant given the `propagatedBuildInputs`
  # chain on `depSlices`, but it's cheap to keep as a defence against
  # gaps in the chain (e.g. when a slice's main lib doesn't carry the
  # pkgconfig deps of one of its sublibs forward).
  extraBuildInputs = haskellLib.uniqueWithName
    (lib.filter (x: x != null)
      (libs ++ frameworks ++ pkgconfig ++ transitiveDepLibs ++ iservRuntimeLibs));

  # Store paths named in this package's own `extra-lib-dirs:` /
  # `extra-include-dirs:` (from `cabalProjectLocal`; re-emitted verbatim by
  # `extraLibDirsBlockFor`).  They reach us through plan-nix's JSON, which
  # carries no string context, so without this the slice's cabal.project
  # names a path its sandbox does not contain — e.g. a vendored SDK's
  # headers: "fatal error: WebView2.h: No such file or directory".
  # Re-attach context to each path's store root so it becomes an input.
  # Only this package's slice changes (and only if it names such a path).
  extraDirInputs =
    let
      roots = lib.unique (lib.concatMap (d:
        let m = builtins.match "(${builtins.storeDir}/[^/]+).*" d;
        in if m == null then [] else m)
        (extraLibDirsOf pkgName ++ extraIncludeDirsOf pkgName));
    in map (r: builtins.appendContext r { ${r} = { path = true; }; }) roots;

  # Mirror v1's `make-config-files.nix:65-85`: emit cabal.project
  # `extra-include-dirs:` and `extra-lib-dirs:` for every C-lib /
  # framework / pkgconfig dep so cabal's foreign-library check at
  # configure time can find headers and `.a`/`.so`/`.dll.a` files.
  # cabal/v2-build doesn't auto-derive these from `buildInputs`
  # (unlike `setup configure` which gets them via NIX_LDFLAGS), so
  # we have to spell them out.
  #
  # Emit per-`package <name>` blocks rather than project-level —
  # cabal's `Distribution.Simple.Configure.checkForeignDeps` probe
  # only picks up the per-package values; project-level
  # `extra-lib-dirs:` is ignored by that probe.
  #
  # Critically, each dep's block must list *that dep's* foreign
  # libs — not the union — because each entry enters
  # `pkgHashExtraIncludeDirs` / `pkgHashExtraLibDirs` of the
  # named package.  Mirroring what each dep emitted in *its own*
  # slice keeps the dep's UnitId stable across slices.  Otherwise
  # cabal sees a hash mismatch and rebuilds the dep from source.
  dirsLinesOf = pkgs:
    let nonEmpty = haskellLib.uniqueWithName (lib.filter (x: x != null) pkgs); in
    if nonEmpty == [] then ""
    else
      lib.concatMapStrings (p: "    extra-include-dirs: ${lib.getDev p}/include\n") nonEmpty
      + lib.concatMapStrings (p: "    extra-lib-dirs: ${lib.getLib p}/lib\n") nonEmpty
      # On windows host, libraries often ship the `.dll` and import
      # lib (`.dll.a`) under `bin/` rather than `lib/` (e.g. our
      # test-clib).  Mirror v1's runtime `[ -d $bin ]` check by
      # always emitting the `bin/` entry under windows host —
      # cabal tolerates non-existent search dirs.
      + lib.optionalString stdenv.hostPlatform.isWindows
          (lib.concatMapStrings (p: "    extra-lib-dirs: ${lib.getBin p}/bin\n") nonEmpty);

  # Map of canonical-pkg-name → that pkg's own foreign libs.  Built
  # by walking the dep tree (`directLibDeps ++ homeDepPkgs`) keyed
  # by package name.  The target itself is keyed on `pkgName`.
  #
  # `pkgconfig` deps and plain `c.libs` are deliberately excluded
  # here — both go into `extraBuildInputs` so the slice's wrapped
  # cc / pkg-config can find them at build time, but neither must
  # appear in cabal.project's `extra-include-dirs:` /
  # `extra-lib-dirs:` lines: those land in
  # `pkgHashExtraIncludeDirs` / `pkgHashExtraLibDirs` and would put
  # `/nix/store/<hash>-<lib>-dev/include` paths into the unit-id
  # hash.  plan-to-nix's compute never sees those paths (its
  # cabal.project is just the user's; haskell.nix's `c.libs`
  # overrides come from modules evaluated *after* plan-nix), so
  # any line here forks the unit-id from plan-nix and breaks the
  # checkAgainstPlan check (e.g. `unix-time` on windows cross,
  # which gets `c.libs = [mingw_w64_pthreads]` from
  # `overlays/windows.nix`).  cabal still finds these libs at
  # configure / build time: `pkgconfig` via the wrapped pkg-config,
  # plain `c.libs` via the wrapped cc's NIX_CFLAGS_COMPILE_FOR_TARGET
  # / NIX_LDFLAGS_FOR_TARGET (every entry here is also in
  # `extraBuildInputs`).
  #
  # `c.frameworks` is kept because Darwin frameworks live under
  # `Library/Frameworks/`, not the standard `include/`/`lib/`
  # layout the cc wrapper expects, so cabal really does need
  # `extra-framework-dirs:` to find them.  The unit-id divergence
  # only affects Darwin host builds.
  # Reads a *dependency's* frameworks straight from its component config, so
  # (like the transitiveDepLibs walk) it must be skipped for ghcjs — the ghcjs
  # pkg-set can't realize a darwin framework (e.g. hfsevents' Cocoa), and a JS
  # build emits no `extra-framework-dirs:` anyway.
  pkgcfglessSysLibs = c:
    lib.optionals (!stdenv.hostPlatform.isGhcjs) (c.frameworks or []);
  perPkgForeignLibs =
    let
      go = acc: deps:
        lib.foldl' (acc: d:
          let
            name = d.identifier.name or "";
            libComp = d.components.library.config or null;
            childLibs = if libComp == null then [] else pkgcfglessSysLibs libComp;
            childDeps = if libComp == null then [] else (libComp.depends or []);
          in if name == "" || acc ? ${name}
             then acc
             else go (acc // { ${name} = childLibs; }) childDeps
        ) acc deps;
      # Same exclusions as `pkgcfglessSysLibs` above: only frameworks
      # need cabal-side `extra-framework-dirs:` entries; plain `libs`
      # are picked up by the wrapped cc and would fork unit-ids if
      # listed here.
      selfLibs = haskellLib.uniqueWithName frameworks;
      initial  = { ${pkgName} = selfLibs; };
    in go initial (directLibDeps ++ homeDepPkgs);

  extraIncludeAndLibDirs = lib.concatStrings
    (lib.mapAttrsToList (n: ds:
      let body = dirsLinesOf ds;
      in if body == "" then "" else "package ${n}\n${body}"
    ) perPkgForeignLibs);
  # When we don't pre-install the same-package library into the
  # exe slice's starting store (see ownLibSlice), cabal's plan will
  # re-build the library alongside the exe.  The library may have
  # its own `build-tools` (e.g. alex / happy) that need to be on
  # PATH during its configure step.  Add every home-dep that
  # resolves to an exe slice to `extraNativeBuildInputs` so these
  # tools are available regardless of which pkg components cabal
  # ends up planning.
  #
  # Look the exe up via `hsPkgs.pkgsBuildBuild` rather than the
  # host `hsPkgs` — `homeBuildToolIds` is the sibling-component
  # `exe-depends` set from plan-json (the build-tool-depends
  # entries).  Without this we'd pull in the cross-compiled exe
  # (e.g. `alex.exe`) which can't run on the build platform; v1's
  # `lookupExeDependency` already uses `pkgsBuildBuild` for the
  # same reason.
  homeDepExeSlices =
    let
      exesOf = nv:
        let p = lookupDepPkg hsPkgs.pkgsBuildBuild nv.name (nv.version or null);
        in if p != null && (p ? components) && (p.components ? exes)
           then lib.filter (v: v != null) (lib.attrValues p.components.exes)
           else [];
    in lib.concatMap exesOf homeBuildToolIds;

  extraNativeBuildInputs = haskellLib.uniqueWithName (lib.filter
    (t: t != null)
    (resolvedBuildTools ++ homeDepExeSlices));

  # Two-stage plans give consuming slices EMPTY `build-tools` (see
  # load-cabal-plan): each slice's own cabal builds the build-tool
  # BUILD-stage, against the BUILD compiler's installed boot libs.  For
  # that solve to succeed the tool's SOURCE must be a candidate in the
  # slice's slicing repo — but composing the tool's SLICE would pull its
  # full drv, whose lib-deps point back at this package (host hsc2hs →
  # host process → host Win32 → …), an eval-time infinite recursion.  So
  # contribute only the tool's SOURCE frag (tarball + .cabal): it carries
  # a drv edge to the tool's source tarball, not to the tool's build, so
  # there is no cycle.
  #
  # The set is the EXE units of `allDepClosure` (which follows
  # `exe-depends`), i.e. every build-tool this slice's build reaches,
  # TRANSITIVELY: Cabal-syntax → alex, and alex's own build-tool happy, so
  # the build-scope `build:Cabal-syntax:alex` (and its `…:alex:happy`)
  # goals all resolve.  Resolved by PLAN ID (`hsPkgs.${id}`), not by
  # host name, because these tools are BUILD-stage-only units with no host
  # twin (alex/happy live only under `dist/build/build/…`) — a host-name
  # lookup returns null for them (only hsc2hs happens to have a host
  # twin).  `sliceOfPkgRecord` → the exe slice; reading
  # `.passthru.v2SourceFrag` forces only the tool's source tarball, never
  # its `drvPath`/`depSlices`, so no cycle.  Empty on native / single-stage
  # cross (build tools flow through their normal paths).
  buildToolSourceFrags =
    lib.optionals isTwoStagePlan
      (let
        exeUnits = lib.filter (e:
            lib.hasPrefix "exe:" (e.entry.component-name or "")
            && (e.entry.pkg-name or "") != pkgName)
          allDepClosure;
        exeFrag = e:
          let sl = sliceOfPkgRecord (hsPkgs.${e.key} or null);
          in if sl == null then null else sl.passthru.v2SourceFrag or null;
        # A build-tool exe built BUILD-stage from source inside this slice
        # needs its own library deps in the slice index too — e.g. happy 2.x
        # exe:happy `build-depends: happy-lib`, so staging only happy's own
        # source leaves the solver with "unknown package happy-lib".  Walk
        # each tool exe's dep closure and source-stage the CONFIGURED units.
        #
        # Crucially, walk it on the BUILD-twin-preferring index
        # (`planJsonByPlanIdBuild'`): build tools are build-stage, and a boot
        # library (array, base, containers, …) shows up in that stage as a
        # `pre-existing` unit (installed from the build compiler), which the
        # `type == "configured"` test drops.  Walking the default
        # (HOST-twin-preferring) index would instead resolve the HOST array —
        # `configured` and source-built for the JS target, but with a
        # null-hash boot fetchurl for `src`; staging it makes
        # `extraFragStaging` coerce null→string.  So the build index both
        # picks the right stage AND keeps unrealizable boot sources out.
        # What remains are genuine reinstallable source deps of the tool
        # (happy-lib, …).  `nonReinstallablePkgs` is a cheap extra guard.
        toolDepClosure = builtins.genericClosure {
          startSet = lib.concatMap (e:
            lib.concatMap (id:
              let q = planJsonByPlanIdBuild'.${id} or null;
              in if q == null then [] else [ { key = id; entry = q; } ]
            ) (allDepsOf e.entry)) exeUnits;
          operator = e:
            lib.concatMap (id:
              let q = planJsonByPlanIdBuild'.${id} or null;
              in if q == null then [] else [ { key = id; entry = q; } ]
            ) (allDepsOf e.entry);
        };
        # GHC boot libraries.  The stable-haskell two-stage plan lists them as
        # `configured` (reinstalled from source) in BOTH stages, and
        # `nonReinstallablePkgs` here is only the short builderVersion=2 list,
        # so neither `type` nor that list tells them apart from a genuine
        # source dep.  But the compiler provides them: their build-stage unit
        # resolves to a null-hash boot `src` fetchurl that can't be realized,
        # so staging one coerces null→string in `extraFragStaging`.  A build
        # tool never needs them source-staged — it resolves them from the build
        # compiler's installed db — so exclude the whole set by name.  What
        # remains is the tool's genuine reinstallable lib deps (happy-lib, …).
        ghcBootLibs = [
          "rts" "ghc-prim" "integer-gmp" "integer-simple" "base" "ghc-bignum"
          "system-cxx-std-lib" "ghc-internal" "ghc-boot" "ghc-boot-th" "ghc"
          "ghci" "Cabal" "Cabal-syntax" "array" "binary" "bytestring"
          "containers" "deepseq" "directory" "exceptions" "file-io" "filepath"
          "ghc-compact" "ghc-heap" "ghc-platform" "ghc-experimental" "hpc"
          "mtl" "os-string" "parsec" "pretty" "process" "semaphore-compat"
          "stm" "template-haskell" "terminfo" "text" "time" "transformers"
          "unix" "xhtml" "rts-fs" "rts-headers" "libffi-clib" "Win32"
        ];
        toolLibExclude = ghcBootLibs ++ nonReinstallablePkgs;
        toolLibUnits = lib.filter
          (e: (e.entry.type or "") == "configured"
              && !(builtins.elem (e.entry.pkg-name or "") toolLibExclude))
          toolDepClosure;
        # Resolve on the HOST `hsPkgs` keyed by NAME-VERSION.  A multi-sublib
        # lib (happy-lib) reaches the closure only through its SUBLIB unit ids
        # (frontend, backend-lalr, …), which are not top-level keys; its bare
        # `hsPkgs.happy-lib` / `pkgsBuildBuild.happy-lib` attrs are present but
        # null, and the versioned key exists only on the host set
        # (`hsPkgs."happy-lib-2.1.7"`).  So `lookupDepPkg hsPkgs name version`
        # hits the `byNV` path and returns the real package; its `v2SourceFrag`
        # is the one shared SOURCE tarball for every sublib (stage-independent,
        # so the host set is fine for build-stage staging).  Boot libs — the
        # only packages whose host record has an unrealizable null-hash `src` —
        # are already dropped by `toolLibExclude` above, so they never reach
        # here.
        #
        # Prefer the unit's own id, like `exeFrag` does: `config.packages` is
        # keyed by plan id for every non-`pre-existing` unit, build-stage ones
        # included, so an ordinary library dep of a build tool (c2hs's
        # `language-c`) resolves exactly.  The name path stays as the fallback
        # for the sublib case above, where there is no top-level id key.  It is
        # only a fallback because `hsPkgs.<pkg-name>` is not a package at all —
        # it is the by-name override alias (see
        # modules/install-plan/override-package-by-name.nix), and reading it
        # yields null for anything the plan did not key by that bare name.
        libFrag = e:
          let byId = hsPkgs.${e.key} or null;
              sl = sliceOfPkgRecord (if byId != null then byId
                     else lookupDepPkg hsPkgs
                            (e.entry.pkg-name or "") (e.entry.pkg-version or null));
          in if sl == null then null else sl.passthru.v2SourceFrag or null;
        frags = lib.filter (f: f != null)
          (map exeFrag exeUnits ++ map libFrag toolLibUnits);
      # Dedup by package name (a tool/lib can be reached via several paths;
      # a multi-sublib lib like happy-lib contributes one shared source).
      in lib.attrValues (lib.listToAttrs
           (map (f: lib.nameValuePair f.pkgName f) frags)));

  # ---- metadata-only sibling sources ------------------------------
  # `ourPlanUnits` seeds `allDepClosure` from THIS component's unit
  # only, so composed slices, sysLibs and constraint pins cover exactly
  # the target's dependency closure.  But cabal's solver works at
  # PACKAGE granularity: elaborating `:pkg:<pkg>:exe:<name>` must still
  # SOLVE the deps of the package's other components (leksah's
  # exe:leksah needs gi-webkit even when the target is exe:leksah-warp,
  # whose binary links none of it).  Those solver-only goals need INDEX
  # candidates, not built slices: stage each out-of-closure dep's
  # source (tarball + revised `.cabal`, via `passthru.v2SourceFrag` —
  # no drv edge to the dep's build) into the slicing repo, exactly as
  # two-stage build-tool sources are staged.  They contribute no store
  # unit, no constraint pin, no sysLibs and no `extra-packages:` goal —
  # if cabal unexpectedly tried to BUILD one it would fail loudly on
  # its (absent) system deps rather than silently linking anything.
  # pkg-config versions for these candidates come from
  # `cabalPkgConfigWrapper`'s metadata fallback instead of a realized
  # `.pc` (see overlays/cabal-pkg-config.nix).
  metadataSourceFrags = metadataPartition.frags;
  # Names of the DIRECT sibling deps that moved to the metadata path —
  # the complement partition for `homeDependIdsInClosure`.
  metadataStagedNames = metadataPartition.stagedNames;
  metadataPartition =
    let
      closureKeys = lib.listToAttrs
        (map (e: lib.nameValuePair e.key true) allDepClosure);
      packagePlanUnits = lib.filter
        (p: (p.pkg-name or null) == package.identifier.name
            && (p.pkg-version or null) == package.identifier.version)
        planJson;
      # LIB dependencies only (no `exe-depends`, no setup): build-tool
      # goals are BUILD-stage under two-stage plans and have their own
      # staging machinery (`buildToolSourceFrags`); walking them here
      # would stage build-twin sources (e.g. a tool's `text`) whose
      # index entries then shadow the HOST stage's pre-existing boot
      # instances in the solver.
      metaDepsOf = q:
        (q.depends or [])
        ++ lib.concatMap (c: c.depends or [])
             (lib.attrValues (builtins.removeAttrs (q.components or {}) ["setup"]));
      # The candidate UNIVERSE walks all three edge kinds (lib, setup,
      # exe): a staged candidate's custom-setup deps (xml-conduit's
      # patched-local cabal-doctest) and build tools must be reachable
      # for `subtreeOf`'s per-edge rules below to see them at all.
      universeDepsOf = q:
        metaDepsOf q ++ setupDepsOfEntry q ++ exeDepsOfEntry q;
      packageDepClosure = mkClosureFrom packagePlanUnits universeDepsOf;
      # Pre-existing units (the compiler's boot packages) are never
      # out-of-closure work: the solver takes the installed instance.
      # Counting them made every sibling whose subtree touches a boot
      # package unstageable, so all of them fell back to BUILT slices
      # (vector:lib built tasty, random, optparse-applicative, ... --
      # ten slices nothing links -- for its sibling `benchmarks-O2`).
      outEntries = lib.filter (e:
          !(closureKeys ? ${e.key})
          && (e.entry.pkg-name or "") != pkgName
          && (e.entry.type or "") != "pre-existing")
        packageDepClosure;
      outByKey = lib.listToAttrs (map (e: lib.nameValuePair e.key e) outEntries);
      # Only units with a fetchable, hash-stable hackage sdist
      # (`pkg-src-sha256`) can be reproduced from metadata alone.
      # Anything else — GHC-boot / source-repo units (`transformers`
      # or a reinstalled `ghc-bignum` in bootstrap universes),
      # pre-existing units, `nonReinstallablePkgs` — cannot: boot
      # sources are null-hash fetchurls that throw on interpolation,
      # and the solver could never close their goals from the index.
      # Any configured non-boot unit can be staged: its slice's
      # `pkgTarball` exists for every source shape — hackage sdist,
      # packed source-repository-package (the fork's own `Cabal` in
      # staged setup scopes), and packed LOCAL directories (the
      # project's patched cabal-doctest).  The `nonReinstallablePkgs`
      # guard keeps out GHC-boot units whose srcs can be null-hash
      # fetchurls (throwing on interpolation) and which installed
      # instances satisfy anyway.
      stageable = e:
        (e.entry.type or "") == "configured"
        && !(lib.elem (e.entry.pkg-name or "") nonReinstallablePkgs);
      # The out-of-closure subtree under one unit id.  A staged SOURCE
      # candidate's solve opens more than lib deps: its custom-setup
      # scope (gi-*'s haskell-gi/Cabal) and its build-tool goals
      # (old-time's `build:old-time:hsc2hs:exe.hsc2hs`).  Walk all
      # three edge kinds, never re-entering the in-closure set (those
      # are composed):
      #   * lib/setup edges to PRE-EXISTING units are skipped — the
      #     compiler's installed instance satisfies those goals;
      #   * an exe-depends edge to a pre-existing unit POISONS the
      #     subtree instead: an installed lib registration cannot
      #     provide the `exe:` component a build-tool goal demands,
      #     so the sibling must fall back to a built slice (whose
      #     composition pins everything `installed` and provides the
      #     tool binary via the normal machinery).
      setupDepsOfEntry = q: q.components.setup.depends or [];
      exeDepsOfEntry = q:
        (q.exe-depends or [])
        ++ lib.concatMap (c: c.exe-depends or [])
             (lib.attrValues (builtins.removeAttrs (q.components or {}) ["setup"]));
      subtreeOf = id: map (x: x.key) (builtins.genericClosure {
        startSet = lib.optional (outByKey ? ${id}) { key = id; };
        operator = item:
          if item.key == "POISON" then [] else
          let q = outByKey.${item.key}.entry;
              follow = d: lib.optional (outByKey ? ${d}) { key = d; };
              # Setup goals must close from the index or the installed
              # db: a pre-existing setup dep (the bundled Cabal) is
              # satisfied installed; an out-of-closure configured one
              # joins the subtree; anything else (in-closure ones are
              # composed) is unreachable — poison.
              followSetup = d:
                if closureKeys ? ${d} then []
                else if outByKey ? ${d} then follow d
                else if ((planJsonByPlanId.${d} or {}).type or "") == "pre-existing" then []
                else [ { key = "POISON"; } ];
              # An exe-dep must either be satisfied in-closure (the
              # build-tool slice machinery provides the binary), join
              # the staged subtree, or POISON it — never be silently
              # dropped: an unknown/pre-existing/build-stage tool id
              # means the tool goal cannot close from the index.
              followExe = d:
                if closureKeys ? ${d} then []
                else if outByKey ? ${d} then follow d
                else [ { key = "POISON"; } ];
          in lib.concatMap follow (metaDepsOf q)
             ++ lib.concatMap followSetup (setupDepsOfEntry q)
             ++ lib.concatMap followExe (exeDepsOfEntry q);
      });
      outSiblings = lib.filter
        (nv: !(lib.elem nv.name componentClosureNames)) homeDependIds;
      siblingUnitIdsOf = nv: map (e: e.key)
        (lib.filter (e:
            (e.entry.pkg-name or "") == nv.name
            && (e.entry.pkg-version or "") == nv.version)
          outEntries);
      siblingSubtree = nv:
        lib.unique (lib.concatMap subtreeOf (siblingUnitIdsOf nv));
      # A sibling dep may leave the built-slice path only when its
      # WHOLE out-of-closure subtree is stageable: a staged candidate
      # is a SOURCE candidate, so the solver must be able to close
      # every goal it opens (bitvec -> ghc-bignum, a configured-local
      # boot unit, sinks the entire monad-logger subtree back to
      # built slices).  Built slices compose their closure and pin it
      # `installed`, so nothing below them is ever solved.
      fullyStageable = nv:
        let ids = siblingSubtree nv;
        in ids != []
           && !(lib.elem "POISON" ids)
           && lib.all (id: stageable outByKey.${id}) ids;
      stagedSiblings = lib.filter fullyStageable outSiblings;
      stagedIds = lib.filter (id: id != "POISON")
        (lib.unique (lib.concatMap siblingSubtree stagedSiblings));
      # Units that are the TARGET of an exe-depends edge from another
      # staged unit are build-TOOL candidates: the solver requires
      # their `executable` stanza present in the index .cabal ("does
      # not contain executable 'happy'"), so the staging strip must
      # keep exes for exactly these.
      toolIds =
        let exeTargets = lib.unique (lib.concatMap
              (id: exeDepsOfEntry outByKey.${id}.entry) stagedIds);
        in lib.filter (id: lib.elem id exeTargets) stagedIds;
      fragOf = id:
        let e = outByKey.${id};
            sl = sliceOfPkgRecord (hsPkgs.${id} or null);
            frag = if sl == null then null else sl.passthru.v2SourceFrag or null;
        # Carry the plan's flag assignment: the slice's solver
        # re-solves a source candidate's flags — unpinned, it may
        # diverge from the plan (text +simdutf wants system-cxx-std-lib
        # where the plan's assignment avoided it) and fail on goals the
        # plan never had.
        in if frag == null then null
           else frag // {
             flags = e.entry.flags or {};
             keepExes = lib.elem id toolIds;
           };
      frags = lib.filter (f: f != null) (map fragOf stagedIds);
      # BUILD-stage setup closure of every staged unit: setup scopes
      # re-solve their dep closures from SOURCE (composed host units
      # are invisible to the build stage), so every configured unit a
      # staged candidate's setup can reach needs a (stripped) index
      # candidate — including packages that are IN-closure for the
      # host (conduit/vector when the target's own lib uses them):
      # the composed conf serves the host scope, the stripped index
      # cabal serves the setup scope (extraFragStaging runs before the
      # repo-frag walk, whose `cp -n` cannot clobber it).  Walked on
      # the BUILD-twin-preferring index (same reasoning as
      # `setupDepClosureIds`) so boot deps resolve to the build
      # compiler's PRE-EXISTING units and drop out.
      setupUniverseIds =
        let byIdB = planJsonByPlanIdBuild';
            cfgOnly = d:
              let q = byIdB.${d} or null;
              in if q == null || (q.type or "") != "configured" then []
                 else [ { key = d; } ];
        in map (x: x.key) (builtins.genericClosure {
          startSet = lib.concatMap (id:
            lib.concatMap cfgOnly (setupDepsOfEntry outByKey.${id}.entry))
            stagedIds;
          operator = item:
            lib.concatMap cfgOnly (metaDepsOf (byIdB.${item.key} or {}));
        });
      setupFragOf = id:
        let q = planJsonByPlanIdBuild'.${id} or null;
            sl = sliceOfPkgRecord (hsPkgs.${id} or null);
            frag = if sl == null then null else sl.passthru.v2SourceFrag or null;
        in if q == null || frag == null
              || lib.elem (q.pkg-name or "") nonReinstallablePkgs
           then null
           else frag // { flags = q.flags or {}; keepExes = false; };
      setupFrags = lib.filter (f: f != null) (map setupFragOf setupUniverseIds);
      # Dedup by name-version; a dep reachable through several siblings
      # contributes one source.
    in {
      # Direct frags first: on a name-version collision listToAttrs
      # keeps the FIRST entry, and the sibling-subtree frag (with the
      # host twin's flags and keepExes) is the more specific one.
      frags = lib.attrValues (lib.listToAttrs
        (map (f: lib.nameValuePair "${f.pkgName}-${f.pkgVersion}" f)
          (frags ++ setupFrags)));
      stagedNames = map (nv: nv.name) stagedSiblings;
    };

  # ---- componentKindLabel / componentName -----------------------
  # `componentId` is a set with `ctype` (e.g. "lib", "exe", "test",
  # "bench", "sublib") and `cname`.
  ctype = componentId.ctype;
  cname = componentId.cname;
  componentKindLabel = ctype;
  componentName = cname;

  # Platform-specific executable extension.  Wasm produces
  # `.wasm`; native Windows produces `.exe`; everything else
  # (including ghcjs under v2) has no extension.
  #
  # v1's `comp-builder.nix:450` appends `.jsexe/all.js` for
  # `isGhcjs && ghc < 9.8`, matching the directory layout that
  # `Setup.hs install` preserves.  v2 builds via `cabal v2-build`,
  # whose install step *bundles* the `.jsexe/` contents into a
  # single self-contained `#!/usr/bin/env node` script at
  # `bin/<cname>` — there is no `.jsexe/` directory in the slice's
  # output.  Use the bundled-file path here so v2's exePath /
  # `find` lookups land on the file cabal actually produced.
  exeExt =
    if stdenv.hostPlatform.isWasm
      then ".wasm"
    else stdenv.hostPlatform.extensions.executable;
  exeName = cname + exeExt;

  # ---- per-kind shape ------------------------------------------
  # `componentPrefix.sublibs == "lib"` (haskellLib in lib/default.nix),
  # so a sublib component arrives here with `ctype == "lib"` too.
  # Distinguish by component name: the main library has `cname ==
  # package-name`, sublibs have any other name.
  isMainLib  = ctype == "lib" && cname == pkgName;
  isSublib   = ctype == "lib" && cname != pkgName;
  isLibrary   = isMainLib || isSublib;
  # Native exe slices ship the binary inside the cabal-store unit
  # dir under `$out/store/.../<unit>/bin/`.  Cross exe slices target
  # `<exe>.exe` (or platform equivalent) which can't run on the
  # build platform anyway, so we capture from `dist-newstyle/`
  # instead.  Same shape as test/bench slices.
  useTarball  = isLibrary || ctype == "exe";
  targetPrefix =
    if ctype == "lib"   then "lib:"  # main lib + sublib both arrive as ctype="lib"
    else if ctype == "exe"   then "exe:"
    else if ctype == "test"  then "test:"
    else "bench:";
  extraProject =
    if ctype == "test"  then "tests: True\nbenchmarks: False\n"
    else if ctype == "bench" then "tests: False\nbenchmarks: True\n"
    else "tests: False\nbenchmarks: False\n";

  # Test / benchmark slices need the target package treated as
  # local: cabal refuses with `Cabal-7127` to build test or
  # benchmark components on a non-local package, so the
  # `extra-packages:` shape that lib / exe slices use isn't
  # available.  Local-style unit-ids fork from
  # `extra-packages:`-style ones, but plan-nix records local
  # packages with `style: "local"` too — so `expectedUnitId`
  # below already skips the unit-id check for them, and
  # `checkAgainstPlan` (the plan-entry diff diagnostic) is the
  # right tool for catching real divergences.
  #
  # Limitation: a non-local package's test or bench (e.g. a
  # hackage dep that ships a test-suite) can't be sliced this
  # way — cabal-7127 would still trigger.  In practice we only
  # build tests / benches for the project's own packages.
  isLocalTestOrBench = (package.isLocal or false) && (ctype == "test" || ctype == "bench");

  # Local-`packages:` mode for LIBRARY slices of `style: "local"` plan
  # units, when the project opts in via `v2LocalPackageSlices` (see the
  # argument comment at the top of this file).  cabal elaborates a local
  # package to the plan's deterministic unit id, so — unlike the
  # extra-packages shape — the id the slice REGISTERS matches what the
  # project plan (and a consumer's plan-time dummy `ghc-pkg dump`)
  # predicts.  Test / bench slices are local for their own reason
  # (cabal-7127) and keep their existing handling.
  #
  # Library components only: exe units never register a `.conf` (the
  # compiler db carries libraries alone), and a LOCAL unit's
  # deterministic id doesn't hash its dep ids, so a lib slice's id is
  # unaffected by its build tools keeping hashed extra-packages slices.
  # Mechanically an inplace exe also lands in the staged store's flat
  # `bin/` — no per-unit dir, no store-install receipt — so the slice's
  # unit capture / downstream tool-reuse machinery wouldn't see it.
  # `style: "inplace"` covers the project's source-repository-packages
  # (the stable-haskell Cabal / Cabal-syntax forks in stage2): the plan
  # elaborates them to the same deterministic bare ids as `"local"`
  # units, but a slice reproducing them through a
  # `source-repository-package` block gets a BuildAndInstall (hashed)
  # elaboration from the fork — so they take the local-`packages:`
  # path too (their staged source replaces the srp block).
  isLocalPackageSlice =
    (v2LocalPackageSlices || builtins.elem pkgName v2LocalPackageSliceNames)
    && !isLocalTestOrBench
    && ctype == "lib"
    && builtins.elem (thisPlanEntry.style or null) [ "local" "inplace" ];
  # Either flavour of local-`packages:` slicing — drives source staging
  # and the cabal.project `packages:` line.
  useLocalPackagesMode = isLocalTestOrBench || isLocalPackageSlice;

  # Whether this slice's SOLVER must see the compiler's real global
  # package db in addition to the composed store units (see the
  # merged-snapshot block in build-cabal-slice.nix).  Consumer-style
  # slices resolve boot libs as `pre-existing` — installed only in the
  # real global db — so hiding it makes them unknown to the solver.
  # Stage-style slices (`v2LocalPackageSlices`, the stable-haskell
  # stage2 boot-lib project) have no pre-existing deps — every dep is a
  # configured unit composed into the staged store — and the project
  # compiler's global db is the PREVIOUS stage's, whose unrelated
  # registrations must stay out of the solver's view.
  solverIncludesGlobalDb =
    !v2LocalPackageSlices || (component.pre-existing or []) != [];

  # The slice targets the package's component directly via cabal's
  # `:pkg:` qualifier (`:pkg:foo:lib:bar`).  cabal-install bug #8684
  # makes the bare form fail with "unambiguous but matches the
  # following targets" when the package isn't in `packages:`, so the
  # qualifier is always required.  `extra-packages:` adds the
  # package to the solver as a remote candidate without treating it
  # as a local package (which would force `inplace` unit-ids that
  # don't match plan-nix).  No local "shim" package or `packages:`
  # entry is needed — the slicing repo + `extra-packages:` is
  # everything cabal v2-build's solver needs.
  #
  # `planJsonByPlanId` arrives pre-built from the project-level
  # `config.plan-json-by-id` (see hspkg-builder).  Used to be
  # rebuilt per slice, which on big projects exploded the
  # evaluator's heap to multiple GiB.

  # Plan units the dep closure should be seeded from.  For lib slices
  # we narrow to *just this slice's own unit* (when `package.identifier.unit-id`
  # is known and present in the plan) — otherwise an unrelated sublib's
  # deps (e.g. `lib:testlib` pulling in `nothunks` / `QuickCheck`) leak
  # into `libConstraintPins` for an unrelated sublib slice (e.g.
  # `lib:si-timers`), and cabal's plan validator rejects the resulting
  # config with "the package configuration specifies <pkg> but (with
  # the given flag assignment) the package does not actually depend
  # on any version of that package".  Local test / bench slices and
  # the rare case of a missing unit-id keep the old "every unit of
  # this package" seed (still correct for those shapes).
  ourPlanUnits =
    let allUnits = lib.filter
          (p: (p.pkg-name or null) == package.identifier.name
              && (p.pkg-version or null) == package.identifier.version)
          planJson;
        uid = package.identifier.unit-id or null;
        myUnit = if uid == null then null else planJsonByPlanId.${uid} or null;
        # Exe / test / bench slices: narrow to the unit whose plan-json
        # `component-name` matches this component, for the same reason
        # the lib narrowing above exists — seeding from EVERY unit of
        # the package drags sibling components' dep closures (leksah's
        # exe:leksah gi-webkit stack) into this slice's composed store,
        # sysLibs and constraint pins.  Sibling deps the SOLVER still
        # needs are staged source-only via `metadataSourceFrags`.
        # Custom-Build packages collapse to one entry with
        # `component-name` unset, so `compUnits` comes up empty and the
        # whole-package seed correctly remains (that single unit really
        # does carry every component's deps).
        planCompName =
          if ctype == "exe" then "exe:${cname}"
          else if ctype == "test" then "test:${cname}"
          else if ctype == "bench" then "bench:${cname}"
          else null;
        compUnits =
          if planCompName == null then []
          else lib.filter (p: (p.component-name or null) == planCompName) allUnits;
    in if isLibrary && myUnit != null then [ myUnit ]
       else if compUnits != [] then compUnits
       else allUnits;

  # `depends` + `exe-depends` — for the slicing repo's tarball set
  # and the slice's dep-slice composition.  cabal needs every
  # build-tool package (and the tool's lib closure) reachable in
  # the index AND composed into the starting store.
  allDepsOf = p:
    (p.depends or [])
    ++ (p.exe-depends or [])
    ++ lib.concatMap (c: (c.depends or []) ++ (c.exe-depends or []))
         (lib.attrValues (p.components or {}));

  mkClosureFrom = seedUnits: depFn: builtins.genericClosure {
    startSet = lib.concatMap (p:
      lib.concatMap (id:
        let q = planJsonByPlanId.${id} or null;
        in if q == null then [] else [ { key = id; entry = q; } ]
      ) (depFn p)
    ) seedUnits;
    operator = e:
      lib.concatMap (id:
        let q = planJsonByPlanId.${id} or null;
        in if q == null then [] else [ { key = id; entry = q; } ]
      ) (depFn e.entry);
  };
  mkClosure = mkClosureFrom ourPlanUnits;
  allDepClosure = mkClosure allDepsOf;

  # Custom-Build packages collapse every component (lib / sublib /
  # exe / ...) into a single plan-nix entry — plan-nix leaves
  # `component-name` unset to mark this.  cabal-install installs all
  # of them under one shared unit-id directory
  # (`<pkg>-<ver>-<hash>/lib/...` + `<pkg>-<ver>-<hash>/bin/...`) and
  # writes a single `.conf` in package.db.  If we target a single
  # component (`:pkg:<pkg>:lib:<lib>`), the slice's `cabal v2-build`
  # builds only that component yet still installs the
  # whole-package-shared `.conf`.  A downstream exe slice that
  # composes that lib slice's `store/` via lndir then sees the
  # `.conf` and concludes the unit is already installed — even
  # though only the lib's files are there — and reports "Up to date"
  # without ever building the exe.  Expand the target to the whole
  # package on Custom-Build so every slice's `cabal v2-build` puts
  # the full unit (lib + every exe) on disk; subsequent slices that
  # lndir-compose this output get the bin/ they need.
  isCustomBuild =
    let uid = package.identifier.unit-id or null;
        entry = if uid == null then null else planJsonByPlanId.${uid} or null;
    in entry != null && (entry.component-name or null) == null;

  # `:pkg:` qualifier disambiguates remote-package targets — cabal
  # bug #8684 makes the bare form fail with "unambiguous but
  # matches the following targets" when the package isn't in
  # `packages:`.
  targetSelector =
    if isCustomBuild
    then ":pkg:${pkgName}"
    else ":pkg:${pkgName}:${targetPrefix}${cname}";


  # The per-slice hackage-style slicing repo (00-index.tar.gz +
  # package/<pkg>-<ver>.tar.gz) is assembled at build time from the
  # per-package `repo-frag`s — see build-cabal-slice.nix.

  # Project-wide solver relaxations.  Our slicing repo is already pinned
  # to the exact versions plan.nix chose (via per-package `constraints:`
  # lines) and uses `active-repositories: hackage.haskell-nix` so the
  # solver can't reach the user's real hackage.  Each package therefore
  # has exactly one candidate version — so `*:*` allow-newer/allow-older
  # can't trigger a "wrong" choice; they just stop cabal rejecting that
  # one candidate over stale upper/lower bounds in the stock .cabal files
  # (which plan.nix itself worked around via head.hackage revisions,
  # allow-newer in the project, etc.).
  #
  # `allow-boot-library-installs: True` lets cabal reinstall the
  # normally-non-reinstallable boot packages (ghc / base / Cabal / …).
  # It only *permits* reinstalls; cabal can act on it only when a boot
  # lib's source is in this slice's repo — i.e. one plan-nix actually
  # reinstalled (e.g. lib:ghc via useLocalGhcLib) — so it's a no-op
  # otherwise.  Unconditional, hence here in the skeleton rather than
  # composed per-slice at build time.
  solverRelaxations = ''
    allow-newer: *:*
    allow-older: *:*
    allow-boot-library-installs: True
  '';

  # `projectConfigPragmas` (the `package *` / per-package cabal.project
  # pragma blocks derived from plan.json's `configure-args`) is computed
  # once per project in `builder/v2-project-globals.nix` and bound near
  # the top of this file, rather than recomputed per slice.

  # Cross GHCs only ship the unversioned bin (e.g.
  # `${ghc.targetPrefix}ghc`), not the `-X.Y.Z` suffixed one, so
  # for cross targets we have to drop the version suffix from the
  # name in `with-compiler:`.  For native we keep the version
  # suffix — cabal hashes the literal `with-compiler:` text into
  # `pkgHashCompilerId` (and therefore the UnitId), so leaving
  # the unversioned form here would fork UnitIds vs any
  # downstream user invoking `cabal v2-build` with the more
  # common `with-compiler: ghc-X.Y.Z` shape.
  withCompiler =
    if (ghc.targetPrefix or "") != ""
    then "${ghc.targetPrefix}ghc"
    else "ghc-${ghcPkgVersion}";
  # `extra-packages:` lists every package whose source build cabal
  # must consider:
  #   * the slice's own target package (so `:pkg:<pkg>:lib:<x>`
  #     targets resolve against the index)
  #   * every entry in `libConstraintPins` — without this, cabal's
  #     solver leaves transitive deps like `process` un-constrained
  #     because a cabal.project `constraints: process source` is
  #     silently ignored on packages that aren't goals in their own
  #     right.  Promoting them to extra-packages makes the solver
  #     consider the source-built copy and lets the `source`
  #     constraint kick in.
  # Skip the target from `extra-packages:` when we're going to put
  # it in `packages:` instead (local test / bench).  Listing it in
  # both is harmless but the local entry takes priority anyway.
  # NOTE: this plan has no source-repository-package dependencies, so
  # build-time `source-repository-package` block composition is not yet
  # implemented; it would be added here (and emitted per-fragment) if a
  # project with SRP deps needs the v2 build-time path.
  packagesLine =
    if useLocalPackagesMode
    then "packages: ./src/${pkgName}-${pkgVersion}\n"
    # The stable-haskell Cabal fork (3.17) rejects a project with neither
    # `packages:` nor `optional-packages:` (Cabal-7168).  A dependency slice
    # builds its target from the slicing repo's `extra-packages:`, not a local
    # package, so give an `optional-packages:` glob that matches nothing here —
    # it satisfies the check without adding any package (UnitId-neutral).
    else "optional-packages: ./*\n";

  # hsc2hs `--via-asm` for Windows cross.  The default `--cross-compile`
  # mode (cabal adds it automatically for cross) validates each
  # `#const`/`#enum` by sizing a C array with the value; Win32's
  # pointer-cast enums (e.g. `(UINT_PTR)HWND_BOTTOM` = `(UINT_PTR)((HWND)-1)`)
  # are not integer-constant-expressions, so gcc rejects them ("storage
  # size of 'test_array' isn't constant").  `--via-asm` validates via a
  # global `long long` initializer / assembler instead (hsc2hs
  # CrossCodegen `validConstTestViaAsm`), which accepts pointer casts.
  # Delivered through a `package *` stanza rather than a `cabal v2-build
  # --hsc2hs-options` CLI flag: the CLI flag only reaches LOCAL `packages:`
  # targets, but dependency slices build their target as a REMOTE
  # extra-package.  Windows-gated (native/hadrian byte-identical); on
  # native build-stage units hsc2hs ignores --via-asm (DirectCodegen).
  # Mirrors v1's comp-builder.nix:398 (`--via-asm` for isWindows).
  hsc2hsViaAsmProject =
    lib.optionalString (stdenv.hostPlatform.isWindows or false) ''
      package *
        hsc2hs-options: --via-asm
    '';

  # The *local / global* part of the cabal.project (everything that
  # doesn't depend on the dependency closure).  build-cabal-slice writes
  # this, then appends the closure-derived sections (source-repo blocks,
  # extra-packages, the six per-package block groups, constraints)
  # composed at build time from the per-package fragments — so the
  # dependency-closure walk never runs in the Nix evaluator.
  localCabalProject = ''
    with-compiler: ${withCompiler}
    active-repositories: hackage.haskell-nix
    ${packagesLine}${solverRelaxations}${projectConfigPragmas}${hsc2hsViaAsmProject}${extraProject}${extraIncludeAndLibDirs}'';

  # Untouched packages keep their revised .cabal separately from the
  # upstream tarball. Patches/hooks may change that metadata after the
  # override was copied (as in v1), so publish the effective tarball's
  # .cabal in every slicing index instead of restoring the old override.
  thisCabalFile =
    if cabalFile != null && resolvedPatches == [] && !pkgHasHook
    then builtins.toFile "${pkgName}.cabal" cabalFile
    else null;

  # Two-stage (stable-haskell `-target` cross) plans.  The compiler is a
  # wrapper around the native ghc whose target global db is empty
  # (`emptyGlobalPackageDb`); its plan was made with
  # `--with-build-compiler` (see call-cabal-project-to-nix.nix), so every
  # unit carries a stage:
  #
  #   * "host" units target the cross platform.  Their slices must
  #     re-plan the same two-stage way — without `--with-build-compiler`
  #     cabal would default the build compiler to the host path (the
  #     TARGET wrapper) and plan every build-stage goal for the target.
  #   * "build" units (build-tool-depends subtrees, setup deps) run on
  #     the build machine.  Their slices use the BUILD compiler in an
  #     ordinary single-stage invocation: the stage does not enter
  #     cabal's unit hash, so the plan unit id reproduces exactly (same
  #     compiler id, native platform, same flags, deps installed from
  #     the native compiler's db).  Captured under the store's
  #     `host/<native-platform>/`, which a host slice's build-stage
  #     lookups reach through the compose step's `build` → `host` link.
  isTwoStagePlan = ghc.emptyGlobalPackageDb or false;
  # plan.json carries no top-level stage key; the stage is the first path
  # component under dist-newstyle/build/ in the unit's dist-dir
  # (`./dist-newstyle/build/<stage>/<platform>/<unit>`).
  planStage =
    let dd = (planJsonByPlanId.${package.identifier.unit-id or ""} or {}).dist-dir or "";
        m  = builtins.match "[.]/dist-newstyle/build/([a-z]+)/.*" dd;
    in if m == null then null else builtins.head m;
  isBuildStageUnit = isTwoStagePlan && planStage == "build";

  # A `build-type: Custom` package's `setup` runs on the BUILD machine, so it
  # must be compiled by the build compiler.  A single-stage cross slice
  # (mainline GHC cross: ghc9124, ghc9141, ...) gives cabal only the cross
  # compiler, and cabal compiles the setup with it -- a target binary that
  # the build machine cannot run (android entropy: `setup: line 1: syntax
  # error`).  It only ever worked where the builder happened to execute the
  # target natively (aarch64 on the aarch64 `nix-linux-builder` VMs).  Give
  # such slices the fork cabal's `--with-build-compiler` too: the setup
  # scope then resolves against the native compiler, whose boot packages
  # have the same versions the plan's `<pkg>:setup.*` pins name.
  #
  # The setup deps enter the Custom unit's hash, so every slice whose closure
  # holds one must plan the same way or it would not recognise the composed
  # unit (cross slices skip the unit-id check, `expectedUnitId` below).
  crossCustomSetup =
    isCross && !isTwoStagePlan && !isBuildStageUnit
    && lib.any (p: (p.components or {}) ? setup)
         (thisPkgUnits ++ map (e: e.entry) allDepClosure);
  sliceTwoStage = (isTwoStagePlan && !isBuildStageUnit) || crossCustomSetup;

  # On targets that need a wrapped ghc (currently just windows
  # cross, where TH compiles route through the wineIservWrapper),
  # `templateHaskell.wrapGhc` is set by the host-platform overlay.
  # Apply it to the ghc we already have so cabal still sees the
  # same compiler-id (UnitId hash unaffected) but every compile
  # silently picks up `-fexternal-interpreter -pgmi <wrapper>`.
  sliceGhc =
    if isBuildStageUnit then ghc.buildGHC
    else if templateHaskell != null && templateHaskell.wrapGhc or null != null
    then templateHaskell.wrapGhc ghc
    else if projectIserv != null then withProjectIserv ghc
    else ghc;

  # A stable-haskell cross compiler for a target the build machine can run
  # (musl64 / static on x86_64-linux) has no `templateHaskell` wrapper --
  # haskell.nix counts same-arch musl as native -- so `-fexternal-interpreter`
  # makes GHC look for `targets/<triple>/bin/ghc-iserv` inside the compiler:
  #   .../targets/x86_64-unknown-linux-musl/lib/../bin/ghc-iserv:
  #   createProcess: posix_spawnp: does not exist
  # A cross compiler cannot ship that binary (the target's boot libraries
  # are built by each project), so the project builds it instead
  # (`utils/ghc-iserv` in the boot injection, modules/cabal-project.nix).
  # Point GHC at that one with `-pgmi`, through a ghc wrapper as
  # `templateHaskell.wrapGhc` does, so the unit-id is unaffected.
  #
  # Only for a package that asks for the external interpreter in its own
  # `ghcOptions`, or -- on a dynamically linked musl host -- a component
  # declared `usesTemplateHaskell`: that keeps the wrapper (and with it the
  # ghc-iserv exe) out of every slice in ghc-iserv's own dependency closure.
  #
  # The second case is because the in-process interpreter cannot work
  # there.  The compiler is a glibc process, and a splice that reaches a C
  # library makes it dlopen the musl shared object
  # (libsodium / openssl for th-dlls):
  #   Failed to build th-dlls-0.1.0.0-... The build process segfaulted
  # Static targets link those libraries as archives, which the RTS linker
  # loads itself, so the same splices run in-process there.
  forceExternalInterpreter =
    (pkgs.stdenv.hostPlatform.isMusl or false)
    && !(pkgs.stdenv.hostPlatform.isStatic or false)
    && (component.usesTemplateHaskell or false);
  projectIserv =
    if isTwoStageCross
       && pkgName != "ghc-iserv"
       && (lib.elem "-fexternal-interpreter" (ghcOptionsOf pkgName)
           || forceExternalInterpreter)
    then hsPkgs.ghc-iserv.components.exes.ghc-iserv or null
    else null;
  # GHC runs `<-pgmi path>-prof` when the splice is compiled -prof (and
  # `-dyn` with -dynamic), so `-pgmi` names a directory holding both
  # flavours.  The project builds only the vanilla ghc-iserv: adding the
  # prof one as a boot package would make every musl project build
  # profiled boot libraries.  For a profiled slice, run the profiled
  # iserv-proxy-interpreter -- which the iserv-proxy project already
  # builds, against its own profiled closure -- behind iserv-proxy, with
  # no emulator (the build machine runs the target).  That is the
  # linux-cross wrapper (overlays/linux-cross.nix) with `env` for qemu.
  sliceProfiled = lib.any (u:
      lib.any (a: a == "--enable-profiling" || a == "--enable-library-profiling"
                  || a == "--enable-executable-profiling")
        (u.configure-args or []))
    thisPkgUnits;
  projectIservDir =
    pkgs.buildPackages.runCommand "project-iserv" { } (''
      mkdir -p $out/bin
      ln -s ${projectIserv}/bin/ghc-iserv $out/bin/ghc-iserv
    '' + lib.optionalString (sliceProfiled && iservProxyExes != null) (
      let interp = iservProxyExes.iserv-proxy-interpreter-prof; in ''
      cat > $out/bin/ghc-iserv-prof <<EOF
      #!${pkgs.buildPackages.runtimeShell}
      exec ${iservProxyExes.iserv-proxy}/bin/iserv-proxy "\$@" \\
        --pipe ${pkgs.buildPackages.coreutils}/bin/env \\
        ${interp}/bin/${interp.exeName} tmp --stdio
      EOF
      chmod +x $out/bin/ghc-iserv-prof
    ''));
  withProjectIserv = ghc:
    pkgs.buildPackages.runCommand "${ghc.name}-with-project-iserv"
      { nativeBuildInputs = [ pkgs.buildPackages.makeWrapper ];
        passthru = {
          inherit (ghc) version meta;
          targetPrefix = ghc.targetPrefix or "";
        };
      } ''
        mkdir -p $out/bin
        prefix="${ghc.targetPrefix or ""}"
        for prog in ghc ghci ghc-${ghc.version} ghci-${ghc.version}; do
          if [ -x ${ghc}/bin/$prefix$prog ]; then
            makeWrapper ${ghc}/bin/$prefix$prog $out/bin/$prefix$prog \
              --add-flags "${lib.optionalString forceExternalInterpreter "-fexternal-interpreter "}-pgmi ${projectIservDir}/bin/ghc-iserv"
          fi
        done
        for f in ${ghc}/bin/$prefix*; do
          base=$(basename "$f")
          [ -e "$out/bin/$base" ] || ln -s "$f" "$out/bin/$base"
        done
        for d in lib share; do
          if [ -d ${ghc}/$d ]; then ln -s ${ghc}/$d $out/$d; fi
        done
      '';

  # Stage the package source for local-`packages:` targets so
  # `packages:` can reference it as a local directory — test / bench
  # slices (cabal-7127 requires test / bench targets to be local to the
  # project) and `isLocalPackageSlice` lib / exe slices alike.
  stageLocalTestBenchSrc = lib.optionalString useLocalPackagesMode ''
    mkdir -p src
    tar -xzf ${pkgTarball} -C src
  '';

  # preBuild for the real slice: only stage sources.  The cabal.project
  # is assembled entirely at build time by build-cabal-slice from
  # `v2Fragment` (local skeleton + closure sections composed from
  # fragments), so we DON'T interpolate the Nix-side `cabalProject` here
  # — that's what keeps the per-slice dependency-closure walk (the six
  # `sliceCanonicalNames` block-assemblies, `depConstraints`,
  # `slicingRepo`, …) out of the evaluator.
  slicePreBuildV2 = stageLocalTestBenchSrc + lib.optionalString iservDynamicLibc ''

    # See `iservDynamicLibc`: link this slice's executables against libc.so.
    export NIX_CFLAGS_LINK_${staticHostSalt}="''${NIX_CFLAGS_LINK_${staticHostSalt}//-static/}"
  '';
  # ghc-iserv is the project's external interpreter (see `projectIserv`),
  # and iserv-proxy-interpreter the one for profiled splices: they run on
  # the build machine and resolve libc symbols for the code they load
  # through dlsym.  A fully static musl executable has no dlsym, so
  # on pkgsStatic (`static`) every splice failed with
  #   ghc-iserv: Failed to lookup symbol: memcmp
  # `executable-static: False` (modules/cabal-project.nix) is not enough
  # there: the pkgsStatic stdenv adds `-static` to every host link, which
  # build-cabal-slice.nix keeps in the host-salted NIX_CFLAGS_LINK.  Drop it
  # for these packages only.  musl-static still ships libc.so and ld-musl, and
  # this is how hadrian's static cross ghc-iserv is linked too (NEEDED
  # libc.so, RUNPATH musl-static/lib).
  iservDynamicLibc =
    lib.elem pkgName [ "ghc-iserv" "iserv-proxy" ]
    && isTwoStageCross
    && (pkgs.stdenv.hostPlatform.isMusl or false)
    && (pkgs.stdenv.hostPlatform.isStatic or false);
  staticHostSalt = lib.replaceStrings [ "-" "." ] [ "_" "_" ]
    pkgs.stdenv.hostPlatform.config;

  # ---- Per-package fragment for build-time composition -------------
  # Each slice writes its OWN contribution into `$out` (source tarball +
  # `.cabal`, the six per-package cabal.project blocks, its constraint
  # pin, its sublib seeds) plus a pointer to its direct lib-dep slices.
  # A downstream slice's build phase composes these by following the
  # pointer files, so the dependency closure never has to be walked in
  # Nix.  STEP 1: emitted additively (not yet consumed) so we can verify
  # it doesn't perturb unit-ids before composition is switched over.
  #
  # `thisPkgUnits` are this package's own plan entries, found via the
  # project-global `packageIdsByName` index (O(units), not an O(planJson)
  # scan).
  thisPkgUnits =
    lib.filter (p: (p.pkg-version or null) == pkgVersion)
      (map (id: planJsonByPlanId.${id})
        (lib.filter (id: planJsonByPlanId ? ${id})
          (packageIdsByName.${pkgName} or [])));
  # Per-package custom-setup dependency pins.  A `build-type: Custom`
  # package's unit-id hashes its setup configuration, so the slice must
  # solve its setup against the SAME deps plan-nix recorded — notably
  # `Cabal`, which otherwise drifts: with a reinstalled `Cabal` in the
  # closure, cabal's unconstrained per-package setup solver prefers it
  # over the GHC-bundled one plan-nix used, forking the unit-id (e.g.
  # ghc-paths 142b137f → e732a98d) and breaking pre-built build-tool
  # reuse (proto-lens-protoc).  We emit `<pkg>:setup.<dep> ==<ver>` for
  # each setup-dep, scoped to this package (cabal accepts the
  # per-package `pkg:setup.dep` qualifier).  No `source` flag: setup
  # `Cabal` is disambiguated by version (bundled 3.10.x vs reinstalled
  # 3.16.x), and the bundled one isn't in the slicing repo anyway.
  #
  # The pins cover the TRANSITIVE closure of the setup scope, not just
  # the direct `setup-depends`: the slice solves under blanket
  # allow-newer/allow-older relaxations, so a source setup `Cabal`
  # (e.g. `Cabal-3.16.1.0` when the package's `setup-depends` excludes
  # the GHC-bundled 3.17) would otherwise pair with the INSTALLED
  # Cabal-syntax — whose module set no longer matches the re-exports
  # that Cabal version declares ("Problem with module re-exports:
  # Distribution.Compat.MonadFail is not exported...").  A
  # `<pkg>:setup.<dep>` constraint applies to the whole setup
  # qualifier scope, so pinning the closure reproduces plan-nix's
  # setup resolution exactly; pins for packages that never become
  # setup-scope goals (rts etc.) are ignored by the solver.
  # Walked on the BUILD-twin-preferring index: setup scopes are
  # build-stage under the fork, so where a package has host+build twins
  # under one bare id the BUILD twin's dep set is the plan's real setup
  # resolution (the haskell-gi codegen setups run against
  # haskell-gi-overloading-1.0 while the host libs use 0.0).
  planJsonByPlanIdBuild' =
    if planJsonByPlanIdBuild == null then planJsonByPlanId else planJsonByPlanIdBuild;
  setupDepClosureIds = map (x: x.key) (builtins.genericClosure {
    startSet = map (id: { key = id; })
      (lib.concatMap (u: u.components.setup.depends or []) thisPkgUnits);
    operator = item:
      let q = planJsonByPlanIdBuild'.${item.key} or null;
          # Not a dep's own `setup` component: that is a separate setup
          # scope (`<dep>:setup.*`), solved on its own.  Pinning its deps
          # under THIS package's `setup.` qualifier merges two resolutions,
          # and when they disagree the slice cannot solve at all — e.g.
          # gi-gdk4 pinned `setup.gi-glib` to both 2.0.30 (its own setup)
          # and 2.0.29 (gi-gio's setup), and so on down the haskell-gi
          # family, once Hackage carried both versions.
          deps = if q == null then []
                 else (q.depends or [])
                      ++ lib.concatMap (c: c.depends or [])
                           (lib.attrValues
                             (removeAttrs (q.components or {}) [ "setup" ]));
      in map (id: { key = id; }) deps;
  });
  ownSetupConstraints =
    lib.unique (lib.filter (x: x != null) (map (id:
      let q = planJsonByPlanIdBuild'.${id} or null;
      in if q == null || !(q ? pkg-name) then null
         else "${pkgName}:setup.${q.pkg-name} ==${q.pkg-version}"
    ) setupDepClosureIds));
  v2Fragment = {
    inherit pkgName pkgVersion;
    tarball = pkgTarball;
    cabalFile = thisCabalFile;            # null → extract effective tarball metadata
    flagsBlock            = flagBlockFor             pkgName;
    ghcOptionsBlock       = ghcOptionsBlockFor       pkgName;
    configureOptionsBlock = configureOptionsBlockFor pkgName;
    programOptionsBlock   = programOptionsBlockFor   pkgName;
    docBlock              = documentationBlockFor    pkgName;
    extraLibDirsBlock     = extraLibDirsBlockFor     pkgName;
    # This package's `package <name>` configuration-pragma delta against
    # the `package *` baseline in `projectConfigPragmas`.
    configBlock           = perPkgConfigBlocks.${pkgName} or "";
    # Consumer-side constraint pin.  Slices are never `pre-existing`,
    # so normally `source` — it forces cabal off a GHC-bundled unit when
    # a boot library is reinstalled at the same version.  A local-mode
    # slice is the opposite case: its composed store unit carries the
    # plan's deterministic LOCAL id, and a `source` pin would make the
    # consumer's solver re-plan the dep extra-packages-style (hashed id
    # ≠ composed unit) and rebuild it inside the consuming slice.  Pin
    # only the version so the solver picks the composed installed unit.
    constraintLine =
      if isLocalPackageSlice
      then "${pkgName} ==${pkgVersion}"
      else "${pkgName} ==${pkgVersion}, ${pkgName} source";
    setupConstraints = ownSetupConstraints;
    # `source-repository-package` block (non-empty only for source-repo
    # packages).  Composed across the closure at build time; such
    # packages are also skipped from `extra-packages:`.
    sourceRepoBlock = ownSourceRepoBlock;
    # Direct library-`depends` slices — the seed for the build-time
    # depends-closure walk (constraints scope; see `dependsSlices`).
    # The source + blocks scope rides the existing `transitive-deps`
    # closure instead.  `exe-depends` (build tools) are NOT seeded here:
    # they contribute source via the repo but get no constraints.
    libDepSlices = dependsSlices;

    # ---- STEP 2b: build-time cabal.project composition inputs -------
    # Local/global skeleton; the composer appends closure sections.
    inherit localCabalProject;
    # This package's own `extra-packages:` entry (empty for local
    # test/bench targets and source-repo packages, which cabal must
    # build from `packages:` / a `source-repository-package` block,
    # not the index).
    # Local-`packages:` targets (either flavour) are cabal's own project
    # packages, not index candidates — and for `isLocalPackageSlice`
    # units an `extra-packages:` entry in a CONSUMER's project would
    # promote the dep to a source goal, re-planning it extra-packages
    # style (hashed id) instead of using the composed installed unit.
    selfExtraPackage =
      lib.optionalString (!useLocalPackagesMode && !isSourceRepoPkg) "${pkgName} ==${pkgVersion}";
  };

  baseSlice = buildCabalStoreSlice {
    # Match v1's `comp-builder.nix:528-530`-style
    # `pname = <pkg>-<ctype>-<cname>; version = <version>` so the
    # cross-aware nixpkgs naming convention puts the host platform's
    # config BETWEEN `pname` and `version` (matching v1's
    # `<pkg>-<ctype>-<cname>-<crossSuffix>-<version>` store paths).
    # Setting `name` directly would have appended the cross suffix
    # at the end instead, giving `<pkg>-<ctype>-<cname>-<version>-<crossSuffix>`
    # which doesn't match downstream consumers (e.g. the
    # `tests.coverage.run` path expectations).
    pname = "${pkgName}-${componentKindLabel}-${componentName}";
    version = pkgVersion;
    inherit depSlices;
    inherit v2Fragment;
    inherit buildToolSourceFrags;
    inherit metadataSourceFrags;
    ghc = sliceGhc;
    twoStage = sliceTwoStage;
    # Repo + cabal.project are composed at build time from `v2Fragment`;
    # `localRepo`/the full Nix `cabalProject` are intentionally NOT
    # referenced here so the per-slice closure walk stays out of eval.
    localRepo = null;
    preBuild = slicePreBuildV2;
    target = targetSelector;
    extraBuildInputs = extraBuildInputs ++ extraDirInputs;
    inherit extraNativeBuildInputs withProgFlags
            allowedBuildToolPackages confLibraryDirs
            buildToolBinOverlays;
    # Per-component stdenv hardeningDisable (set via haskell.nix
    # `packages.<pkg>.components.<kind>.<name>.hardeningDisable =
    # ["fortify"]`).  Drives `NIX_HARDENING_ENABLE` for the slice's
    # build env so C-toolchain wrappers strip the listed hardening
    # flags before invoking gcc/clang — e.g. dropping `fortify`
    # prevents the Android NDK from pulling `bits/fortify/stdio.h`
    # into c2hs preprocessing, which c2hs can't parse.
    hardeningDisable = component.hardeningDisable or [];
    # Per-component `Setup build -jN` (see modules/component-options.nix).
    buildJobs = component.buildJobs or null;
    # Things that flow into downstream slices' build envs through
    # stdenv's propagation chain.  Library deps don't appear here
    # because in v2 they're the dep slices themselves, already in
    # `buildInputs`.
    #
    # Propagating `libs` here would propagate them to *every*
    # consumer — including consumers on a different stdenv
    # (the v2 dev shell on aarch64-darwin sticks Linux cross
    # slices into `inputsFrom`).  Stdenv would then take a
    # Linux-target `pkgs.liburing` and try to build it for
    # Darwin.  Limit `libs` propagation to Windows, where
    # `wineIservWrapper` walks `pkgsHostTarget` for DLL
    # discovery (matching v1).  For non-Windows targets each
    # slice gathers transitive sysLibs locally via
    # `transitiveDepLibs`, kept inside its own
    # `extraBuildInputs`.
    propagated = haskellLib.checkUnique
      "${ghc.targetPrefix}${pkgName}-${pkgVersion}-${componentKindLabel}-${componentName} propagatedBuildInputs" (
           haskellLib.uniqueWithName frameworks
        ++ haskellLib.uniqueWithName pkgconfig
        ++ lib.optionals stdenv.hostPlatform.isWindows
          (haskellLib.uniqueWithName libs));
    # The slice's `cabal v2-build` should only ever build the
    # target package (any number of components — lib + sublibs +
    # exe, etc.) plus, on cross, the transitive build-tools that
    # cabal's solver always plans for `build-tool-depends:` goals.
    # Any OTHER package appearing in cabal's plan means a lib dep
    # we composed into the starting store ended up rebuilt.
    expectedPackage = pkgName;
    # The slice must produce its own component's plan-id.
    # `package.identifier.unit-id` is set by
    # `modules/install-plan/planned.nix` to the plan-id of the
    # specific install-plan entry this slice was built from.
    #
    # Skip the unit-id check when plan-nix built this component
    # in-place rather than for the store.  cabal's `style2str` reports
    # two such cases: `"local"` (a package in cabal.project's
    # `packages:` block) and `"inplace"` (a *non*-local package cabal
    # still elaborated `BuildInplaceOnly` — e.g. the generated
    # haskell-gi `gi-*` family under the stable-haskell GHC, whose
    # boot-lib deps carry `-inplace` ids).  BuildInplaceOnly packages
    # get the fixed unit-id suffix `<pkgid>-inplace`, whereas the slice
    # serves the identical source through its slicing repo and cabal
    # builds it `BuildAndInstall` → `style: "global"` with a hashed
    # `<pkgid>-<hash>` id.  The suffix differs by construction (same
    # source bytes either way), so the unit-id equality check can never
    # hold; the plan diff at `.checkAgainstPlan` is the right tool for
    # spotting real divergence here.  Downstream slices re-solve against
    # the same repo and agree on the hashed id, so composition is
    # consistent.
    # Local-mode slices are the exception to the `style == "local"` skip
    # below: cabal elaborates the target as a project-local package (the
    # same shape the plan used), so the slice's unit id is deterministic
    # and MUST equal the plan's — this check is what guards the
    # stable-haskell compiler's global-db ids staying predictable for
    # consumer plan-time dummy dumps.
    expectedUnitId =
      let uid = package.identifier.unit-id or null;
          entry = if uid == null then null else planJsonByPlanId.${uid} or null;
          style = if entry == null then null else entry.style or null;
      in if isCross || isCustomBuild then null
         else if isLocalPackageSlice then uid
         else if style == "local" || style == "inplace" then null
         else if isTwoStageCross then null
         else uid;
    # Local-mode slices necessarily also build required SIBLING
    # components of their (local) package in-slice — tolerated by the
    # unit-id check via this prefix (see build-cabal-slice.nix).
    allowedSiblingUnitPrefix =
      if isLocalPackageSlice then "${pkgName}-${pkgVersion}" else null;
    inherit solverIncludesGlobalDb;
    passthru = {
      inherit pkgTarball;
      # Source-only frag (tarball + revised .cabal + name/version).  A
      # two-stage consumer places a build-tool's SOURCE into its slicing
      # repo through this WITHOUT composing the tool's full slice — the
      # latter would form an eval cycle (host tool slice → host lib dep →
      # back to the consuming package).  It carries no drv edge to the
      # tool's build, only to the tool's source tarball.
      v2SourceFrag = {
        inherit pkgName pkgVersion;
        tarball = pkgTarball;
        cabalFile = thisCabalFile;
      };
      # Mirror v1's `.config` passthru so downstream code that walks
      # the dep graph via flatLibDepends (see shell-for-v2.nix,
      # haskellLib.flatLibDepends) can traverse v2 components the
      # same way as v1.
      config = component;
      # v1 puts the package source in the component derivation's own
      # `src` attribute (`commonAttrs.src = cleanSrc.root` in
      # comp-builder.nix), so callers read it back as `component.src` --
      # `test/cabal-project-nix-path` untars a `haskell-nix.tool` result's
      # `.src` to get hello's sources.  A v2 slice builds several packages
      # at once and so has no `src` derivation attribute at all; expose the
      # same value here to keep the two builders interchangeable.
      src = (haskellLib.rootAndSubDir src).root;
      # `lib/cover.nix` (HPC coverage report) reads `srcSubDirPath`
      # off each mix library to know where the .hs sources live for
      # `hpc markup --srcdir=...`.  v1 plumbs this from `cleanSrc`;
      # mirror the shape here so cover.nix works against v2 slices.
      srcSubDir = (haskellLib.rootAndSubDir src).subDir;
      srcSubDirPath = let r = haskellLib.rootAndSubDir src; in r.root + r.subDir;
      identifier = package.identifier // {
        component-id = "${pkgName}:${componentId.ctype}:${componentId.cname}";
        component-name = componentId.cname;
        component-type = componentId.ctype;
      };
      # Expose the resolved `build-tool-depends` entries too, again to
      # match v1's passthru shape.  Shells (particularly the v2 shell
      # with `allToolDeps`) gather these to put build tools on PATH
      # before the user runs `cabal build`.
      executableToolDepends = extraNativeBuildInputs;
      # Every host-platform lib the slice was linked against.
      # `lib/check.nix`'s v2 branch adds these to its
      # `nativeBuildInputs` so test runners (wineTestWrapper for
      # windows, etc.) can find the runtime DLLs / dylibs / .so
      # files the exe imports.  This mirrors v1's automatic
      # `propagatedBuildInputs` chain — v2 slices don't ride
      # stdenv's propagation since dep slices flow as a
      # `DEP_SLICES` env var rather than as buildInputs, so we
      # surface the same set explicitly.
      runtimeLibs = extraBuildInputs;
    };
  };

  # When `coverage: True` is set, cabal stores per-package HPC
  # artifacts under `$out/store/<ghc>/<unit-id>/lib/extra-compilation-artifacts/hpc/`
  # (mangled cabal unit-id name, e.g. `pkg-0.1.0.0-f77c657f`).
  # The .mix file *content* is derived from source, not unit-id, so the
  # lib slice's mixes answer for any name a tix file might use.  Surface
  # them under every such name, because which one it is depends on how
  # the test exe that dropped the tix saw this library:
  #
  #   * `<pkg>-<ver>-inplace` -- an inplace rebuild in a sibling test
  #     slice, the case this block was originally written for;
  #   * the real unit-id (`<pkg>-<ver>-<hash>`), cabal's own directory
  #     name for the installed unit;
  #   * `<pkg>-<ver>`, which is what the stable-haskell fork's two-stage
  #     build records -- and the one that was missing:
  #       hpc: can not find pkgb-0.1.0.0/ConduitExample in
  #         .../share/hpc/vanilla/mix
  #     which is where `tests.coverage.run` on ghc914-sh failed once
  #     `hpc` itself was on PATH.
  #
  # Duplicating is safe precisely because the content is source-derived;
  # a wrong guess is a hard error at report time, a spare copy is a few
  # kB.  Tix files don't land here (they're produced at test-run time by
  # `lib/check.nix`).
  hpcCopyForLibrary = lib.optionalString isLibrary ''
    for src_hpc in $out/store/ghc-*/*/lib/extra-compilation-artifacts/hpc \
                   $out/store/host/*/lib/*/extra-compilation-artifacts/hpc; do
      [ -d "$src_hpc" ] || continue
      for way_dir in "$src_hpc"/*/; do
        [ -d "$way_dir" ] || continue
        way=$(basename "$way_dir")
        if [ -d "$way_dir/mix" ]; then
          for unit_dir in "$way_dir/mix"/*/; do
            [ -d "$unit_dir" ] || continue
            for mixAlias in "${pkgName}-${pkgVersion}-inplace" \
                            "${pkgName}-${pkgVersion}" \
                            "$(basename "$unit_dir")"; do
              mkdir -p "$out/share/hpc/$way/mix/$mixAlias"
              cp -r "$unit_dir"/. "$out/share/hpc/$way/mix/$mixAlias/"
            done
          done
        fi
      done
    done
  '';

  # Trim cabal's `dist-newstyle/` from the slice's $out at the
  # end of installPhase: the only consumer that needs it during
  # this build is `kindSpecificInstallPhase`'s test/bench find
  # (which runs above before this trim).  Downstream slices /
  # callers don't read the slice's `$out/dist-newstyle/`, so we
  # can drop the source-tarball / build-tree bulk to keep slice
  # outputs small.  Lift `cache/plan.json` to `$out/plan.json`
  # so it stays available for human debugging.
  trimDistNewstyle = ''
    if [ -d $out/dist-newstyle ]; then
      if [ -f $out/dist-newstyle/cache/plan.json ]; then
        cp $out/dist-newstyle/cache/plan.json $out/plan.json
      fi
      chmod -R u+w $out/dist-newstyle 2>/dev/null || true
      # Keep the `store` symlink: the slice ran cabal with
      # `--builddir=$out/dist-newstyle`, so with the stable-haskell
      # cabal fork every baked path (Paths_ datadir, RPATHs, .conf
      # fields) is spelled through `$out/dist-newstyle/store` and the
      # link must stay resolvable forever (see build-cabal-slice.nix's
      # "Staged store layout" comment).  Everything else is build-tree
      # bulk no downstream consumer reads.
      shopt -s nullglob dotglob
      for entry in $out/dist-newstyle/*; do
        [ "$(basename "$entry")" = store ] && continue
        rm -rf "$entry"
      done
      shopt -u nullglob dotglob
      if [ ! -d $out/store ]; then
        rm -rf $out/dist-newstyle
      fi
    fi
  '';

  # Per-kind installPhase tail: surface binaries for exe / test /
  # bench, and run the test as part of the build.  The final binary
  # lands at `$out/bin/${exeName}` (platform-specific extension —
  # `.exe` on native Windows, `.wasm` for wasm, etc.).
  kindSpecificInstallPhase =
    if isLibrary then hpcCopyForLibrary + trimDistNewstyle
    else if useTarball then ''

      mkdir -p $out/bin
      # `\( -type f -o -type l \)` because cabal may say "Up to date"
      # and skip rebuilding when a depSlice's lndir composition already
      # supplied the exe — in which case `$out/store/.../bin/<exe>` is
      # a symlink into the dep slice, not a real file.
      bin=$(find $out/store \( -type f -o -type l \) -path "*/bin/${exeName}" | head -n1)
      if [ -z "$bin" ]; then
        # TODO: this currently fires when cabal short-circuits on
        # "Up to date" without materialising the exe in $out/store,
        # which can happen when a transitive slice already supplied
        # the unit and our composition didn't carry the bin/.  Emit
        # a non-functional placeholder so the slice still produces
        # an output (lets the dev shell open while we investigate).
        echo "WARN: ${componentKindLabel} binary ${exeName} not found in $out/store" >&2
        echo "      emitting placeholder so this slice still produces an output" >&2
        printf '#!/bin/sh\necho "%s: placeholder — slice did not materialise the exe" >&2\nexit 1\n' \
          "${exeName}" > $out/bin/${exeName}
        chmod +x $out/bin/${exeName}
      else
        cp "$bin" $out/bin/${exeName}
        chmod +x $out/bin/${exeName}
      fi
      # `build-cabal-slice.nix`'s installPhase already cleared
      # dep-slice content out of $out/store (keeping only the
      # expected unit's dir + conf).  No further cleanup needed
      # here — the bin we just copied came from
      # `$out/store/<uid>/bin/${exeName}`, which survived the
      # cleanup as part of the expected unit's dir.
      ${trimDistNewstyle}
    '' else ''

      mkdir -p $out/bin
      bin=$(find $out/dist-newstyle \( -type f -o -type l \) -name '${exeName}' | head -n1)
      if [ -z "$bin" ]; then
        echo "FAIL: ${componentKindLabel} binary ${exeName} not found in $out/dist-newstyle" >&2
        find $out/dist-newstyle \( -type f -o -type l \) >&2
        exit 1
      fi
      cp "$bin" $out/bin/${exeName}
      chmod +x $out/bin/${exeName}
      ${trimDistNewstyle}
    '';

  # v2 test slices only *build* the test binary — actually running
  # it is left to `lib/check.nix` (via `haskellLib.check`), matching
  # v1's separation of build-time and check-time.  This avoids
  # paying the test run cost when the caller only needs the
  # binary built (e.g. for offline inspection or alternate runners).

  slice = baseSlice.overrideAttrs (old: {
    installPhase = old.installPhase + kindSpecificInstallPhase;
  });

  # Sibling drv that re-runs only the slice's *planning* step (cabal
  # v2-build --dry-run) and dumps a per-package diff between the
  # entry plan-nix recorded for that package and the entry cabal
  # actually planned in this slice.  Useful when a slice fails the
  # unit-id check (or plans an unexpected package) — the diff makes
  # the diverging field visible (compiler-id, flags, dep unit-ids,
  # ...).  Inspect with:
  #   nix-build -A project.hsPkgs.<pkg>.components.library.checkAgainstPlan
  # then read $out/diff-report.txt.  Output also includes the slice's
  # plan.json and a copy of plan-nix.json so they can be diffed
  # outside of nix.  Plan-nix.json is plumbed in as a /nix/store path
  # (via `pkgsBuildBuild.writeText`) so it's a dep of this drv only,
  # not of the slice itself.
  planNixJsonFile = pkgs.buildPackages.writeText "plan-nix.json"
                      (builtins.toJSON planJson);
  checkAgainstPlan = buildCabalStoreSlice {
    pname = "check-${pkgName}-${componentKindLabel}-${componentName}";
    version = pkgVersion;
    inherit depSlices;
    inherit v2Fragment;
    inherit buildToolSourceFrags metadataSourceFrags;
    ghc = sliceGhc;
    twoStage = sliceTwoStage;
    localRepo = null;
    preBuild = slicePreBuildV2;
    target = targetSelector;
    extraBuildInputs = extraBuildInputs ++ extraDirInputs;
    inherit extraNativeBuildInputs withProgFlags
            allowedBuildToolPackages confLibraryDirs
            buildToolBinOverlays solverIncludesGlobalDb;
    # Per-component stdenv hardeningDisable (set via haskell.nix
    # `packages.<pkg>.components.<kind>.<name>.hardeningDisable =
    # ["fortify"]`).  Drives `NIX_HARDENING_ENABLE` for the slice's
    # build env so C-toolchain wrappers strip the listed hardening
    # flags before invoking gcc/clang — e.g. dropping `fortify`
    # prevents the Android NDK from pulling `bits/fortify/stdio.h`
    # into c2hs preprocessing, which c2hs can't parse.
    hardeningDisable = component.hardeningDisable or [];
    dryRunOnly = true;
    inherit planNixJsonFile;
  };

  # cabal-install records `documentation: True` (from cabal.project)
  # by setting `elabBuildHaddocks = True` on the elaborated install
  # plan and ALSO by adding `--ghc-option=-haddock` to the unit's
  # `configure-args` (so GHC keeps haddock comments in `.hi` files).
  # We use the `--ghc-option=-haddock` plan-json signal as evidence
  # that documentation was enabled at project-eval time — it's the
  # only haddock-related thing plan-nix surfaces in `configure-args`,
  # since the booleans (`elabBuildHaddocks`, the haddock-html /
  # haddock-hscolour / haddock-internal / ... family) live on the
  # ElaboratedConfiguredPackage and don't show up as configure-args.
  # When we see `-haddock` for a unit, we emit `documentation: True`
  # for that package in the slice's cabal.project (see
  # `documentationBlockFor` below) so the slice's elaboration sets
  # the same haddock booleans plan-nix did and the UnitIds match.
  # The marker alone is ambiguous (a plain `ghc-options: -haddock`
  # leaves the same arg without setting the haddock booleans), so it
  # is additionally gated on the project-text scan behind
  # `docEnabledNames` — see `projectSetsDocumentation` in
  # `builder/v2-project-globals.nix`.
  docEnabled =
    let uid   = package.identifier.unit-id or null;
        entry = if uid == null then null else planJsonByPlanId.${uid} or null;
        args  = if entry == null then [] else (entry.configure-args or []);
    in lib.elem "--ghc-option=-haddock" args
       && docEnabledNames ? ${pkgName};

  # Sibling slice that runs `cabal v2-haddock` and surfaces
  # haddock html in cabal's native unit-dir layout
  # (`$out/store/<ghc>/<unit-id>/share/doc/html/`).  Keeping
  # the cabal-store layout means the doc slice can be `lndir`'d
  # into `~/.cabal/store/` like any other slice.  Built only on
  # attribute access; the dry-run check below catches the case
  # where `documentation` propagation is incomplete.  Each unit
  # in the doc slice's `$out/store` carries only that unit's
  # own target's html; dep haddocks come from the corresponding
  # deps' own `.doc` slices propagated via `depSlices` — but
  # only for deps whose own plan-nix entry has documentation
  # enabled.  Mixed projects (some packages with docs, others
  # without) keep working because non-doc deps come in as plain
  # slices.
  docSlice = buildCabalStoreSlice {
    # See the comment on `baseSlice` for why we use pname + version
    # instead of `name` directly.  Doc slice goes after `version` so
    # the cross suffix lands BETWEEN pname and version, before the
    # `-doc` distinguisher.
    pname = "${pkgName}-${componentKindLabel}-${componentName}";
    version = "${pkgVersion}-doc";
    # Compose the main slice in plus, for each lib dep that
    # has documentation enabled in plan-nix, that dep's `.doc`
    # slice — so cabal v2-haddock finds the haddock-interfaces
    # it needs for `--read-interface=` (cross-package
    # hyperlinks) and doesn't try to rebuild the dep with
    # `--enable-documentation`.  Deps without docs keep coming
    # in as plain slices so mixed projects work.
    depSlices = depSlices ++ [ slice ]
                ++ map (d: d.doc) (lib.filter
                     (d: (d.passthru.docEnabled or false))
                     depSlices);
    inherit v2Fragment;
    # Haddock re-solves the package, including sibling components whose
    # dependencies are staged as source metadata by the normal slice.
    inherit buildToolSourceFrags metadataSourceFrags;
    ghc = sliceGhc;
    twoStage = sliceTwoStage;
    localRepo = null;
    preBuild = slicePreBuildV2;
    target = targetSelector;
    extraBuildInputs = extraBuildInputs ++ extraDirInputs;
    inherit extraNativeBuildInputs withProgFlags
            allowedBuildToolPackages confLibraryDirs
            buildToolBinOverlays solverIncludesGlobalDb;
    # Per-component stdenv hardeningDisable (set via haskell.nix
    # `packages.<pkg>.components.<kind>.<name>.hardeningDisable =
    # ["fortify"]`).  Drives `NIX_HARDENING_ENABLE` for the slice's
    # build env so C-toolchain wrappers strip the listed hardening
    # flags before invoking gcc/clang — e.g. dropping `fortify`
    # prevents the Android NDK from pulling `bits/fortify/stdio.h`
    # into c2hs preprocessing, which c2hs can't parse.
    hardeningDisable = component.hardeningDisable or [];
    # Per-component `Setup build -jN` (see modules/component-options.nix).
    buildJobs = component.buildJobs or null;
    doHaddock = true;
    # The build-cabal-slice dry-run check fails when cabal plans
    # to build anything other than `expectedPackage` — that's
    # exactly the diagnostic we want for `.doc`: if dep doc
    # slices' UnitIds don't match what cabal v2-haddock would
    # compute (i.e. the project hasn't enabled documentation
    # everywhere), the user gets a clear "package X needs
    # rebuild" error instead of a silent slow build.
    expectedPackage = pkgName;
  };

  # Composed dep store for this component — slices it builds on top
  # of, *not* the slice itself.  Useful as a starting point for
  # downstream `cabal v2-build` invocations, or for inspection
  # (`nix-build -A foo.components.library.store`).  `depSlices` is
  # only the *direct* set; `composeStore` follows each entry's
  # `$out/nix-support/transitive-deps` file for the closure.
  store = composeStore {
    name = "store-${ghc.targetPrefix or ""}${pkgName}-${componentKindLabel}-${componentName}-${pkgVersion}";
    slices = depSlices;
  };

  # Mirror v1's passthru/meta for exe / test / bench slices:
  #   * `exePath` — absolute path to the produced binary
  #   * `exeName` — filename (with platform extension)
  #   * `meta.mainProgram` — makes `nix run` target the right binary
  # See comp-builder.nix:453, 546-547, 576 for the v1 equivalents.
  isExeLike = ctype == "exe" || ctype == "test" || ctype == "bench";
  exePathAttrs = lib.optionalAttrs isExeLike {
    inherit exeName;
    exePath = "${slice}/bin/${exeName}";
  };

  # v1 exposed `.profiled` as an overlay rebuild with
  # `enableLibraryProfiling = true`.  v2 reads configure-args from
  # plan.json, so an overlay would emit toggles that plan-nix
  # doesn't know about and the slice's UnitId would diverge.
  # Express profiling in `cabal.project` instead; see
  # `docs/dev/profiling.md` for the migration recipe.  Setting
  # this at both the top level and inside `passthru` is needed
  # because mkDerivation only lifts `passthru` → top level at
  # derivation creation time, so post-hoc `// { passthru = ... }`
  # doesn't re-lift.
  profiledThrow = throw ''
    v2 slices do not provide `.profiled`.  Enable profiling
    by adding to cabal.project (or `cabalProjectLocal`):

        package ${pkgName}
          profiling: True
          library-profiling: True

    (or `package *` for project-wide).  See
    `docs/dev/profiling.md` for the rationale.
  '';

  # Same shape as `.profiled` above — v1's `.dwarf` was an overlay
  # rebuild with `enableDWARF = true` that also swapped to the GHC
  # `.dwarf` variant (RTS / `ghc-internal` compiled with -g).  In
  # v2 the overlay would diverge from plan-nix's UnitId, so the
  # two side-effects are expressed separately at project level:
  #   * `debug-info:` in cabal.project → DWARF in the user's code.
  #   * `compilerSelection` swap to `c.dwarf` → DWARF in the RTS.
  dwarfThrow = throw ''
    v2 slices do not provide `.dwarf`.  Enable DWARF debug info
    at project level:

      1. cabal.project (or `cabalProjectLocal`), for DWARF in
         the package's own modules:

             package ${pkgName}
               debug-info: 2

         (or `package *` for project-wide).

      2. `compilerSelection`, for DWARF in the GHC RTS and
         `ghc-internal` / `base`:

             project = cabalProject' {
               ...
               compilerSelection = p:
                 lib.mapAttrs (_: c: c.dwarf) p.haskell-nix.compiler;
             };

    The regular slice then contains DWARF and `<slice>.exePath`
    gives the debug-info exe directly.  See
    `docs/dev/debug-info.md` for the rationale.
  '';

  # `.doc` is the sibling haddock slice when the package's
  # plan-nix entry already includes `--ghc-option=-haddock`;
  # otherwise it throws with a migration recipe.  We don't
  # synthesise `.haddockDir` — local-package UnitIds in
  # plan-nix (`<pkg>-<ver>-inplace…`) don't equal cabal's
  # mangled-hash form in the slice's `$out/store/`, so there's
  # no eval-time-stable html path; callers should `find` it
  # under `slice.doc`.
  docAttrs = lib.optionalAttrs isLibrary {
    doc = if docEnabled then docSlice else throw ''
      v2 slices only expose `.doc` when haddock is part of the
      build's UnitId-determining inputs.  Add to cabal.project
      (or `cabalProjectLocal`):

          package ${pkgName}
            documentation: True

      (or `package *` for project-wide).  See
      `docs/dev/haddock.md` for the rationale.
    '';
    # Surfaced via passthru too so doc slices can branch in
    # `depSlices` between a dep's `.doc` (when it has one) and
    # the dep's regular slice (when it doesn't).
    inherit docEnabled;
  };

  decorate = base: base // exePathAttrs // docAttrs // {
      inherit checkAgainstPlan;
      profiled = profiledThrow;
      dwarf = dwarfThrow;
      passthru = base.passthru // {
        inherit checkAgainstPlan;
        isSlice = true;
        profiled = profiledThrow;
        dwarf = dwarfThrow;
      } // exePathAttrs // docAttrs;
      meta = (base.meta or {}) // lib.optionalAttrs isExeLike {
        mainProgram = exeName;
      };
      inherit store;
      # Noop `override` for v2 slices.  v1 derivations are
      # overridable functions; v2 slices are concrete derivations,
      # so we ignore the override args and return the same
      # decorated slice — and crucially preserve `override` on the
      # result so back-to-back `drv.override {...}.override {...}`
      # calls (as in the iserv-proxy-interpreter / -prof pair) work.
      override = _: decorate base;
    };
in decorate slice
