# Coverage

haskell.nix can generate coverage information for your package or
project using Cabal's inbuilt hpc support.

## Prerequisites

To get a sensible coverage report, you need to enable coverage on each
of the packages of your project.

### In `cabal.project` (recommended)

haskell.nix reads cabal's own `coverage` field, so the setting you use
with `cabal build` / `cabal test` works here too.  A top-level field
applies to every package listed in `packages:`:

```cabal
packages: pkga pkgb
coverage: True
```

or enable it for particular packages only:

```cabal
package pkga
  coverage: True
```

This works with both component builders (`builderVersion = 1`, the
default, and `builderVersion = 2`): cabal records it in the plan
(`--enable-coverage` in the package's `configure-args`), and haskell.nix
sets `doCoverage` on those packages from there.

To keep `cabal.project` unchanged and make coverage optional, pass the
same text as `cabalProjectLocal`, which haskell.nix appends to the
project the way cabal reads a `cabal.project.local`:

```nix
{ withCoverage ? false }:

pkgs.haskell-nix.cabalProject {
  src = ./.;
  compiler-nix-name = "ghc9103";
  cabalProjectLocal = pkgs.lib.optionalString withCoverage ''
    coverage: True
  '';
}
```

Turning coverage on or off changes the plan, so the local packages are
rebuilt.

### With the `doCoverage` module option (`builderVersion = 1` only)

The default builder also accepts the `doCoverage` module option:

```nix
pkgs.haskell-nix.cabalProject {
  src = ./.;
  compiler-nix-name = "ghc9103";
  modules = [{
    packages.pkga.components.library.doCoverage = true;
    packages.pkgb.components.library.doCoverage = true;
  }];
}
```

With `builderVersion = 2` this option alone is not enough: the v2
builder builds each package the way the cabal plan says, so without the
`cabal.project` setting the libraries are built without coverage and the
report comes out empty.  Use the `cabal.project` setting (you can keep
the module option alongside it).

## Per-package

```shell
nix-build default.nix -A "projectWithCoverage.$pkg.coverageReport"
```

This will generate a coverage report for the package you requested.
All tests that are enabled (configured with `doCheck == true`) are
included in the coverage report. See [Running tests](./testing.md) for
how `doCheck` selects tests.

See the [developer coverage docs](../dev/coverage.md#package-reports) for more information.

## Project-wide

```shell
nix-build default.nix -A "projectWithCoverage.projectCoverageReport"
```

This will generate a coverage report for all the local packages in
your project.

See the [developer coverage docs](../dev/coverage.md#project-wide-reports) for more information.

## Custom

By default, the behaviour of the `coverageReport` attribute is to
generate a coverage report that describes how that package affects the
coverage of all local packages (including itself) in the project.

The default behaviour of `projectCoverageReport` is to sum the
default coverage reports (produced by the above process) of all local
packages in the project.

You can modify this behaviour by using the `coverageReport` and
`projectCoverageReport` functions found in the haskell.nix library:

```nix
{{#include coverage/default.nix}}
```
