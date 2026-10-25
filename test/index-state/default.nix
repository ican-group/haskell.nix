# Test a package set
{ stdenv, lib, testSrc, tool, compiler-nix-name, evalPackages, evalSystem, haskell-nix }:

with lib;

let
  # The hackage-security 0.6.0.1 was uploaded at 2020-04-06T20:54:35Z
  # See https://hackage.haskell.org/package/hackage-security-0.6.0.1
  version-used-at = index-state: ((tool compiler-nix-name "cabal" {
      version = "3.2.0.0";
      inherit index-state evalSystem;
      cabalProject = ''
        packages: .
        allow-newer: cabal-install:base, hackage-security:*
        package cabal-install
          flags: -native-dns
      '';
    }).project.getPackage "hackage-security").components.library.version;
  version-before = version-used-at "2020-04-06T20:54:34Z";
  version-after = version-used-at "2020-04-06T20:54:35Z";

in
  stdenv.mkDerivation {
    name = "index-state-test";

    buildCommand = ''
      if [[ "${version-before}" != "0.6.0.0" ]]; then
        echo 'Unexpected version ${version-before} (expected "0.6.0.0")'
        exit 1
      fi
      if [[ "${version-after}" != "0.6.0.1" ]]; then
        echo 'Unexpected version ${version-after} (expected "0.6.0.1")'
        exit 1
      fi

      touch $out
    '';

    meta.platforms = platforms.all;
    # This test will need to be updated to use newer hackage index-state for it
    # to work with GHC 9 and above.
    # Does not work for GHCJS
    # We can probably enable ghc961 again once Cabal 3.10 is in hackage
    meta.disabled = stdenv.hostPlatform.isGhcjs
      || __compareVersions haskell-nix.compiler.${compiler-nix-name}.version "9.0" >= 0;

    passthru = {
      # Used for debugging with nix repl
      inherit project packages;
    };
  }
