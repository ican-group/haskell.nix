# Cross-compiling Template Haskell: how it works

| Term | Meaning | GHC's name |
|---|---|---|
| **build machine** | where GHC and cabal run | host |
| **host machine** | where the compiled program will run | target |

GHC names machines from the compiler's point of view; cabal and this page
name them from the package's.

This page is for people who ship GHC or cabal and want cross-compiled
Template Haskell (TH) to work.  It covers what to build and install: first
for plain GHC, then for GHC with a cross-aware cabal.  haskell.nix is the
reference implementation; links point at its source.

Rows and stanzas marked *stable-haskell GHC* apply only to the stable-haskell
fork of GHC; packagers of upstream GHC can skip them.

## The problem

A splice runs *while* GHC compiles the module.  When cross compiling, the
splice and everything it calls are compiled for the host machine, and a cross
GHC cannot load host code into its own process.

GHC's answer is the **external interpreter**: a separate program, built for
the host, that loads the splice's object code and runs it.  GHC talks to it
over a pipe (the `iserv` protocol).  What is left is starting a host program
on the build machine.

## The pieces

```
 build machine
 ─────────────────────────────────────────────────────────────────────
   cross GHC ──(-pgmi)──▶ wrapper script
                              │ exec
                              ▼
                          iserv-proxy                 [build-machine binary]
                              │ starts it under a runner (qemu / wine / hl)
                              ▼
                          iserv-proxy-interpreter     [host binary, emulated]

   GHC ◀── iserv protocol ──▶ proxy ◀── pipe + .o/.a/.so files ──▶ interpreter
```

* **iserv-proxy** sits between GHC and the interpreter.  It starts the
  interpreter and forwards GHC's messages.  When the interpreter asks for an
  object, archive or DLL it cannot see, the proxy sends the file over.  (It
  can also reach an interpreter on a real device over TCP; haskell.nix only
  uses the pipe.)
* **iserv-proxy-interpreter** is a host executable linked against GHC's
  `ghci` library.  It loads host code with GHC's runtime linker and runs the
  splice.
* **The runner** makes the host binary executable on the build machine.

