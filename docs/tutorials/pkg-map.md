# Mapping non-Haskell dependencies to Nixpkgs

Cabal files may contain dependencies to external non-Haskell
dependencies via:

* [`build-tool-depends`](https://cabal.readthedocs.io/en/latest/cabal-package.html#pkg-field-build-tool-depends)
* [`pkgconfig-depends`](https://cabal.readthedocs.io/en/latest/cabal-package.html#pkg-field-pkgconfig-depends)
* [`frameworks`](https://cabal.readthedocs.io/en/latest/cabal-package.html#pkg-field-frameworks)
* [`extra-libraries`](https://cabal.readthedocs.io/en/latest/cabal-package.html#pkg-field-extra-libraries)

If there is a `pkgs` attribute in Nixpkgs that matches the name given
in the Cabal file, then it will be added as a dependency (see the
output of `cabal-to-nix`). Otherwise, there needs to be a mapping from
Cabal file names (decided by the package author) to Nix package
identifiers.

### Nixpkgs overlay

The user may solve it by themself by overriding Nixpkgs and adding a
package alias. For example:

```nix
nixpkgs.overlays = [
  (self: super: {
    icuuc = self.icu;
    icui18n = self.icu;
    icudata = self.icu;
  })
];
```

The user can map package(s) in Nixpkgs to a `pkgconfig-depends` name by
overlaying the `haskell-nix.extraPkgconfigMappings` attribute:

```nix
nixpkgs.overlays = [
  (self: super: {
    haskell-nix = super.haskell-nix // {
      extraPkgconfigMappings = super.haskell-nix.extraPkgconfigMappings // {
          # String pkgconfig-depends names are mapped to lists of Nixpkgs
          # package names
          "SDL_gpu" = [ "SDL_gpu" ];
      };
    };
  })
];
```

### Replace libraries of components

If a component is missing a dependency it can be added via modules. For example:

``` nix
project = pkgs.haskell-nix.project' {
  src = self;
  compiler-nix-name = "ghc8102";
  modules = [{
    # Replace `extra-libraries` dependencies
    packages.X11.components.library.libs = pkgs.lib.mkForce (with pkgs.xorg;
        [ libX11 libXrandr libXext libXScrnSaver libXinerama ]);
  }];
};
```

### Mapping in Haskell.nix

Alternatively, if the name is commonly used, an alias can be added to
the Haskell.nix sources, so that it's solved for all users.

* [`lib/pkgconf-nixpkgs-map.nix`](https://github.com/ican-group/haskell.nix/blob/master/lib/pkgconf-nixpkgs-map.nix)
  — for `pkgconfig-depends`.

  Each mapping entry is a list of packages.

* [`lib/system-nixpkgs-map.nix`](https://github.com/ican-group/haskell.nix/blob/master/lib/system-nixpkgs-map.nix)
  — for `build-tool-depends`, `frameworks`, `extra-libraries`, etc.

  Each name can be mapped to:
  1. A single package from nixpkgs.
  2. `null` — eliminates the dependency
  3. A list of packages — sometimes needed for dependencies such as `X11`.

> **Tip:** Open a PR
>
> Please go ahead and open a [pull request](https://github.com/ican-group/haskell.nix/pulls)
> to improve the package mappings.
