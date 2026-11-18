# Adding a new GHC version to haskell.nix

## Update `overlays/bootstrap.nix`

Each ghc version is defined in this file.  Duplicate one of the existing
ghc version definitions and replace the version numbers.  Make sure
you update the `spec.sha256` or the other versions source will be used.
Check the LLVM version that should be used in the
[ghc wiki](https://gitlab.haskell.org/ghc/ghc/-/wikis/commentary/compiler/backends/llvm/installing).

## Update the list of cached GHC versions in `ci.nix`

## Update [supported ghc versions](../reference/supported-ghc-versions.md) document

## Materialized files

New GHC versions do not need their own materialized files.  Since GHC 9.11
the nix files for the GHC boot packages are generated on demand (see
`combineAndMaterialize` in `overlays/ghc-packages.nix`).

The bootstrap tools used to build GHC (`alex`, `happy`, `hscolour`) are
materialized per nixpkgs boot compiler, not per new GHC, in
`materialized/alex-*`, `materialized/happy-*` and `materialized/bootstrap`
(see `overlays/bootstrap.nix`).  Those only need new files when the boot
compiler changes; the build fails with `Materialized nix used for ... is
missing` and an `updateMaterialized` hint if they are needed.

The files in `materialized/ghc-boot-packages-nix` are still used by GHC
versions before 9.11.  There is one directory per `compiler-nix-name`
(including the `llvm` variants), with `-aarch64` and `-ghcjs` variants for
aarch64 and GHCJS targets.  If a change affects them (for instance a patch to
the `.cabal` file of a boot package), check every affected compiler on both
an x86_64 and an aarch64 system, for example:

```shell
nix-build scripts/check-compiler-materialization \
  --arg compiler-nix-names '["ghc967" "ghc967llvm" "ghc984" "ghc984llvm" "ghc9103" "ghc9103llvm"]' \
  --arg systems '["x86_64-linux" "aarch64-linux"]'
```

The ghcjs and cross entries in `scripts/check-compiler-materialization` are
gated on hard-coded lists of compilers, so extend those if the `-ghcjs`
directory of the compiler you changed is not covered.

The script turns on `checkMaterialization` for everything it evaluates, so it
also checks the bootstrap tool plans above.  Updating those can change the
derivation of every GHC, so do that in a separate change.

When a materialized file is out of date the build fails with a message like:

```
Materialized nix used for ghc967-boot-packages-nix.nix incorrect. To fix run: /nix/store/...-updateMaterialized
```

Run the `updateMaterialized` script and repeat the `nix-build` until it no longer fails.
If the failure is not a problem with materialization and no `updateMaterialized` script
is provided then you may need to fix the failure another way or (if it only relates to
one of the cross compilers) modify `scripts/check-compiler-materialization/default.nix`
so that it skips that compiler.
