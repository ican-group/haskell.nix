# Getting started

`haskell.nix` can automatically translate your [Cabal](https://cabal.readthedocs.io/en/latest/cabal-project.html) or [Stack](https://docs.haskellstack.org/en/stable/README/#quick-start-guide) project and its dependencies into Nix code.

The first steps are to ensure you have [Nix](https://nixos.org/download.html) installed and [the binary cache set up](#setting-up-the-binary-cache) on your machine.

Then you have the choice to set-up your project using [the experimental Flake feature](#create-a-project-using-flakes) or [Niv](#create-a-project-using-niv), which are 2 ways to pin `nixpkgs` with Nix.

If you have an existing Haskell project that you want to build with `haskell.nix`, you might [prefer to use `hix`](#getting-started-with-hix). `hix` is a more easy and user-friendly way to use `haskell.nix`, using it reduce considerably the size of the Nix expression you will have to maintain in your project codebase.

## Setting up the binary cache

**IMPORTANT:** you _must_ do this or you _will_ build several copies of GHC!

`haskell.nix` CI pushes its GHCs and boot libraries to two binary caches:

| Cache | Public key | Holds |
| --- | --- | --- |
| `https://cache.zw3rk.com` | `loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk=` | every compiler and platform `haskell.nix` CI tests, including cross compilers (see the table in the [README](https://github.com/ican-group/haskell.nix#compiler-ci-status)) |
| `https://cache.iog.io` | `hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=` | the GHC versions IOG's own projects use |

Each cache only works with its own key: a substitute that is not signed by
one of your `trusted-public-keys` is ignored (with a warning like
`ignoring substitute for '...', as it's not signed by any of the keys in 'trusted-public-keys'`).

Add both to `/etc/nix/nix.conf`. `[...]` denote any existing entries.
```
extra-substituters = [...] https://cache.zw3rk.com https://cache.iog.io [...]
extra-trusted-public-keys = [...] loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk= hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ= [...]
```

* Use the `extra-` settings.  Plain `substituters = ...` and
  `trusted-public-keys = ...` *replace* the defaults, so unless you list
  `https://cache.nixos.org` and `cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=`
  there too, Nix stops using the nixpkgs cache and builds much of nixpkgs
  (including the bootstrap GHC) from source.
* With a multi-user install (the default on macOS and on most Linux
  installs), the settings are read by the Nix daemon, so restart it after
  editing the file: `sudo systemctl restart nix-daemon` on Linux,
  `sudo launchctl kickstart -k system/org.nixos.nix-daemon` on macOS (or
  reboot).
* `~/.config/nix/nix.conf` and `--option` on the command line only add
  substituters for [trusted users](https://nix.dev/manual/nix/latest/command-ref/conf-file.html#conf-trusted-users).
  For anyone else Nix prints `ignoring untrusted substituter` and carries
  on without them, which is why `/etc/nix/nix.conf` is the place for them.
* The `nixConfig` of a flake (such as the one in the
  [template](#create-a-project-using-flakes)) is the same, and even a
  trusted user has to accept it, when Nix asks or with
  `--accept-flake-config`; otherwise Nix prints
  `ignoring untrusted flake configuration setting 'extra-substituters'`.

If you're running NixOS, add the following to `/etc/nixos/configuration.nix`
instead.  NixOS keeps `cache.nixos.org` in these lists for you.
```nix
# Binary caches for haskell.nix
nix.settings.substituters = [
  "https://cache.zw3rk.com"
  "https://cache.iog.io"
];
nix.settings.trusted-public-keys = [
  "loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk="
  "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
];
```

To check what the daemon ended up with, run:
```
nix config show substituters
nix config show trusted-public-keys
```

Once you have a project (see below), `nix build --dry-run` lists what would
be fetched from a cache and what would be built (it still has to build the
project's evaluation-time dependencies, such as its plan, to get that far).
If a `ghc` derivation is in the `will be built` list, the caches are not set
up correctly.

This can be tricky to get setup properly. If you're still having trouble getting cache hits, consult the corresponding [troubleshooting section](../troubleshooting.md#why-am-i-building-ghc).

To push your own project's builds to a cache, see
[Caching your project's builds](caching-your-project.md).

## Create a project using Flakes

This section assumes you choose to uses the experimental flakes features, and so that you have added `experimental-features = [ "nix-command" "flakes" ];` in your Nix configuration. You can look at [the Wiki](https://nixos.wiki/wiki/Flakes) for more instructions.

The following `nix flake init` command creates a template `hello` package containing a `flake.nix` and `nix/hix.nix` file. The project can be used with
regular `nix` tools. This template is defined in the [haskell.nix repository](https://github.com/ican-group/haskell.nix/tree/master/templates/haskell-nix), so it always matches the current `hix init` output and supported GHC versions.
Its `flake.nix` uses [flake-parts](https://flake.parts) and haskell.nix's
flake-parts module (see [Using flake-parts](./flake-parts.md)); the project's
settings are in `nix/hix.nix`.
```bash
nix flake init --template github:ican-group/haskell.nix
nix develop
cabal build
```

To view the contents of the flake run:
```
nix flake show
```

To build a component with nix:
```
nix build .#hello:exe:hello
```

To build and run a component:
```
nix run .#hello:exe:hello
```

## Scaffolding

The following code could be copy-pasted and will work with `stack.yaml` and `cabal.project` based projects.
It uses haskell.nix's [flake-parts module](./flake-parts.md), which also
shows how to write the same flake without flake-parts.

Edit your `flake.nix` as:
```nix
{{#include getting-started-flakes/flake.nix}}
```

> **Note:** Git dependencies
> 
> If you have git dependencies in your project, you'll need to [calculate sha256 hashes for them](./source-repository-hashes.md).

## Working with a project

Top-level attributes are Haskell packages (incl. dependencies) part of your project.

This section will show side by side the commands using Flakes experimental `new-command` API and legacy Nix commands.

To build the library component of a package in the project run:
```shell
nix build .#your-package-name:lib:your-package-name
```

There are also other components such as `exes`, `tests`, `benchmarks` and `all`.
To build an executable:
```shell
nix build .#your-package-name:exe:your-exe-name
```

Building a test component (`your-package-name:test:your-test-name`) only
compiles the test. To run it, build its check, or run all of them with
`nix flake check`
(see [Running tests](./testing.md)). Replace `x86_64-linux` with your system:
```shell
nix build '.#checks.x86_64-linux."your-package-name:test:your-test-name"'
```

When the project directory (the one with `cabal.project` or `stack.yaml`)
is itself the directory of a package, the flake also has a `default`
package and app taken from that package, the one a bare `cabal build` or
`cabal run` would use there.  `nix build` builds the package's executable
if it has exactly one, and its library otherwise; `nix run` runs that
executable.  Set `flake.doDefaults = false` in the project to leave them
out.

Flakes provide a `devShell` attribute that allow you to spawn a developer shell, here with `cabal`, `hlint` and `haskell-language-server`:
```shell
nix develop .
cabal repl your-package-name:lib:your-package-name
cabal build your-package-name
```

To open a shell for use with `stack` and HLS, see [Using Stack and HLS with a Stack project](./development.md#using-stack-and-hls-with-a-stack-project).

## Getting started with Hix

Hix is a command line tool that provides an easy way to add `haskell.nix` support to existing haskell projects.

The `hix init` command adds a `flake.nix` and `nix/hix.nix` file. After that the project can be used with regular `nix` tools.

For instance to run `cabal build` on the `hello` package from hackage:
```shell
cabal unpack hello
cd hello-1.0.0.2
nix run "github:ican-group/haskell.nix#hix" -- init
nix develop
cabal build
```

To view the contents of the flake run:
```shell
nix flake show
```

To build a component with nix:
```shell
nix build .#hello:exe:hello
```

To build and run a component:
```shell
nix run .#hello:exe:hello
```

### Installing Hix

To use the other Hix features first install Hix with:
```shell
nix-env -iA hix -f https://github.com/ican-group/haskell.nix/tarball/master
```

To update run to the latest version run:
```shell
hix update
```

### Using `hix develop`, `hix flake`, `hix build` and `hix run`

These commands work the same as the `nix` versions without using the `flake.nix`.  Instead a boiler plate `haskell.nix` `flake.nix` file is added to `.hix-flake/flake.nix` and used from there.

The is can be useful if the project already includes a `flake.nix` or if you do not intend to maintain one.


Then all of these should work without the need to run `hix init`:
```shell
hix develop
hix flake show
hix build .#hello:exe:hello
hix run .#hello:exe:hello
```

### Using `hix-shell` and `hix-build`

These commands behave like `nix-build` and `hix-shell` would if a boiler plate `default.nix` and `shell.nix` we present.
```shell
hix-shell --run 'cabal build all'
hix-build -A hsPkgs.hello.components.exes.hello
```

## Going forward

Read through [project](../reference/library.md#project) function reference to see how the API works.

There are a number of things to explore further in the tutorials section.
