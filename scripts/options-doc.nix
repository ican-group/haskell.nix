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

  # Apply the package set function to get NixOS options.
  inherit (import ../package-set.nix { hackage = null; inherit pkgs pkg-def; }) options;

  allOptions = (pkgs.nixosOptionsDoc {
    options = builtins.removeAttrs options [ "_module" ];
  }).optionsNix;

  # The documentation lists the options of `packages.<name>` once for each
  # package that a default module (the Hackage quirks, for instance) sets
  # something for, as `packages.text.*`, `packages.network.*` and so on.
  # Keep one copy, as `packages.<name>.*`.
  isPackageOption = lib.hasPrefix "packages.";
  aPackage = builtins.elemAt (lib.splitString "."
    (lib.findFirst isPackageOption (throw "no package options") (lib.attrNames allOptions))) 1;
  packageOptions = lib.mapAttrs' (name: lib.nameValuePair
      ("packages.<name>." + lib.removePrefix "packages.${aPackage}." name))
    (lib.filterAttrs (name: _: lib.hasPrefix "packages.${aPackage}." name) allOptions);

  # Every kind of component has the options of `components.library`; list
  # those once, and only the ones a kind adds for the others.
  componentKinds = [ "sublibs" "foreignlibs" "exes" "tests" "benchmarks" ];
  isRepeatedComponentOption = name:
    let m = builtins.match
      "packages\\.<name>\\.components\\.(${lib.concatStringsSep "|" componentKinds})\\.<name>\\.(.*)" name;
    in m != null
      && packageOptions ? "packages.<name>.components.library.${builtins.elemAt m 1}";

  optionsNix =
    lib.filterAttrs (name: _: !isPackageOption name) allOptions
    // lib.filterAttrs (name: _: !isRepeatedComponentOption name) packageOptions;

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
`.exes.<name>`, `.foreignlibs.<name>`, `.tests.<name>` and
`.benchmarks.<name>`) all take the options of
`packages.<name>.components.library`.

${renderOptions {} optionsNix}
''
