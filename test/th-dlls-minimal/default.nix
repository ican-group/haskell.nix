# Test building TH code that needs DLLs when cross compiling for windows
{ stdenv, lib, util, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  # See `docs/dev/profiling.md` — v2 expects profiling toggles in
  # cabal.project so plan-nix records `--enable-library-profiling`.
  test-clib = stdenv.mkDerivation {
    name = "test-clib";
    version = "1.0";
    src = testSrc "th-dlls-minimal/test-clib";
  };
  project = { externalInterpreter, profiled ? false }: project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "th-dlls-minimal";
    # Spell test-clib's lib dirs out in `cabal.project` (not via
    # `components.library.libs` alone): that way plan-nix evaluates
    # cabal with the same `extra-lib-dirs:`, the unit-id it records
    # for `test-lib` includes them, and the v2 slice's
    # cabal-computed uid stays in sync.  Mingw ships import libs
    # (`.dll.a`) under `bin/` rather than `lib/`, so list both.
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal
      + lib.optionalString profiled ''
        package *
          library-profiling: True
      ''
      + lib.optionalString stdenv.hostPlatform.isWindows ''
        package test-lib
          extra-lib-dirs: ${test-clib}/lib
          extra-lib-dirs: ${test-clib}/bin
      '';
    modules = [
     ({pkgs, ...}: {
      packages.th-dlls-minimal.components.library.preBuild = ''
        export ISERV_ARGS=-v
        export PROSY_ARGS=-v
      '';
      packages.test-lib.components.library.libs = mkForce [ test-clib ];
      packages.th-dlls-minimal.components.library.usesTemplateHaskell = true;
      packages.th-dlls-minimal.components.exes.just-template-haskell.usesTemplateHaskell = true;
     })
     ({pkgs, ...}: lib.optionalAttrs externalInterpreter {
      packages.th-dlls-minimal.ghcOptions = [ "-fexternal-interpreter" ];
    })];
  };

  packages         = (project { externalInterpreter = false;                  }).hsPkgs;
  packages-ei      = (project { externalInterpreter = true;                   }).hsPkgs;
  packages-prof    = (project { externalInterpreter = false; profiled = true; }).hsPkgs;
  packages-ei-prof = (project { externalInterpreter = true;  profiled = true; }).hsPkgs;

in lib.recurseIntoAttrs {
  # This test is just for windows currently (the full th-dlls test runs on other platforms)
  meta.disabled = !stdenv.hostPlatform.isWindows
    # Rosetta error: invalid gdt selector index 5 (wine crashes under Rosetta with msvcrt)
    || (stdenv.hostPlatform.isWindows && stdenv.hostPlatform.libc != "ucrt")
    ;

  ifdInputs = {
    plan-nix             = (project { externalInterpreter = false;                  }).plan-nix;
    plan-nix-ei          = (project { externalInterpreter = true;                   }).plan-nix;
    plan-nix-profiled    = (project { externalInterpreter = false; profiled = true; }).plan-nix;
    plan-nix-profiled-ei = (project { externalInterpreter = true;  profiled = true; }).plan-nix;
  };

  build                    = packages.th-dlls-minimal.components.library;
  build-profiled           = packages-prof.th-dlls-minimal.components.library;
  just-template-haskell    = packages.th-dlls-minimal.components.exes.just-template-haskell;
  build-ei                 = packages-ei.th-dlls-minimal.components.library;
  build-profiled-ei        = packages-ei-prof.th-dlls-minimal.components.library;
  just-template-haskell-ei = packages-ei.th-dlls-minimal.components.exes.just-template-haskell;
}
