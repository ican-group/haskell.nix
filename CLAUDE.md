# haskell.nix Developer Notes

## General rules

- **Never use materialization** (`materialized` argument).
- **Never use `index-state`** for tools — just pin the version.
- **Never run `cabal` or `ghc --make`** — use `pkgs.haskell-nix.cabalProject` or `pkgs.haskell-nix.tool`
- **Never search /nix/store** — do not use `grep`, `find`, `ls`, or any glob pattern against `/nix/store`. Instead use `nix build` or `nix eval` to find exactly what you are looking for. Searching `/nix/store` is unreliable because it can return stale or unexpected versions from unrelated builds.

## `haskell-nix.tool` — build a tool from Hackage or Source

```nix
pkgs.haskell-nix.tool "ghc9103" "cabal" "3.12.1.0"
pkgs.haskell-nix.tool "ghc9103" "hlint" { version = "3.8"; inherit evalSystem; }
pkgs.haskell-nix.tool "ghc9103" "my-tool" { src = ./path/to/my-tool; }
```

## Using generated source with `haskell-nix.cabalProject`

If possible try to avoid generated source.  If you do have
to generate source avoid large monolythic source derivations.

If the `.cabal` file is not generated use:

```
  modules = [{
    packages.package-name.src = generatedSrc;
  }];
```

If the `.cabal` file is also generated use:

```
  cabalProjectLocal = ''
    packages: ${generatedSrc};
  '';
```

Remove it from `cabal.project` file if necessary.

## Updating the `head.hackage` pin (stale-hash build failures)

`head.hackage.ghc.haskell.org` is a **rolling** repository, so the fixed-output
derivation that runs `cabal v2-update` against it (see
`lib/cabal-project-parser.nix`) goes stale whenever head.hackage updates. Symptom
(hits GHC >= 9.13 / `ghc914-sh` plans that use head.hackage):

```
error: hash mismatch in fixed-output derivation '…-head.hackage.ghc.haskell.org.drv':
         specified: sha256-<old>
            got:    sha256-<new>
```

Fix — build the failing FOD to learn the current hash, then update the
`--sha256:` line of the `head.hackage.ghc.haskell.org` repository block in
`test/cabal.project.local`:

```
nix build /nix/store/…-head.hackage.ghc.haskell.org.drv^out --no-link   # prints specified/got
# copy the `got:` value into test/cabal.project.local  (the `--sha256:` under `repository head.hackage…`)
```

Expect to redo this periodically; it is inherent to pinning a rolling repo.

## Notes

- `"cabal"` is aliased to package `cabal-install`; other aliases in `overlays/tools.nix`.
- Pass `evalSystem` (a system string) whenever possible; the project's
  `evalPackages` option is read-only and derived from it.
- Compilers built with `cabalProject` instead of hadrian (e.g. `ghc914-sh`, the
  stable-haskell GHCs) set `passthru.isStableHaskell = true`. Their boot packages
  are **not** in the GHC source tree, so the `ghc-boot-packages` /
  `ghc-extra-pkgs` machinery in `overlays/ghc-packages.nix` is skipped for them.
