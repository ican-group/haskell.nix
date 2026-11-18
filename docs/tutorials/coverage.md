# Coverage

haskell.nix can generate coverage information for your package or
project using Cabal's inbuilt hpc support.

## Prerequisites

To get a sensible coverage report, you need to enable coverage on each
of the packages of your project:

```nix
pkgs.haskell-nix.project {
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "haskell-nix-project";
    src = ./.;
  };
  compiler-nix-name = "ghc884";

  modules = [{
    packages.$pkg.components.library.doCoverage = true;
  }];
}
```

If you would like to make coverage optional, add an argument to your nix expression:

```nix
{ withCoverage ? false }:

pkgs.haskell-nix.project {
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "haskell-nix-project";
    src = ./.;
  };
  compiler-nix-name = "ghc884";

  modules = pkgs.lib.optional withCoverage [{
    packages.$pkg.components.library.doCoverage = true;
  }];
}
```

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
