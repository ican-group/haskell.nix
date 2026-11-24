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
    internal = true;
    description = ''
      The compiler, as the generated package expressions test it in `.cabal`
      conditionals (`compiler.isGhc`, `compiler.version`, ...).
    '';
    type = lib.types.unspecified;
  };
  options.cabal.system = lib.mkOption {
    internal = true;
    description = ''
      The host platform, as the generated package expressions test it in
      `.cabal` conditionals (`system.isLinux`, ...).
    '';
    type = lib.types.unspecified;
  };
  config.cabal = { inherit compiler system; };
}
