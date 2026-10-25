# V2 Component Builder (cabal v2-build / slice-based)

The v2 builder is an alternative to the v1 (`Setup.hs`-based) builder.
Where v1 produces one nix derivation per Cabal component by invoking
`Setup.hs` directly (see `builder-v1.md`), v2 produces one nix
derivation per Cabal component by running `cabal v2-build` inside an
isolated, pre-populated **cabal store** and capturing the new entries
that invocation produced.

The unit of output is a *slice* — a directory laid out exactly the
way cabal's store is (`host/<platform>/`), holding only the units
this component caused cabal to install.  Composing a downstream
slice's starting store from upstream slices' `$out/store/` (via
`lndir`) lets cabal reuse those units instead of rebuilding.

Switch builders at the project level by setting `builderVersion = 2;`
(the default).  The component derivation at
`hsPkgs.<pkg>.components.<kind>.<n>` is whichever builder
`builderVersion` selects — there's no per-component opt-in.

## Why v2 exists

- **Sublibs work in the dev shell.**  The v1 shell wraps GHC with a
  pre-populated package db, which doesn't expose Cabal *public sublibs*
  (`library <n>` stanzas) to a downstream `cabal v2-build` — the user's
  cabal solver re-builds the sublib from source even though we have it
  pre-built.  The v2 shell pre-populates the user's cabal store
  instead, so cabal sees every component (main lib + sublibs + exe-only
  units) as already-installed and reuses them.
- **Match what users see in development.**  `cabal v2-build` is the
  command users run interactively.  Producing a slice with the same
  command (and the same UnitId hash inputs) means the units we
  pre-populate in the project's cabal store *can* be reused by a plain
  `cabal v2-build` inside the shell.

## What v2 produces

For each component (`lib`, `lib:<sublib>`, `exe:<name>`,
`test:<name>`, `bench:<name>`), v2 produces a single nix derivation
whose `$out` looks like:

```
$out/
├── store/
│   └── ghc-<ver>-inplace/
│       ├── package.db/<unit-id>.conf …  (new units installed by this slice)
│       ├── <unit-id>/…                  (new unit dirs)
│       └── lib/lib<unit-id>-…dylib      (flat dylibs cabal emits)
├── dist-newstyle/                       (full cabal dist tree)
├── unit-ids                             (newline-separated list of captured units)
├── nix-support/propagated-build-inputs  (pkg-config / framework / windows-lib deps)
└── bin/<exe-name>                       (only for exe/test/bench)
```

`$out/store/<ghcDir>/` is the cabal-store layout cabal expects.
Composing many slices via `lndir` produces a merged store whose
`<unit-id>.conf` files come from whichever slice produced each unit;
`ghc-pkg recache` over the merged db makes the whole set queryable.

A v2 slice's UnitId is required to equal the plan-id plan-nix
recorded for that component (`expectedUnitId` check, see below).
The captured set in `$out/store/` must equal exactly
`[expectedUnitId]`; any extras are an error.

## High-level flow

1. **`modules/component-driver.nix`** drives `config.hsPkgs` exactly
   the same way v1 does.  It calls `builder.build-package config pkg`
   for each package and stores the result in `config.hsPkgs`.

2. **`builder/hspkg-builder.nix`** receives `pkg` and walks every
   buildable component.  For each one it computes:
   - `homeDependIds` — sibling-component plan-json deps for cabal's
     re-solve inside the slice (so the slicing repo holds every
     tarball cabal might need).
   - `pkgSet`, `packageIdsByName`, `planJsonByPlanId` — the
     canonical-name + plan-id keyed view of the install plan that
     comp-v2-builder uses to find per-plan-unit configure-args.
     `planJsonByPlanId` is the project-level
     `config.plan-json-by-id` index so per-component lookups are
     O(log N) attrset hits rather than linear scans over the
     install-plan list.

   Then it calls `comp-v2-builder` for each component and returns
   the result.  Under `builderVersion = 2`, that derivation IS the
   primary value at `hsPkgs.<pkg>.components.<kind>.<n>`.

3. **`builder/comp-v2-builder.nix`** computes the slice's
   `cabal.project`, the slicing repo (a derivation with all the
   `<pkg>-<ver>.tar.gz` files cabal might need + an `00-index.tar.gz`),
   the dep slices to compose, and the slice's `name` / `target` /
   `expectedPackage` / `expectedUnitId`, then calls
   **`buildCabalStoreSlice`**.

