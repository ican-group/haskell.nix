# Tools

Executables you want on hand while working on a project, rather than
as part of it (`cabal`, `hlint`, `haskell-language-server`, `hoogle`,
`ormolu`, ...), are usually built from Hackage with `haskell-nix.tool`,
`haskell-nix.tools` or, most often, the `tools` argument of
[`shellFor`](library.md#shellfor) (or a project's `shell`).

## Adding tools to a shell

```nix
project.shellFor {
  tools = {
    cabal = "latest";
    hlint = "3.8";
    haskell-language-server = {};
  };
}
```

or, using the project `shell` argument (see
[`project'`](library.md#project)):

```nix
pkgs.haskell-nix.project' {
  src = ./.;
  compiler-nix-name = "ghc912";
  shell.tools = {
    cabal = "latest";
    hlint = "latest";
  };
}
```

Each entry is `<name> = <version or arguments>`.  The tools are built
with the same GHC as the shell (the build platform's GHC when cross
compiling), which matters for tools such as `haskell-language-server`
that load your code into GHC.

Shells of projects using the v2 builder (`builderVersion = 2`, the
default for the stable-haskell compilers) treat `cabal` specially and
also accept prebuilt derivations; see
[Shells with `builderVersion = 2`](#shells-with-builderversion--2).

## haskell-nix.tool and haskell-nix.tools

The same tools are available outside a shell:

```nix
pkgs.haskell-nix.tool "ghc912" "cabal" "3.14.2.0"
pkgs.haskell-nix.tools "ghc912" { cabal = "latest"; hlint = "latest"; }
```

`tool` takes the GHC (`compiler-nix-name`), the tool name and a version
(or arguments, see below), and returns the executable component.
`tools` takes an attribute set of tools and returns an attribute set of
the executables.

A project has `tool` and `tools` attributes too, which use the
project's GHC (and its `evalSystem`):

```nix
project.tool "cabal" "latest"
project.tools { cabal = "latest"; hlint = "latest"; }
```

## What a tool is

`haskell-nix.tool "ghc912" "cabal" "3.14.2.0"` is a shorthand for:

```nix
(pkgs.haskell-nix.hackage-package {
  compiler-nix-name = "ghc912";
  name = "cabal-install";
  version = "3.14.2.0";
  configureArgs = "--disable-benchmarks --disable-tests";
}).getComponent "exe:cabal"
```

So a tool is a [`hackage-package`](../tutorials/building-package-from-stackage-hackage.md):
a one package `cabalProject'` whose `cabal.project` only asks for that
package from Hackage, planned against haskell.nix's Hackage index.

Some tools are better known by their executable's name than their
package's.  `haskell-nix.toolPackageName` maps the name you use to the
Hackage package (`cabal` is `cabal-install`, `gen-hie` is `implicit-hie`,
`refactor` is `apply-refact`, `sos` is `steeloverseer`), and
`haskell-nix.packageToolName` maps the package back to its executable.
Every other tool's executable must have the same name as its package.

`modules/hackage-quirks.nix` holds fixes applied to particular tools
(for instance constraints that keep old `stack` versions buildable).

## Versions

The version can be:

* An exact Hackage version, such as `"3.14.2.0"`.
* `"latest"`, which leaves the version out of the plan, so cabal's
  solver picks the newest version that builds with the GHC and index
  state in use.  `{}` means the same, as `"latest"` is the default.

`"latest"` depends on the Hackage index haskell.nix was pinned with, so
it changes when you update haskell.nix.  Pin a version (and if you like
an `index-state`, see below) when you need the tool to stay the same.

## Arguments

Instead of a version you can give an attribute set.  Its attributes are
passed to `hackage-package`, so they can be any
[`cabalProject'`](library.md#cabalproject) argument, as well as
`version`:

```nix
tools.cabal = {
  version = "3.14.2.0";
  # The Hackage index to plan with (defaults to the latest one
  # haskell.nix knows about).
  index-state = "2025-06-01T00:00:00Z";
  # Extra cabal.project text, e.g. to set flags or constraints.
  cabalProjectLocal = ''
    constraints: hackage-security >=0.6.3
  '';
  # haskell.nix modules for the tool's package set.
  modules = [{ packages.cabal-install.doHaddock = false; }];
};
```

A list is also accepted, and treated as a list of project modules
(each one an attribute set or module function):

```nix
tools.hlint = [
  { version = "3.8"; }
  ({ lib, ... }: { modules = [{ packages.hlint.flags.ghc-lib = true; }]; })
];
```

### Pinning the plan with materialization

Building a tool's plan (`plan-nix`) needs evaluation-time builds (IFD).
To avoid it, [materialize](../tutorials/materialization.md) the tool's
plan.  This needs a fixed `index-state` and `version`:

```nix
tools.cabal = {
  version = "3.14.2.0";
  index-state = "2025-06-01T00:00:00Z";
  materialized = ./materialized/cabal;
};
```

The `hoogle` used for a shell's Hoogle index (`withHoogle = true`) is
built from `tools.hoogle` too, so it can be pinned and materialized
the same way.  (A v2 shell builds no Hoogle index; it only puts that
`hoogle` on `PATH`.)

### A different GHC

A tool is built with the GHC you give `tool` (or the shell's / project's
GHC).  If a tool does not support it yet, set `compiler-nix-name`
for that tool:

```nix
tools.hlint = { version = "latest"; compiler-nix-name = "ghc910"; };
```

Do not do this for tools that need to match the GHC your code is built
with, such as `haskell-language-server`.

### Executables that need a flag

Some packages only build their executable when a Cabal flag is on.  If
the solver turns it off, asking for the tool fails with an error
listing the executables the package does have.  Turn the flag on with
`cabalProjectLocal`:

```nix
tools.cabal-plan = {
  version = "latest";
  cabalProjectLocal = ''
    package cabal-plan
      flags: +exe
  '';
};
```

## Building a tool from source

To use a version of a tool that is not on Hackage (a branch, an
unreleased fix, a fork), set `src` instead of a Hackage version.  The
tool is then planned using the `cabal.project` in that source.  With
flakes, add the source as an input:

```nix
{
  inputs.cabal-src = { url = "github:haskell/cabal"; flake = false; };
  outputs = { self, nixpkgs, haskellNix, cabal-src, ... }:
    ...
      shell.tools.cabal = { src = cabal-src; };
    ...
}
```

Without flakes, use any source, for instance `builtins.fetchGit` or a
local checkout (`src = ../cabal;`).  `index-state`,
`cabalProjectLocal` and `modules` work here as they do for a Hackage
version.

In a v2 shell, `tools.cabal` without a `version` is replaced by the
cabal that built the project (see below), so pass the tool you built
instead:

```nix
shell.tools.cabal = pkgs.haskell-nix.tool "ghc912" "cabal" { src = cabal-src; };
```

Building a tool from source only changes that tool.  It does not change
the Cabal library haskell.nix itself uses to plan projects (which comes
with `nix-tools`) or to build `Setup.hs`.

## Shells with `builderVersion = 2`

A v2 shell (`builder/shell-for-v2.nix`) gives you a cabal store that
already holds your project's dependencies, built by haskell.nix's own
cabal-install (`haskell-nix.v2-cabal-install`, also available as
`project.v2-cabal-install`).  A different cabal-install computes
different unit IDs, misses every unit in that store and rebuilds all of
them.  So in a v2 shell:

* `tools.cabal = "latest"`, `{}`, `"v2-cabal-install"`, or any argument
  set without a `version` gives you `v2-cabal-install`, not a
  cabal-install from Hackage.  Its other arguments (`src`,
  `index-state`, `cabalProjectLocal`, ...) are not used.
* `tools.cabal = "<version>"` (or `{ version = "<version>"; ... }`)
  builds that version from Hackage as usual, with a warning when it is
  not the version that built the store.
* A tool can be a derivation, which is put on `PATH` as it is.  This is
  how to use a cabal built from source (see above), or any tool that
  cannot be built with the project's GHC.  For instance a from-source
  compiler such as `ghc914-sh` cannot always build tools itself, so
  build them with a nixpkgs-provided GHC:
  `tools.hlint = pkgs.haskell-nix.tool "ghc912" "hlint" "latest";`.
  A `cabal` derivation gets the same warning as a version pin unless it
  is the cabal-install that built the store.  (v1 shells take
  derivations in `tools` too.)
* Tools are built with `haskell-nix.tool`, so their plans are made on
  the build machine's system rather than the project's `evalSystem`.
* `withHoogle = true` only puts `hoogle` on `PATH` (from `tools.hoogle`
  when given); run `hoogle generate` yourself to make an index.

## haskell.nix's own cabal-install

`tools.cabal = "v2-cabal-install"` asks for the cabal-install the v2
builder builds slices with, built for the project's `evalSystem` (the
same derivation as `project.v2-cabal-install`).  It works in shells of
either builder, and in a project's `shell` argument, where `project` is
not available.  It is only valid for `cabal`.  See
[the troubleshooting entry](../troubleshooting.md#why-does-cabal-build-in-my-shell-rebuild-a-dependency-that-has-public-sub-libraries)
for why a default-builder shell may want it.

## Tools given in more than one place

A project's `shell.tools` and a `shellFor { tools = ...; }` are merged
tool by tool:

* Module priorities come first: `lib.mkForce` picks a definition
  outright.
* `"latest"` and `{}` ask for no particular version, and give way to
  any other definition.  So a template's `shell.tools.cabal = "latest"`
  does not get in the way of a `shellFor { tools.cabal = ...; }`.
* A derivation wins over a version or module spec, with a warning when
  that throws away an actual pin.
* Two different derivations, or two different version strings, are an
  error.  Use `lib.mkForce` on the one you want.
* Otherwise module specs are merged as before.

## Alternatives

`tools` is a convenience for "the executable of one Hackage package".
Use something else when that is not what you want:

* **[`hackage-package`](../tutorials/building-package-from-stackage-hackage.md)**
  gives you the whole package (its library, its tests, all of its
  executables) rather than one executable.  `hackage-project` gives you
  the project (`plan-nix`, `hsPkgs`, `shellFor`, ...).
* **[`cabalProject'`](library.md#cabalproject) or
  [`project'`](library.md#project)** on the tool's source (or on a
  `cabal.project` listing several tools) is best when a tool needs a
  custom `cabal.project`, several tools have to share one build plan,
  or you want the tool's library too.  Pass its executables to the shell
  with `nativeBuildInputs` (or `buildInputs`).
* **Your own project's executables** do not need `tools`.  The
  `build-tool-depends` of the packages a shell is for are added to it
  already (see `allToolDeps` in [`shellFor`](library.md#shellfor)).
* **nixpkgs** (`pkgs.haskellPackages.<tool>` or `pkgs.<tool>`) is
  usually cached and quick to get, but is built with nixpkgs' GHC and
  Hackage snapshot, not your project's.  That is fine for tools that do
  not look at your code with GHC (formatters you run on files, `cabal`
  itself), and wrong for `haskell-language-server` and other tools that
  use the GHC API.  Add them with `nativeBuildInputs`.
