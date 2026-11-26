# Cross compilation

Cross compiling a Haskell project needs a GHC that generates code for the
target platform, and every library dependency built for that platform.
[Haskell.nix][] provides both: it builds the project with the cross
package sets of nixpkgs.

First, understand how to cross-compile a normal package from Nixpkgs.
Matthew Bauer's [Beginners' guide to cross compilation in Nixpkgs][bauer]
is a useful resource.  For example, this builds GNU Hello for a 64-bit ARM
Linux machine:

    nix-build '<nixpkgs>' -A pkgsCross.aarch64-multiplatform.hello

[Haskell.nix][] uses the same principle: replace the package set `pkgs`
with a cross-compiling one such as `pkgs.pkgsCross.aarch64-multiplatform`.

## Building a project for another platform

Every project has a `projectCross` attribute.  `projectCross.<system>` is
the same project, with the same modules and settings, built with
`pkgs.pkgsCross.<system>`, where `<system>` is one of the names in nixpkgs'
`lib.systems.examples`.  With the project from
[Getting started](getting-started.md) (`default.nix`):

```shell
# Native
nix-build -A hsPkgs.hello.components.exes.hello
# 64-bit ARM Linux
nix-build -A projectCross.aarch64-multiplatform.hsPkgs.hello.components.exes.hello
# 64-bit Windows (UCRT)
nix-build -A projectCross.ucrt64.hsPkgs.hello.components.exes.hello
# Static x86_64 Linux executable, linked with musl libc
nix-build -A projectCross.musl64.hsPkgs.hello.components.exes.hello
```

You can also call `haskell-nix.project` from a cross package set
directly.  This is the same as `projectCross.aarch64-multiplatform`
above:

```nix
let
  haskellNix = import (builtins.fetchTarball "https://github.com/ican-group/haskell.nix/archive/master.tar.gz") {};
  pkgs = import haskellNix.sources.nixpkgs-unstable haskellNix.nixpkgsArgs;
in pkgs.pkgsCross.aarch64-multiplatform.haskell-nix.project {
  src = ./.;
  compiler-nix-name = "ghc912";
}
```

The cross GHC and its libraries are built (or substituted) as part of the
first build.  Use a GHC version that haskell.nix CI builds for your target
(see below) and the cache to avoid building GHC yourself.

### With flakes

