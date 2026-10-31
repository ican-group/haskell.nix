[Haskell.nix][] contains a library of functions for creating buildable
package sets from their Nix expression descriptions. The library is
what you get when importing [Haskell.nix][]. It might be helpful to
load the library in the [Nix REPL](../tutorials/development.md#using-nix-repl) to
test things.

 * [Data structures](#data-structures) — the kinds of data that you will encounter working with [Haskell.nix][].
 * [Top-level attributes](#top-level-attributes) — Functions and derivations defined in the Haskell.nix attrset.
 * [Package-set functions](#package-set-functions) — Helper functions defined on the `hsPkgs` package set.

# Data structures

## Package Set

The result of `mkPkgSet`. This is an application of the NixOS module
system.

```nix
{
  options = { ... };
  config = {
    hsPkgs = { ... };
    packages = { ... };
    compiler = {
      version = "X.Y.Z";
      nix-name = "ghcXYZ";
      packages = { ... };
    };
  };
}
```

| Attribute      | Type | Description                                         |
|----------------|------|-----------------------------------------------------|
| `options` | Module options | The combination of all options set through the `modules` argument passed to `mkPkgsSet`. |
| `config` |  | The result of evaluating and applying the `options` with [Haskell.nix][] |
| `.hsPkgs` | Attrset of [Haskell Packages](#haskell-package) | Buildable packages, created from `packages` |
| `.packages` | Attrset of [Haskell Package descriptions](#haskell-package-descriptions) | Configuration for each package in `hsPkgs` |
| `.compiler` | Attrset | |



## Haskell Package description

The _Haskell package descriptions_ are values of the
`pkgSet.config.packages` attrset. These are not derivations, but just
the configuration for building an individual package. The
configuration options are described under `packages.<name>` in [Module
options](./modules.md).

## Component description

The _component descriptions_ are values of the
`pkgSet.config.packages.<package>.components` attrset. These are not
derivations, but just the configuration for building an individual
component. The configuration options are described under
`packages.<name>.components.*` in [Module options](./modules.md).


## Haskell Package

In [Haskell.nix][], a _Haskell package_ is a derivation which has a
`components` attribute. This derivation is actually just for the
package `Setup.hs` script, and isn't very interesting. To actually use
the package, look within the components structure.

```nix
components = {
  library = COMPONENT;
  exes = { NAME = COMPONENT; };
  tests = { NAME = COMPONENT; };
  benchmarks = { NAME = COMPONENT; };
}
```

## Component

In [Haskell.nix][], a _component_ is a derivation corresponding to a
[Cabal component](https://www.haskell.org/cabal/users-guide/developing-packages.html)
of a package.

## Identifier

A package identifier is an attrset pair of `name` and `version`.

## Extras

Extras allow adding more packages to the package set. These will be
functions taking a single parameter `hackage`. They should return an
attrset of package descriptions.

## Modules

Modules are the primary method of configuring building of the package
set. They are either:

1. an attrset containing [option declarations](./modules.md), or
2. a function that returns an attrset containing option declarations.

If using the function form of a module, the following named parameters
will be passed to it:

| Argument         | Type | Description         |
|------------------|------|---------------------|
| `haskellLib`     | attrset | The [haskellLib](#haskelllib) utility functions. |
| `pkgs` | | The Nixpkgs collection. |
| `pkgconfPkgs` | | A mapping of cabal build-depends names to Nixpkgs packages. (TODO: more information about this) |
| `buildModules` | | |
| `config` | | |
| `options` | | |


# Top-level attributes

## project'

Function that accepts attribute set with a `src` attribute and looks for `stack.yaml` file relative to it.

If file exists, it calls [stackProject](#stackproject') function. Otherwise it will call [cabalProject](#cabalproject') function.

**Example**:

```nix
pkgs.haskell-nix.project' {
  # 'cleanGit' cleans a source directory based on the files known by git
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "haskell-nix-project";
    src = ./.;
  };
}
```

## stackProject'

A function calling [callStackToNix](#callstacktonix) with all arguments.

Then feeding its result into [mkStackPkgSet](#mkstackpkgset) passing also
`pkg-def-extras` and `modules` arguments.

**Return value**:

| Attribute         | Type                                             | Description                                                                |
|-------------------|--------------------------------------------------|----------------------------------------------------------------------------|
| `hsPkgs`          | Attrset of [Haskell Packages](#haskell-package)  | Buildable packages, created from `packages`                                |
| `stack-nix`       |                                                  | `projectNix` attribute of [`callStackToNix`](#callstacktonix) return value |
| `shellFor`        | Function                                         | [`shellFor`](#shellfor)                                                    |
| `ghcWithHoogle`   | Function                                         | [`ghcWithHoogle`](#ghcwithhoogle)                                          |
| `ghcWithPackages` | Function                                         | [`ghcWithPackages`](#ghcwithpackages)                                      |


## cabalProject'

A function calling [callCabalProjectToNix](#callcabalprojecttonix) with all arguments.

Then feeding its result into [mkCabalProjectPkgSet](#mkcabalprojectpkgset) passing also
`pkg-def-extras`, `extra-hackages` and `modules` arguments.

**Return value**:

| Attribute         | Type                                             | Description                                                                 |
|-------------------|--------------------------------------------------|-----------------------------------------------------------------------------|
| `hsPkgs`          | Attrset of [Haskell Packages](#haskell-package)  | Buildable packages, created from `packages`                                 |
| `plan-nix`        |                                                  | `projectNix` attribute of [`callCabalProjectToNix`](#callcabalprojecttonix) return value  |
| `index-state`     |                                                  | `index-state` attribute of [`callCabalProjectToNix`](#callcabalprojecttonix) return value |
| `shellFor`        | Function                                         | [`shellFor`](#shellfor)                                                     |
| `ghcWithHoogle`   | Function                                         | [`ghcWithHoogle`](#ghcwithhoogle)                                           |
| `ghcWithPackages` | Function                                         | [`ghcWithPackages`](#ghcwithpackages)                                       |
| `projectCross`    | Attrset                                          | Like `pkgs.pkgsCross.<system>` from nixpkgs `p.projectCross.<system>` returns the project results for cross compilation (where system is a member of nixpkgs lib.systems.examples).  So `p.projectCross.ghcjs.hsPkgs` is the same as `hsPkgs` but compiled with ghcjs |
| `projectVariants`    | Attrset                                          | Attribute set of variant for the project, mapped from `flake.variants` config values |
| `appendModule`    | Function                                          |  Re-eval the project with an extra module (or module list). |
| `extend` and `appendOverlays` | Function                                          |  Modify a project, or add attributes, through overlays: `p.extend(final: prev: { })`. The overlays are carried-over `projectCross` and `appendModule` invocations. |

## project, cabalProject and stackProject

These versions of the function are the same as project', cabalProject'
and stackProject', but `hsPkgs` attributes are also included in the
return value directly.  That way a package can be referenced as
`(project {...}).foo` instead of `(project' {...}).hsPkgs.foo`.

## mkStackPkgSet

Creates a [package set](#package-set) based on the `pkgs.nix` output
of `stack-to-nix`.

```nix
mkStackPkgSet =
    { stack-pkgs, pkg-def-extras ? [], modules ? []}: ...
```

| Argument         | Type | Description         |
|------------------|------|---------------------|
| `stack-pkgs`     |  | `import ./pkgs.nix` — The imported file generated by `stack‑to‑nix`. |
| `pkg‑def‑extras` | List of [Extras](#extras) | For overriding the package set. |
| `modules` | List of [Modules](#modules) | For overriding the package set. |

**Return value**: a [`pkgSet`](#package-set)

## mkCabalProjectPkgSet

Creates a [package set](#package-set) based on the `pkgs.nix` output
of `plan-to-nix`.

```nix
mkCabalProjectPkgSet =
    { plan-pkgs, pkg-def-extras ? [], modules ? []}: ...
```

| Argument         | Type | Description         |
|------------------|------|---------------------|
| `plan-pkgs`     |  | `import ./pkgs.nix` — The imported file generated by `plan‑to‑nix`. |
| `pkg‑def‑extras` | List of [Extras](#extras) | For overriding the package set. |
| `modules` | List of [Modules](#modules) | For overriding the package set. |

**Return value**: a [`pkgSet`](#package-set)

## mkPkgSet

This is the base function used by both `mkStackPkgSet` and
`mkCabalProjectPkgSet`.

**Return value**: a [`pkgSet`](#package-set)

## snapshots

This is an attrset of `hsPkgs` packages from Stackage.

## haskellPackages

A `hsPkgs` package set, which is one of the recent LTS Haskell
releases from [`snapshots`](#snapshots).

The chosen LTS is updated occasionally in [Haskell.nix][], though a
manual process.

## nix-tools

A derivation containing the `nix-tools` [command-line tools](commands.md).

## callStackToNix

Runs `stack-to-nix` and produces the output needed for
`importAndFilterProject`.

**Example**:

```nix
  pkgSet = mkStackPkgSet {
    stack-pkgs = (importAndFilterProject (callStackToNix {
      src = ./.;
    })).pkgs;
    pkg-def-extras = [];
    modules = [];
  };
```


## callCabalProjectToNix

Runs `cabal new-configure` and `plan-to-nix` and produces the output
needed for `importAndFilterProject`.

**Example**:

```nix
  pkgSet = mkCabalProjectPkgSet {
    plan-pkgs = (importAndFilterProject (callCabalProjectToNix {
      index-state = "2019-04-30T00:00:00Z";
      src = ./.;
    })).pkgs;
```

| Argument             | Type | Description         |
|----------------------|------|---------------------|
| `name`               | String | Optional name for better error messages. |
| `src`                | Path   | Location of the cabal project files. |
| `compiler-nix-name`  | String | The name of the ghc compiler to use eg. "ghc9122" |
| `index-state`        | Timestamp | Optional hackage index-state, eg. "2025-01-10T00:00:00Z". |
| `index-sha256`       | Sha256 | Optional hash of the truncated hackage index-state. |
| `plan-sha256`        | Sha256 | Optional hash of the plan-to-nix output (makes the plan-to-nix step a fixed output derivation). |
| `cabalProject`       | String | Optional cabal project file contents (defaults to readFile "${src}/cabal.project"). |
| `cabalProjectLocal`  | String | Optional cabal project file contents (defaults to readFile "${src}/cabal.project.local"). |
| `cabalProjectFreeze` | String | Optional cabal project file contents (defaults to readFile "${src}/cabal.project.freeze"). |
| `ghc`                |        | Deprecated. Use `compiler-nix-name` instead. Optional ghc to use |
| `nix-tools`          |        | Optional nix-tools to use |
| `hpack`              |        | Optional hpack to use |
| `cabal-install`      |        | Optional cabal-install to use |
| `configureArgs`      | String | Optional extra arguments to pass to `cabal new-configure` (--enable-tests is included by default, include `--disable-tests` to override that). |

## importAndFilterProject

Imports from a derivation created by `callStackToNix`
or `callCabalProjectToNix`.

The result is an attrset with the following values:

| Attribute      | Type | Description                                         |
|----------------|------|-----------------------------------------------------|
| `pkgs` | attrset | that can be passed to `mkStackPkgSet` (as `stack-pkgs`) or `mkCabalProjectPkgSet` (as `plan-pkgs`). |
| `nix` | | this can be built and cached so that the amount built in the evaluation phase is not too great (helps to avoid timeouts on Hydra). |

## hackage
## stackage

## fetchExternal

## cleanSourceHaskell

```nix
cleanSourceHaskell = { src, name ? null }: ...
```

Filters a source tree removing common filenames that are not Haskell
build sources.

This can avoid unecessary rebuilds when these files change.

It's recommended to provide `name` so that the source derivation
remains constant regardless of how it was fetched.

Example:

```nix
src = pkgs.haskell-nix.cleanSourceHaskell {
  src = ./.;
  name = "myproject-src";
};
```

## haskellSourceFilter

```nix
haskellSourceFilter = name: type: ...
```

This is a source filter function which cleans common build products
and files not needed to do a Haskell build from a source directory.

It should be used with `pkgs.lib.cleanSourceWith`. Alternatively,
use the convenience function [`cleanSourceHaskell`](#cleansourcehaskell).


## haskellLib

Assorted functions for operating on [Haskell.nix][] data. This is
distinct from `pkgs.haskell.lib` in the current Nixpkgs Haskell
Infrastructure.

### collectComponents, collectComponents'

Extracts a selection of components from a Haskell [package set](#package-set).

This can be used to filter out all test suites or benchmarks of
your project, so that they can be built in Hydra (see check if you
want to run the tests as well as build them).

`collectComponents'` is an alias of `collectComponents` without
predicate for filtering.

```nix
collectComponents =
    group: packageSel: haskellPackages: ...
collectComponents' = group: collectComponents (_: true)
```


| Argument          | Type   | Description         |
|-------------------|--------|---------------------|
| `group`           | String | A [sub-component type](#subComponentTypes). |
| `packageSel`      | A function `Package -> Bool` | A predicate to filter packages with. |
| `haskellPackages` | [Package set](#package-set)    | All packages in the build. |

**Return value**: a recursive attrset mapping package names → component names → components.

**Example**:

```nix
tests = collectComponents "tests" (package: package.identifier.name == "mypackage") hsPkgs;
```

Will result in moving derivations from `hsPkgs.mypackage.components.tests.unit-tests`
to `tests.mypackage.unit-tests`.

### collectChecks, collectChecks'

These are just like `collectComponents` and `collectComponents'`, except that they collect
the `checks` attributes of packages (which aren't components, and so can't be collected
by the other functions.

#### check

This function turns a derivation that builds a test into one to run it.

| Argument          | Type   | Description         |
|-------------------|--------|---------------------|
| `drv`           | Derivation | One of `$pkg.components.tests.$test`. |

For convenience `$pkg.components.tests` are mapped with this function
to `$pkg.checks`.

This function is intended for use with `tests` but it should also work
for `exes` and `benchmarks` if you just want to run them to make sure
they execute.

#### subComponentTypes

Sub-component types identify [components](#component) and are one of:

 - `sublibs`
 - `foreignlibs`
 - `exes`
 - `tests`
 - `benchmarks`

# Project functions

These functions are included in the `project` return values.
In the past they also existed within `project.hsPkgs`,
but have now been removed from there.

## shellFor

Create a `nix-shell` [development
environment](../tutorials/development.md) for developing one or more
packages with `ghci` or `cabal v2-build` (but not Stack).

```nix
shellFor =
    { packages, withHoogle ? true, exactDeps ? false, ...}: ...
```

| Argument       | Type | Description         |
|----------------|------|---------------------|
| `name`         | String   | Name of the derivation |
| `packages`     | Function | Package selection function. It takes a list of [Haskell packages](#haskell-package) and returns a subset of these packages. |
| `components`   | Function | Similar to `packages`, by default all the components of the selected packages are selected. |
| `additional`   | Function | Similar to `packages`, but the selected packages are built and included in `ghc-pkg list` (not just their dependencies). |
| `withHoogle`   | Boolean  | Whether to build a Hoogle documentation index and provide the `hoogle` command. |
| `exactDeps`    | Boolean  | Prevents the Cabal solver from choosing any package dependency other than what are in the package set. |
| `allToolDeps`  | Boolean  | Indicates if the shell should include all the tool dependencies of the haskell packages in the project. |
| `tools`        | Function | AttrSet of tools to make available e.g. `{ cabal = "3.2.0.0"; }` or `{ cabal = { version = "3.2.0.0"; }; }`. If an AttrSet is provided for a tool, the additional arguments will be passed to the function creating the derivation for that tool. So you can provide an `index-state` or a `materialized` argument like that `{ cabal = { version = "3.2.0.0"; index-state = "2020-10-30T00:00:00Z"; materialized = ./cabal.materialized; }; }` for example. You can specify and materialize the version of hoogle used to construct the hoogle index by including something like `{ hoogle = { version = "5.0.17.15"; index-state = "2020-05-31T00:00:00Z"; materialized = ./hoogle.materialized; }`. Uses a default version of hoogle if omitted. |
| `packageSetupDeps` | Boolean | Set this to `false` to exclude custom-setup dependencies.
| `enableDWARF`  | Boolean  | Include debug info |
| `crossPlatforms` | Function | Platform selection function for cross compilation targets to support eg. `ps: with ps; [ghcjs mingwW64]` (see nixpkgs lib.systems.examples for list of platform names). |
| `inputsFrom`   | List     | List of other shells to include in this one.  The `buildInputs` and `nativeBuildInputs` of each will be included using [mkShell](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-mkShell).
| `shellHook`    | String   | Bash statements that are executed when the shell starts. |
| `buildInputs`  | | Passed to [`mkDerivation`](https://nixos.org/nixpkgs/manual/#sec-using-stdenv) (via [mkShell](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-mkShell)). |
| `nativeBuildInputs` | | Passed to [`mkDerivation`](https://nixos.org/nixpkgs/manual/#sec-using-stdenv) (via [mkShell](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-mkShell)). |
| `passthru`     | | Passed to [`mkDerivation`](https://nixos.org/nixpkgs/manual/#sec-using-stdenv)  (via [mkShell](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-mkShell)). |

The arguments are checked using the module `modules/shell.nix`.

To set environment variables in the shell use:

```
  shellHook = ''
    export FOO="bar"
  '';
```

or

```
(p.shellFor {}).overrideAttrs {
   FOO = "bar";
}
```

The `shellFor` arguments can also be passed to the project `shell`
argument.  For instance:

```
(pkgs.haskell-nix.project {
  ...
  shell.tools.cabal = {}
).shellFor {}
```

Is the same as:

```
(pkgs.haskell-nix.project {
  ...
).shellFor {
  tools.cabal = {}
}
```

**Return value**: a derivation

> ⚠️ **Warning:**
>
> `exactDeps = true` will set the `CABAL_CONFIG` environment variable
> to disable remote package servers. This is a
> [known limitation](../dev/removing-with-package-wrapper.md)
> which we would like to solve. Use `exactDeps = false` if this is a
> problem.


## ghcWithPackages

Creates a `nix-shell` [development
environment](../tutorials/development.md) including the given
packages selected from this package set.

**Parameter**: a package selection function.

**Return value**: a derivation

**Example**:

```nix
haskell.haskellPackages.ghcWithPackages (ps: with ps; [ lens conduit ])
```

## ghcWithHoogle

The same as `ghcWithPackages`, except, a `hoogle` command with a
Hoogle documentation index of the packages will be included in the
shell.

[haskell.nix]: https://github.com/ican-group/haskell.nix
