# V1 Component Builder (Setup.hs-based)

The v1 builder is haskell.nix's original component builder.  It produces
**one nix derivation per Cabal component** by invoking that package's
`Setup.hs` directly.  v2 (see `builder-v2.md`) is the default; opt
back in to v1 with the project-level `builderVersion = 1;` option.

Setting `builderVersion = 1` makes
`hsPkgs.<pkg>.components.library` (and exes / tests / benchmarks /
sublibs) be the v1 derivation.  Switching builders is project-wide
— there's no per-component opt-in.

## What v1 produces

For each component cabal would build (`lib`, `lib:<sublib>`,
`exe:<name>`, `test:<name>`, `bench:<name>`), v1 produces a separate
nix derivation.  The library derivation's `$out` looks like a
fully-installed package — `lib/`, `lib/<ghcDir>/<pkg-id>/...`,
`package.conf.d/<pkg-id>.conf`, etc. — so that downstream components
can register it via `ghc-pkg`.  Exe-like derivations install the
binary to `$out/bin/<name>` (with the platform-appropriate extension).

Per-component derivations let cabal-cached `nix-build`s share
dependencies across projects: two projects whose `library` derivations
hash to the same path get the same `/nix/store` output, regardless of
what else is in either project.

## High-level flow

Given the module-system config (`config.packages.<pkg>` produced by
`modules/plan.nix` from `plan-json`/Stackage snapshots), the builder:

1. **`modules/component-driver.nix`** iterates `config.packages` and
   calls `builder.build-package config pkg` for each non-null,
   non-pre-existing entry.  The result lands in `config.hsPkgs`.

2. **`builder/hspkg-builder.nix`** receives `pkg`, walks every
   buildable component in `pkg.components`, and for each one calls
   either `comp-builder` (v1) or `comp-v2-builder` (v2) — whichever
   `builderVersion` selects.  Only one derivation is produced per
   component; `pkg.components.library` (etc.) IS that derivation.

3. **`builder/comp-builder.nix`** is the v1 component derivation.  It
   stages the package source, runs `Setup.hs configure` with the
   component selected, then `Setup.hs build` and `Setup.hs install`,
   and captures the resulting installed component as `$out`.

4. **`builder/setup-builder.nix`** builds the `Setup.hs` binary itself
   (using `setup-depends`).  It runs on the build platform regardless
   of the project's host platform — Setup is a build-time tool.

5. **`builder/make-config-files.nix`** assembles the per-component
   `package.conf.d` (a ghc-pkg database) from the component's
   transitive library deps.  Each dep contributes its own pre-built
   `<pkg-id>.conf` file; `make-config-files` concatenates them and
   runs `ghc-pkg recache`.

6. **`builder/ghc-for-component-wrapper.nix`** wraps `ghc` with
   `GHC_PACKAGE_PATH=<package.conf.d>` so the component's `Setup.hs
   build` sees exactly the deps assembled in step 5 — no more, no
   less.

7. **`builder/haddock-builder.nix`** runs `Setup.hs haddock`
   afterwards (if `doHaddock` is enabled), producing the haddock
   output as a separate derivation alongside the library.

## Data flow per component

```
plan.nix                cabal-to-nix output
  │                       │
  ▼                       ▼
component.depends ──── component.libs / pkgconfig / build-tools
       │
       ▼
make-config-files ── package.conf.d (real ghc-pkg db of deps)
       │
       ▼
ghc-for-component ─ wraps GHC with GHC_PACKAGE_PATH
       │
       ▼
comp-builder       ─ runs Setup.hs configure / build / install
       │
       ▼
$out
  ├─ lib/<ghcDir>/<pkg-id>/...     (library files)
  ├─ <pkg-id>.conf                 (registration file)
  ├─ bin/<exe>                     (for exe / test / bench)
  └─ ...