4. **`builder/build-cabal-slice.nix`** (alias `buildCabalStoreSlice`)
   is the slice derivation itself.  It composes dep slices via
   `lndir` into a starting cabal store — walks `pkgsHostTarget`
   for direct deps and follows each entry's
   `$out/nix-support/transitive-deps` for the rest of the closure,
   so transitive dep slices stay out of nix-side `buildInputs` —
   runs `cabal v2-build --dry-run` (and validates the plan
   against `expectedPackage`), then runs `cabal v2-build` for
   real, captures the new units into `$out/store/`, and writes
   the slice's own `nix-support/transitive-deps` so downstream
   consumers can follow the closure the same way.  The
   `expectedUnitId` check at the end requires the captured set
   to equal `[expectedUnitId]` exactly.

   Cabal-file overrides are copied before package patches and hooks, matching
   V1. For patched or hooked sources, every slice index uses the resulting
   tarball's Cabal file; it must not restore the unpatched override during
   Cabal's revision update. Untouched Hackage sources retain their original
   tarball and separate revised Cabal file. Run the source-only regression with
   `make test-v2-cabal-overrides SYSTEM=aarch64-darwin TIMEOUT=300` (or your native
   system); it does not build a Haskell compiler or package.

5. **`builder/compose-store.nix`** is a tiny helper that lndirs
   slices into a single cabal-store layout, walking
   `pkgsHostTarget` and following `nix-support/transitive-deps`
   files exactly like the slice's own buildPhase.  Used by the
   per-component `.store` attribute (the slice's *deps*, not the
   slice itself) and by the v2 shell's composed store.

## Data flow per component

```
plan.json + module config
  │
  ▼
componentTarball (incl. patches)
  │
  ▼
slicingRepo (every dep's source tarball + this component's tarball,
  │           plus a synthesised 00-index.tar.gz that cabal can read
  │           via `repository … url: file://…  secure: False`)
  │
  ▼
cabal.project    (with-compiler, active-repositories, allow-newer,
  │              extra-packages: <target> + <constrained deps>,
  │              constraints: any.<target> source, <pin> ==<ver> source,
  │              per-package ghc-options / configure-options / flags,
  │              per-package extra-(include|lib|framework)-dirs for
  │              `c.frameworks` only — `c.libs` and `c.pkgconfig`
  │              are deliberately excluded (their nix-store paths
  │              would land in `pkgHashExtra(Include|Lib)Dirs` and
  │              fork the slice's UnitId from plan-nix's, since
  │              plan-to-nix's compute never sees the
  │              haskell.nix-injected paths).  The cc wrapper
  │              still finds these libs via NIX_*_FOR_TARGET — the
  │              slice has them in `extraBuildInputs`,
  │              project-level cabal pragmas extracted from plan.json's
  │              configure-args)
  │
  ▼
buildCabalStoreSlice
  ├─ lndir each depSlice's $out/store into $storeDir
  ├─ ghc-pkg recache (merged db)
  ├─ cabal v2-build --dry-run  →  validate against expectedPackage
  └─ cabal v2-build            →  produce new units
  │
  ▼
