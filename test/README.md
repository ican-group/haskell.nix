### Haskell infrastructure test cases

To build the test cases, run from the `test` directory:

```shell
nix-build --no-out-link default.nix
```

To run all tests (includes impure tests), use the script:

```shell
./tests.sh
```

#### Generated code

If you change the test Cabal files or need to regenerate the code with
nix-tools, then see `regen.nix`. Run it like this:

```shell
$(nix-build --no-out-link regen.nix)
```

#### Cross-Template-Haskell regression checks

From the repository root:

```shell
make check test-linux-cross-wrapper
make test-qemu-linux-user SYSTEM=x86_64-linux
```

The wrapper checks use a recording proxy and require Nix and Python.
`make verify` runs the syntax, dependency, emulator-selection, and wrapper
checks without building QEMU.

The QEMU checks compile a static AArch64 guest with a cross C compiler.
They check code-page updates, four concurrent writers over 256 rounds,
and require real read-only and unmapped writes
to terminate with signal status 139 within a deadline. `QEMU=/nix/store/…`
selects an already-built emulator and records it as a Nix dependency.
The default uses the same QEMU selection as the Linux cross-TH overlay:
patched on x86_64 Linux with QEMU 9.1–11, unchanged on native ARM64.
The test driver exposes `qemu-linux-user.run` on supported x86_64 Linux
build hosts, so the checks enter the existing CI test matrix. The guest
compile uses `buildPackages.coreutils` for build-host `timeout`.

For host signal diagnostics in an ARM64 nix-linux-builder VM:

```shell
make probe-rosetta-signals SYSTEM=x86_64-linux
make test-rosetta-signals SYSTEM=aarch64-linux
```

The first command records Rosetta behavior in `results.tsv` and per-case
logs even when the host is nonconforming. A successful **probe** build only
means the evidence was saved. `make test-rosetta-signals` enforces correct
signal behavior and currently fails under the affected Rosetta runtime.
The native ARM64 control should pass in the same VM. `preferLocalBuild`
requests a local build and `allowSubstitutes = false` disables substitution;
neither forces an output already present in the store to run again.
To rerun an existing output, use `nix-build --check` or `nix build --rebuild`.
Retain the logs and verify which physical builder executed the tests.
A cached Hydra result also does not prove execution on the affected builder.

Android ARM32 has a separate startup regression:

```shell
make test-qemu-arm32-personality SYSTEM=x86_64-linux TIMEOUT=1800
make test-qemu-arm32-personality SYSTEM=aarch64-linux TIMEOUT=1800
```

The test compiles a static Bionic payload with the pinned API 26 NDK on an
x86_64 Linux builder, then runs QEMU on `SYSTEM`. It checks startup,
personality queries and setter return values, host-backed `UNAME26`, and
thread/fork inheritance and isolation. A small retained TLS alignment input
accommodates API 26's older CRT without raising the minimum Android API.
The Linux cross-TH overlay selects this personality patch only for Android
ARM32, with QEMU 9.1–11. Bionic initializes the virtual execution domain again
after an exec; this test does not establish general Linux exec persistence.
Native ARM64 hosts receive the personality patch without the Rosetta signal
patch. `QEMU=/nix/store/…` overrides the emulator for a control run.

The fixed Android ARM32 route enables `annotations.build` and
`annotations.build-profiled` for `ghc914-sh` in the existing compiler test
matrix. Both compile a module annotation through the target interpreter. These
test projects opt out of the native-builder marker in their own package set;
the generic policy stays conservative because it also covers unrelated older
cross-compiler stalls. Other routes retain their existing exclusions.
Run both through the public CI attributes (choose an available evaluation system):

```sh
timeout -k 5 7200 nix-build ci.nix --arg ifdLevel 3 \
  --argstr system x86_64-linux --argstr evalSystem x86_64-linux \
  --no-out-link --max-jobs 1 --cores 1 \
  -A unstable.ghc914-sh.armv7a-android-prebuilt.tests.annotations.build \
  -A unstable.ghc914-sh.armv7a-android-prebuilt.tests.annotations.build-profiled
```

For the verified crash and hang mechanism, see
[the cross-compilation investigation](../docs/tutorials/cross-compilation.md#diagnosing-template-haskell-failures-on-rosetta-builders).

#### ELF COMDAT function regression

On native x86_64 Linux:

```shell
make test-elf-comdat-functions TIMEOUT=600
```

The test driver exposes `elf-comdat-functions.run` for `ghc914-sh` on this
platform. It uses the selected compiler's configured RTS source and headers
to compile only `Elf.c` and `Linker.c`, then links a small loader probe with
these replacement objects. A linker-map check ensures the original archive
members were not selected. It does not rebuild GHC or the other RTS objects;
the compiler and its normal inputs must already be built or substituted.

Both object orders must resolve one full-section COMDAT function, including
GCC's zero-size PIC-thunk form. Baseline duplicate failures and negative cases
retain strong duplicate rejection: ordinary groups, partial functions,
additional definitions, differing signatures, and archive-owner changes.
Every probe has a 15-second runtime bound. `make check` also exercises the
actual project module's fixed point and its platform, compiler, builder,
profiling, and patch-order conditions without building a compiler.

The production patch applies only to the `ghc914-sh` v2 source-built RTS for
i386 musl targets built on Linux, including auxiliary interpreters and all
RTS ways. The native loader test checks symbol-selection behavior; it does
not by itself qualify a profiled target interpreter or a final static CLI.

#### MinGW wide formatting

`mingw-stdio.run` in the Windows x86_64 test matrix compiles a static C probe
with the selected cross compiler and runs it under the existing Linux x86_64
Wine provider. It checks ISO `swprintf` at exact, spare, and insufficient
capacity, including bounds and successful termination. The output includes
the linker map and runtime results. It does not test GHC or Template Haskell.

Run the UCRT regression against the unstable Nixpkgs pin with
`make test-mingw-stdio SYSTEM=x86_64-linux TIMEOUT=10800`. The first build can
rebuild the patched CRT and cross compiler; later runs reuse those outputs.

`make check` also checks backport selection and excluded-platform laziness
without building a compiler, CRT, or Wine. The MinGW 13/14 backport can be
removed when all supported Nixpkgs pins contain upstream fix
[`e7e21db`](https://github.com/mingw-w64/mingw-w64/commit/e7e21db45eaae989b04f3c24964dead5b53310de).
