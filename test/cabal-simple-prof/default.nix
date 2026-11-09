# Test a package set
{ stdenv, lib, util, cabalProject', haskellLib, testSrc, compiler-nix-name, evalPackages, evalSystem, testCabalProjectLocal, testInputMap }:

with lib;

let
  modules = [
    {
      # Package has no exposed modules which causes
      #   haddock: No input file(s)
      packages.cabal-simple.doHaddock = false;
      packages.cabal-simple.enableProfiling = true;
      enableLibraryProfiling = true;
      # executableProfiling = false;
    }
  ];

  project = cabalProject' {
    inherit compiler-nix-name evalSystem;
    src = testSrc "cabal-simple-prof";
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal
      + lib.optionalString (haskellLib.isCrossHost && stdenv.hostPlatform.isAarch64) ''
        constraints: text -simdutf, text source
      ''
      # v2 reads profiling settings from plan.json's `configure-args`
      # (the cabal-install-recorded toggles), not from haskell.nix's
      # module-level `enableProfiling`/`enableLibraryProfiling`.  Mirror
      # the modules above in cabal.project shape so plan-nix records
      # the matching configure-args, keeping the slice's UnitId
      # reproducible.  The module-level overrides are kept for v1.
      + ''
        package *
          library-profiling: True
        package cabal-simple
          profiling: True
        -- text-iso8601 (reached via aeson) is the one library in this
        -- closure whose profiled compile does not fit in memory:
        -- `Data.Time.FromText` is SIGKILLed under `-O -prof` on BOTH
        -- x86_64-linux and aarch64-darwin, while the vanilla `-O` compile of
        -- the same two modules takes about two seconds.  It is the only
        -- failing step in the job, which has never passed on ghc914-sh (it
        -- passes on ghc9103 and ghc9141).
        --
        -- Drop optimisation for this one package.  `-O` alone is clearly fine
        -- (the vanilla way) and `-prof` is what the test needs, so it is the
        -- combination that is fatal; optimisation is the half we can give up
        -- here, since the test links text-iso8601 only to satisfy aeson and
        -- never exercises it.
        --
        -- `profiling-detail: none` is kept because it is the reason we know
        -- cost centres are NOT the cause: with it, GHC gets no `-fprof-auto*`
        -- flag at all (`ProfDetailNone` -> `mempty` in `profDetailLevelFlag`)
        -- and the compile still died -- 705s on darwin, 105s on linux, in
        -- eval 2534.  So `-prof -O` is enough on its own, and `-fprof-late`
        -- would not have helped either.  Do not "simplify" this back to a
        -- profiling-detail-only fix.
        --
        -- Note it must be spelled `profiling-detail`, not
        -- `library-profiling-detail`: the latter records
        -- `--profiling-detail=none --library-profiling-detail=default` in
        -- plan.json, and Cabal takes the library level as
        -- `profDetail <> profLibDetail` (Configure.hs `tryLibProfileLevel`),
        -- so `default` wins on the right.
        --
        -- What must NOT be touched is `library-profiling`: cabal-simple's exe
        -- is profiled and links cabal-simple -> aeson -> text-iso8601, so
        -- without the `.p_o` objects the link fails instead of the compile.
        --
        -- The blowup itself is undiagnosed.  ghc914-sh differs from the
        -- passing ghc9103 / ghc9141 in GHC point release (9.14.0 vs 9.14.1),
        -- builder (v2 slices vs v1 Setup.hs) and build configuration at once,
        -- and separating them needs a compiler build.  If it is ever chased
        -- down, drop this whole stanza.
        package text-iso8601
          profiling-detail: none
          optimization: False
      '';
    inherit modules;
  };

  exe = (project.getComponent "cabal-simple:exe:cabal-simple")
    .override (lib.optionalAttrs stdenv.hostPlatform.isAndroid { setupBuildFlags = ["--ghc-option=-optl-static" "--ghc-option=-optl-ldl"]; });

in lib.recurseIntoAttrs {
  meta.disabled = stdenv.hostPlatform.isGhcjs || stdenv.hostPlatform.isWasm;
  ifdInputs = {
    inherit (project) plan-nix;
  };
  # The exe runs through `testWrapper` (an emulator on cross hosts), so pin
  # it the way `haskellLib.check` pins test runs: a nix-linux-builder VM
  # cannot execute an i686 exe at all.
  run = stdenv.mkDerivation (haskellLib.emulatorRunAttrs // {
    name = "cabal-simple-prof-test";

    buildCommand = ''
      exe="${exe.exePath}"

      size=$(command stat --format '%s' "$exe")
      printf "size of executable $exe is $size. \n" >& 2

      # fixme: run on target platform when cross-compiled
      printf "checking whether executable runs with profiling... " >& 2
      # Curiosity: cross compilers prodcing profiling with `+RTS -p -h` lead to the following cryptic message:
      #   cabal-simple: invalid heap profile option: -h*
      # Hence we pass `-hc`.
      ${toString exe.config.testWrapper} $exe +RTS -p -hc

      touch $out
    '';

    meta = {
      platforms = platforms.all;
    };

    passthru = {
      # Used for debugging with nix repl
      inherit project;
    };
  });
}