Both programs come from
[stable-haskell/iserv-proxy](https://github.com/stable-haskell/iserv-proxy),
branch `iserv-syms`.  That branch also compiles a table of libc symbols into
the interpreter (`cbits/symbols.<host>.c`, for musl, Android and Windows), so
the runtime linker can resolve them for the code a splice loads.

## Step 1: plain GHC

1. **A cross GHC** for the host.
2. **`iserv-proxy-interpreter`, built for the host with that same GHC.**  It
   must speak the compiler's `iserv` protocol, so build one per GHC version,
   host and way.  It does not depend on the user's project.
3. **`iserv-proxy`, built for the build machine** with any native GHC.
4. **A runner** for the host:

   | Host | Runner |
   |---|---|
   | any Linux the build machine can't run natively | `qemu-<arch>` (user mode) |
   | musl Linux, on a macOS build machine | `hl` from [hyper-linux](https://github.com/zw3rk/hyper-linux) (must be installed) |
   | Windows | `wine` |
   | a host the build machine can run (e.g. x86_64 musl on x86_64 Linux) | none |
   | JavaScript, WebAssembly | GHC's own interpreter under `node` ([below](#javascript-and-webassembly)) |

   A dynamically linked interpreter needs the host's dynamic loader and libc
   under qemu: pass the host sysroot (`qemu-aarch64 -L <sysroot>`, or set
   `QEMU_LD_PREFIX`), or link the interpreter statically.  haskell.nix links
   it statically for Android and musl hosts (stable-haskell GHC: libc
   dynamic, see [Appendix A](#building-the-interpreter)), and dynamically
   for glibc hosts, where it gets away without a sysroot because the ELF
   interpreter is an absolute path that exists on the build machine.

5. **A wrapper script per host triple**, which GHC starts as `-pgmi`.  The
   short version (full scripts in [Appendix A](#wrapper-scripts)):

   ```sh
   #!/bin/sh
   exec iserv-proxy "$@" --pipe qemu-aarch64 iserv-proxy-interpreter tmp --stdio
   ```

6. **The flags**, plus [the per-host ones](#ghc-flags-per-host):

   ```sh
   aarch64-unknown-linux-gnu-ghc -fexternal-interpreter -pgmi ./iserv-wrapper Main.hs
   ```

GHC picks the program by *way*: it runs `<pgmi>-prof` for profiled code,
`<pgmi>-dyn` for `-dynamic` code and `<pgmi>-prof-dyn` for both
(`GHC.Runtime.Interpreter.Init`).  Ship at least the plain and `-prof` wrappers
(the `-prof` interpreter must be built against profiled libraries).  Ship
`-dyn` only if your users build with `-dynamic`.

### What to ship

| File | Built for | Install at |
|---|---|---|
| `iserv-proxy` | build machine | anywhere; the wrapper names it |
| `iserv-proxy-interpreter` (and `-prof`) | host | anywhere; the wrapper names it |
| wrapper script, named `ghc-iserv` (and `ghc-iserv-prof`, …) | — | `$(ghc --print-libdir)/../bin/`, next to `unlit` |

Without `-pgmi`, GHC runs `$topdir/../bin/ghc-iserv` (`$topdir` is
`ghc --print-libdir`), adding the way suffix as above.  Install the wrappers
there and users only add `-fexternal-interpreter`.  Elsewhere, users pass
`-pgmi` too.

What the user's machine needs at build time:

| Host | Needs |
|---|---|
| Linux, other architecture | `qemu-<arch>` (qemu user mode) |
| musl Linux, macOS build machine | `hl` (hyper-linux) |
| Windows | `wine` |
| JavaScript, WebAssembly | `node` |

### JavaScript and WebAssembly

GHC has its own external interpreter for these and always uses it.  Don't set
`-pgmi`.

* **JavaScript:** `node` on `PATH`.
* **WebAssembly:** `node` on `PATH` (haskell.nix uses Node.js 24).  GHC runs
  `dyld.mjs` with **one** library directory: the last `libraries:` entry of
  the C compiler's `-print-search-dirs`.  `libc.so` and `libffi.so` must both
  be in it; haskell.nix symlinks them into one directory ([link][sh-wasm-dyld]).
* Both load the `ghci` package at splice time, so it must be built for the
  host ([Step 2](#step-2-ghc-and-cabal)).

## Step 2: GHC and cabal

This assumes the cabal from the stable-haskell cross-compilation branch
(`stable-haskell/merge`, the cabal side of
[haskell/cabal#12356](https://github.com/haskell/cabal/pull/12356)).

Every unit in its plan belongs to a machine (`"machine"` in `plan.json`):

| Built for | What | Compiled by |
|---|---|---|
| host | everything you asked for, **including all a splice imports** | the cross GHC (`--with-compiler`) |
| build | custom `Setup.hs`, `build-tool-depends` executables (alex, happy, hsc2hs, …) and their libraries | the native GHC (`--with-build-compiler`) |

Splices need **no build-machine copy** of their dependencies: a `lens` used in
a splice is compiled once, for the host, and loaded into the interpreter.

A complete invocation:

```sh
cabal build all \
  --with-compiler=aarch64-unknown-linux-gnu-ghc \
  --with-hc-pkg=aarch64-unknown-linux-gnu-ghc-pkg \
  --with-build-compiler=ghc \
  --with-build-hc-pkg=ghc-pkg \
  --with-build-hsc2hs=hsc2hs
```

with this in `cabal.project`:

```cabal
-- Host units only: `package *` would also reach the build-machine units.
package host:*
  ghc-options: -fexternal-interpreter -pgmi /path/to/iserv-wrapper
```

(haskell.nix wraps `ghc` to add these flags instead; you don't need to.)
`--with-build-PROG` sets any other build-machine program.

Per target:

* **JavaScript and WebAssembly:** add `extra-packages: ghci` and leave out
  the `ghc-options` above.  JavaScript also needs `constraints: ghcjs
  installed` ([test][js-th-test]).
* **WebAssembly:** the runtime linker only loads `.so` files, so host
  libraries must be shared:

  ```cabal
  package host:*
    shared: True
  ```

* **Other hosts:** a statically linked interpreter loads `.a` / GHCi `.o`
  files, so cabal's defaults work.

Keep host-only settings (`executable-static:`, `shared:`, the flags above) in
`package host:*`.

**Build the interpreter without TH-over-iserv**, or it depends on itself: the
iserv-proxy build must not get the `-fexternal-interpreter -pgmi` flags.

## Appendix A: per-target reference

### Wrapper scripts

**Linux (qemu or hl)**, from [linux-cross.nix][linux-cross-wrapper]:

```sh
#!/bin/sh
set -eu
# GHC passes the pipe file descriptors in "$@".
# `tmp` is the interpreter's storage directory (relative to its working
# directory): files the proxy sends over land there.
exec iserv-proxy "$@" \
  --pipe qemu-aarch64 /path/to/iserv-proxy-interpreter tmp --stdio ${ISERV_ARGS:-}
```

Use `hl` instead of `qemu-aarch64` on macOS, and the profiled interpreter in
the `-prof` wrapper.

**Windows (wine)**, from [mingw_w64.nix][mingw-wrapper]:

```sh
#!/bin/sh
set -eu
# wine can fail to start if the environment is very large; trim it if so.

# The interpreter and every DLL a splice might load, in one directory.
REMOTE_ISERV=$(mktemp -d)
ln -s /path/to/interpreter/bin/* "$REMOTE_ISERV"
for p in $DLL_DIRS; do            # the host libraries' install directories
  find "$p" -iname '*.dll'   -exec ln -sf {} "$REMOTE_ISERV" \;
  find "$p" -iname '*.dll.a' -exec ln -sf {} "$REMOTE_ISERV" \;
done
# Some DLLs are named libX.dll but loaded as X.dll.
( cd "$REMOTE_ISERV" && for l in lib*.dll; do ln -s "$l" "${l#lib}"; done )

# --no-load-call: wine sees the same files, so the proxy need not copy DLLs.
WINEDLLOVERRIDES="winemac.drv=d" \
WINEDEBUG=warn-all,fixme-all,-menubuilder,-mscoree,-ole,-secur32,-winediag \
WINEPREFIX=$(mktemp -d) \
  exec iserv-proxy "$@" --pipe wine "$REMOTE_ISERV/iserv-proxy-interpreter.exe" \
    tmp --stdio --no-load-call ${ISERV_ARGS:-}
```

### GHC flags per host

Flags haskell.nix uses for host code, besides `-fexternal-interpreter -pgmi`.
GHC flags reach every build.  The Setup flags are passed only by its older
per-package builder, not by the cabal path in Step 2.

| Host | Flag | Kind | In `package host:*` | Why |
|---|---|---|---|---|
| Linux, Windows | `-L<host gmp>/lib` | GHC | `ghc-options:` | work-around for [GHC #15275](https://gitlab.haskell.org/ghc/ghc/issues/15275) ([Linux][lc-ghcopts], [Windows][mingw-ghcopts]) |
| aarch64 Linux | `-fPIC -optc-fPIC` | GHC | `ghc-options:` | ([link][lc-ghcopts]) |
| aarch64 Linux | `--gcc-option=-fPIC` | Setup build | `gcc-options: -fPIC` | also GHC #15275 ([link][linux-setup-flags]) |
| arm32 Linux | `--gcc-option=-fno-pic --gcc-option=-fno-plt` | Setup build | `gcc-options: -fno-pic -fno-plt` | ([link][linux-setup-flags]) |
| Android | `-optl-ldl` | GHC | `ghc-options:` | the RTS references `dlopen` and friends ([link][lc-ghcopts]) |
| arm32, Android | `--disable-split-sections` | Setup configure | `split-sections: False` | ([link][lc-split]) |
| Windows | `--disable-split-sections` | Setup configure | `split-sections: False` | ([link][mingw-split]) |
| Windows | `-L<pthreads>/lib -L<pthreads>/bin` | GHC | `ghc-options:` | library search path for the pthreads library ([link][mingw-ghcopts]) |

### Building the interpreter

One package, built twice from a checkout of iserv-proxy: for the host (the
interpreter) and for the build machine (the proxy).  cabal reads
`<project file>.local`, so give the host build its own project file:

```sh
# Host interpreter: cross GHC, reads cabal.project.host.local (stanzas below).
cp cabal.project cabal.project.host
cabal build exe:iserv-proxy-interpreter \
  --project-file=cabal.project.host \
  --with-compiler=aarch64-unknown-linux-gnu-ghc \
  --with-hc-pkg=aarch64-unknown-linux-gnu-ghc-pkg \
  --with-build-compiler=ghc --with-build-hc-pkg=ghc-pkg

# Build-machine proxy: native GHC, plain cabal.project, none of the stanzas.
cabal build exe:iserv-proxy --with-compiler=ghc
```

The host stanzas, from [overlays/haskell.nix][iserv-proxy-exes]; use the ones
for your host.  Build the `-prof` interpreter separately (its own project
file, with the last stanza added):

```cabal
-- GHC >= 9.14: let a splice load even when it references a symbol nothing
-- provides, instead of aborting the whole load.
package iserv-proxy
  ghc-options: -rtsopts=all -with-rtsopts=--optimistic-linking

-- aarch64, GHC < 9.8: the threaded RTS breaks TH with C libraries (th-dlls).
package iserv-proxy
  flags: -threaded

-- Windows: avoid "32 bit pseudo relocation ... out of range" under wine.
if os(mingw32)
  package iserv-proxy
    ghc-options: -debug -optl-Wl,--disable-dynamicbase,--disable-high-entropy-va,--image-base=0x400000

-- Android: qemu can't run Android's dynamic loader, so link statically.
-- Add -optl-no-pie on arm32.
package iserv-proxy
  ghc-options: -debug -optl-static -optl-ldl

-- musl, stable-haskell GHC: a fully static interpreter has no dlsym, so
-- no libc symbol resolves ("Failed to lookup symbol: strlen").  On that GHC
-- executable-static means -fully-static and its runtime linker skips libc.a,
-- so link libc dynamically; Haskell libraries stay static.  Leave out the
-- ghc-options line on fully static hosts (no libgcc_s).
package iserv-proxy
  executable-static: False
  ghc-options: -optl-Wl,--no-as-needed -optl-lstdc++ -optl-lgcc_s

-- The -prof interpreter.
package iserv-proxy
  profiling: True
```

**Android and C libraries.**  The static interpreter cannot `dlopen`, and the
runtime linker tries a shared object before an archive.  Ship only static
archives (`.a`) of the C libraries splices use ([link][android-static-libs]).

### Patches

**cabal** — two commits not yet in `stable-haskell/merge`:

| Change | Commit | Needed for | Workaround without it |
|---|---|---|---|
| Build shared libraries when the RTS linker only loads them | [`ed916be3`][c-shared] | wasm | `shared: True` in `package host:*` |
| `executable-static` applies to host units only | [`3b773094`][c-static] | static hosts built on a machine without static system libraries (macOS → musl) | put `executable-static: True` in `package host:*`, not `package *` |

**iserv-proxy:**

| Patch | What it does | Needed for |
|---|---|---|
| [windows-crt-symbols][p-win] | CRT symbol aliases for the interpreter | Windows, GHC 9.6–9.10 |
| [arm32-static-libc][p-arm32-libc], [arm32-bionic-symbols][p-arm32-bionic] | static libc and a Bionic symbol table | Android arm32, *stable-haskell GHC* |
| [i386-musl-dynamic-libc][p-i386] | drops a hidden libc symbol so the interpreter can link libc dynamically | i386 musl, *stable-haskell GHC* |

[c-shared]: https://github.com/stable-haskell/cabal/commit/ed916be32331e541bfff74c1fea2592e49e84b45
[c-static]: https://github.com/stable-haskell/cabal/commit/3b773094325aa515a7a59beddc5d88721d13d945

## Appendix B: how haskell.nix wires this up

For readers who want to dig into the reference implementation.

**Hadrian-built cross GHCs** get no `ghc-iserv` ([link][hadrian-iserv]):
every splice except JavaScript and WebAssembly goes through iserv-proxy and a
runner, as in Step 1.

**The stable-haskell GHC with `-target`** is one native compiler wrapped as a
cross compiler with `-B<libdir> -target=<triple>`; each project builds the
host's boot libraries from GHC's source ([link][sh-target],
[link][sh-boot-pkgs]).  When the build machine can run host code (x86_64 musl
on x86_64 Linux) and the host libraries are static, splices run in-process,
with no interpreter.  A package that asks for `-fexternal-interpreter` gets
GHC's own `ghc-iserv`, built for the host in the same project
([link][project-iserv]).  A glibc GHC can't `dlopen` musl `.so` files, so
with shared musl libraries a splice needs the external interpreter.  This
setup isn't reproducible outside haskell.nix yet.

| What it does | Source |
|---|---|
| Linux wrapper script; adds the flags to every `ghc` call | [overlays/linux-cross.nix][linux-cross-wrapper] |
| Picks qemu or hl per Linux host; extra Setup configure flags | [overlays/armv6l-linux.nix][linux-th] |
| Windows wrapper script and DLL directory | [overlays/mingw_w64.nix][mingw-wrapper] |
| Builds iserv-proxy (build machine) and the interpreter (host, plain and profiled), with TH-over-iserv turned off for that build | [overlays/haskell.nix][iserv-proxy-exes] |
| Picks the interpreter for each component | [builder/comp-v2-builder.nix][slice-ghc] |
| Puts `node` on `PATH`; one library directory for `dyld.mjs` | [build-cabal-slice.nix][node-path], [stable-haskell.nix][sh-wasm-dyld] |
| Uses `--with-build-compiler` for the two-stage plan | [modules/cabal-project.nix][sh-two-stage] |
| End-to-end test: splices calling C libraries | [test/th-dlls][th-dlls] |

[linux-cross-wrapper]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/linux-cross.nix#L24-L42
[linux-cross-wrapGhc]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/linux-cross.nix#L73-L112
[lc-split]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/linux-cross.nix#L43
[lc-ghcopts]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/linux-cross.nix#L44-L52
[linux-th]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/armv6l-linux.nix#L3-L49
[linux-setup-flags]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/armv6l-linux.nix#L59-L62
[mingw-split]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/mingw_w64.nix#L19
[mingw-wrapper]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/mingw_w64.nix#L21-L66
[mingw-ghcopts]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/mingw_w64.nix#L71-L78
[iserv-proxy-exes]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/haskell.nix#L1361-L1611
[slice-ghc]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/builder/comp-v2-builder.nix#L1992-L2033
[project-iserv]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/builder/comp-v2-builder.nix#L2011-L2033
[node-path]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/builder/build-cabal-slice.nix#L657-L708
[sh-wasm-dyld]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/stable-haskell.nix#L2154-L2190
[hadrian-iserv]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/compiler/ghc/default.nix#L1307-L1310
[sh-target]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/stable-haskell.nix#L2003-L2014
[sh-boot-pkgs]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/modules/cabal-project.nix#L501-L547
[sh-two-stage]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/modules/cabal-project.nix#L737-L741
[js-th-test]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/test/js-template-haskell/default.nix#L16-L25
[android-static-libs]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/test/default.nix#L16-L30
[th-dlls]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/test/th-dlls/default.nix
[p-win]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/patches/iserv-proxy-windows-crt-symbols.patch
[p-arm32-libc]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/patches/iserv-proxy-arm32-static-libc.patch
[p-arm32-bionic]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/patches/iserv-proxy-arm32-bionic-symbols.patch
[p-i386]: https://github.com/ican-group/haskell.nix/blob/5ed5b883f37155506c841affd889483db21437f6/overlays/patches/iserv-proxy-i386-musl-dynamic-libc.patch
