# Map overrides of the form `packages.${pkg-name}` to all the matching
# packages in the plan.
{pkgs, config, options, ...}: {
  use-package-keys = true;
  package-keys = map (p: p.pkg-name) config.plan-json.install-plan ++ map (p: p.id) config.plan-json.install-plan;
  # A canonical pkg-name can appear in the install plan under
  # several ids (haskell.nix's per-instance UnitIDs — multiple
  # instances that differ only in their dep UnitIDs, or a multi-
  # component package split across per-component entries).  Group
  # the install-plan ids by their pkg-name so consumers can look
  # each up at `config.packages.${id}` instead of guessing by name.
  package-ids-by-name = pkgs.lib.foldl'
    (acc: p: acc // { ${p.pkg-name} = (acc.${p.pkg-name} or []) ++ [ p.id ]; })
    {}
    config.plan-json.install-plan;
  # The install plan keyed by plan id — a name → entry index over
  # `plan-json.install-plan` for O(log N) lookup of a specific
  # plan entry by its haskell.nix per-instance UnitID instead of
  # the linear scan a `lib.findFirst` over the list would do.
  #
  # A `pre-existing` unit can SHADOW a configured one under the same
  # id: the stable-haskell plan-time dummy dump reports a boot lib
  # installed as `base-4.22.0.0` while the project also builds it as
  # a local package under that same deterministic id (see the shadow
  # dedup in lib/load-cabal-plan.nix).  `listToAttrs` keeps the FIRST
  # occurrence and plan.json lists pre-existing units first, so
  # without reordering every shadowed boot lib resolves to the
  # pre-existing entry — which has no `style` / `component-name`,
  # silently disabling the v2 builder's local-`packages:` mode and
  # unit-id checks (`thisPlanEntry`, `isCustomBuild`,
  # `expectedUnitId`).  Configured entries must win.
  # Additionally a configured unit can appear under one id in BOTH the
  # fork's stages (host + build twins — make-install-plan emits bare
  # ids; see the twin dedup in lib/load-cabal-plan.nix).  The HOST twin
  # must win here too: this index drives `thisPlanEntry`,
  # `isCustomBuild`, `expectedUnitId` and the home-dep resolution, all
  # of which describe the host artifacts.
  plan-json-by-id =
    let isPre = p: p.type == "pre-existing";
        stageOf = pkgs.haskell-nix.haskellLib.planUnitStage;
        conf = pkgs.lib.filter (p: !(isPre p)) config.plan-json.install-plan;
    in pkgs.lib.listToAttrs
      (map (p: { name = p.id; value = p; })
        (pkgs.lib.filter (p: stageOf p == "host") conf
         ++ pkgs.lib.filter (p: stageOf p != "host") conf
         ++ pkgs.lib.filter isPre config.plan-json.install-plan));
  # The same index preferring BUILD twins — for the v2 builder's
  # custom-setup machinery: setup scopes are BUILD-stage, so the setup
  # closure walk and the `<pkg>:setup.<dep> ==<ver>` pins must follow
  # the build twin's dep set (the plan's real setup choices — e.g. the
  # haskell-gi codegen setups run against haskell-gi-overloading-1.0
  # while the host libs use 0.0).
  plan-json-by-id-build =
    let isPre = p: p.type == "pre-existing";
        stageOf = pkgs.haskell-nix.haskellLib.planUnitStage;
        conf = pkgs.lib.filter (p: !(isPre p)) config.plan-json.install-plan;
    in pkgs.lib.listToAttrs
      (map (p: { name = p.id; value = p; })
        (pkgs.lib.filter (p: stageOf p == "build") conf
         ++ pkgs.lib.filter (p: stageOf p != "build") conf
         ++ pkgs.lib.filter isPre config.plan-json.install-plan));
  # Project-global v2-builder data derived once from the plan (see
  # `builder/v2-project-globals.nix`).  Lazy: only forced by the v2
  # builder, so v1 / non-plan projects never pay for it.
  plan-json-v2-globals = import ../../builder/v2-project-globals.nix {
    inherit (pkgs) lib;
  } {
    planJson = config.plan-json.install-plan;
    inherit (pkgs.haskell-nix.haskellLib) planUnitStage;
    # Assembled project text for the `documentation:` scan; null (=
    # unknown) when neither piece was threaded into this pkg-set
    # (stack / legacy instantiations).
    rawCabalProject =
      if config.cabalProject or null == null && config.cabalProjectLocal or null == null
      then null
      else (if config.cabalProject or null == null then "" else config.cabalProject)
         + "\n"
         + (if config.cabalProjectLocal or null == null then "" else config.cabalProjectLocal);
  };
  packages = pkgs.lib.listToAttrs (map (p: {
      name = p.id;
      value = pkgs.lib.modules.mkAliasDefinitions (options.packages.${p.pkg-name});
    }) (pkgs.lib.filter (p: p.id != p.pkg-name) config.plan-json.install-plan));
}
