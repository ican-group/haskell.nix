This file contains a summary of changes to Haskell.nix and `nix-tools`
that will impact users.

## October 25, 2026

  * Removed the `haskell-nix` knobs `emulatorNativeBuilderPackages` and
    `emulatorNativeBuilderTH`.  Template Haskell slices, the `base` and
    `th-orphans` slices and the native GHC 9.14 library no longer get
    `emulatorSystemFeatures`: built on emulated (`nix-linux-builder`)
    hosts they all passed.  `emulatorSystemFeatures` now applies only to
    checks for hosts matching `emulatorNativeBuilderCheck`, by default
    32-bit x86 Linux, whose exes cannot run under Rosetta.
    `usesTemplateHaskell` stays: it still selects `-fexternal-interpreter`
    for dynamically linked musl hosts.

## October 16, 2026

New compiler: `ghc914-sh`, GHC 9.14 from the stable-haskell fork, built
with the stable-haskell Makefile rather than hadrian, and its boot
libraries built by haskell.nix's v2 builder.  Projects using it get
`builderVersion = 2` by default (v1 cannot build against the fork's boot
packages).  It ships no shared libraries (`enableShared = false`), no
haddock for cross targets and no DWARF build, and the tests that need
those are skipped for it.

Breaking changes around the eval platform (the platform `cabal` /
`nix-tools` run on during plan construction).  Everything that used to
take a nixpkgs for this now takes a system string, `evalSystem`, and
reuses one memoised nixpkgs per system:

  * The project option `evalPackages` is deprecated: set
    `evalSystem = "<system>"` instead.  Setting `evalPackages` still works
    for now (its system becomes the eval system) but warns.
  * `haskell-nix.tool'` / `tools'` take an `evalSystem` string as their
    first argument.  A nixpkgs is still accepted, with a warning.
  * `haskell-nix.roots` takes `evalSystem`; its `evalPackages` argument is
    still accepted, with a warning.
  * The compiler override argument `ghcEvalPackages` is gone.  Compilers
    now carry memoised per-eval-system variants: select
    `ghc.evalWith.${evalSystem}` (or `ghc.override { evalSystem = ...; }`).
  * `haskellLib.isNativeMusl` no longer classifies darwin → linux-musl
    (same CPU architecture) as *native* musl; it now additionally requires
    the build platform to be Linux, so those darwin-hosted builds take the
    cross-compilation path.

