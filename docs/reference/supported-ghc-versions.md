# Supported GHC Versions

The following GHC versions are defined in `haskell.nix` (there is a derivation
for each, though not all are cached or tested by CI):

- 9.6.6 (TH is broken in mingwW64, but ucrt64 works)
- 9.8.4
- 9.10.1
- 9.12.1

8.10.7 may still work with older nixpkgs versions, but is broken for
nixpkgs-unstable.

The following table shows the Nixpkgs/GHC versions which are built/cached, and
which of those are further tested.  If you use a combination of Nixpkgs version
and GHC version which is in this table, you should hit our cache, saving
considering time by not building GHC and a few additional tools.

Note that if you try to use `haskell.nix` as an overlay over Nixpkgs from a
standard Nixpkgs channel you will likely get a cache miss.  To hit our cache you
really should use an instance of Nixpkgs provided by `haskell.nix` itself.

| Nixpkgs version  | Nixpkgs pinning    | GHC version | `compiler-nix-name`   | Tested in CI? |
|------------------|--------------------|-------------|-----------------------|---------------|
| unstable         | `nixpkgs-unstable` | 9.6.7       | `ghc96` or `ghc967`   | Yes           |
| unstable         | `nixpkgs-unstable` | 9.8.4       | `ghc98` or `ghc984`   | Yes           |
| unstable         | `nixpkgs-unstable` | 9.10.3      | `ghc910` or `ghc9103` | Yes           |
| unstable         | `nixpkgs-unstable` | 9.12.4      | `ghc912` or `ghc9124` | Yes           |

See [ci.nix](https://github.com/ican-group/haskell.nix/blob/master/ci.nix)
for the source of truth about what is built and tested (in the off chance this
document is out-of-sync with your checkout).

See the [getting started guide](../tutorials/getting-started.md) for
instructions on how to set up Nix to take advantage of our cache when building.
This guide also covers where to use the Nixpkgs pinning and `compiler-nix-name`
settings from the table above.  For further information, see the [instructions
for how to pin Nixpkgs](../dev/nixpkgs-pin.md).

See
[overlays/bootstrap.nix](https://github.com/ican-group/haskell.nix/blob/master/overlays/bootstrap.nix)
for a full list of all the valid `compiler-nix-name`s beyond what's
cached/tested in CI.  You're free to use these, but be ready for longer build
times.

Lastly, see [instructions on adding new GHC versions](../dev/adding-new-ghc.md)
in the event that what's in `haskell.nix` doesn't suit your needs.

## Using a GHC from nixpkgs

A project can use one of nixpkgs' GHCs (`pkgs.haskell.compiler.<name>`)
instead of one haskell.nix builds, with the `compilerSelection` project
option:

```nix
pkgs.haskell-nix.cabalProject' {
  src = ./.;
  compilerSelection = p: p.haskell.compiler;
  compiler-nix-name = "ghc967";   # a name in pkgs.haskell.compiler
}
```

`compilerSelection` is given the build platform's `pkgs` and returns the set
`compiler-nix-name` is looked up in; by default that is
`p.haskell-nix.compiler`.  Use a full name from `pkgs.haskell.compiler` (say
`ghc967` rather than `ghc96`): a short name is first resolved to the newest
GHC haskell.nix has for that series, which nixpkgs may not have.

nixpkgs' native GHCs are in `cache.nixos.org`, so this avoids building GHC
when haskell.nix's caches do not have the one you want.  The project is
planned and built as usual, with either builder (`builderVersion = 1` or
`2`).

Things to know:

* Everything built with it is a cache miss on the haskell.nix caches, which
  only have packages built with haskell.nix's own GHCs.
* haskell.nix's GHCs carry patches that nixpkgs' do not, and haskell.nix's
  CI only tests its own GHCs.  Cross-compilation in particular (Template
  Haskell, Windows, JavaScript, WebAssembly) is only tested with them.
* Cross-compiling (`projectCross`) uses nixpkgs' cross GHC for the target,
  which is not usually in `cache.nixos.org`, so it is built from source.
* Attributes that only haskell.nix's GHCs have, such as the `.dwarf`
  variant, are not there.
