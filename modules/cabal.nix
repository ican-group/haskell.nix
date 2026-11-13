{ lib, config, pkgs, ... }:

let
  # it also crucially depends on system, and compiler, both of which need to be resolved to the
  # current system being targeted.
  inherit (import ../lib/cabal-system-compiler.nix { inherit lib; } {
    inherit (pkgs) stdenv;
    compilerVersion = config.compiler.version;
  }) compiler system;

in {
  options.cabal.compiler = lib.mkOption {
    type = lib.types.unspecified;
  };
  options.cabal.system = lib.mkOption {
    type = lib.types.unspecified;
  };
  config.cabal = { inherit compiler system; };
}
