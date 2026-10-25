# Rosetta poll/fork reproducer

This ordinary Linux C program reproduced the captured suspension stall without
GHC. It uses one coordinator, one poller and two heap-allocated `POLLIN` entries:
a nonblocking pipe and an eventfd. The coordinator wakes both, waits until the
poller drains them, forks a child that only calls `_exit(0)`, and reaps it.
It supplies the next wake only after that fork completes. There is no periodic
rescue wake, injected signal, ptrace, interpreter modification or kernel delay.

Build inside native Linux or the Linux guest with an existing C11 compiler:

```sh
make build
python3 run-bounded.py original 120 ./poll_fork --api poll --iterations 10000 --timing
python3 run-bounded.py finite 120 ./poll_fork --api poll --iterations 10000 --timeout-ms 1000 --timing
```

The outer driver retains streamed `.log` files and command/exit/timeout `.json`
records. It stops only its own process group. Use a fresh result name. The
program has no internal overall deadline; retain the external bound.

Use explicit `--api poll` for this reproduction. The program's default `ppoll`
API takes a different Rosetta route in the measured runtime. Indefinite `poll`
passes `-1`; `--timeout-ms 1000` passes a one-second finite timeout. The frozen
C file is byte-identical to the failing capture's source, SHA256
`cd0bb843af279994660ca0ac7e961f4f188666c4c70e92c21ff7969165a48e73`.
The binary is not checked in. The measured build used GCC15.2/glibc2.42;
12 native Linux controls passed 1,000 forks each before Rosetta testing.

The private Mac6 capture completed at least 3,400 forks before stopping. Its
complete, uncapped 6,735-record trace captures a private suspension signal
returning to Rosetta's poll-adapter entry, followed by an infinite native
`ppoll`. A passive snapshot finds the coordinator waiting for ACK1 in
`clone_process` and the poller blocked in that same poll. The owned deadline
ends the run after about 120 seconds. This is a rare race, not a deterministic
failure on every invocation. A successful run does not disprove it.

Earlier finite controls passed without observing the critical pre-call window;
their completion alone did not prove the mitigation. A later optional phase
sweep captured the pending suspension cycle with a one-second poll, an actual
timeout return0, normal Rosetta ACK2 publication/wake attempt, and subsequent
coordinator progress. The trace does not log the wake syscall result or native
clone completion. Historical Hydra attribution remains conditional because its
original guest has no matching signal trace. See the [experimental wait-cap RCA](../../docs/tutorials/cross-compilation.md#rosetta-host-compiler-wait-cap-experimental).

`post-ack-work.patch` preserves that later source without changing the original
failing C file. It adds optional deterministic arithmetic after publishing the
C readiness ACK and before re-entering poll. This is a scheduling intervention,
not a production repair or a neutral performance comparison. It adds no timer,
sleep, signal, extra FD wake or interpreter/kernel delay. Reconstruct it with
`make handoff-source`; the generated source SHA256 must be
`6514a8ab66ed3dfeff255300cbd7e49cbbe296f408adaa6073dd5af0fc4ba2e6`.

```sh
make build-handoff
python3 run-bounded.py handoff-original 120 ./poll_fork_handoff --api poll --iterations 10000 --post-ack-work-max 10000 --timing
python3 run-bounded.py handoff-finite 120 ./poll_fork_handoff --api poll --iterations 10000 --post-ack-work-max 10000 --timeout-ms 1000 --timing
```

The maximum is per readiness ACK, not an elapsed-time bound; retain the external
watchdog. The captured pair used the same PIE ELF, built privately with the
pinned GCC15.2/glibc2.42 and warning flags. A new build need not match its bytes
or exposure timing. The revised ELF's separate native Linux execution remains
pending after SSH signing failed before any cases ran. The original harness's
native matrix above remains a separate result. Rosetta ACK1/ACK2 and the C
readiness ACK are different protocols.

Other arguments are documented by invoking the program with `--help` (which
prints usage and exits unsuccessfully). `--progress-every N` controls the
before-ACK/before-fork/after-wait markers. `--timing` reports monotonic elapsed
time. Poller errors propagate to the coordinator; shutdown sets the stop flag
before the final wake and join. No device or production CI action is required
to run this standalone diagnostic.
