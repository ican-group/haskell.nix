# Project investigation notes

- Use `make help` for verification and emulator diagnostics. Keep heavyweight
  builds under a wall-clock timeout.
- Read [the cross-TH investigation](docs/tutorials/cross-compilation.md#diagnosing-template-haskell-failures-on-rosetta-builders)
  before diagnosing a Rosetta target SIGSEGV followed by a Nix timeout.
- Rosetta can report mapped-page write faults as `SEGV_MAPERR` and lose a
  blocked self-sent `SIGSEGV`. The QEMU workaround covers x86_64 Linux hosts
  with versions 9.1–11; review that boundary when changing pins.
- A host-signal probe succeeding means evidence was saved. A cached Hydra
  success does not prove that the physical Darwin builder executed the job.
- Reevaluate derivations after changing QEMU. Retrying an
  immutable old derivation retains its old dependencies.
