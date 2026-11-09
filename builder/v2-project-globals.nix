# Project-level data for the v2 builder, computed once per plan.
#
# Only two things live here, and neither may put project-wide information
# into a slice derivation:
#   * `pragmasOf`: a pure configure-args -> cabal.project field translation
#     that each slice applies to its OWN plan unit.
#   * `docEnabledNames`: each slice looks up only its own package name,
#     so only a boolean about itself reaches its derivation.  The boolean
#     is decided with the help of the project text (see
#     `projectSetsDocumentation`), an accuracy compromise that a per-unit
#     plan.json field from nix-tools would remove.
#
# Memoised behind the project-level module option
# `config.plan-json-v2-globals` (see
# `modules/install-plan/override-package-by-name.nix`) and passed into every
# slice via hspkg-builder.
{ lib }:

{ planJson      # plan.json's `install-plan` array
, rawCabalProject ? null
                # assembled cabal.project + cabalProjectLocal text the
                # plan was made from, or null when the caller can't
                # provide it (legacy pkg-set instantiations).  Used to
                # disambiguate the `-haddock` configure-arg marker —
                # see `projectSetsDocumentation` below.
}:
let
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

  # ---- configure-args -> cabal.project config fields ----------------
  # A pure translation, applied by each slice to its OWN plan unit's
  # `configure-args` (comp-v2-builder `configFields`).  Nothing here is
  # aggregated over the plan: a slice's config must come from its own node
  # (and, at build time, its closure's fragments), never from a project-wide
  # baseline, or the same unit hashes to a different derivation in a project
  # whose other packages are configured differently.
  #
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
  # A unit's config fields, one `<field>: <value>` per element, sorted.
  pragmasOf = args: lib.sort (a: b: a < b)
    (lib.unique (lib.filter (s: s != null) (map pragmaOf args)));
in {
  inherit pragmasOf docEnabledNames;
}
