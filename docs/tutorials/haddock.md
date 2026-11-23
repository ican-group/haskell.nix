# Building documentation (Haddock)

Each Haskell component built by haskell.nix can have a `.doc`
attribute: a derivation that runs Haddock for it.

```shell
nix-build -A hsPkgs.pkga.components.library.doc
```

Whether it is there, and how you switch it on or off, depends on the
component builder the project uses.

## `builderVersion = 1` (the default)

Documentation is on by default: every library has a `.doc`.  The
HTML ends up in `share/doc/<package>/html/` in the output.

It is controlled by the `doHaddock` module option, not by
`cabal.project`.  Turn it off for the whole project with a top-level
module setting, or for a single package:

```nix
pkgs.haskell-nix.cabalProject {
  src = ./.;
  compiler-nix-name = "ghc9103";
  modules = [
    # No haddock for any package.
    { doHaddock = false; }
    # Or for just one:
    # { packages.pkga.doHaddock = false; }
  ];
}
```

With `doHaddock = false` the component has no `.doc` attribute.  A
`documentation: False` in `cabal.project` does not do this.
(`documentation: True` makes cabal pass `-haddock` to GHC, which
haskell.nix passes on, but the `.doc` derivations are there either
way.)  The related options `doHoogle`, `doHyperlinkSource` and
`doQuickjump` (all on by default) control the Hoogle index, the
hyperlinked source and the Quickjump index.

## `builderVersion = 2`

The v2 builder builds each package the way cabal planned it, and in
cabal, building documentation changes a package's unit-id.  So `.doc`
exists only when the plan has documentation enabled, which is set in
`cabal.project` (or `cabalProjectLocal`) with cabal's own field:

```cabal
packages: pkga pkgb
documentation: True
```

A top-level field applies to the packages in `packages:`.  To also
get documentation for dependencies, so links into them resolve, use
`package *`:

```cabal
package *
  documentation: True
```

or `package <name>` for one package.

Without it, using `.doc` stops evaluation with an error explaining
the `documentation: True` setting.  The HTML is under
`store/…/<unit-id>/share/doc/html/` in the `.doc` output (cabal's own
store layout); the unit-id contains a hash, so find a page with e.g.
`find -L result -name PkgA.html`.  See the
[developer notes](../dev/haddock.md) for the details.

## See also

* [Generating coverage information](./coverage.md): the other
  `cabal.project` setting that works project-wide in the same way.
* [Creating a development environment](./development.md#how-to-get-a-local-hoogle-index)
  for a shell with a local Hoogle index of your dependencies.
* `test/sublib-docs` in the haskell.nix repository: `package *` /
  `documentation: True`, checking that a library's docs link into a
  dependency's (aeson's) docs.
