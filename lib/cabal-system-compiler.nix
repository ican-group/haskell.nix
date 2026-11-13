# The `system` and `compiler` arguments the Cabal2Nix files are evaluated
# with: cabal's `os(..)`, `arch(..)` and `impl(..)` conditions resolved for
# the platform `stdenv` builds for.  Used for the package set's own platform
# (modules/cabal.nix) and for the build machine's units of a two-stage plan
# (lib/load-cabal-plan.nix), which must not see the target's answers.
{ lib }:
{ stdenv, compilerVersion }:
let
  hostMap = import ./host-map.nix stdenv;
  cabal = import ./cabal-os-arch-comp.nix;
in {
  compiler = cabal.compiler // {
    isGhc = true;
    # this is partially a hack to support `impl(ghcjs)`.
    # We set GHC == true _and_ GHCJS == true.
    isGhcjs = hostMap.os == "Ghcjs" && (builtins.compareVersions compilerVersion "9" < 0);
    # maybe we need something for asterius here
    # as well.
    version = lib.mapAttrs (_: f: v: f (builtins.compareVersions compilerVersion v)) {
      eq = c: c == 0;
      gt = c: c > 0;
      ge = c: c >= 0;
      lt = c: c < 0;
      le = c: c <= 0;
    };
  };
  system = cabal.os   // { "is${hostMap.os}"   = true; }
        // cabal.arch // { "is${hostMap.arch}" = true; };
}
