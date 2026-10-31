# Building WebAssembly packages

haskell.nix supports cross-compiling Haskell projects to WebAssembly via the
[WASI](https://wasi.dev/) target (`wasm32-unknown-wasi`). This uses GHC's
built-in WASM backend together with a customised LLVM toolchain and wasi-libc.

## Prerequisites

- **Supported build hosts** — Linux (`x86_64-linux`, `aarch64-linux`) and
  macOS (`aarch64-darwin`) are supported. `x86_64-darwin` may work but is
  not regularly tested.
- **GHC 9.10 or newer** — Earlier versions do not have a WASM backend.
  GHC 9.12 is recommended and is the version tested in CI.
- **Binary cache** — Building a cross GHC from source takes a very long time.
  Make sure the IOG cache is configured so the pre-built WASM GHC is fetched
  instead (see [getting started](getting-started.md#setting-up-the-binary-cache)).

## Flake setup

Start from a normal haskell.nix Cabal project flake and add `p.wasi32` to
`crossPlatforms` in both the `project'` call and the `flake {}` call:

```nix
{
  description = "My Haskell project";

  inputs.haskellNix.url = "github:ican-group/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils, haskellNix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        overlays = [
          haskellNix.overlay
          (final: _prev: {
            myProject = final.haskell-nix.project' {
              src = ./.;
              compiler-nix-name = "ghc912";   # GHC 9.12 is recommended for WASM

              # Add wasi32 to the dev shell so cabal wrappers for the WASM
              # target are available (optional but handy during development).
              shell.crossPlatforms = p: [ p.wasi32 ];
            };
          })
        ];
        pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
        flake = pkgs.myProject.flake {
          # Expose WASM build outputs alongside the native ones.
          crossPlatforms = p: [ p.wasi32 ];
        };
      in flake // {
        packages.default = flake.packages."mypackage:exe:mypackage";
      });
}
```

## Building a WASM executable

WASM outputs are exposed in the flake under the prefix `wasm32-unknown-wasi`:

```shell
nix build .#wasm32-unknown-wasi:mypackage:exe:mypackage
```

The resulting `.wasm` file is at `result/bin/mypackage.wasm`.

To build a library:

```shell
nix build .#wasm32-unknown-wasi:mypackage:lib:mypackage
```

## Running tests

The `wasmtime` runtime is automatically set as the test wrapper for WASM
targets (configured in the `wasm.nix` overlay). Running tests works the same
as for native targets:

```shell
nix build .#wasm32-unknown-wasi:mypackage:test:mytest
./result/bin/mytest
```

Or with `checks`:

```shell
nix flake check
```

## Development shell

When `shell.crossPlatforms = p: [ p.wasi32 ]` is set, `nix develop` includes
a `wasm32-unknown-wasi-cabal` wrapper that invokes cabal with the WASM
cross-compilation environment pre-configured:

```shell
nix develop
wasm32-unknown-wasi-cabal build mypackage
```

## How it works

haskell.nix's WASM support is built from several layers applied automatically
whenever the target platform is WASM:

- **`overlays/wasm.nix`** — Applied only when `stdenv.targetPlatform.isWasm`.
  It customises LLVM 21, overrides `wasilibc` to the haskell-wasm fork, and
  sets `wasmtime` as the test wrapper.
- **`lazy-inputs/libffi-wasm`** — A WASM-specific build of libffi from the
  [haskell-wasm GitLab group](https://gitlab.haskell.org/haskell-wasm/).
- **`compiler/ghc/default.nix`** — GHC is configured with the WASM clang
  toolchain (`wasm32-unknown-wasi-clang`, `wasm-ld`), the "quick" Hadrian
  flavour, native bignum, and no profiled libs.
- **GHC patches** (`ghc-9.12-wasm-*.patch`) — Applied for GHC 9.12 to fix
  shared library and CAF handling on WASM.

The cross system name used by nixpkgs is `wasi32`
(`lib.systems.examples.wasi32`), which resolves to the triple
`wasm32-unknown-wasi`. All haskell.nix `projectCross` and `pkgsCross`
machinery therefore uses this name.

## Limitations

- **No interpreter / Template Haskell** — WASM builds cannot run a native TH
  splice evaluator. Projects that use Template Haskell must rely on the
  stage-1-only cross-compilation path (no `iserv-proxy`).
- **No GMP** — The WASM backend uses the native bignum library; GMP is not
  available.
- **`x86_64-darwin` untested** — Linux and `aarch64-darwin` build hosts are
  known to work; `x86_64-darwin` may work but is not regularly tested.
- **Shared libraries are experimental** — Static `.wasm` archives are the
  primary output; shared library support requires GHC patches that target 9.12
  only.
