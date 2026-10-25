# Test building TH code that needs DLLs when cross compiling for windows
{ stdenv, lib, util, project', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, buildPackages, testCabalProjectLocal, testInputMap }:

with lib;

let
  # haskell-gi's custom Setup.hs pulls in cabal-doctest, whose 1.0.12 (the
  # newest on hackage) does not build against Cabal 3.17: that release split
  # Verbosity into VerbosityFlags + VerbosityHandles, so the result of
  # `buildVerbosity` no longer typechecks where a Verbosity is wanted.
  #
  # It has to come in as a source-repository-package rather than
  # `packages.cabal-doctest.patches`: patches repack the tarball, which moves
  # `pkgHashSourceHash` and so the unit-id, while plan-nix was computed by
  # plan-to-nix against unpatched hackage -- the slice then fails
  # checkAgainstPlan.  An SRP is visible to the planner, so both sides agree.
  #
  # No `--sha256:` line: `testInputMap` carries the flake's `cabal-doctest`
  # input under this url, which short-circuits the source-repo fetch (and so
  # the `builtins.fetchGit` that would need a hash in pure eval).  The `tag:`
  # below must stay equal to that input's rev -- lib/call-cabal-project-to-nix
  # compares the two and throws if they drift, and flake.nix pins the input to
  # this rev so an update cannot move one without the other.
  cabalDoctestSrp = ''
    source-repository-package
        type: git
        location: https://github.com/stable-haskell/cabal-doctest.git
        tag: 641cda5a4590f2384568a9598713f3039b99258d
  '';

  project = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "gi-gtk";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal + cabalDoctestSrp + ''
      -- The overloading feature of haskell-gi makes build times very long
      constraints: any.haskell-gi-overloading ==0.0
    '';
  };

  # See `docs/dev/profiling.md` — v2 expects profiling toggles in
  # cabal.project so plan-nix records `--enable-…-profiling`.
  projectProfiled = project' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "gi-gtk";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal + cabalDoctestSrp + ''
      constraints: any.haskell-gi-overloading ==0.0
      package *
        library-profiling: True
      package test-gi-gtk
        profiling: True
    '';
  };

  packages = project.hsPkgs;
  packagesProfiled = projectProfiled.hsPkgs;

in lib.recurseIntoAttrs rec {
  meta.disabled = stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm
    # Gtk cross compilation seems to be broken in nixpkgs
    || stdenv.hostPlatform.isWindows
    # We can't make static libraries for Gtk
    || stdenv.hostPlatform.isMusl
    # Older versions of GHC fail for aarch64 with
    # error: incompatible pointer to integer conversion assigning to 'ffi_arg' (aka 'unsigned long') from 'HsPtr' (aka 'void *') [-Wint-conversion]
    || builtins.elem compiler-nix-name ["ghc8107" "ghc902" "ghc928" "ghc948"] && stdenv.hostPlatform.isAarch64
    # Cross compilation to aarch64 is also broken
    || stdenv.hostPlatform.isAarch64 && !stdenv.buildPlatform.isAarch64
    # glu is marked ase broken for isAndroid
    || stdenv.hostPlatform.isAndroid
    # Skip until we update haskell.nix to Cabal 3.16
    || builtins.elem compiler-nix-name ["ghc91320251028"];

  ifdInputs = {
    inherit (project) plan-nix;
    plan-nix-profiled = projectProfiled.plan-nix;
  };

  build = packages.test-gi-gtk.components.exes.test-gi-gtk;
  check = haskellLib.check build;
  build-profiled = packagesProfiled.test-gi-gtk.components.exes.test-gi-gtk;
  check-profiled = haskellLib.check build-profiled;
}