$out/store/<ghcDir>/…   (this slice's captured units)
$out/dist-newstyle/…    (full cabal dist tree)
$out/bin/<exe-name>     (extracted from the captured store)
```

## How cabal's solve is constrained

There's no "shim" package.  Each slice's `cabal.project` has:

- **No `packages:` line.**  Cabal v2-build accepts a project with
  only `extra-packages:` so long as the targets use the remote-package
  qualifier (`:pkg:foo:lib:bar`).
- **`extra-packages:`** lists the slice's target package + every
  entry in `libConstraintPins` (the lib-dep closure of this
  component's plan units).  Without listing them as goals,
  cabal silently drops `<pkg> source` constraints on transitively-
  introduced packages.
- **`constraints:`** has one line per pinned dep:
  ```
  constraints: any.<target> source
  constraints: <dep> ==<ver>, <dep> source
  …
  ```
  Pre-existing (boot) packages are skipped — re-pinning them tends
  to push cabal off the legacy-tool PATH fallback for tools like
  `hsc2hs`, and GHC's bundled package db already fixes their
  versions.
- **`active-repositories: hackage.haskell-nix`** so cabal only sees
  the slicing repo (the user's real hackage is invisible).
- **`allow-newer: *:*`** so stale upper bounds in `.cabal` files
  don't reject the single candidate version we ship per package.
- **Project-level `package *` block** carrying the
  `--enable-shared` / `--enable-static` / etc. toggles plan-nix
  recorded in its `configure-args` — without this, cabal's defaults
  fork `pkgHashEnableSharedLib` and friends from plan-nix.

The slice targets the package's component directly via cabal's
`:pkg:` qualifier (`:pkg:foo:lib:bar`).  cabal-install bug #8684
makes the bare form fail when the package isn't in `packages:`, so
the qualifier is always required.

## How dep slices compose

`comp-v2-builder` collects every slice the current component needs:

- `directDepSlices` — every lib dep of this component, from
  `component.depends`.  Slices for sibling components of the same
  package (e.g. a sublib) are kept; only a same-package self-reference
  (added by `lookupDependency` for Custom-build-type packages) is
  dropped.
- `ownLibSlice` — when this is a non-library component (test,
  bench, exe) of a Cabal-spec ≥ 2.0 package, the same package's
  library slice goes into the starting store too, so cabal reuses
  the lib unit instead of rebuilding it.
- `buildToolSlices` — every v2 exe slice resolved from
  `build-tool-depends` (alex, happy, hsc2hs, ...).  Composing them
  into the starting store lets cabal's solver find them as
  already-installed.
- `homeDepSlices` — sibling-component plan-json deps that aren't
  in `component.depends` (e.g. tests' deps when building a lib).

Only the *direct* dep slices are passed in nix-side
`buildInputs` (deduped via `haskellLib.uniqueWithName`, which
partitions by `identifier.unit-id` so two incarnations of the
same `name-version` land in separate buckets).  The slice's
buildPhase walks `pkgsHostTarget` for the direct entries and
follows each one's `$out/nix-support/transitive-deps` to pull
in the rest of the closure at build time, then `lndir`s every
unique entry's `$dep/store` into `$storeDir` before
`cabal v2-build` runs.  cabal sees the dep units as
already-installed and skips them.

Hoisting the closure walk out of the nix evaluator and into
bash (with the closure recorded per-slice in
`nix-support/transitive-deps`) keeps `buildInputs` lists short
and avoids the O(N²) heap blow-up the previous nix-side
`passthru.transitiveStoreSlices` walk caused on big projects.

## UnitId stability

`cabal v2-build` hashes `PackageHashInputs` to compute each
component's UnitId, including:

- Source archive hash (`pkgHashSourceHash`),
- Dependency component IDs,
- `pkgHashCompilerId` (`with-compiler:` text in cabal.project),
- `pkgHashFlagAssignment` (per-package `flags:`),
- `pkgHashProgramArgs` (program option arguments, including per-package
  `ghc-options:`),
- `pkgHashConfigureScriptArgs` (per-package `configure-options:`),
- `pkgHashExtra(Include|Lib)Dirs` (per-package
  `extra-(include|lib)-dirs:`),
- `pkgHashEnableSharedLib` / `pkgHashEnableStaticLib` /
  `pkgHashEnableLibraryForGhci` / profiling / split-sections /
  split-objs toggles.

For the units we pre-install via `depSlices` to be reused inside
the slice's own `cabal v2-build`, *every* hash input listed above
has to be identical between the producing slice and this slice.
That's why comp-v2-builder is careful about:

- Reading `ghcOptions` / `configureOptions` from both
  `packages.<n>.<field>` (set by the user via `modules`) and
  `packages.<plan-id>.<field>` (set by `configure-args.nix` from
  plan.json's `configure-args`).  See `perPackageOptionOf`.
- Filtering `-hide-all-packages` from extracted ghc-options
  under v2 only (`configure-args.nix`): cabal injects it on
  every `Setup configure` call, so round-tripping it through
  the v2 builder's per-package `ghc-options:` block would
  produce a duplicate `--ghc-option=-hide-all-packages` entry
  in `pkgHashProgramArgs`, while a downstream `cabal v2-build`
  outside the slice only sees it once — forking the UnitId
  hash and defeating cache reuse.  v1 doesn't round-trip
  through cabal.project, so it leaves the option alone.
- Emitting per-package `extra-(include|lib|framework)-dirs`
  blocks for each dep's own `c.frameworks` only.  `c.libs` and
  `c.pkgconfig` deliberately do *not* land here — their
  nix-store paths would feed
  `pkgHashExtra(Include|Lib)Dirs` and fork unit-ids from
  plan-nix's (plan-to-nix's compute never sees the
  haskell.nix-injected paths).  cabal still finds these libs
  via the wrapped cc / pkg-config — the slice's
  `extraBuildInputs` carries them so
  `NIX_CFLAGS_COMPILE_FOR_TARGET` /
  `NIX_LDFLAGS_FOR_TARGET` route them in at compile / link
  time.  See `pkgcfglessSysLibs`.
- Keeping the dummy GHC's `--info` capability fields aligned with
  the real GHC's (see `lib/call-cabal-project-to-nix.nix`).
  Without `Support dynamic-too: YES` / `RTS ways: … dyn` in the
  dummy, plan-to-nix records `--disable-shared` while the real
  cabal v2-build picks `--enable-shared`, forking
  `pkgHashEnableSharedLib`.  ghcjs / wasm cross targets keep the
  more restricted capability set since their cross GHCs really
  don't ship a dynamic RTS.

After `cabal v2-build --dry-run` the slice cross-checks the plan
against `expectedPackage` and exits early if cabal is about to
build any package other than the slice's target — that almost
always means a hash input has drifted.  After the build, the
captured unit-ids must equal `[expectedUnitId]` exactly.

Patching a Hackage archive after project planning can still violate this
check: the slice uses a repacked archive while the project plan records the
upstream archive's hash. A native AArch64 Darwin/GHC 9.14 build of patched
`crypton-x509-system-1.6.8` reproduces this failure both before and after the
Cabal-override ordering fix, with identical direct dependency IDs. Keeping
the effective Cabal file in the slice's indexes does not resolve this
planning/source consistency limit. Supply consistent sources before project
planning; do not disable the unit-ID check to accept a different result.

## `checkAgainstPlan` — diagnosing divergence

Each slice has a sibling derivation at
`hsPkgs.<pkg>.components.<kind>.<n>.checkAgainstPlan`.  It re-runs
*just* the slice's `cabal v2-build --dry-run` step, captures the
slice's `dist-newstyle/cache/plan.json`, and diffs each entry
against the corresponding entry in plan-nix.json (matched by id,
otherwise by `pkg-name` + `component-{name,type}`).  Both are
pretty-printed with `jq -S` and diffed with full-file context so
the diverging field (compiler-id, flags, dep unit-ids, …) is
visible against the rest of the entry.

Plan-nix.json is plumbed in via `pkgsBuildBuild.writeText` only on
`checkAgainstPlan` itself — it's never a dep of the slice.

```
nix build .#…hsPkgs.<pkg>.components.library.checkAgainstPlan
cat result/diff-report.txt    # per-pkg full-context diffs
cat result/cabal.project      # the slice's exact cabal.project
cat result/build.log          # cabal v2-build --dry-run output
```

`$out` also contains the slice's full `plan.json`, a copy of
plan-nix.json, and the slice's `build.log`.

## Per-component `.store` attribute

`comp-v2-builder` attaches `.store` to each slice — a derivation
holding the lndir'd composition of that component's `depSlices`
(the deps, not the slice itself).  Useful for inspection:

```
nix-build -A 'foo.components.library.store'
```

The same `composeStore` helper builds the v2 shell's composed dep
store; both attach a `package.cache` produced by `ghc-pkg recache`.

## Dev shell

When a project sets `builderVersion = 2;`, `project.shell` and
`project.shellFor { ... }` automatically dispatch to the v2
implementation in `builder/shell-for-v2.nix` (see the dispatch in
`builder/default.nix`).  Users opting into v2 wholesale don't have
to change their shell call site.

Where the v1 shell wraps GHC with a pre-populated package db, the
v2 shell pre-populates the project's cabal store so a plain
`cabal v2-build` inside the shell reuses our slices instead of
rebuilding from source — and so public sublibs that the v1
GHC-package-db approach can't expose to cabal show up correctly.

The v2 builder's cabal-install (`haskell-nix.v2-cabal-install`, the
stable-haskell fork) keeps a project-local store under the build dir,
`<project root>/dist-newstyle/store/`, with units under
`host/<platform>/` (and a `build -> host` link for build-stage
units).  The project root is found the way cabal finds it: the
nearest directory at or above `$PWD` with a `cabal.project`, else
`$PWD`.  A project built with `--builddir DIR` re-runs
`haskell-nix-cabal-store-sync DIR`.

The shell's `cabal` has to be that same cabal-install: a different
one computes different UnitIds (and may not read the `host/`
layout), misses every unit, and rebuilds the world.
`tools.cabal = {}` or `"latest"` selects it; it is also available
as `project.v2-cabal-install` for shells built without `shellFor`.

The hook (`haskell-nix-cabal-store-sync`):

1. Writes a `nix-store --add-root --indirect` gcroot for the
   composed dep store under `<store>/.haskell-nix-gcroots/`
   so `nix-collect-garbage` can't drop the slices our links point
   at.
2. Scans every `<unit-id>.conf` / unit-dir / lib file in the
   composed store against the project's existing store,
   classifying each as new, same, or conflict.
3. If conflicts exist and `--force` wasn't passed, errors out with
   a summary (and instructions to re-run with `--force`).
4. Symlinks new (and, with `--force`, conflicting) entries from
   composedStore into the project's store via `ln -s` (single files)
   or `lndir` (unit dirs).
5. Runs `ghc-pkg recache` on each touched package db.

The script is exposed standalone as `haskell-nix-cabal-store-sync`,
so a user can re-run it with `--force` from inside the shell.

### Cross compilation

For each cross target (`crossPlatforms = p: [ p.ghcjs ]; …`) the
overlay adds the cross project's shell to the main shell's
`inputsFrom`.  `shell-for-v2.nix`:

- Routes `cabalStoreSync` through `pkgs.pkgsBuildBuild.writeShellScriptBin`
  so the cross shell evaluates without a host CC (cross targets
  like ghcjs have none).
- Resolves `shellGhc` to the cross-compiling GHC at
  `pkgs.buildPackages.haskell-nix.compiler.<n>` (build → host) —
  i.e. a GHC that runs on the build platform but targets the
  cross host.
- Builds a `${prefix}cabal` wrapper (e.g.
  `javascript-unknown-ghcjs-cabal`) that invokes plain `cabal`
  with `--with-compiler=<ghcShim>/bin/${prefix}ghc` so the user
  doesn't have to remember the cross-GHC paths.  `ghcShim` is a
  tiny symlink farm exposing both prefixed and unprefixed GHC
  binaries so cabal v2-build's "near compiler" lookup finds plain
  `ghc-pkg`.
- Merges `passthru.depSlices` from every `inputsFrom` shell into
  this shell's `composedStore` so cross + native slices both seed
  the project's cabal store.

## How configure-args.nix integrates

Cabal's `plan.json` records the exact `Setup configure` command
line it would invoke for each plan unit.
`modules/install-plan/configure-args.nix` parses those:

- `--ghc-option=X` / `--ghcjs-option=X` →
  `packages.<plan-id>.ghcOptions`
- `--configure-option=X` →
  `packages.<plan-id>.configureOptions`
- other `--PROG-option=X` →
  `packages.<plan-id>.configureFlags`

These get merged with the canonical-name-keyed entry that the user
writes via `modules`.  `comp-v2-builder.nix`'s
`perPackageOptionOf` reads both and complains if components / plan
units disagree (cabal's `package <n>` block applies to all
components — there's no way to emit per-component values via
cabal.project).

## Testing & checking

The slice itself only *builds* a test/bench's binary — actually
running it is left to `lib/check.nix` (via `haskellLib.check`),
mirroring v1's split between build-time and check-time.  For
cross-host targets that need a launcher (windows: wine; ghcjs:
node), the launcher prefix is taken from the slice's
`passthru.config.testWrapper` (set by the windows / ghcjs default
modules).

## Key files

| Path                                                | Role                                                       |
|-----------------------------------------------------|------------------------------------------------------------|
| `builder/comp-v2-builder.nix`                       | per-component: cabal.project + slicingRepo + plumbing      |
| `builder/build-cabal-slice.nix`                     | the slice derivation (compose + cabal v2-build + capture)  |
| `builder/compose-store.nix`                         | lndir helper for `.store` and shell composed store         |
| `builder/shell-for-v2.nix`                          | v2 nix-shell (`haskell-nix-cabal-store-sync` hook)         |
| `builder/cabal-install-patches/`                    | cabal-install patches (sublib visibility, completed-revdeps) |
| `lib/call-cabal-project-to-nix.nix`                 | dummy GHC's `--info` (must mirror real GHC's capability fields) |
| `modules/install-plan/configure-args.nix`           | extract ghc/configure args from plan.json                  |
| `modules/install-plan/planned.nix`                  | mark planned components + populate plan-id pkg.identifier  |
| `modules/install-plan/override-package-by-name.nix` | `package-ids-by-name` + plan-id alias                      |

## When to prefer v2

- Your project (or any of its deps) uses Cabal *public sublibs*
  (`library <n>` stanzas).  v1's shell can't expose those to
  cabal; v2's shell can.
- You want a plain `cabal v2-build` inside the dev shell to reuse
  our pre-built slices instead of rebuilding from source.
- You care about UnitId stability between haskell.nix-built units
  and the units a plain `cabal v2-build` inside the shell would
  produce.

v1 is still supported — set `builderVersion = 1;` on the project.
See [`builder-v1.md`](./builder-v1.md).
