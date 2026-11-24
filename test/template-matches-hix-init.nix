# Guard the getting-started flake template (templates/haskell-nix) against
# drifting from `hix init`.
#
# Both scaffold the same `nix/hix.nix` — the file that pins the template's GHC
# version.  If they diverge (e.g. the supported GHC is bumped in one but not the
# other) users following the getting-started guide can land on an unsupported
# compiler.  That is exactly what happened with the previously-external template
# in issue #2518.
#
# `hix init` also writes a `flake.nix`.  The template's is the same apart from
# its first line (a `description` rather than a comment) and the system in the
# commented-out `evalSystem` line, so those two lines are left out when
# comparing it.
#
# Cheap and platform-independent, so ci.nix runs it once (unstable nixpkgs).
{ pkgs }:

let
  hix = import ../hix/default.nix { inherit pkgs; };
in
pkgs.runCommand "template-matches-hix-init"
{
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnused pkgs.diffutils pkgs.bash ];
  templateHixNix = ../templates/haskell-nix/nix/hix.nix;
  templateFlakeNix = ../templates/haskell-nix/flake.nix;
} ''
  export HOME="$TMPDIR"
  mkdir -p proj && cd proj

  # Run the real `hix init`; it writes ./flake.nix and ./nix/hix.nix.
  # Invoke via bash so we don't depend on /usr/bin/env in the build sandbox.
  bash ${hix}/bin/hix init > hix-init.log 2>&1 \
    || { echo "hix init failed:" >&2; cat hix-init.log >&2; exit 1; }

  if ! diff -u "$templateHixNix" nix/hix.nix; then
    echo >&2
    echo "ERROR: templates/haskell-nix/nix/hix.nix has drifted from 'hix init'." >&2
    echo "These must stay in sync (they pin the template GHC version) — see #2518." >&2
    echo "Update templates/haskell-nix/nix/hix.nix to match hix/init/nix/hix.nix." >&2
    exit 1
  fi

  echo "templates/haskell-nix/nix/hix.nix matches 'hix init' output." >&2

  normalise() { sed -e '2d' -e 's|#evalSystem = ".*";|#evalSystem = "SYSTEM";|' "$1"; }
  if ! diff -u <(normalise "$templateFlakeNix") <(normalise flake.nix); then
    echo >&2
    echo "ERROR: templates/haskell-nix/flake.nix has drifted from 'hix init'." >&2
    echo "Update it to match hix/init/flake.nix." >&2
    exit 1
  fi

  echo "templates/haskell-nix/flake.nix matches 'hix init' output." >&2
  touch "$out"
''