`haskell-nix.roots` (and `p.roots`) now also link the plan-nix
derivations behind the compiler (hadrian, or stage1/stage2 for the
stable-haskell GHCs; `hadrian-plan` is now `plan-hadrian`), the
iserv-proxy projects, the v2 builder's `cabal-install`, and the eval-time
dummy ghc/ghc-pkg pair — each for the build system and, when
`evalSystem` differs, an `-eval` twin.  Building `roots` in CI therefore
caches everything a later evaluation needs to realise via IFD, so
evaluators (e.g. hydra's) substitute the plans instead of building them
mid-eval.

`builderVersion = 2`:

  * Slices are now built with the stable-haskell fork of cabal-install
    (3.17.0.1, `haskell-nix.v2-cabal-install`) for every compiler, not
    mainline 3.16.1.0, and v2 projects' plans are made with the matching
    fork nix-tools (`nix-tools-unchecked-sh`), so the plan's UnitIds are
    the ones the slices compute.  UnitIds change, so every slice rebuilds
    once.  v1 projects' plans are unchanged.
  * That cabal keeps a project-local store, `dist-newstyle/store`, and the
    v2 shell now seeds it there (under the project root, found as cabal
    finds it) rather than `~/.cabal/store`.  The shell's generated
    `cabal.project.local` also goes to the project root, and names the
    build compiler, without which the fork cabal resolves its build stage
    (`base` and all) from hackage.
  * `shellFor`'s `tools.cabal = "latest"` now means the slice builder's
    cabal-install, like `{}` already did: the newest one on hackage cannot
    reuse the slices.  The same derivation is `project.v2-cabal-install`,
    for shells not built with `shellFor`.

Cross compilation:

  * New component option `usesTemplateHaskell`, and new `haskell-nix`
    knobs `emulatorSystemFeatures`, `emulatorNativeBuilderPackages`,
    `emulatorNativeBuilderCheck` and `emulatorNativeBuilderTH` (plus
    `haskellLib.emulatorRunAttrs`), for build farms that need to keep
    emulator-run derivations (TH splices, test runs) off builders where
    the emulator is itself emulated.  `emulatorSystemFeatures` is empty
    by default, which turns the whole mechanism off.
  * x86_64-linux cross builds use a user-mode-only qemu (9.1 – 11) with a
    patch for running under Rosetta, and the iserv-proxy input now
    follows `stable-haskell/iserv-proxy`.
  * New `hyper-linux` flake input (`pkgs.hyper-linux`): on Apple Silicon
    it is the emulator for darwin → linux cross builds, running Template
    Haskell splices and cross-built test exes, where qemu-user does not
    exist.
  * The linux-cross and mingw test wrappers now quote their arguments
    (`"$@"`), so arguments containing spaces reach the test exe intact.

## August 17, 2026

`builderVersion = 2`: `shellFor`'s `tools.cabal` now defaults to the same
cabal-install the slice builder uses, instead of solving for the newest one
in the project's hackage index.

A UnitId is a hash of cabal-install's own rendering of a package's build
inputs, so two cabal-install versions give the same package two different
UnitIds.  When the shell's `cabal` was not the one that built the slices it
missed every unit in the composed cabal store and rebuilt the whole
dependency tree from source — no error, just a shell that had quietly
stopped doing the one thing it exists for.  That is what happened when
cabal-install 3.18.1.0 reached hackage on August 15 while the slice builder
stayed pinned to 3.16.1.0.

Only projects that ask for `shell.tools.cabal` are affected, and only when
they do not pin a version.  An explicit pin still wins; you now get a
warning when it isn't the version the slices were built with.

The flakes we hand to users keep working on x86_64-darwin.  `hix init`, the
`haskell-nix` flake template, the boilerplate behind `hix
develop`/`build`/`run`, and the getting-started-flakes tutorial all follow
`nixpkgs-unstable`, and nixpkgs 26.11 dropped that platform.  Because
`flake-utils`' `eachSystem` evaluates every listed system in order to
collect its output names, the one unimportable system broke `nix develop`
and `nix build` on *all* of them — not just on Intel macOS.  Generated
flakes now take a `nixpkgs-2605` input and import it for x86_64-darwin
only, the same per-system selection haskell.nix's own `flake.nix` and
`ci.nix` already make.

## June 12, 2026

`builderVersion = 2`: test `checks` now run with more of the environment
`cabal v2-test` would provide, so tests that read their package's data,
read source-relative files, or spawn build-tool executables work.

The v2 check runs the installed test binary directly (rather than via
`cabal v2-test`) in an empty directory with only the runtime libs on PATH,
so `lib/check.nix` now additionally:

  * sets each installed package's `<pkg>_datadir` (the env var Cabal's
    `Paths_<pkg>` consults) at the `share` dir the slice stages under
    `$out/store/ghc-*/<unit>/share`, so `getDataFileName` finds
    `data-files` (the compiled-in datadir points at an ephemeral
    build-time `cabal` dir);
  * puts the component's `build-tool-depends` (`executableToolDepends`,
    including same-package exes a test spawns) on `PATH`; and
  * runs the test from a writable copy of the package source subdir, so
    tests that read source-relative files (golden files / fixtures) find
    them — mirroring v1, which unpacks `src` and `cd`s into it.

All three happen before `preCheck`, so a project's own `preCheck` can
still override them.

## June 9, 2026

Derivations in the pkgconf → nixpkgs map (`lib/pkgconf-nixpkgs-map.nix`)
may now carry a `pc-version` attribute, which `allPkgConfigWrapper`
reports for `pkg-config --modversion` in preference to the derivation
`.version`.

