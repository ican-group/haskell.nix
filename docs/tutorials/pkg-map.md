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

### Adding dependencies the `.cabal` file does not declare

Some packages need things from nixpkgs that their `.cabal` file does not
name: a custom `Setup.hs` that runs a tool such as `mysql_config` or
`pg_config`, a library found by a `configure` script, or a tool a test
suite runs.  Give them to the component that needs them with a module.
Each component has these options:

| Option | Goes to | Use it for |
|---|---|---|
| `libs` | `buildInputs` | C libraries to link against (what `extra-libraries` would name) |
| `pkgconfig` | `propagatedBuildInputs` | Libraries found with `pkg-config`; a list of lists, one list per `pkgconfig-depends` entry |
| `frameworks` | `propagatedBuildInputs` | macOS frameworks |
| `build-tools` | `nativeBuildInputs` | Programs run during the build: `Setup.hs` helpers, code generators, tools a test runs |

For example, the `mysql` package from Hackage runs `mysql_config` from its
`Setup.hs` (it fails with "The program 'mysql_config' is required but it
could not be found"), and the libraries `mysql_config` names are needed
when linking anything that uses it:

```nix
project = pkgs.haskell-nix.project' {
  src = ./.;
  compiler-nix-name = "ghc96";
  modules = [{
    # `mysql_config`, run by mysql's Setup.hs
    packages.mysql.components.library.build-tools = [ pkgs.libmysqlclient ];
    # The libraries `mysql_config --libs` lists
    packages.mysql.components.library.libs =
      [ pkgs.libmysqlclient pkgs.zlib pkgs.openssl ];
  }];
};
```

These definitions are added to the ones haskell.nix makes from the `.cabal`
file.  To replace those instead, use `lib.mkForce`:

```nix
modules = [{
  packages.X11.components.library.libs = pkgs.lib.mkForce (with pkgs.xorg;
    [ libX11 libXrandr libXext libXScrnSaver libXinerama ]);
}];
```

The same options apply to the other components (`components.exes.<name>`,
`components.tests.<name>`, `components.setup` and so on); see
[Module options](../reference/modules.md).

For the development shell, which builds nothing itself, add tools and
libraries with the project's `shell.nativeBuildInputs` and
`shell.buildInputs` (see [Project options](../reference/project-options.md)).

#### The `nix:` section of `stack.yaml`

`stack.yaml` can list nixpkgs packages under `nix: packages:`.  Only
`stack --nix` reads that list; `stackProject` and `stack-to-nix` ignore it.
Give each of those packages to the components that need it, as above, and
to the shell if you build with `cabal` or `stack` in it:

```nix
pkgs.haskell-nix.stackProject' {
  src = ./.;
  modules = [{
    packages.mysql.components.library.build-tools = [ pkgs.libmysqlclient ];
    packages.mysql.components.library.libs =
      [ pkgs.libmysqlclient pkgs.zlib pkgs.openssl ];
  }];
  shell.buildInputs = [ pkgs.libmysqlclient pkgs.zlib pkgs.openssl ];
}
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
