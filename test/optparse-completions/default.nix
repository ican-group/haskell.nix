# Test the `generateOptparseApplicativeCompletions` component option and
# `haskellLib.addOptparseApplicativeCompletions` (#381), on both builders.
{ stdenv, lib, buildPackages, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, testInputMap, testCabalProjectLocal }:

let
  mkProject = builderVersion: project' {
    inherit compiler-nix-name evalSystem builderVersion;
    src = testSrc "optparse-completions";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal
      + lib.optionalString (haskellLib.isCrossHost && stdenv.hostPlatform.isAarch64) ''
        constraints: text -simdutf, text source
      '';
    modules = [{
      packages.optparse-completions.components.exes.optparse-completions.generateOptparseApplicativeCompletions = true;
    }];
  };

  # A stable-haskell compiler only works with the v2 builder (see the
  # `builderVersion` default in modules/cabal-project.nix).
  onlyV2 = buildPackages.haskell-nix.compiler.${compiler-nix-name}.isStableHaskell or false;

  projects = { v2 = mkProject 2; } // lib.optionalAttrs (!onlyV2) { v1 = mkProject 1; };

  exeOf = p: p.hsPkgs.optparse-completions.components.exes.optparse-completions;

  # Arm and x86 Linux cross hosts get an emulator `testWrapper`
  # (overlays/armv6l-linux.nix), so completions are expected for those and
  # anything the build machine runs natively.  Elsewhere (Windows,
  # JavaScript, WebAssembly) the component is left as it is.
  expectCompletions = stdenv.buildPlatform.canExecute stdenv.hostPlatform
    || (stdenv.hostPlatform.isLinux
        && (stdenv.hostPlatform.isAarch32 || stdenv.hostPlatform.isAarch64 || stdenv.hostPlatform.isx86));

  checkExe = builderVersion: exe:
    assert lib.assertMsg ((exe ? withoutCompletions) == expectCompletions)
      "optparse-completions: v${builderVersion} completions ${if exe ? withoutCompletions then "added" else "not added"} for ${stdenv.hostPlatform.config}";
    if expectCompletions then ''
      for f in share/bash-completion/completions/${exe.exeName}.bash \
               share/zsh/site-functions/_${exe.exeName} \
               share/fish/vendor_completions.d/${exe.exeName}.fish; do
        printf "v${builderVersion}: checking $f... " >&2
        grep -qF ${exe.exeName} "${exe}/$f"
        echo ok >&2
      done
      printf "v${builderVersion}: checking the exe is still there... " >&2
      test -x ${exe.exePath}
      echo ok >&2
    '' else ''
      printf "v${builderVersion}: no completions for %s\n" ${stdenv.hostPlatform.config} >&2
    '';

in lib.recurseIntoAttrs {
  ifdInputs = lib.mapAttrs (_: p: p.plan-nix) projects;

  run = stdenv.mkDerivation {
    name = "optparse-completions-test";

    buildCommand = lib.concatStrings (lib.mapAttrsToList
      (n: p: checkExe (lib.removePrefix "v" n) (exeOf p)) projects) + ''
      touch $out
    '';

    meta.platforms = lib.platforms.all;

    passthru = {
      # Used for debugging with nix repl
      inherit projects;
    };
  };
}
