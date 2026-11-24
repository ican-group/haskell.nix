# Reference page for the arguments of `cabalProject'`, `stackProject'` and
# `project'`, including their `shell` and `flake` submodules.  The project
# functions take a module, so these are module options; this evaluates the
# project modules on their own (with no project) just to read the options.
{ pkgs ? import <nixpkgs> {}
, lib ? pkgs.lib
}:
let
  optionsFor = projectType: (lib.evalModules {
    modules = [
      ../modules/project-common.nix
      projectType
      {
        _module.args = {
          inherit pkgs;
          inherit (pkgs.haskell-nix) haskellLib;
          buildProject = null;
        };
        _module.check = false;
      }
    ];
  }).options;

  optionsNix = projectType: (pkgs.nixosOptionsDoc {
    options = builtins.removeAttrs (optionsFor projectType) [ "_module" ];
  }).optionsNix;

  cabal = optionsNix ../modules/cabal-project.nix;
  stack = optionsNix ../modules/stack-project.nix;

  inherit (import ./render-options-doc.nix { inherit lib; }) renderOptions;

  inSubmodule = prefix: name: lib.hasPrefix "${prefix}." name;
  isCommon = _: v: builtins.elem "haskell.nix/modules/project-common.nix" v.declarations;
  # `shell` and `flake` get sections of their own.
  topLevel = lib.filterAttrs (n: _:
    !builtins.elem n [ "shell" "flake" ] && !inSubmodule "shell" n && !inSubmodule "flake" n);
  submodule = prefix: lib.filterAttrs (n: _: inSubmodule prefix n) cabal;

  section = prefix: renderOptions {
    headingLevel = 3;
    nameOf = n: if prefix == null then n else lib.removePrefix "${prefix}." n;
  };

in builtins.toFile "project-options.md" ''
# Project options

These are the arguments of [`cabalProject'`](library.md#cabalproject),
[`stackProject'`](library.md#stackproject) and
[`project'`](library.md#project) (and their unprimed versions).  The project
functions take a module, so an argument can also be a list of modules or a
function of `{ config, pkgs, lib, ... }`, and
[`appendModule`](library.md#cabalproject) adds more modules to a project:

```nix
pkgs.haskell-nix.cabalProject' [
  { src = ./.; compiler-nix-name = "ghc912"; }
  ({ config, ... }: { shell.tools.cabal = "latest"; })
]
```

The `modules` argument is different: it sets the options of the package
set, which are on the [Module options](modules.md) page.

!!! note "Generated"
    This page is generated from the Nix sources in
    [`modules`](https://github.com/ican-group/haskell.nix/tree/master/modules)
    by `scripts/project-options-doc.nix`.

## Options of every project

${section null (lib.filterAttrs isCommon (topLevel cabal))}

## `cabalProject'` options

${section null (lib.filterAttrs (n: v: !isCommon n v) (topLevel cabal))}

## `stackProject'` options

${section null (lib.filterAttrs (n: v: !isCommon n v) (topLevel stack))}

## `shell`

The project's `shell` argument: the arguments of `shellFor` that make the
project's `shell` attribute (and the flake's default `devShell`).
`p.shellFor { ... }` takes the same arguments, and merges them with these.

${section "shell" (submodule "shell")}

## `flake`

The project's `flake` argument: the defaults for `p.flake { ... }`, which
takes the same arguments and merges them with these.

${section "flake" (submodule "flake")}
''
