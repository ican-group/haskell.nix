# Running tests

In haskell.nix, building a test suite and running it are two separate
derivations:

| Attribute | What building it does |
|-----------|-----------------------|
| `hsPkgs.<pkg>.components.tests.<name>` | Compiles the test suite. It is **not** run. |
| `hsPkgs.<pkg>.checks.<name>` | Runs the compiled test suite. The build fails if the test exits with a non-zero status. |

A check derivation's `$out/test-stdout` holds the test's standard output.
If the test writes HPC `.tix` files, the check copies them into
`$out/share/hpc` for the [coverage report](./coverage.md).

With the default builder, the log of a test component's build includes
a reminder of this:

```
The test my-pkg.components.tests.my-test was built.  To run the test build my-pkg.checks.my-test.
```

## Running a test

When `default.nix` evaluates to the project:

```shell
# Compile only
nix-build default.nix -A hsPkgs.my-pkg.components.tests.my-test
# Compile and run
nix-build default.nix -A hsPkgs.my-pkg.checks.my-test
```

With flakes, `project.flake {}` (see [Getting started](./getting-started.md))
puts every check of the project's own packages in the flake's `checks`
output. The output uses the same `<pkg>:test:<name>` keys that `packages`
uses for the test components:

```shell
# Compile only
nix build '.#my-pkg:test:my-test'
# Compile and run (replace x86_64-linux with your system)
nix build '.#checks.x86_64-linux."my-pkg:test:my-test"'
# Run every check (and build everything else `nix flake check` checks)
nix flake check
```

The flake's `apps` output also has the test executables, so
`nix run '.#my-pkg:test:my-test'` runs a test outside the Nix sandbox
(for example, one that needs network access). This works whatever
`doCheck` is set to.

The `ciJobs` and `hydraJobs` outputs of `project.flake {}` include the
same checks.  When the plan leaves the test suites out
(`configureArgs = "--disable-tests"`), they also leave out any
sub-library that only those test suites use (it is still in the flake's
`packages`); set `flake.ciSkip = [];` in the project to build those too.

To collect checks yourself, for example for a CI job, use
[`collectChecks` / `collectChecks'`](../reference/library.md#collectchecks-collectchecks):

```nix
haskellLib.collectChecks' (haskellLib.selectProjectPackages project.hsPkgs)
```

To run some other component, such as an executable, use
[`haskellLib.check`](../reference/library.md#check):

```nix
haskellLib.check project.hsPkgs.my-pkg.components.exes.my-exe
```

## Choosing which tests are run: `doCheck`

`doCheck` (default `true`) decides whether a test suite gets a
`checks.<name>` attribute at all. Tests with `doCheck = false` are left
out of `hsPkgs.<pkg>.checks`, out of `collectChecks`, and so out of the
flake's `checks` and `nix flake check`.

The test component is still there and can still be built with
`components.tests.<name>`. `doCheck` only controls whether it is run.
Because tests are run by their own check derivation, `doCheck` has no
effect on the derivation that compiles the test.

Like other component options, `doCheck` can be set for one test, one
package, or the whole project:

```nix
pkgs.haskell-nix.project' {
  # ...
  modules = [
    # A test that needs network access
    { packages.my-pkg.components.tests.integration.doCheck = false; }
    # Every test suite of one package
    { packages.other-pkg.doCheck = false; }
  ];
}
```

## Test arguments and hooks

These component options change how the check runs the test:

| Option | Description |
|--------|-------------|
| `testFlags` | Extra command-line arguments for the test executable, e.g. `[ "--hide-successes" ]`. The elements are joined with spaces into a shell command line without quoting, so quote any argument that has spaces or shell characters in it yourself, e.g. `[ "--match" "'Parser tests'" ]`. |
| `testWrapper` | List giving a command, and its arguments, that the test executable and its arguments are appended to. haskell.nix sets it to run cross-compiled tests under an emulator (see below). |
| `preCheck` | Shell code run before the test. |
| `postCheck` | Shell code run after the test has passed. |

For example:

```nix
modules = [{
  packages.my-pkg.components.tests.my-test = {
    testFlags = [ "--match" "'/Parser/'" ];
    preCheck = ''
      export MY_TEST_FIXTURES=$PWD/fixtures
    '';
  };
}];
```

The test runs from a copy of the package's source directory, so tests
can read fixture or golden files by their path relative to the
package's `.cabal` file.

## Cross-compiled tests

Checks also exist for cross-compiled projects, for example
`projectCross.mingwW64.hsPkgs.my-pkg.checks.my-test`. To run there,
the test executable has to run on the build machine. For these targets
haskell.nix sets `testWrapper` (or, for ghcjs, puts `node` on `PATH`) so
that it can:

* Windows: `wine`.
* Linux (ARM, i686, x86_64 and Android): `qemu` user-mode emulation, or
  `hyper-linux` when the build machine is macOS.
* WebAssembly: `wasmtime`.
* JavaScript (ghcjs): `node`.

`doCheck` decides which tests get checks for cross-compiled projects,
as it does for native ones. The `doCrossCheck` option is set by the
Windows and Linux cross overlays, but does not currently add or remove
any checks.

To keep the checks of native builds only, make `doCheck` depend on the
platform:

```nix
modules = [({ haskellLib, ... }: {
  doCheck = !haskellLib.isCrossHost;
})];
```

`haskellLib.isCrossHost` is false for native builds, including native
musl builds such as `projectCross.musl64` on `x86_64-linux`, which run
on the build machine without an emulator.

## Differences with `builderVersion = 2`

Checks have the same attribute names, are selected by the same
`doCheck` option, and use `testFlags`, `testWrapper`, `preCheck` and
`postCheck` in the same way. The differences are:

* The v2 check runs the executable installed by the test's v2 slice
  instead of reusing the v1 component's build environment.
* `testFlags` is only passed to test suites. When `haskellLib.check` is
  used on another component, such as an executable, it runs with no
  arguments.
* v1 checks have `profiled` and `dwarf` attributes that run the
  profiled and DWARF builds of the test. v2 checks do not.
