# Motivation

`haskell.nix` is an infrastructure based on `nix` to build Haskell code.
It provides a way to build `cabal-install` and `Stack` based projects using `nix`,
reading the `cabal.project` or `stack.yaml` files used by those tools, hence reducing
the amount of `nix` code that needs to be maintained and making it easy to continue
using `cabal-install` and `Stack` as well.

In the rest of this page we motivate `haskell.nix` by comparing it to:
- [Stack](https://docs.haskellstack.org/en/stable/) and [cabal-install](https://cabal.readthedocs.io/en/stable/) build tools
- [nixpkgs](https://haskell4nix.readthedocs.io/) Haskell infrastructure for `nix`


## Comparison with `Stack` and `cabal-install`

Using `haskell.nix` instead of `Stack` or `cabal-install` gives us:
- deterministic and hermetic builds
- distributed caching
- precise selection of the toolchain (GHC...) to use (which only `Stack` allows to some extent)
- precise selection of the native libraries to use (using `nix`), if any

In addition, `haskell.nix` has better support for cross-compilation (e.g.
compiling Haskell code on Linux that will be run on Windows). It does this by
carefully distinguishing the GHC compiler for the build platform (used to
compile `Cabal`'s `Setup.hs` files for Linux in our example) and the GHC
compiler for the host platform (GHC cross-compiler targeting Windows in our
example).

By design `haskell.nix` reuses configuration files from other tools and converts
them into `nix` expressions:
- `.cabal` files
- `Stack`'s `stack.yaml`
- `cabal-install`'s `cabal.project`...

As such it doesn't require more work from you if your projects already build
with `Stack` or `cabal-install`.

`haskell.nix` can also be used to provide developer environments including
common Haskell tools: GHC, cabal-install, HLS (Haskell Language Server), hlint,
etc. With these environments, you don't need to use `ghcup` nor to pass programs
explicitly (e.g. as in `cabal -w ghc-9.2.2`). See [devx](https://github.com/input-output-hk/devx).


## Comparison with `nixpkgs`

To properly compare with `nixpkgs` we need to get more into the technical details
of both solutions.

### Cross compilation

`haskell.nix` has more maintainable support for cross-compilation (e.g.
compiling Haskell code on a Linux machine to produce a program that runs on
Windows).

Both `nixpkgs` and `haskell.nix` rely on tools to convert `.cabal` files into
`nix` expressions. `.cabal` files can contain conditionals (e.g. `os(windows)`) to
conditionally build modules, pass flags to the compiler, etc.

The difference is that:
- `nixpkgs` generates a different `nix` expression for each os/arch/flags
  configuration.
- `haskell.nix` generates a single `nix` expression that exposes the conditionals
  to `nix`.

The drawback of the `nixpkgs` approach is that managing so many different `nix`
expressions for a single `.cabal` file becomes a maintenance burden over time.

### Performance: build-type

When `haskell.nix` converts a `.cabal` file into a `nix` expression, it keeps
track of the `build-type` value. All the `.cabal` files that use `build-type:
simple` reuse the same `Setup` program that is built once and cached.

### Dependencies: package sets

Not all Haskell packages work well together. As it is cumbersome to pinpoint
every package version explicitly, it is common to rely on curated sets of
packages: packages that are known to work well together to some extent (e.g.
Stackage snapshots).

- `nixpkgs` provides its own curated set of packages which might or might not
  work for the project we work on.

- `haskell.nix` allows any form of package set.

First [hackage.nix](https://github.com/ican-group/hackage.nix) exposes the
`nix` expressions of every revision of every package from Hackage.

As the Hackage index is an ever growing repository of Haskell packages,
`haskell.nix` supports pinning the Hackage index to a specific revision
and letting Cabal's solver resolve the dependencies in a reproducible way.

An alternative is to start with a curated package set. For example,
[stackage.nix](https://github.com/ican-group/stackage.nix) exposes the
`nix` expressions of every Stackage Snapshot.

In addition, it is possible to explicitly specify a package version and
revision, or even to fetch its sources (e.g. using Git).

### Granularity and performance: per component level control

Haskell packages can contain several *components*: libraries, executables,
testsuites...

- `nixpkgs` mostly considers package as a whole.
- `haskell.nix` uses component granularity for dependencies.

The `nixpkgs` approach leads to some issues:

- building only a specific component (e.g. an executable) in a package is tricky
  to do

- dependencies of the different components are mixed up: this can lead to cyclic
  dependencies that `nix` can't solve. For example, package `unicode` exposes
  `lib-unicode` and `test-unicode` executable, where `test-unicode` depends on
  `lib-print` from package `print`, which itself depends on `lib-unicode`.
  Component-wise, dependencies aren't cyclic, however, package-wise, they are.

- build times: the Haskell builder in nixpkgs builds a package sequentially,
  first the library then the executables and finally the tests. It then executes
  the tests before the package is considered done. The upshot of this is that
  packages are only considered done if the test-suites passed. The downside is
  that if you have to compile multiple packages the likelihood of them failing
  is low, you have unnecessarily serialized your build. In a more aggressive
  setting libraries could start building as early as their dependent libraries
  are built.  Of course they will have to be invalidated later should the
  test-suites of their dependencies fail, but this way we can make use of
  parallel building.  In an ideal scenario this will reduce build times close to
  the optimum.

### More logic in nix

The `cabal2nix` tool has a resolver that resolves system dependencies
and licenses to values in `nixpkgs`.  This logic ends up being a simple
dictionary lookup and therefore can be a simple nix expression. This also
offloads some of the work the cabal to nix translation tool needs to
do into nix, and as such if changes are necessary (or needed to be
performed ad hoc) there is no need to rebuild the conversion tool and
subsequently mark every derived expression as out of date.

### Decoupling

Finally, by treating `haskell.nix` and `nixpkgs` as separate entities we
can decouple the Haskell packages and infrastructure from the `nixpkgs`
package set, and rely on it to provide us with system packages while
staying up to date with Haskell packages from hackage while retaining
a stable (or known to be good) nixpkgs revision.
