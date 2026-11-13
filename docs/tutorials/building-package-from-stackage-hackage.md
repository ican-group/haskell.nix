
# Build a specific package from Hackage or Stackage

## From a [Stackage][] snapshot

To build a package, say [lens][], from a Stackage snapshot, say
[lts-13.28][], you could run:
```shell
nix-build -E '(with import <nixpkgs> (import (builtins.fetchTarball "https://github.com/ican-group/haskell.nix/archive/master.tar.gz") {}).nixpkgsArgs; haskell-nix.snapshots."lts-13.28").lens.components.library'
```
This would build the (public) library component of the [lens][] package as
fixed by the [lts-13.28][] stackage snapshot. Nightly snapshots like
`nightly-2020-06-21` are also available.

## A specific version from Hackage

To build any package from hackage, say [lens][], at any version, say 4.17.1,
you could run:
```shell
nix-build -E '(with import <nixpkgs> (import (builtins.fetchTarball "https://github.com/ican-group/haskell.nix/archive/master.tar.gz") {}).nixpkgsArgs; (haskell-nix.hackage-package { name = "lens"; version = "4.17.1"; compiler-nix-name = "ghc8102"; })).components.library'
```
This would build the (public) library component of the [lens-4.17.1][] package
from hackage.

### Pinning hackage index

The dependencies would be resolved against the most recent
[hackage-index-state][] which comes with your [haskell.nix][] checkout via the
[hackage.nix][] pin.  A specific one can be specified as well:
```shell
nix-build -E '(with import <nixpkgs> (import (builtins.fetchTarball "https://github.com/ican-group/haskell.nix/archive/master.tar.gz") {}).nixpkgsArgs; (haskell-nix.hackage-package { name = "lens"; version = "4.17.1"; compiler-nix-name = "ghc8102"; index-state = "2019-07-14T00:00:00Z"; })).components.library'
```
This would use the hackage index as of `2019-07-14T00:00:00Z` to produce a
build plan for the [lens-4.17.1][] package.

[Stackage]: https://stackage.org
[Hackage]: https://hackage.haskell.org
[hackage.nix]: https://github.com/ican-group/hackage.nix
[haskell.nix]: https://github.com/ican-group/haskell.nix
[lts-13.28]: https://www.stackage.org/lts-13.28
[lens]: https://hackage.haskell.org/package/lens
[lens-4.17.1]: https://hackage.haskell.org/package/lens-4.17.1
[hackage-index-state]: https://github.com/ican-group/hackage.nix/blob/master/index-state-hashes.nix
