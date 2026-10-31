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