Set the project's `flake.crossPlatforms` to add the cross compiled
components to the flake outputs.  Starting from the flake in
[Getting started](getting-started.md#scaffolding), add it to the project:

```nix
haskellNix.projects.default = {
  # ...
  flake.crossPlatforms = p: [ p.musl64 p.ucrt64 ];
};
```

(Without flake-parts, pass it to the project's `flake` function instead:
`project.flake { crossPlatforms = p: [ p.musl64 p.ucrt64 ]; }`.)

Each cross compiled component is named after the target platform's
`config` triple:

```shell
nix build .#hello:exe:hello                            # native
nix build .#x86_64-unknown-linux-musl:hello:exe:hello  # static linux
nix build .#x86_64-w64-mingw32:hello:exe:hello         # windows
```

The same naming applies to `checks` and `apps`.

### In a development shell

`shell.crossPlatforms` adds the cross compilers to the project's shell,
next to the native one.  Each comes with a `cabal` wrapper named after
its target, for example:

```nix
shell.crossPlatforms = p: [ p.ucrt64 ];
```

```shell
x86_64-w64-mingw32-cabal build all
```

## Targets

These are the targets that haskell.nix CI builds and tests on
`x86_64-linux`.  The exact set of GHC versions per target is in the
`crossSystems` function of `ci.nix`.

| `projectCross.<system>` | Platform |
| --- | --- |
| `musl64`, `musl32` | x86_64 and i686 Linux, musl libc, statically linked |
| `aarch64-multiplatform` | 64-bit ARM Linux (glibc) |
| `aarch64-multiplatform-musl` | 64-bit ARM Linux, musl libc, statically linked |
| `mingwW64`, `ucrt64` | 64-bit Windows (MSVCRT or UCRT C runtime) |
| `aarch64-android-prebuilt`, `armv7a-android-prebuilt` | Android |
| `ghcjs` | JavaScript, using GHC's JavaScript backend |
| `wasi32` | WebAssembly (WASI), see [WebAssembly](wasm.md) |

`pkgs.pkgsStatic` (static musl executables for the build machine's CPU)
is tested too, with `pkgs.pkgsStatic.haskell-nix.project`, on both
`x86_64-linux` and `aarch64-linux` (where `aarch64-multiplatform-musl`
is also built).  On `aarch64-darwin` CI builds `ghcjs` and
`wasi32`, and for GHC 9.14 also cross compiles to `musl64` and
`aarch64-multiplatform-musl` (running Linux code under `hyper-linux`).
On `x86_64-darwin` it builds `ghcjs`.

The stable-haskell GHC (`ghc914-sh`) uses the same `projectCross`
interface.  It builds the target's boot libraries (`base`,
`template-haskell`, ...) as part of the project, from a package
repository named `ghc-boot-target` that haskell.nix adds to it with
`active-repositories: :rest, ghc-boot-target:override`.  A project that
sets `active-repositories` itself replaces that line, so it has to list
the repository too, with `:override` (it stops cabal picking Hackage's
`base` and friends):

```
active-repositories: hackage.haskell.org, ghc-boot-target:override
```

Without it cabal cannot find the target's boot packages.  As with
`haskell-nix-hsc2hs` (see `usePatchedHsc2hs`), list it only for
`ghc914-sh` cross projects: other projects have no such repository.

## Template Haskell and tests

Cross compiled Template Haskell works without configuration.  The splices
run in an interpreter built for the target, started on the build machine
by `iserv-proxy` under an emulator: `qemu` for Linux and Android (or
`hyper-linux` on macOS), `wine` for Windows, `node` for JavaScript.  See
[Cross-compiling Template Haskell: how it works](cross-template-haskell.md)
for the details.

Test suites run under the same emulators.  See
[Cross-compiled tests](testing.md#cross-compiled-tests).

## Static executables with musl libc

With the default builder, executables built for a musl target
(`projectCross.musl64`, `projectCross.musl32`) are statically linked:
haskell.nix passes `-optl=-static` (and `-optl=-pthread`) to GHC when
linking them, and its musl overlay enables the static libraries of common
C dependencies such as `gmp`, `zlib`, `ncurses`, `bzip2` and `xz`.
`pkgs.pkgsStatic` links everything statically with either builder.

If a package links another C library, the static version of that library
may need adding to the link:

```nix
modules = [({ pkgs, lib, ... }: lib.mkIf pkgs.stdenv.hostPlatform.isMusl {
  packages.my-package.components.exes.my-exe.configureFlags = [
    "--ghc-option=-optl=-L${pkgs.libsodium}/lib"
  ];
})];
```

> **Note:** Licensing
>
> By default GHC implements `Integer` with GMP, which is LGPL licensed,
> and a statically linked executable includes it.  GHC's native bignum
> backend avoids GMP; haskell.nix's GHC derivations build with it when
> overridden with `enableNativeBignum = true` (the default for JavaScript
> and WebAssembly).  haskell.nix does not cache GHCs built that way.

## Fixing build problems

Some packages need extra configuration to cross compile: patches, flags,
or C libraries for the target.  Add these as
[module options](../reference/modules.md) in the project's `modules`, and
make them conditional on the target platform so the native build is not
affected:

```nix
modules = [({ pkgs, lib, ... }: lib.mkIf pkgs.stdenv.hostPlatform.isWindows {
  packages.my-package.flags.use-pkg-config = false;
  packages.my-package.configureFlags = [ "--ghc-option=-DWINDOWS_BUILD" ];
})];
```

The project's `modules` apply to every `projectCross` project, and the
`pkgs` module argument is the package set of the platform being built
for.  `haskellLib.isCrossHost` (also a module argument) is true when the
code is built for another platform, except musl on the build machine's
own Linux CPU (for example `musl64` on `x86_64-linux`), which runs
without an emulator.

## Troubleshooting

### Diagnosing Template Haskell failures on Rosetta builders

The Linux cross-compilation chain is GHC → `iserv-wrapper` → `iserv-proxy`
→ QEMU → the target interpreter. A target signal followed by a Nix timeout
can have separate causes. Preserve the process tree and wait channels
before terminating a stalled build. Use a wall-clock bound for reproductions.
QEMU's “core dumped” message alone does not prove that it wrote a core file.

Investigation of [build 2014157](https://ci.zw3rk.com/build/2014157) on
2026-10-02 isolated this failure to x86_64 QEMU running under Rosetta in
nix-linux-builder's ARM64 Linux VM. The failing job was
`x86_64-linux.unstable.ghc9141.aarch64-android-prebuilt.tests.th-dlls.build-profiled`.
Reproductions reused the cached compiler, proxy, target interpreters, and
package inputs:

| Execution environment | Normal pass | Profiled pass |
| --- | --- | --- |
| Native x86_64 Linux, original QEMU 11.0.1 | Completed | Completed |
| ARM64 VM, x86_64 QEMU 11.0.1 under Rosetta | Completed | Target SIGSEGV; QEMU remained alive |
| Same VM, patched x86_64 QEMU 11.0.1 under Rosetta | Completed | Completed |
| Same VM, native ARM64 QEMU 11.0.1 | Completed | Completed |
| Same VM, static ARM64 interpreter executed directly | Completed | Completed |

The patched reproduction completed compilation, installation, and fixup
with exit code 0 within a 240-second bound. It retained the original proxy
and shell-wrapper behavior; only QEMU changed. The native x86_64 run also
completed installation, then failed Nix's comparison of output contents.
That separate reproducibility failure does not indicate a TH crash.

Two host signal defects explain the crash and hang:

1. Rosetta reports `SEGV_MAPERR` for writes to existing anonymous pages
   protected with `mprotect`. Native ARM64 reports `SEGV_ACCERR` for the
   same tests in the same VM. This affects resident and nonresident pages
   with read-only, read/execute, and inaccessible protections. The x86
   fault context correctly identifies a write (`REG_ERR=6`). QEMU's
   [signal handler](https://github.com/qemu/qemu/blob/v11.0.1/linux-user/signal.c)
   requires `SEGV_ACCERR` to recognize writes to translated code pages.
   The profiled interpreter's core stops at the first `memcpy` store in
   `ocGetNames_ELF`, loading `HSbase-4.22.0.0-inplace.p_o`, with a
   destination that QEMU's guest memory map lists as writable.
2. Rosetta loses a self-sent `SIGSEGV` when that signal is blocked. QEMU
   sends the fatal signal while blocked, then calls `sigsuspend`. In the
   reproduction QEMU remained in `sigsuspend`, the proxy waited for a
   reply, and GHC waited for the proxy. Unblocking the signal before
   sending it makes the host probe terminate with status 139. Unblocking
   it after sending it does not recover the lost signal. Native ARM64
   correctly preserves and delivers it.

The workaround applies two changes to cross-TH QEMU on x86_64 Linux:

- Accept a write reported as `SEGV_MAPERR` only when QEMU's page metadata
  permits the guest write and `mincore` confirms that the host page exists.
  Then use QEMU's existing code-page unprotect path. Check metadata under
  the mmap lock and allow another writer to have already unprotected the
  page. Keep these guards: real read-only pages and missing host mappings
  must remain faults.
- Unblock the fatal signal before sending it to QEMU itself.

The overlay selects a user-only emulator for the required guest target.
The patch applies to pinned QEMU 9.1.3, 9.2.4, 10.1.5, 10.2.4, and 11.0.1;
only 11.0.1 received runtime validation. Native ARM64, Darwin hosts, and
versions outside 9.1–11 retain their original QEMU selection. Review the
boundary when changing pins.

The guest regressions cover code changes, four concurrent writers over
256 rounds, and real read-only and unmapped writes. Original x86_64 QEMU
under Rosetta failed all four; patched QEMU and native ARM64 QEMU passed.
The acceptance binary was cross-compiled on ARM64 and used a temporary
wrapper for the cross compiler's runtime library. The default patched
nixpkgs QEMU package build remains an integration check.

The stack-size warning is separate: Nix continues after the failed
`setrlimit(RLIMIT_STACK)`. Matched successful nonprofiled jobs contain the
same warning, and earlier QEMU 10.2.2 failures do not. Both architectures
in the VM report 4096-byte pages. Android, LLVM, and QEMU 11 are not
required for this recurring CI signature.

See [the regression instructions](../../test/README.md) for bounded guest
and host-signal checks. A successful diagnostic probe means evidence was
saved; inspect its results. Cached Hydra outputs do not prove execution
on the affected physical builder. Native ARM64 QEMU is a verified way to
avoid the Rosetta execution path while investigating or backporting.

For rollout, update the CI source pin and evaluate new derivations before
rerunning the profiled job. Retrying build 2014157's immutable derivation
retains the old emulator. Confirm the new emulator path in the log and
execute the guest regressions and full profiled build on the affected
physical builders. Increasing `max-silent-time` does not repair these faults.

### Android ARM32 startup on ARM64 Linux builders

Bionic requests `personality(PER_LINUX32)` before entering `main`. An ARM64
kernel without AArch32 EL0 support rejects that execution domain with `EINVAL`,
even when QEMU can emulate the ARM32 instructions. This produces:

```text
libc: error setting PER_LINUX32 personality: Invalid argument
qemu: uncaught target signal 6 (Aborted) - core dumped
```

Running native ARM64 QEMU avoids nested emulation but does not by itself fix
the rejected host personality call. The Android ARM32 QEMU selection therefore
includes a personality fallback on Linux build hosts with QEMU 9.1–11. Only
after the host rejects `PER_LINUX32` with `EINVAL`, it retries with `PER_LINUX`
and the same upper flags. QEMU retains the full guest value per task, including
query and previous-value results, thread inheritance, and fork isolation.
Other host errors remain errors. Upper flags such as `UNAME26` remain backed by
the host kernel.

The personality patch is separate from the Rosetta signal patch. Native ARM64
QEMU receives only the personality patch; x86_64 QEMU receives both. The
personality selection is limited to Android ARM32 guests: Bionic initializes
the virtual domain again on exec, so this does not promise general Linux
personality persistence across exec.

The `ghc914-sh` ARM32 interpreter also patches its symbol table before Cabal
planning. Its missing-function stubs included 21 routines supplied by the NDK's
static `libc.a`, including the private `__libc_shared_globals` startup function.
With duplicate definitions allowed by the toolchain, the stub could win and call
`printf` before Bionic had initialized TLS, producing a target `SIGSEGV` even on
native ARM64 QEMU. The patch removes those false stubs and keeps their symbol
references, so the interpreter and GHCi use the real libc implementations. The
API-specific shared-library export list does not describe all static definitions.
The table also registers Bionic's iconv routines from API28 and `nl_langinfo`
from API26. Static Bionic's `dlsym` cannot supply those addresses when TH loads
the core library objects. Projects using GNU iconv instead need registrations
for that provider's names as well.

The generic `haskell-nix.emulatorSystemFeatures` default still requires the
native-builder marker. Its package deny-list also covers cross-compiler stalls
without QEMU, which this patch does not fix. A project verified with the patched
emulator can set `haskell-nix.emulatorSystemFeatures = []` in its Android ARM32
target package set. Keep that opt-out scoped to the compiler and QEMU versions
tested by the project. The `ghc914-sh` annotation regressions use such a scoped
package set without changing the policy for other projects or compilers.

Run `make test-qemu-arm32-personality SYSTEM=aarch64-linux TIMEOUT=1800` on
the affected ARM64 builder, and repeat with `SYSTEM=x86_64-linux` for Rosetta.
The test compiles with the pinned Android API 26 NDK. It checks Bionic startup
and the personality semantics above; it does not substitute for a real
cross-Template-Haskell build. See [the regression instructions](../../test/README.md)
for emulator overrides and instructions for rerunning an existing test output.

[bauer]: https://matthewbauer.us/blog/beginners-guide-to-cross.html
[haskell.nix]: https://github.com/ican-group/haskell.nix
