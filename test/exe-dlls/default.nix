# Test building TH code that needs DLLs when cross compiling for windows
{ stdenv, lib, util, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  # HsOpenSSL declares its C dependency as `Extra-Libraries: ssl crypto`,
  # so Cabal records `extra-libraries` and leaves `extra-libraries-static`
  # EMPTY.  On musl every executable is linked fully statically --
  # modules/cabal-project.nix turns on `executable-static` for musl so
  # that plan-to-nix and the build agree -- and GHC reads the `*-static`
  # fields for that link.  `-lssl -lcrypto` are therefore never passed
  # and every OpenSSL symbol in libHSHsOpenSSL.a is undefined:
  #
  #   libHSHsOpenSSL-...a(BN.o): undefined reference to `BN_rand_range'
  #
  # libsodium is in the same executable and links fine, which is what
  # pins the cause down: it uses `pkgconfig-depends`, and Cabal resolves
  # that with `pkg-config --static`, filling BOTH fields.  Registrations
  # from one and the same build:
  #
  #   extra-libraries: sodium           extra-libraries: ssl crypto
  #   extra-libraries-static: sodium    <absent>
  #
  # HsOpenSSL's `use-pkg-config` flag swaps the Extra-Libraries line for
  # `pkgconfig-depends: libssl, libcrypto`, so turn it on and it gets the
  # same treatment (pkgconf-nixpkgs-map already maps both to `openssl`).
  # musl only: this moves HsOpenSSL's unit id, and the flag is not
  # portable -- HsOpenSSL documents it as macOS/linux, and it is not
  # guarded by `os()`, so on Windows it would take the pkg-config branch
  # too.  Non-musl targets keep the Extra-Libraries branch and their
  # current ids.
  hsOpenSSLViaPkgConfig = lib.optionalString stdenv.hostPlatform.isMusl ''
    package HsOpenSSL
      flags: +use-pkg-config
  '';

  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "exe-dlls";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal
      + lib.optionalString stdenv.hostPlatform.isAndroid
          (builtins.readFile ../cabal.project.android)
      + hsOpenSSLViaPkgConfig;
    modules = import ../modules.nix;
  };

  # `.profiled` is no longer supplied as an overlay rebuild by the
  # v2 builder; profiling is enabled via cabal.project so plan-nix
  # records the matching configure-args (see
  # `docs/dev/profiling.md`).  The profiled variant is a sibling
  # project with the toggles in `cabalProjectLocal`.
  projectProfiled = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "exe-dlls";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal
      + lib.optionalString stdenv.hostPlatform.isAndroid
          (builtins.readFile ../cabal.project.android)
      + hsOpenSSLViaPkgConfig
      + ''
      package *
        library-profiling: True
      package exe-dlls
        profiling: True
    '';
    modules = import ../modules.nix;
  };

  packages = project.hsPkgs;
  packagesProfiled = projectProfiled.hsPkgs;

in lib.recurseIntoAttrs rec {
  meta.disabled = stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm;

  ifdInputs = {
    inherit (project) plan-nix;
    plan-nix-profiled = projectProfiled.plan-nix;
  };

  build = packages.exe-dlls.components.exes.exe-dlls;
  check = haskellLib.check build;
  build-profiled = packagesProfiled.exe-dlls.components.exes.exe-dlls;
  check-profiled = haskellLib.check build-profiled;
}