This fixes a `builderVersion = 2` UnitId fork for packages whose `.pc`
`Version:` field differs from the nixpkgs derivation `.version`.  The
motivating case is `systemd`: `libsystemd.pc` reports only the major
version (e.g. `258` / `259`) while the derivation `.version` carries a
patch component (`258.5` / `259.3`).  plan-to-nix's `allPkgConfigWrapper`
reported the `.version`, while the real `pkg-config` a v2 build slice runs
reports the `.pc` value; cabal folds the resolved pkgconfig-dep version
into `pkgHashPkgConfigDeps`, so a `pkgconfig-depends`-using package (e.g.
`libsystemd-journal`) got a different UnitId in the slice than plan-nix
recorded, failing the slice's expected-package check.

`systemd` is now overridden to set `pc-version` to its major version
(matching the `.pc`).  The `pkgconf-pc-version` test verifies that every
`pc-version` package agrees with what the real `pkg-config --modversion`
returns.

## May 23, 2026

**Breaking change:** `cabalProjectLocal` and `cabalProjectFreeze`
no longer auto-load `cabal.project.local` / `cabal.project.freeze`
from the project source.  The option types are now `lines`
(default `""`) instead of `nullOr lines` with a `readFile`-based
default.

Projects that relied on the implicit `readFile` behaviour should
set the option explicitly:

```nix
haskell-nix.cabalProject {
  src = ./.;
  cabalProjectLocal = builtins.readFile ./cabal.project.local;
  cabalProjectFreeze = builtins.readFile ./cabal.project.freeze;
  # ...
}
```

Reasons for the change:

  * The implicit IFD-based default forced every project that
    didn't want it (notably internal `hadrian` and
    `ghc-extra-projects` builds) to set `cabalProjectLocal = null`
    explicitly just to suppress the read.
  * The `nullOr lines` type prevented haskell.nix from merging
    project-level `cabalProjectLocal` content (`mkBefore` /
    `mkAfter`) with explicit user values, which the new
    platform-conditional defaults below rely on.

Platform-conditional defaults are now injected into every cabal
project's `cabalProjectLocal`:

  * **musl host** — `package * \n executable-static: True`.
    comp-builder already adds `--ghc-option=-optl=-static` at
    build time; this surfaces the toggle in cabal.project so
    plan-to-nix records `--enable-executable-static` for every
    unit.  Observable build behaviour is unchanged.
  * **x86_64-darwin host** — `package * \n library-for-ghci: True`.
    Mirrors what comp-builder passes for `!ghcjs && !wasm && !android`,
    so plan-nix's recorded UnitIds match the artefacts.
  * **android host** — `package * \n ghc-options: -optl-static -optl-ldl`
    (plus `-optl-no-pie` on aarch32).  Mirrors the
    `setupBuildFlags` overrides previously applied only by
    `lib/check.nix`'s test-exe re-wrap.
  * **wasm GHC ≥ 9.12** — `package * \n shared: True`.  Wasm's RTS
    linker only loads `.so` files; `--disable-shared` (the cabal
    default) would force a `.a`-only install that TH-eval can't
    load.

These directives sit at `mkBefore` priority so a project's own
`cabalProjectLocal` overrides them if needed.

**Cache impact:** plan-nix hashes will change for affected
platforms on the next CI run — a one-time rebuild wave.

To opt out of a specific default, override it in your project's
`cabalProjectLocal`:

```nix
cabalProjectLocal = ''
  package *
    executable-static: False
'';
```

The post-plan `packages.ghc.src` override that
`modules/configuration-nix.nix` used to apply unconditionally is
now opt-in via the new project-level `useLocalGhcLib` option.

If your project depends on / constrains the `ghc` package (e.g.
uses `ghc-lib-reinstallable` or pins `lib:ghc`), add
`useLocalGhcLib = true` to your project arguments:

```nix
haskell-nix.cabalProject {
  # ...
  useLocalGhcLib = true;
}
```

For cabal projects this injects a `source-repository-package`
block into `cabalProjectLocal` that points at the configured GHC
tree.  For stack projects it re-applies the previous
`packages.ghc.src` post-plan override.

