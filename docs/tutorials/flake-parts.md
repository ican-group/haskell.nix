# Using flake-parts

haskell.nix has a [flake-parts](https://flake.parts) module,
`haskellNix.flakeModules.default`.  It adds haskell.nix projects to a
flake-parts flake, and their packages, apps, checks and dev shells to the
flake's outputs.  It does the work of the overlay, `import nixpkgs`,
`flake-utils.lib.eachSystem` and `project.flake` boilerplate of a plain
haskell.nix `flake.nix`, and it works alongside other flake-parts modules
(treefmt, pre-commit hooks and so on).

The [template](./getting-started.md#create-a-project-using-flakes) and
`hix init` use it.

## A minimal flake

```nix
{
  inputs.haskellNix.url = "github:ican-group/haskell.nix";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  outputs = inputs@{ flake-parts, haskellNix, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ haskellNix.flakeModules.default ];
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      perSystem = { ... }: {
        haskellNix.projects.default = {
          src = ./.;
          compiler-nix-name = "ghc912";
          shell.tools.cabal = "latest";
        };
      };
    };
}
```

Then, for a package `hello` with an executable `hello`:

```shell
nix build .#hello:exe:hello
nix run .#hello:exe:hello
nix develop
nix flake check
```

When the project directory is itself a package's directory, `nix build` and
`nix run` use that package (see `flake.doDefaults` in
[Project options](../reference/project-options.md#flake)).

Add the haskell.nix binary caches to the flake's `nixConfig` (or the Nix
configuration) as the [getting started guide](./getting-started.md) describes.

## `haskellNix.projects.<name>`

Each project takes the arguments of
[`project'`](../reference/library.md#project), listed in
[Project options](../reference/project-options.md).  `project'` makes a
Stack project when `src` has a `stack.yaml` and no `cabal.project`, and a
cabal project otherwise.

A project is a module, so it can be a function, and it can be defined in
more than one place; the definitions merge the way project modules do:

```nix
perSystem = { ... }: {
  haskellNix.projects.default = { pkgs, ... }: {
    src = ./.;
    shell.buildInputs = [ pkgs.nixpkgs-fmt ];
  };
};
```

The template and `hix init` keep the project's settings in `nix/hix.nix`,
which the `hix` commands read too:

```nix
haskellNix.projects.default = {
  src = ./.;
  imports = [ haskellNix.projectModules.hix ./nix/hix.nix ];
};
```

`haskellNix.projectModules.hix` declares the options that only the `hix`
commands use (`nixpkgsPin`, `overlays` and so on, which a `nix/hix.nix` may
set) and gives `compiler-nix-name` the default `hix` gives it.

Reading `config.haskellNix.projects.<name>` gives the project itself:

```nix
perSystem = { config, ... }: {
  haskellNix.projects.default = { ... };
  # `nix build .#docs`: the haddock docs of the project's libraries
  packages.docs = config.haskellNix.projects.default.projectHaddock;
};
```

## Outputs

The outputs of the `default` project keep the names `project.flake` gives
them (`hello:exe:hello`, the `default` dev shell).  Those of any other
project get its name and `:` in front: `other:hello:exe:hello`, and the dev
shell `devShells.other`; only the `default` project gives `packages.default`
and `apps.default`.  The project's `flake` arguments apply as usual, so
`flake.crossPlatforms` adds outputs such as `javascript-unknown-ghcjs:hello:exe:hello`
and `flake.variants` adds variants.

The projects' `hydraJobs` and `ciJobs` are set on the flake too, laid out as
`flake-utils.lib.eachSystem` lays them out: `hydraJobs.<job>.<system>` and
`ciJobs.<system>.<job>`.  They come from each system's
`haskellNix.hydraJobs`, and other jobs can be added there; they merge with
the projects' job by job:

```nix
perSystem = { config, pkgs, ... }: {
  checks.smoke-test = pkgs.callPackage ./nix/smoke-test.nix { };
  # Also a Hydra job, next to the projects' checks.
  haskellNix.hydraJobs.checks = { inherit (config.checks) smoke-test; };
};
```

To set the flake's `hydraJobs` and `ciJobs` yourself, set
`haskellNix.addHydraJobs = false` (outside `perSystem`).

To choose the outputs yourself, set `haskellNix.addFlakeOutputs = false` and
take what you want from `config.haskellNix.outputs`, which has the
`packages`, `apps`, `checks`, `devShells`, `hydraJobs` and `ciJobs` of all the
projects.

`nix flake show` and `nix flake check` evaluate every system in `systems`.
haskell.nix plans each project with import-from-derivation, so that needs
builders for those systems, or an `evalSystem` that you have (see
[Project options](../reference/project-options.md)).  `nix build`, `nix run`
and `nix develop` only evaluate the current system.

## `haskellNix.pkgs`

The nixpkgs the projects are made with.  By default it is the one
haskell.nix is tested and cached with (`haskellNix.legacyPackages.${system}`),
with the haskell.nix overlay.  It is separate from flake-parts' `pkgs`
argument, which other modules expect to be plain nixpkgs.  To use your own
nixpkgs:

```nix
perSystem = { system, ... }: {
  haskellNix.pkgs = import inputs.nixpkgs {
    inherit system;
    inherit (inputs.haskellNix) config;
    overlays = [ inputs.haskellNix.overlay ];
  };
};
```

A nixpkgs haskell.nix does not test with can mean building GHC and
other tools rather than getting them from the cache.

## Without flake-parts

A flake can also call haskell.nix directly.  `project.flake {}` gives one
system's outputs, so `flake-utils.lib.eachSystem` is the usual way to put
them together:

```nix
{
  inputs.haskellNix.url = "github:ican-group/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils, haskellNix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          inherit (haskellNix) config;
          overlays = [ haskellNix.overlay ];
        };
        project = pkgs.haskell-nix.project' {
          src = ./.;
          compiler-nix-name = "ghc912";
          shell.tools.cabal = "latest";
        };
      in project.flake {});
}
```
