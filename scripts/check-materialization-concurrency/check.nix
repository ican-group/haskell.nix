{ stdenv, lib, writeScript, gawk }:

with lib;

writeScript "check-materialization-concurrency.sh" ''
  #!${stdenv.shell}

  set -euo pipefail

  # We expect to see both the hello and world derivations to start building
  # before either of them finish. Their start order is up to the scheduler.
  nix-build -j2 scripts/check-materialization-concurrency --arg n "\"$(date)\"" 2>&1 | ${gawk}/bin/awk '
    /^EVENT / {
      if (NF != 3) {
        print "unexpected event: " $0 > "/dev/stderr"
        invalid = 1
        exit 1
      }

      kind = $2
      name = $3

      if (kind == "start" && (name == "hello" || name == "world")) {
        starts[name]++
        if (starts[name] > 1) {
          print "duplicate start event: " name > "/dev/stderr"
          invalid = 1
          exit 1
        }
      } else if (kind == "end" && (name == "hello" || name == "world")) {
        if (starts["hello"] != 1 || starts["world"] != 1) {
          print "both derivations must start before either finishes" > "/dev/stderr"
          invalid = 1
          exit 1
        }
        ends[name]++
        if (ends[name] > 1) {
          print "duplicate end event: " name > "/dev/stderr"
          invalid = 1
          exit 1
        }
      } else {
        print "unexpected event: " $0 > "/dev/stderr"
        invalid = 1
        exit 1
      }
    }

    END {
      if (invalid) exit 1
      if (starts["hello"] != 1 || starts["world"] != 1 ||
          ends["hello"] != 1 || ends["world"] != 1) {
        print "expected one start and end event for each derivation" > "/dev/stderr"
        exit 1
      }
    }
  '
''