Symptoms when the flag is needed but not set: the planner fails
because it can't satisfy a `ghc ==<version>` constraint against
the boot package set, or `lib:ghc` is rejected with
`allow-boot-library-installs` errors.

## Mar 24, 2026

GHC options set in `cabal.project` files (via `package` or
`program-options` stanzas) are now automatically picked up from
`plan.json` and applied during builds.

Previously, `ghc-options` specified in a `cabal.project` file like:

```
package my-package
  ghc-options: -DSOME_FLAG
```

were silently ignored by Haskell.nix.  Users had to duplicate them
in a `modules` setting:

```nix
modules = [{
  packages.my-package.ghcOptions = ["-DSOME_FLAG"];
}];
```

This is no longer necessary.  The `configure-args` added to `plan.json`
by `nix-tools` (PR #2484) are now parsed, and `--ghc-option` /
`--ghcjs-option` entries are extracted and applied automatically.

If you were already setting `ghcOptions` in `modules` to work around
this limitation, the options will be applied twice (once from
`plan.json`, once from `modules`).  This is harmless for most flags
but you may want to remove the redundant `modules` entry.

## Jul 3, 2025

Some time ago the behavior of `shellFor` changed so that the arguments
are now checked against `modules/shell.nix`.  This was done as part of a fix
for bugs in the way `shellFor` arguments and project `shell` arguments
interacted (both are now `modules` and the normal module merge rules apply).

This means it is no longer possible to pass arbitrarily named arguments
to `shellFor` in order to set environment variables.

Instead of:

```
p.shellFor {
  FOO = "bar";
}
```

Use:

```
p.shellFor {
  shellHook = ''
    export FOO="bar"
  '';
}
```

or

```
(p.shellFor {}).overrideAttrs {
   FOO = "bar";
}
```

## Jan 29, 2025

Removed GHC <9.6 from CI.

The latest `nixpkgs-unstable` caused problems with
  * GHC 8.10.7
  * GHC 9.6.6 mingwW64 (ucrt64 works still as does mingwW64
    with newer GHC versions)

## Sep 17, 2024

Cabal projects now use the more granular Unit IDs from plan.json
to identify packages.  This allows for different versions of a
package to be used when building `built-tool-depends` and setup
dependencies.

Overrides in the `modules` argument apply to all versions of
the package.  However to make this work we needed to make
each `packages.somepackage` an option (instead of using an
`attrsOf` the submodule type).

It is now an error to override a package that is not in the
plan.  This can be a problem if different GHC versions, target
platforms, or cabal flag settings cause the package to be
excluded from the plan.  Adding `package-keys` can tell
haskell.nix to include the option anyway:

```
  modules = [{
    # Tell haskell.nix that `somepackage` may exist.
    package-keys = ["somepackage"];
    # Now the following will not cause an error even
    # if `somepackage` is not in the plan
    packages.somepackage.flags.someflag = true;
  }];
```

There is a helper function you can use to add `package-keys`
for all of the `builtins.attrNames` of `packages`:

```
  modules = [(pkgs.haskell-nix.haskellLib.addPackageKeys {
    packages.somepackage.flags.someflag = true;
  })];
```

Do not use the module's `pkgs` arg to look `addPackageKeys` up
though or it will result an `infinite recursion` error.

Code that uses `options.packages` will also need to be updated.
For instance the following code that uses `options.packages`
to set `--Werror` for local packages:

```
  ({ lib, ... }: {
    options.packages = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule (
        { config, lib, ... }:
        lib.mkIf config.package.isLocal
        {
          configureFlags = [ "--ghc-option=-Werror"];
        }
      ));
    };
  })
```

Now needs to do it for each of the entry in `config.package-keys`
instead of using `attrsOf`:

```
  ({ config, lib, ... }: {
    options.packages = lib.genAttrs config.package-keys (_:
      lib.mkOption {
        type = lib.types.submodule (
          { config, lib, ... }:
          lib.mkIf config.package.isLocal
          {
            configureFlags = [ "--ghc-option=-Werror"];
          }
        );
      });
  })
```

## Jun 5, 2024

Haskell.nix now respects the `pre-existing` packages selected
by the cabal planner.  The selection made by the planner
is used to set `nonReinstallablePkgs`.

Instead setting `nonReinstallablePkgs` and `reinstallableLibGhc`
haskell.nix projects should add `constraints` to the cabal project.

For instance to force the use of the `pre-exising` `text`
package add:

```
  constraints: text installed
```

To make sure `text` is reinstalled use:

```
  constraints: text source
```

The `pre-existing` `ghc` will now be used by default as
that is what `cabal` will choose (haskell.nix used to choose
`reinstallableLibGhc=true` by default).

To allow cabal to choose reinstalling `ghc` add:

```
  allow-boot-library-installs: True
```

To force cabal to choose reinstalling:

```
  constraints: ghc source
  allow-boot-library-installs: True
```

It may also need `allow-newer: ghc:Cabal`

## Mar 27, 2023

Haskell.nix will no longer parse the `cabal.project` file to
determine the `index-state`. This decision was made due to
the function's inability to handle more than one `index-state`
or a qualified `index-state` as the first `index-state`
field in the file.

As a result, there will be some drawbacks:

* There will no longer be a warning in the trace output
  if an index state is not found.

* Even if the `index-state:` in the `cabal.project` has not changed,
  the plan will be recomputed when hackage.nix is bumped. However, this
  is not expected to be a problem since plan recomputations are typically
  quick.

* `project.index-state` cannot be used to obtain the found `index-state`.
  However, the parse function is still available if required
  (haskell-nix.haskellLib.parseIndexState).  

## Jul 27, 2022
* Removed reliance on `builtins.currentSystem`.  It was used it to provide
  `pkgs.evalPackages` via an overlay that it used to run derivations
  used in imports from derivation (IFDs).

  These derivations are now run on `buildPackages` by default.

  Passsing `evalPackages` to a project function will change where all the
  derivations used in IFDs are run for that project (including shell tools):
    evalPackages = import nixpkgs haskellNix.nixpkgsArgs;

  Passing `evalSystem` instead will use create a suitable `nixpkgs` using `pkgs.path`
  and `pkgs.overlay`:
    evalSystem = "x86_64-linux";
  or
    evalSystem = builtins.currentSystem;

  The `haskellLib.cleanGit` function is also affected by this change.  If you are cross
  compiling and using `cleanGit` you should probably do something like:
    pkgs = import nixpkgs haskellNix.nixpkgsArgs;
    evalPackages = import nixpkgs (haskellNix.nixpkgsArgs // { system = evalSystem; });
    p = pkgs.pkgsCross.mingwW64.haskell-nix.cabalProject {
      inherit evalPackages;
      src = evalPackages.haskell-nix.haskellLib.cleanGit { src = ./.; };
    };

## Feb 16, 2022
* Removed lookupSha256 argument from project functions.
  Pass a `sha256map` instead.
* Added better support for `repository` in `cabal.project`.  These
  blocks should now work without the need for passing `extra-hackages` and
  `extra-hackage-tarballs`.

## Aug 6, 2021
* Included dependencies of haskell.nix that were tracked in `nix/sources.json`
  as flake inputs (`flake.lock` replaces `nix/sources.json`).
* Uses `flake-compat` to continue to provide a compatible interface for non
  flake projects.

## Jul 23, 2021
* `source-repository-package` references in `cabal.project` files are now
  left as a `source-repository-package` when calculating the the `plan-nix` for
  `cabalProject` based functions.
  This makes haskell.nix match the behaviour of `cabal` better.
  Materialized files for projects that use `source-repository-package`
  references will need to be updated.
* Only planned components are included in a haskell.nix cabal project.
  If cabal solver does not include the component in the `plan.json` file it
  will not be present in `hsPkgs.pkg.components`.
* When the same package occurs more than once in a plan.json file
  the latest version is picked by haskell.nix.

## Apr 8, 2021
* Project arguments are now validated with the Nix module system.
  If unexpected argments are passed to a project function this may now
  result in an error.

## Feb 22, 2021
* Add `.dwarf` to build any component with DWARF dubug info on linux
  (ghc >=8.10.2).
* Pass `enableDWARF` to `shellFor` for to get a shell where all the
  components are the `.dwarf` ones.

## Feb 18, 2021
* `ghcOptions` has been moved from package and is now a list of strings.
    old: packages.x.package.ghcOptions = "someGHCoption";
    new: packages.x.ghcOptions = ["someGHCoption"];
  To specify ghcOptions for all packages:
    ghcOptions = ["someGHCoption"];
  For a single component:
    packages.x.compoents.library.ghcOptions = ["someGHCoption"];

## Feb 8, 2021
* Removed older versions of haskell-language-server from custom-tools
  (0.8.0 is in hackage so we can still get that version).

## Jan 14, 2021
* Added support for cross package refs (with a project).  Relative
  directory references between packages within a project should now
  work.
* Added `includeSiblings` to `cleanSourceWith`.  When `true` it
  prevents the `subDir` arg from causing filtering of other directories.
* Added `keepGitDir` to `cleanGit` to allow `.git` directory to be kept
  (useful for components that use the `githash` package).

## Nov 26, 2020
* Renamed `otherShells` arg for `shellFor` to `inputsFrom

## Nov 25, 2020
* The `shellFor` `makeConfigFiles` `ghcWithHoogle` and `ghcWithPackages`
  functions have been removed from `project.hsPkgs`.  Instead access
  them from `project` itself (e.g. change `p.hsPkgs.shellFor` to `p.shellFor`).
* The reflex-platform like `project.shells.ghc` has been removed.
  If needed, add something like `p // { shells.ghc = p.shellFor {} }`
  to `shell.nix`.

## Nov 24, 2020
* Added `${targetPrefix}cabal` wrapper script for running cross
  compilers in `shellFor`.
* `otherShells` arg added to `shellFor`.

## Oct 31, 2020
* Passing `tools.hoogle` to `shellFor` with a value suitable for `haskel-nix.tool` will
  use the specified `hoogle` inside `shellFor`. This allows for materialization
  of `hoogle`.

## Oct 28, 2020
* Passing `compiler-nix-name` to project functions for `stack.yaml`
  based projects now overrides the compiler used (was ignored before).

## Sep 8, 2020
* Added the ability to generate coverage reports for packages and
  projects.
* Added the `doCoverage` module option that allows users to choose
  packages to enable coverage for.
* Added a `doCoverage` flag to the component builder that outputs HPC
  information when coverage is enabled.
* Added test for coverage.

## July 21, 2020
* Removed `components.all`, use `symlinkJoin` on components.exes or
 `shellFor` if you need a shell.
* Added `components` argument to `shellFor`.

## July 21, 2020
* Added GHC 8.8.4 and replaced 8.8.3 in tests and as the ghc
  used to build nix-tools for stack projects.

## July 20, 2020
* Changed `haskell-nix.roots` and `p.roots` to single derivations.

## July 8, 2020
* Removed `sources.nixpkgs-default`, use `sources.nixpkgs` instead.
* Removed `./nixpkgs` directory, use  `(import ./. {}).sources`
  or `./nix/sources.nix` instead.
* Removes V1 interface for details on how to fix old code see:
    https://github.com/input-output-hk/haskell.nix/issues/709
* Removed defaultCompilerNixName.
* cabalProject, cabalProject', hackage-project and hackage-package
  now require a `compiler-nix-name` argument.
* `haskell-nix.tool` and `.tools` now require a `compiler-nix-name` argument.
  New functions `p.tool` and `p.tools` (where p is a project) do not.
  Like `shellFor { tools = ... }` they will use the compiler nix name
  from the project (including stack projects where it is derived from
  the resolver).
* `haskell-nix.alex` and `haskell-nix.happy` have been removed. Use
  `p.tool "alex" "3.2.5"` or `shellFor { tools = { alex = "3.2.5"; } }`.
* `haskell-nix.nix-tools` -> `haskell-nix.nix-tools.ghc883` (it includes
  the hpack exe now).
* `haskell-nix.cabal-install` ->
  `p.tool "cabal" "3.2.0.0"` or `shellFor { tools = { cabal = "3.2.0.0"; } }`
* `haskell-nix.haskellNixRoots` -> `haskell-nix.roots ghc883` or `p.roots`

## June 25, 2020
* Haddock docs are now built in their own derivation when needed (not as part
  of the component build).
  They should build automatically when something (such as `shellFor`) attempts
  to accesses the `.doc` attribute of component.

## December 27, 2019
* Fix overlays/bootstrap.nix to provide LLVM 6, not LLVM 5, to ghc-8.6.X compilers.

## November 18, 2019
  * Changed the `cleanSourceHaskell` to accept an attrset of `src` and
    (optional) `name` parameters. This allows you to keep the source
    derivation name constant, so that your builds are always
    cached. Usage of `cleanSourceHaskell` will need to be updated.

## October 12, 2019
 * [`shellFor`](https://input-output-hk.github.io/haskell.nix/reference/library/#shellfor) no longer sets `CABAL_CONFIG` by default.
   This avoids surprising users, but means that Cabal may select a plan which is different to your Haskell.nix package set.
   If you would like the old behaviour, use `shellFor { exactDeps = true; }`.

## August 9, 2019
 * Add the [`haskellLib.collectComponents`](https://input-output-hk.github.io/haskell.nix/reference/library/#haskellLib) function.

## June 21, 2019
 * Add `ghcWithPackages` and `ghcWithHoogle` to hsPkgs ([documentation](https://input-output-hk.github.io/haskell.nix/reference/library/#package-set-functions).
 * Benchmark components can now build successfully.
 * Reduced the closure bloat of nix-tools, and added closure size limit to CI.
 * Added more reference documentation and set up auto-generated
   documentation for [Module Options](https://input-output-hk.github.io/haskell.nix/reference/modules/).
 * Miscellaneous bug fixes.

## June 7, 2019
  * Several additions to the [documentation](https://input-output-hk.github.io/haskell.nix/).
    * More information about getting nix-tools, Haskell.nix, pinning.
    * Updates the stack-to-nix and cabal-to-nix guides.
    * Adds a section on development environments.
    * Adds a little information about cross compilation.
    * Adds a (partially complete) reference section (command line manuals, library reference).
    * Symlinks the changelog into the documentation pages.

## May 29, 2019
  * Added `shellFor` function to package set.

## May 28, 2019
  * Added `snaphots` and `haskellPackages` attributes to the
    Haskell.nix top-level.

## May 22, 2019
  * Add the `cleanSourceHaskell` utility function to the Haskell.nix
    top-level.

## May 21, 2019
  * Add the `callCabalProjectToNix` function, which uses "import from
    derivation" (IFD) so that nix-tools doesn't need to be run
    manually.
  * The `hackage.nix` update process has changed, so that Cabal index
    state hashes are also included in the generated repo.

## May 20, 2019
  * Remove Travis CI in favour of Buildkite.

## May 17, 2019
  * Add the `callStackToNix` function, which uses "import from
    derivation" (IFD) so that `stack-to-nix` doesn't need to be run
    manually.

## Mar 15, 2019
  * `overlays` was renamed to `extras` in
    [#79](https://github.com/input-output-hk/haskell.nix/pull/79)
    to prevent confusion between the notion of Nix overlays.

    Therefore `plan-pkgs` and `stack-pkgs` as generated by `plan-to-nix` and `stack-to-nix` will
    expose `extras` instead of `overlay`. Similarly `mkStackPkgSet`, `mkPkgSet` and `mkCabalProjectPkgSet`
    take a `pkg-def-extras` instead of `pkg-def-overlay` argument.  If you are using `iohk-nix`, the
    `iohk-overlay` was parameter was renamed to `iohk-extras`.
