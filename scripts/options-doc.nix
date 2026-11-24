{ pkgs ? import <nixpkgs> {}
, lib ? pkgs.lib
}:
let
  # Provide a dummy pkg-def for the package set function
  pkg-def = _hackage: {
    packages = {};
    compiler = {
      version = "";
      nix-name = "";
      packages = {};
    };
  };

  # Apply the package set function to get NixOS options.  With
  # `use-package-keys = false`, `packages` is an `attrsOf` option, so the
  # documentation lists its options once, as `packages.<name>.*` (rather than
  # once for each package that a default module sets something for).
  inherit (import ../package-set.nix {
    hackage = null;
    inherit pkgs pkg-def;
    modules = [ { use-package-keys = false; } ];
  }) options;

  allOptions = (pkgs.nixosOptionsDoc {
    options = builtins.removeAttrs options [ "_module" ];
  }).optionsNix;

  # Every kind of component (and `allComponent`) has the options of
  # `components.library`; list those once, and for the others only the ones
  # they add.
  repeatsLibraryOption = name:
    let m = builtins.match
      "packages\\.<name>\\.(allComponent|components\\.setup|components\\.(sublibs|foreignlibs|exes|tests|benchmarks)\\.<name>)\\.(.*)" name;
    in m != null
      && allOptions ? "packages.<name>.components.library.${builtins.elemAt m 2}";

  optionsNix = lib.filterAttrs (name: _: !repeatsLibraryOption name) allOptions;

  inherit (import ./render-options-doc.nix { inherit lib; }) renderOptions;

in builtins.toFile "options.md" ''
Haskell.nix modules options for packages and components.  These are the
options the `modules` argument of a project sets.  For the arguments of
the project functions themselves (`cabalProject'`, `stackProject'`,
`shell` and `flake`) see [Project options](project-options.md).

!!! note "Generated"
    This documentation is generated from Nix sources in the
    [`modules`](https://github.com/ican-group/haskell.nix/tree/master/modules)
    subdirectory using `scripts/options-doc.nix`

# Configuration Options

The components of a package (`packages.<name>.components.sublibs.<name>`,
`.exes.<name>`, `.foreignlibs.<name>`, `.tests.<name>`, `.benchmarks.<name>`
and `.setup`) and `packages.<name>.allComponent` all take the options of
`packages.<name>.components.library`, which are only listed there.

${renderOptions {} optionsNix}
''
