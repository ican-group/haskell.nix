# Cross compilation

Cross compilation of Haskell projects involves building a version of
GHC that outputs code for the target platform, and providing builds of
all library dependencies for that platform.

First, understand how to cross-compile a normal package from
Nixpkgs. Matthew Bauer's [Beginners' guide to cross compilation in
Nixpkgs][bauer] is a useful resource.

[bauer]: https://matthewbauer.us/blog/beginners-guide-to-cross.html


Using an example from the guide, this builds GNU Hello for a Raspberry
Pi:

    nix build -f '<nixpkgs>' pkgsCross.raspberryPi.hello

We will use the same principle in [Haskell.nix][] — replacing the normal
package set `pkgs` with a cross-compiling package set
`pkgsCross.raspberryPi`.

### Raspberry Pi example

This is an example of using [Haskell.nix][] to build the [Bench][]
command-line utility, which is a Haskell program.

```nix
{ pkgs ? import <nixpkgs> {} }:
let
  haskellNix = import (builtins.fetchTarball https://github.com/ican-group/haskell.nix/archive/master.tar.gz);
  native = haskellNix { inherit pkgs; };
in
  native.haskellPackages.bench.components.exes.bench
```

Now switch the package set as in the previous example:

```nix
{ pkgs ? import <nixpkgs> {} }:
let
  haskellNix = import (builtins.fetchTarball https://github.com/ican-group/haskell.nix/archive/master.tar.gz);
  raspberryPi = haskellNix { pkgs = pkgs.pkgsCross.raspberryPi; };
in
  raspberryPi.haskellPackages.bench.components.exes.bench
```

You should be prepared for a long wait because it first needs to build
GHC, before building all the Haskell dependencies of [Bench][]. If all
of these dependencies compiled successfully, I would be very surprised!

> **Hint:**
>
> The above example won't build, but you can try and see, if you like.
> It will fail on [clock-0.7.2](http://hackage.haskell.org/package/clock-0.7.2),
> which needs a patch to build.

To fix the build problems, you must add extra configuration to the
package set. Your project will have a [`mkStackPkgSet`](../reference/library.md#mkstackpkgset) or
[`mkCabalProjectPkgSet`](../reference/library.md#mkcabalprojectpkgset). It is there where you must add
[module options](../reference/modules.md) for setting compiler flags, adding patches, and so on.

> **Note:**
>
> Note that `haskell.nix` will automatically use `qemu` to emulate the target
> when necessary to run Template Haskell splices.

### Static executables with Musl libc

Another application of cross-compiling is to produce fully static
binaries for Linux. For information about how to do that with the
[Nixpkgs Haskell infrastructure][nixpkgs] (not [Haskell.nix][]), see
[nh2/static‑haskell‑nix][nh2]. Vaibhav Sagar's linked
[blog post][vaibhav] is also very informative.


```nix
{ pkgs ? import <nixpkgs> {} }:
let
  haskellNix = import (builtins.fetchTarball https://github.com/ican-group/haskell.nix/archive/master.tar.gz);
  musl64 = haskellNix { pkgs = pkgs.pkgsCross.musl64; };
in
  musl64.haskellPackages.bench.components.exes.bench
```

This example will build [Bench][] linked against Musl libc. However
the executable will still be dynamically linked. To get fully static
executables you must add package overrides to:

1. Disable dynamic linking
2. Provide static versions of system libraries. (For more details, see
   [Vaibhav's article][vaibhav]).

```nix
{
  packages.bench.components.exes.bench.configureFlags =
    lib.optionals stdenv.hostPlatform.isMusl [
      "--disable-executable-dynamic"
      "--disable-shared"
      "--ghc-option=-optl=-pthread"
      "--ghc-option=-optl=-static"
      "--ghc-option=-optl=-L${gmp6.override { withStatic = true; }}/lib"
      "--ghc-option=-optl=-L${zlib.static}/lib"
    ];
}
```

> **Note:** Licensing
>
> Note that if copyleft licensing your program is a problem for you,
> then you need to statically link with `integer-simple` rather than
> `integer-gmp`. However, at present, [Haskell.nix][] does not provide
> an option for this.


### How to cross-compile your project

Set up your project Haskell package set.

```nix
{{#include cross-compilation/default.nix}}
```

Apply that package set to the Nixpkgs cross package sets that you are
interested in.

We are going to expand the `pkgs.pkgsCross` shortcut to be more
explicit.

```nix
let
  pkgs = import <nixpkgs> {}
in {
  shortcut = pkgs.pkgsCross.SYSTEM;
  actual = import <nixpkgs> { crossSystem = pkgs.lib.systems.examples.SYSTEM; };
}
```

In the above example, for any `SYSTEM`, `shortcut` and `actual` are
the same package set.

```nix
{{#include cross-compilation/release.nix}}
```

Try to build it, and apply fixes to the `modules` list, until there
are no errors left.


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


[nh2]: https://github.com/nh2/static-haskell-nix
[vaibhav]: https://vaibhavsagar.com/blog/2018/01/03/static-haskell-nix/
[haskell.nix]: https://github.com/ican-group/haskell.nix
[bench]: https://hackage.haskell.org/package/bench
[nixpkgs]: https://nixos.org/nixpkgs/manual/#users-guide-to-the-haskell-infrastructure