```

## How dependencies get found

For each component:

- **Library deps**: every dep's v1 derivation appears in the
  component's `propagatedBuildInputs` chain.  `make-config-files`
  walks that chain via `haskellLib.flatLibDepends` to gather every
  transitive lib's `<pkg-id>.conf` and merge them into one
  `package.conf.d`.  GHC is then started with that as its package db.

- **System libs / frameworks / pkg-config**: stdenv puts each in
  `buildInputs`; the cc-wrapper's `NIX_LDFLAGS` / `NIX_CFLAGS_COMPILE`
  variables make them visible to `Setup.hs configure`'s
  `checkForeignDeps` probe.

- **`build-tool-depends`** (alex, happy, hsc2hs, etc.): each tool is
  resolved via `hsPkgs.pkgsBuildBuild.<tool>.components.exes.<tool>`
  (build-platform — the tool runs at build time, not at runtime on
  the host) and added to `nativeBuildInputs`.

## How configure flags are derived

`builder/comp-builder.nix` computes the `Setup.hs configure` command
line from a fixed set of inputs:

- `--with-ghc=`, `--with-ghc-pkg=`, `--with-hsc2hs=` (cross-aware via
  `${ghc.targetPrefix}`),
- `--with-gcc=`, `--with-ar=`, `--with-strip=`, `--with-ld=` from the
  cross stdenv's `cc.targetPrefix` / `cc.bintools.targetPrefix`,
- `--with-pkg-config=` from `buildPackages.cabalPkgConfigWrapperReal` (only
  when the component has `pkgconfig-depends`),
- `--enable-library-vanilla`, `--enable-shared`, profiling /
  documentation toggles from the module config,
- `--package-db=` pointing at the dep `package.conf.d` from
  make-config-files,
- `--cid=<unit-id>` taken from plan.json's resolved unit id, and
  `--dependency=<dep-name>=<dep-unit-id>` for each lib dep,
- `--ghc-option=<o>` for every entry in the component's `ghcOptions`
  (sourced from plan.json's `configure-args` via
  `modules/install-plan/configure-args.nix`, plus anything set
  directly in user `modules`),
- `--configure-option=<o>` for `configureOptions`.

These flags determine cabal's `pkgHashConfigInputs` and therefore the
final UnitId.  Two projects whose components reach `Setup.hs configure`
with identical flags + identical sources land at the same nix store
path.

## Testing & checking

`haskellLib.check <comp>` wraps a test or benchmark derivation in
another derivation that actually *runs* the binary and captures stdout
to `test-stdout`.  v1 splits build-time (the comp derivation) from
check-time (the wrapped check derivation) so that callers who only
want the binary (e.g. for offline inspection) don't pay the test-run
cost.

For cross-compiled hosts whose binaries can't run on the build host
directly (windows: wine; ghcjs: node; wasm: wasmtime), the
component's module config sets `testWrapper`, a list prepended to the
exe path inside `check`.

## Key files

| Path                                   | Role                                             |
|----------------------------------------|--------------------------------------------------|
| `modules/component-driver.nix`         | iterates `config.packages` → `config.hsPkgs`     |
| `builder/default.nix`                  | wires up the builders (v1 + v2 + setup + ...)    |
| `builder/hspkg-builder.nix`            | per-package: build every component               |
| `builder/comp-builder.nix`             | per-component: the v1 derivation                 |
| `builder/setup-builder.nix`            | builds `Setup.hs`                                |
| `builder/make-config-files.nix`        | assembles dep package.conf.d                     |
| `builder/ghc-for-component-wrapper.nix`| wraps GHC with the right package db              |
| `builder/haddock-builder.nix`          | runs Setup.hs haddock                            |
| `builder/shell-for.nix`                | v1 nix-shell (pre-populates ghc-pkg db)          |
| `lib/check.nix`                        | runs test/bench binaries, captures stdout         |
| `modules/package.nix`                  | per-package option declarations                  |
| `modules/component.nix`                | per-component option declarations                |

## When to prefer v1

- You want a build that mirrors what cabal would produce via
  `Setup.hs` directly — useful for projects that depend on Custom
  build-types' specific Setup behaviour.
- You need haddocks / per-component derivations / the
  `haskellLib.check` separation between build and run.

For a project where you want fewer derivations, faster eval at
high-component-count projects, and a closer match to what
`cabal v2-build` produces in development, v2 is now an option — see
[`builder-v2.md`](./builder-v2.md).
