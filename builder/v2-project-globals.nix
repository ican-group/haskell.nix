# Project-global data derived once from plan.json for the v2 builder.
#
# `projectConfigPragmas`, the documentation-enabled package set, and the
# per-package source-repo flag map all depend ONLY on the install plan
# (plus the project's ghc version and host platform) — never on any
# individual component.  comp-v2-builder needs them while emitting every
# slice's `cabal.project`, and computing them inline meant re-scanning
# the whole plan (and re-running the configure-arg regexes) once per
# component — which dominated v2 evaluation (hundreds of millions of
# `builtins.match` / `lib.elem` calls on a project the size of
# cardano-node).
#
# So we compute them ONCE here and memoise the result behind the
# project-level module option `config.plan-json-v2-globals` (see
# `modules/install-plan/override-package-by-name.nix`), then pass it into
# every slice via hspkg-builder.
{ lib }:

{ planJson      # plan.json's `install-plan` array
, planUnitStage # haskellLib.planUnitStage: a plan unit's stage
                # ("build" / "host")
, rawCabalProject ? null
                # assembled cabal.project + cabalProjectLocal text the
                # plan was made from, or null when the caller can't
                # provide it (legacy pkg-set instantiations).  Used to
                # disambiguate the `-haddock` configure-arg marker —
                # see `projectSetsDocumentation` below.
}:
let
  # ---- per-package source-repo flags (was `planFlagsFor`) ----------
  # For source-repository-package units, module-system flag overrides
  # don't reach cabal-install at plan time, so the slice must reproduce
  # the flag assignment plan-nix actually saw — plan-json's flags.
  # Hackage / repo-tar / local packages keep the module-flag behaviour
  # (resolved per-slice, not here).  Keyed on the *first* unit of each
  # pkg-name, matching the old `lib.findFirst` semantics.
  firstUnitByName = lib.foldl'
    (acc: p:
      let n = p.pkg-name or null;
      in if n == null || acc ? ${n} then acc else acc // { ${n} = p; })
    {} planJson;
  flagsByName = lib.filterAttrs (_: v: v != null)
    (lib.mapAttrs
      (_: unit:
        let srcType = (unit.pkg-src or {}).type or null;
        in if srcType == "source-repo" then unit.flags or {} else null)
      firstUnitByName);

  # ---- documentation-enabled package names (was `pkgDocEnabled`) ----
  # `documentation: True` adds `--ghc-option=-haddock` to a unit's
  # configure-args; a name is "doc-enabled" if any of its units carry it.
  #
  # The marker is ambiguous: a plain `ghc-options: -haddock` in the
  # project (e.g. haskell-language-server's `package *` stanza) leaves
  # the IDENTICAL configure-arg, but its elaborated units hash with
  # `pkgHashDocumentation = False` — emitting `documentation: True` for
  # them forks the slice's UnitId from plan-nix AND makes `cabal
  # v2-build` run the haddock program (which stable-haskell compilers
  # don't ship).  plan.json has no truthful per-unit documentation
  # field (`haddock-args` is always the bare verb), so disambiguate
  # with the project text: only treat `-haddock` as documentation when
  # some line of the assembled cabal.project actually turns
  # `documentation:` on.  Coarse (a doc-True project that ALSO gives
  # some package plain `ghc-options: -haddock` still misclassifies
  # that package, and `import:`ed files are not scanned) — the real
  # fix is make-install-plan emitting `elabBuildHaddocks`, at the cost
  # of a nix-tools (world-rebuild) change.  With rawCabalProject
  # unknown (null) keep the old marker-only behaviour.
  projectSetsDocumentation =
    rawCabalProject == null
    || lib.any
         (l: builtins.isString l
             && builtins.match "[ \t]*documentation[ \t]*:[ \t]*[Tt]rue[ \t\r]*" l != null)
         (builtins.split "\n" rawCabalProject);
  docEnabledNames =
    if !projectSetsDocumentation then {}
    else lib.listToAttrs (lib.concatMap
      (e:
        if lib.elem "--ghc-option=-haddock" (e.configure-args or [])
        then [ { name = e.pkg-name or ""; value = true; } ]
        else [])
      planJson);

  # ---- projectConfigPragmas (was the inline `let` in comp-v2) ------
  # Each plan entry's `configure-args` is per-unit; we group by pkg-name
  # (since cabal.project only supports per-package granularity) and emit
  # a `package *` baseline block plus per-package delta blocks, so the
  # slice's `cabal v2-build` keeps `pkgHashConfigInputs` aligned with
  # plan-nix.  See `pragmasByName` for how the Build and Host stages of a
  # two-stage plan are reconciled.
  configuredEntries = lib.filter (p: (p.type or "") == "configured") planJson;

  # Whitelist of cabal.project field names that map 1:1 to
  # `--enable-X` / `--disable-X` / `--X=value` Setup configure args.
  isProjectField = field: lib.elem field [
    "shared" "static"
    "library-vanilla" "library-profiling"
    "executable-dynamic" "executable-static"
    "profiling" "profiling-shared"
    "optimization" "debug-info" "build-info"
    "library-for-ghci"
    "split-sections" "split-objs"
    "executable-stripping" "library-stripping"
    "coverage" "relocatable"
    "profiling-detail" "library-profiling-detail"
  ];
  pragmaOf = arg:
    let
      en = builtins.match "--enable-([a-z0-9-]+)" arg;
      di = builtins.match "--disable-([a-z0-9-]+)" arg;
      kv = builtins.match "--([a-z0-9-]+)=(.+)" arg;
    in
      # `debug-info` is a LEVEL (0..3), not a boolean: its cabal.project value is
      # parsed by `flagToDebugInfoLevel`, which rejects True/False ("Can't parse
      # debug info level False").  This matters with the stable-haskell Cabal
      # fork (3.17); older Cabal accepted the boolean form.  Map the enable/
      # disable Setup flags to the equivalent level (disable → 0 = NoDebugInfo,
      # matching `--disable-debug-info`; enable → 2 = NormalDebugInfo, the
      # no-arg default) so `pkgHashConfigInputs` stays aligned with plan-nix.
      if di != null && builtins.head di == "debug-info" then "debug-info: 0"
      else if en != null && builtins.head en == "debug-info" then "debug-info: 2"
      else if en != null && isProjectField (builtins.head en) then "${builtins.head en}: True"
      else if di != null && isProjectField (builtins.head di) then "${builtins.head di}: False"
      else if kv != null && isProjectField (builtins.head kv) then "${builtins.head kv}: ${builtins.elemAt kv 1}"
      else null;
  pragmasOf = args: lib.unique (lib.filter (s: s != null) (map pragmaOf args));

  # pkg-name → stage → union of pragmas across that stage's units.
  pragmasByNameStage = lib.foldl' (acc: e:
    let
      name = e.pkg-name or "";
      stage = planUnitStage e;
      ps = pragmasOf (e.configure-args or []);
      byStage = acc.${name} or {};
    in if name == "" then acc
       else acc // {
         ${name} = byStage // {
           ${stage} = lib.unique ((byStage.${stage} or []) ++ ps);
         };
       }
  ) {} configuredEntries;

  # Fields that cabal itself applies to Host units only, however they are
  # set (the fork's `withFullyStaticExe` is `solverPkgStage == Host && ...`).
  hostScopedFields = [ "executable-static" ];
  fieldOf = p: builtins.head (builtins.match "([^:]+):.*" p);

  # pkg-name → the pragmas to emit for it.
  #
  # A package can have units in both stages of a two-stage plan (base,
  # containers, ...: the Build copies serve the build tools), and a
  # `package <name>` stanza applies to both -- the fork's cabal has
  # stage-qualified stanzas only for whole stages (`package build:*`), and
  # a per-package stanza overrides them.  So per package:
  #   * a pragma every stage agrees on is emitted;
  #   * a Host-scoped field that differs keeps its Host value, which cabal
  #     will not apply to the Build units anyway;
  #   * any other field that differs is left out here, and carried by the
  #     `package <stage>:*` stanzas instead (see `stageBlocks`).
  # Emitting either value per package would impose it on the other stage:
  # that is how a wasm `shared: True` reached the Build-stage happy-lib and
  # failed for want of `Prelude.dyn_hi` in the Build base.
  pragmasByName = lib.mapAttrs (_: byStage:
    let
      stages = builtins.attrValues byStage;
      host = byStage.host or [];
    in if builtins.length stages == 1 then builtins.head stages
       else lib.filter
              (p: lib.all (ps: lib.elem p ps) stages
                  || (lib.elem (fieldOf p) hostScopedFields && lib.elem p host))
              (lib.unique (lib.concatLists stages))
  ) pragmasByNameStage;
  allPkgNames = builtins.attrNames pragmasByName;

  # Baseline: for each field that *every* pkg-name sets, the value most
  # pkg-names agree on (ties go to the first in sort order).
  #
  # The baseline (in the `package *` block) is part of every slice's
  # cabal.project skeleton, so it must not change just because some
  # package elsewhere in the plan is configured differently.  An
  # intersection would: one local package with `coverage: True` (or
  # `profiling: True`) drops `coverage` from it, and with it every
  # package's slice gets a different skeleton from the same slice in a
  # project without that package.  The majority value keeps such
  # outliers in their own per-package blocks (`perPkgConfigBlocks`),
  # which reach only the slices whose closure contains that package.
  #
  # Restricting to fields every package sets keeps each package's
  # effective configuration exactly its own pragmas: its block overrides
  # every baseline value it disagrees with, and the baseline never
  # supplies a field the package itself left unset (a stage-differing
  # field dropped by `pragmasByName`, say).
  baseline =
    if allPkgNames == [] then []
    else
      let
        firstPkg = builtins.head allPkgNames;
        commonFields = lib.filter
          (f: lib.all (n: lib.any (p: fieldOf p == f) pragmasByName.${n}) allPkgNames)
          (lib.unique (map fieldOf pragmasByName.${firstPkg}));
        valueCounts = f: lib.foldl' (acc: n:
          lib.foldl' (acc': p: acc' // { ${p} = (acc'.${p} or 0) + 1; }) acc
            (lib.filter (p: fieldOf p == f) pragmasByName.${n})
        ) {} allPkgNames;
        majority = f:
          let counts = valueCounts f;
          in lib.foldl' (best: p: if counts.${p} > counts.${best} then p else best)
               (builtins.head (builtins.attrNames counts))
               (builtins.attrNames counts);
      in map majority commonFields;
  baselineSet = lib.listToAttrs (map (p: { name = p; value = true; }) baseline);

  baselineBlock =
    if baseline == [] then ""
    else "package *\n"
       + lib.concatMapStrings (p: "  " + p + "\n") baseline;

  # Stage-qualified stanzas for the fields `pragmasByName` leaves out.
  #
  # A field that differs between a package's stages is either computed per
  # stage by cabal (e.g. `shared`, which defaults on for a wasm Host --
  # `target RTS linker only supports shared libraries` -- and off for the
  # native Build compiler) or set per stage by the project, now that the
  # fork's cabal accepts `package build:*` / `package host:*`.  Either way
  # the plan recorded one value per stage.  For every such field, emit each
  # stage's value in `package <stage>:*` wherever all of that stage's
  # packages agree on it, so the slice reproduces it explicitly.  Where a
  # stage is not uniform the field stays unset there, and the slice's cabal
  # recomputes it the way plan-nix's did.  Per-package stanzas override
  # these, and only ever carry values that hold in all of a package's
  # stages, so every package still sees its own value.
  #
  # Single-stage plans have no such fields, so they get no stage stanzas
  # and their text is unchanged.  Host-scoped fields keep their special
  # handling above.
  stageNames = lib.unique (lib.concatMap builtins.attrNames
    (builtins.attrValues pragmasByNameStage));
  differingFields = lib.unique (lib.concatLists (lib.mapAttrsToList
    (_: byStage:
      let lists = builtins.attrValues byStage;
      in if builtins.length lists < 2 then []
         else map fieldOf (lib.filter
                (p: !(lib.all (ps: lib.elem p ps) lists))
                (lib.unique (lib.concatLists lists))))
    pragmasByNameStage));
  stageBlockPragmas = stage:
    let
      inStage = lib.filter (n: pragmasByNameStage.${n} ? ${stage})
                  (builtins.attrNames pragmasByNameStage);
      listsOf = map (n: pragmasByNameStage.${n}.${stage}) inStage;
    in if inStage == [] then []
       else lib.filter
              (p: lib.elem (fieldOf p) differingFields
                  && !(lib.elem (fieldOf p) hostScopedFields)
                  && lib.all (ps: lib.elem p ps) listsOf)
              (builtins.head listsOf);
  stageBlocks = lib.concatMapStrings (stage:
    let ps = stageBlockPragmas stage;
    in if ps == [] then ""
       else "package ${stage}:*\n"
          + lib.concatMapStrings (p: "  " + p + "\n") ps
  ) stageNames;

  # pkg-name → its delta block.  Not part of `projectConfigPragmas`: each
  # slice carries its own package's block in its fragment
  # (comp-v2-builder `configBlock`) and composes those of its dependency
  # closure at build time, like the flags / ghc-options blocks.  Emitting
  # every package's block in every slice made each slice depend on the
  # whole plan.
  perPkgConfigBlocks = lib.filterAttrs (_: b: b != "") (lib.genAttrs allPkgNames (name:
    let delta = lib.filter (p: !(baselineSet ? ${p})) pragmasByName.${name};
    in if delta == [] then ""
       else "package ${name}\n"
          + lib.concatMapStrings (p: "  " + p + "\n") delta));

  projectConfigPragmas = baselineBlock + stageBlocks;
in {
  inherit projectConfigPragmas perPkgConfigBlocks docEnabledNames flagsByName;
}
