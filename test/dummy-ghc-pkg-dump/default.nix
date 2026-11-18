# Diff the dependency graph in `dummy-ghc-pkg dump --global` (the eval-time
# stand-in cabal-install reads the compiler's pre-existing packages from
# during plan-to-nix) against the real compiler's `ghc-pkg dump --global`.
#
# The dummy dump is synthesised in `lib/dummy-ghc.nix` by reading each boot
# package's `.cabal` file with `cabal2json` + `jq`.  Conditional
# `build-depends` are only partly interpreted there, so the synthesised
# `depends:` can silently drift from what the real compiler registered.
# When it does, cabal plans against a package graph that is not the one
# the real build sees (e.g. an edge the real db has is missing, so the
# solver never marks its target pre-existing).
#
# Compared, for every unit: its `id`, and the set of `depends:` ids.
# Everything else (paths, exposed-modules, abi, …) is ignored here;
# `--info` is covered by `test/dummy-ghc-info`.
{ stdenv, lib, pkgs, compiler-nix-name, buildPackages
, testSrc ? null  # `callTest` passes this; we don't need a source dir.
, ...
}:

let
  # The real cross / native GHC the project would actually build with.
  realGhc = buildPackages.haskell-nix.compiler.${compiler-nix-name};

  # Built as `lib/call-cabal-project-to-nix.nix` builds it, but with the
  # test's own build packages rather than `evalPackages` so the script is
  # runnable here (see the note in `test/dummy-ghc-info`).
  dummyGhcPkg = (import ../../lib/dummy-ghc.nix {
    inherit pkgs;
    evalPackages = buildPackages;
    ghc = realGhc;
  }).dummy-ghc-pkg;

  ghcPkgCmd = "${realGhc.targetPrefix}ghc-pkg";

  # One line per unit (`unit <id>`) and per dependency edge
  # (`dep <id> <dep-id>`), sorted, so the diff ignores field and unit order.
  normalise = pkgs.buildPackages.writeText "normalise-ghc-pkg-dump.awk" ''
    function flush() {
      if (id != "") {
        print "unit " id
        n = split(deps, d, " ")
        for (i = 1; i <= n; i++) if (d[i] != "") print "dep " id " " d[i]
      }
      id = ""; deps = ""; field = ""
    }
    /^---/ { flush(); next }
    /^[^ \t]/ {
      field = $1
      sub(/^[^:]*:[ \t]*/, "")
      if (field == "id:") id = $1
      else if (field == "depends:") deps = deps " " $0
      next
    }
    /^[ \t]/ { if (field == "depends:") deps = deps " " $0 }
    END { flush() }
  '';
in stdenv.mkDerivation {
  name = "dummy-ghc-pkg-dump-test-${realGhc.name}";

  meta.platforms = lib.platforms.all;

  buildCommand = ''
    set -euo pipefail
    echo "real ghc-pkg:  ${realGhc}/bin/${ghcPkgCmd}" >&2
    echo "dummy ghc-pkg: ${dummyGhcPkg}/bin/${ghcPkgCmd}" >&2

    ${realGhc}/bin/${ghcPkgCmd} dump --global -v0 > real.dump \
      || { echo "real ghc-pkg dump failed" >&2; exit 1; }
    ${dummyGhcPkg}/bin/${ghcPkgCmd} dump --global -v0 > dummy.dump \
      || { echo "dummy ghc-pkg dump failed" >&2; exit 1; }

    awk -f ${normalise} real.dump  | sort -u > real.norm
    awk -f ${normalise} dummy.dump | sort -u > dummy.norm

    if ! diff -u dummy.norm real.norm > diff.out; then
      echo "" >&2
      echo "===== dummy ghc-pkg dump diverges from the real compiler's =====" >&2
      echo "(- only in dummy, + only in real)" >&2
      cat diff.out >&2
      echo "" >&2
      echo "Fix the dump synthesis in \`lib/dummy-ghc.nix\` (or the" >&2
      echo "\`ghc-pre-existing\` list in overlays/haskell.nix) until the diff is empty." >&2
      exit 1
    fi

    cp dummy.norm $out
  '';

  passthru = { inherit dummyGhcPkg realGhc; };
}
