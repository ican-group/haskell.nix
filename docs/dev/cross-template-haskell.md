# How Template Haskell is cross compiled

This page explains how haskell.nix runs Template Haskell (TH) splices when
cross compiling, and which parts you need to reproduce it with plain GHC, or
with GHC and cabal.  Source links point at the haskell.nix code that does each
step.

It assumes the cross-compilation work in the stable-haskell cabal branch
(`stable-haskell/merge`, the cabal side of
[haskell/cabal#12356](https://github.com/haskell/cabal/pull/12356)) is the
cabal in use.

## The problem

A splice is Haskell code that runs *while the compiler is compiling*.  When
cross compiling, the splice and everything it calls are compiled for the
**host** (the machine the program will run on), but the compiler runs on the
**build** machine.  A cross GHC cannot load host code into its own process.

So GHC hands the splice to a separate **external interpreter** process, built
for the host, and talks to it over a pipe using GHC's `iserv` protocol.  The
interpreter has to be started on something that can execute host code.

| Word in this page | Meaning | GHC calls it | cabal calls it |
|---|---|---|---|
| build machine | where GHC and cabal run | host | `build` machine |
| host machine | where the compiled program runs | target | `host` machine |

## The moving parts

```
 BUILD MACHINE
 ┌───────────────────────────────────────────────────────────────────┐
 │  cabal ──▶ cross GHC  -fexternal-interpreter -pgmi iserv-wrapper  │
 │                 │                                                 │
 │                 │ iserv protocol (two pipes)                      │
 │                 ▼                                                 │
 │            iserv-wrapper   (shell script, picks runner + flags)   │
 │                 │ exec                                            │
 │                 ▼                                                 │
 │            iserv-proxy     (built for the BUILD machine)          │
 │                 │ --pipe <runner> <interpreter> <dir> --stdio     │
 │                 ▼                                                 │
 │            runner          qemu-<arch> │ wine │ hl │ env          │
 │                 │                                                 │
 │   ┌─────────────▼──────────────────────────────────────────────┐  │
 │   │ iserv-proxy-interpreter   (built for the HOST machine)     │  │
 │   │ loads host .o / .a / .so files and runs the splice         │  │
 │   └────────────────────────────────────────────────────────────┘  │
 └───────────────────────────────────────────────────────────────────┘
```

* **GHC** is told to use an external interpreter (`-fexternal-interpreter`)
  and which program to start (`-pgmi <path>`).
* **iserv-proxy** runs on the build machine.  It starts the interpreter
  (`--pipe`) and forwards GHC's messages to it.  When the interpreter asks for
  an object, archive or DLL it does not have, the proxy sends the file over.
  It can also connect over TCP to an interpreter on a real device; haskell.nix
  only uses `--pipe`.
* **iserv-proxy-interpreter** is a host executable linked against `ghci`.  It
  loads the compiled host code with GHC's runtime linker and runs the splice.
* **The runner** makes host code executable on the build machine.

Both executables come from
[stable-haskell/iserv-proxy](https://github.com/stable-haskell/iserv-proxy)
(branch `iserv-syms`).

## Step 1: plain GHC

What you need, in order:

1. **A cross GHC** for the host.
2. **`iserv-proxy-interpreter` built for the host**, against the same GHC and
   boot libraries that compile the splices.
3. **`iserv-proxy` built for the build machine**, with any native GHC.
4. **A runner** for the host (see the table below).
5. **A wrapper script** that GHC can start as `-pgmi`.  haskell.nix's Linux
   one is essentially:

   ```sh
   #!/bin/sh
   exec iserv-proxy "$@" --pipe qemu-aarch64 iserv-proxy-interpreter tmp --stdio
   ```

   `"$@"` carries the pipe file descriptors GHC passes in.  `tmp` is the
   interpreter's directory for files the proxy sends it.
6. **Pass the flags to GHC**:

   ```sh
   aarch64-unknown-linux-gnu-ghc -fexternal-interpreter -pgmi ./iserv-wrapper Main.hs
   ```

GHC picks the interpreter program by *way*: it runs `<pgmi>-prof` for
profiled code and `<pgmi>-dyn` for `-dynamic` code.  Ship a wrapper under each
name you need.  haskell.nix builds a profiled interpreter for the `-prof`
wrapper ([linux-cross.nix][linux-cross-wrapper]).

### Runners

| Host | Runner | Where |
|---|---|---|
| Linux (aarch64, armv7, i686, x86_64 from another arch) | `qemu-<arch>` user mode | [armv6l-linux.nix][linux-th], [linux-cross.nix][linux-cross-wrapper] |
| Linux, on a darwin build machine | `hl` ([hyper-linux](https://github.com/zw3rk/hyper-linux)) | [armv6l-linux.nix][linux-hl] |
| Windows | `wine` | [windows.nix][windows-th], [mingw_w64.nix][mingw-wrapper] |
| Host the build machine can run (e.g. x86_64 musl on x86_64 Linux) | none | [comp-v2-builder.nix][project-iserv] |
| JavaScript | GHC's own JS interpreter under `node` | [build-cabal-slice.nix][node-path] |
| WebAssembly | GHC's `dyld.mjs` under `node` | [compiler/ghc/default.nix][wasm-dyld], [stable-haskell.nix][sh-wasm-dyld] |

For JavaScript and WebAssembly GHC already has its own external interpreter.
Only `node` needs to be on `PATH`, and for wasm `dyld.mjs` needs to find
`libc.so` and `libffi.so` in one directory.

### Things the interpreter needs

The interpreter loads host code with GHC's runtime linker, so it fails in ways
a normal executable does not.  These are the fixes haskell.nix applies, all in
[the iserv-proxy project][iserv-proxy-exes]:

| Problem | Fix | Hosts |
|---|---|---|
| A splice reaches a symbol nothing provides, and the load aborts | Link the interpreter with `-rtsopts=all -with-rtsopts=--optimistic-linking` ([link][optimistic]) | GHC ≥ 9.14 |
| A fully static interpreter has no `dlsym`, so no libc symbol resolves (`Failed to lookup symbol: strlen`) | Link it with `executable-static: False` (dynamic libc, static Haskell libraries) ([link][musl-dynamic]) | musl |
| qemu cannot run Android's dynamic loader | Link it with `-optl-static -optl-ldl` ([link][android-static]) | Android |
| `32 bit pseudo relocation … out of range` under wine | `--disable-dynamicbase,--disable-high-entropy-va,--image-base=0x400000` | Windows |
| The interpreter cannot find a splice's C DLLs | Link every DLL from the build inputs next to the interpreter ([link][wine-dlls]) | Windows |
| GHC [#15275](https://gitlab.haskell.org/ghc/ghc/issues/15275) | `-L<gmp>/lib` on the GHC command line | Linux, Windows |

The `iserv-syms` branch of iserv-proxy also compiles per-host tables of libc
symbols into the interpreter (`cbits/symbols.<host>.c`, for musl, Android and
Windows), so the runtime linker can resolve them for code a splice loads.

## Step 2: GHC and cabal

With the cross-compilation cabal, every unit in the plan belongs to a
machine.  `plan.json` records it in the `"machine"` field.

| Built for | What | Compiled by |
|---|---|---|
| host | every library and executable you asked for, **including everything a splice imports** | the cross GHC |
| build | `Setup.hs` of custom-setup packages, `build-tool-depends` executables (alex, happy, hsc2hs, …) and their libraries | the build GHC (`--with-build-compiler`) |

Splices need **no build-machine copy** of their dependencies.  A `lens` used
in a splice is compiled once, for the host, and loaded into the interpreter.

What cabal needs from you:

* **The external interpreter flags.**  Either set them for every package:

  ```cabal
  package *
    ghc-options: -fexternal-interpreter -pgmi /path/to/iserv-wrapper
  ```

  or wrap `ghc` so it always adds them.  haskell.nix does the latter
  ([wrapGhc][linux-cross-wrapGhc]): `ghc-options` enter cabal's unit-id hash,
  and haskell.nix needs the same unit id from every build of a package.  A
  plain cabal user does not need the wrapper.
* **The build compiler** for a two-stage plan:
  `--with-build-compiler=<native ghc>` (and `--with-build-hc-pkg`).  Other
  build-machine programs use `--with-build-PROG`.
* **Libraries the interpreter can load.**  A statically linked interpreter
  loads `.a` / GHCi `.o` files, so the default (no shared libraries) works.
  The wasm runtime linker only loads `.so` files, so wasm needs shared host
  libraries (see the note below).
* **Host-only settings in `package host:*`.**  The cabal branch accepts
  machine-qualified stanzas.  `package *` reaches build-machine units too,
  whose native compiler may not support what the host needs; haskell.nix sets
  `shared:` in `package host:*` for this reason ([link][host-stanza]).
* **`extra-packages: ghci`** for JavaScript and WebAssembly.  GHC's own
  interpreter loads the `ghci` unit at splice time, so it must be built for
  the host ([js-template-haskell test][js-th-test]).

haskell.nix builds `iserv-proxy` and `iserv-proxy-interpreter` in two separate
cabal projects, one per machine, with TH support turned off in them so the
interpreter does not depend on itself ([iserv-proxy-exes][iserv-proxy-exes],
[`crossTemplateHaskellSupport = false`][no-self-th]).

## The two kinds of cross GHC

### Hadrian-built cross GHC

A conventional cross compiler with its boot libraries built in.  haskell.nix
does not build a `ghc-iserv` for it ([compiler/ghc/default.nix][hadrian-iserv]),
so every cross splice goes through iserv-proxy and a runner, as in Step 1.  The
flags reach GHC through the ghc wrapper (v2 builder) or `--ghc-option`
`setupBuildFlags` (v1 builder) ([armv6l-linux.nix][linux-setup-flags]).

### stable-haskell GHC (`ghc914-sh`) with `-target`

The stable-haskell GHC is one native compiler that can target several
platforms at run time.  haskell.nix makes a cross compiler by wrapping the
native one with `-B<libdir> -target=<triple>` and a generated settings file
([stable-haskell.nix][sh-target]).  The wrapper:

* sets `cross compiling` to `YES` in its settings, which also makes GHC use
  the external interpreter for splices ([link][sh-cross-yes]);
* ships **no** host libraries.  Each project builds the boot libraries
  (`base`, `ghc-internal`, `ghci`, …) from GHC's source as local packages in
  its own plan ([boot packages][sh-boot-pkgs]);
* is planned **two-stage** (`withBuildCompiler = true`,
  [link][sh-two-stage]): build-machine units are compiled with the native
  compiler, host units with the wrapper.

Which interpreter a splice uses:

| Host | Interpreter |
|---|---|
| The build machine cannot run host code (Android, Windows, other arch) | iserv-proxy + runner, exactly as for a hadrian GHC |
| The build machine can run host code (x86_64 musl / static on x86_64 Linux) | the project builds GHC's own `utils/ghc-iserv` for the host ([link][sh-ghc-iserv]) and GHC runs it directly via `-pgmi` ([link][project-iserv]) |
| …and the code is profiled | iserv-proxy + `iserv-proxy-interpreter-prof`, with `env` as the runner ([link][project-iserv-prof]) |

On a dynamically linked musl host the in-process interpreter cannot load musl
shared objects into the glibc compiler.  Components that run splices are
built with `-fexternal-interpreter` there if they set
[`usesTemplateHaskell = true`][uses-th].

## Cabal changes this relies on

haskell.nix patches cabal for building one package at a time inside Nix
(unit-id stability, store reuse, build parallelism).  **None of those patches
are needed for TH.**

Two commits on haskell.nix's fork of the cabal branch (`hkm/sh-merge2-ports`)
are not in `stable-haskell/merge` and do matter for cross:

> **Note:** *elaboration: default to shared libs when the RTS linker only
> loads them* (ed916be32).  Without it, set `shared: True` in
> `package host:*` for wasm.  Not in `package *`: that also reaches the
> build machine, whose native compiler may have no dyn way.

> **Note:** *elaboration: fully-static executables are Host-stage only*
> (3b7730943).  Without it, `executable-static: True` also applies to build
> tools, which fails when the build machine has no static system libraries
> (e.g. darwin cross compiling to musl).

## Where to look

| Concern | Source |
|---|---|
| Linux wrapper script, GHC flags, ghc wrapper | [overlays/linux-cross.nix][linux-cross-wrapper] |
| Which Linux hosts get qemu / hl | [overlays/armv6l-linux.nix][linux-th] |
| Windows wrapper script and DLL handling | [overlays/mingw_w64.nix][mingw-wrapper] |
| Building iserv-proxy and the interpreter | [overlays/haskell.nix][iserv-proxy-exes] |
| Choosing the ghc wrapper per slice (v2 builder) | [builder/comp-v2-builder.nix][slice-ghc] |
| `-target` cross compiler | [overlays/stable-haskell.nix][sh-target] |
| Boot libraries built in the user's project | [modules/cabal-project.nix][sh-boot-pkgs] |
| End-to-end test (C libraries used from splices) | [test/th-dlls][th-dlls] |

[linux-cross-wrapper]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/linux-cross.nix#L24-L51
[linux-cross-wrapGhc]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/linux-cross.nix#L73-L112
[linux-th]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/armv6l-linux.nix#L3-L49
[linux-hl]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/armv6l-linux.nix#L33-L41
[linux-setup-flags]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/armv6l-linux.nix#L59-L62
[windows-th]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/windows.nix#L59-L81
[mingw-wrapper]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/mingw_w64.nix#L21-L79
[wine-dlls]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/mingw_w64.nix#L43-L58
[iserv-proxy-exes]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/haskell.nix#L1361-L1611
[no-self-th]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/haskell.nix#L1405-L1411
[optimistic]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/haskell.nix#L1434-L1458
[android-static]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/haskell.nix#L1472-L1504
[musl-dynamic]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/haskell.nix#L1505-L1545
[slice-ghc]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/builder/comp-v2-builder.nix#L1986-L1997
[project-iserv]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/builder/comp-v2-builder.nix#L1999-L2033
[project-iserv-prof]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/builder/comp-v2-builder.nix#L2034-L2061
[uses-th]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/modules/component-options.nix#L9-L22
[node-path]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/builder/build-cabal-slice.nix#L657-L664
[wasm-dyld]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/compiler/ghc/default.nix#L707-L730
[sh-wasm-dyld]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/stable-haskell.nix#L2154-L2190
[hadrian-iserv]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/compiler/ghc/default.nix#L1307-L1310
[sh-target]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/stable-haskell.nix#L2003-L2014
[sh-cross-yes]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/stable-haskell.nix#L2429-L2435
[sh-boot-pkgs]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/modules/cabal-project.nix#L501-L547
[sh-ghc-iserv]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/modules/cabal-project.nix#L538-L547
[sh-two-stage]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/modules/cabal-project.nix#L737-L741
[host-stanza]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/modules/cabal-project.nix#L706-L731
[js-th-test]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/test/js-template-haskell/default.nix#L16-L25
[th-dlls]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/test/th-dlls/default.nix
