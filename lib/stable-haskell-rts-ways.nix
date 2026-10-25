# The `RTS ways` string a stable-haskell compiler (ghc914-sh) reports in
# `ghc --info` -- and the one it would report if left alone.
#
# Why this file exists
# --------------------
# The value is not measured from anything.  `utils/ghc-toolchain/exe/Main.hs`
# in the stable-haskell GHC fork hard-codes it, with its own admission:
#
#     , ("RTS ways", "v thr debug thr_debug")
#       -- FIXME: should be a property of the RTS, not of the target
#
# haskell.nix runs `ghc-toolchain-bin --output-settings` to generate the
# compiler's `settings` file (overlays/stable-haskell.nix), and GHC echoes
# every settings key back out of `--info`, so that literal is what every
# consumer sees.
#
# `Distribution.Simple.Compiler.waySupported` reads exactly this field and,
# for GHC >= 9.10.1, TRUSTS it:
#
#     waySupported way comp = ... case Map.lookup "RTS ways" (compilerProperties comp) of
#                                   Just ways -> Just (way `elem` words ways)
#     profilingVanillaSupported comp = waySupported "p" comp
#
# With no `p` in the list, `Distribution.Simple.Configure.configure` takes the
# else branch, sets `withProfLib = False` and warns
#
#     The compiler ghc-9.14 does not support profiling. Profiling has been
#     disabled.
#
# ...which silently drops the profiling way from every package cabal
# configures through an external `Setup.hs` -- i.e. every `build-type: Custom`
# or `Configure` package.  Among the boot libraries a stable-haskell `-target`
# compiler builds from source that is `ghc-boot` (Custom) and `ghc` (Custom);
# the `Simple` ones (ghc-heap, ghci, binary, ...) take cabal's per-component
# path, never reach that check, and DO get their `.p_hi` / `_p.a`.  The
# mismatch surfaces as a profiled consumer failing on an unprofiled
# dependency:
#
#     Could not load module 'GHC.Serialized'.
#     Perhaps you haven't installed the profiling libraries for package
#     'ghc-boot-9.14'?
#
# which is every `iserv-proxy-interpreter-prof` job, and (at ifdLevel 3) the
# `cabal-simple-prof` test too.
#
# Why the profiling ways are real
# -------------------------------
# The fork models `threaded` and `debug` as separate rts SUB-LIBRARIES
# (`rts:threaded-debug` & co, selected by `rtsWayUnitId'` in
# GHC/Driver/DynFlags.hs) because `GHC.Platform.Ways` gives them no compiler
# options of their own -- `wayOptc WayThreaded = []` -- so the `-DTHREADED_RTS`
# / `-DDEBUG` have to come from the .cabal file.  Profiling is not like that.
# It is a "full" way (`wayRTSOnly WayProf = False`), it carries its own flags
#
#     wayOptc _ WayProf = ["-DPROFILING"]
#     wayOptP _ WayProf = ["-DPROFILING"]
#
# and cabal builds C/Cmm `extra-sources` once PER WAY
# (Distribution.Simple.GHC.Build.ExtraSources: `ProfWay -> compileIfNeeded
# profSrcOpts{ghcOptObjSuffix = "p_o"}`, and `profSrcOpts` sets
# `ghcOptProfilingMode`).  So `library-profiling: True` on the existing four
# rts sub-libraries yields `libHSrts-1.0.3-<way>_p.a` whose C and Cmm really
# were compiled with `-DPROFILING` -- the same source set hadrian compiles for
# its `_p` ways.  Each of the four sub-libraries therefore has a vanilla and a
# profiled flavour: eight ways in total, and no new sub-library, no
# `rtsWayUnitId'` change and no rts.cabal change is needed.
#
# The plans already ask for it: every boot-library unit in an
# `iserv-proxy-interpreter-prof` plan, the four rts way units included, carries
# `--enable-library-profiling`.  Cabal was refusing, not haskell.nix.
#
# Keep the two strings in step with the fork.  `tests.dummy-ghc-info` diffs the
# plan-time dummy's `--info` against the real compiler's byte for byte, so
# lib/dummy-ghc.nix and overlays/stable-haskell.nix must agree exactly -- which
# is the whole reason the value lives here rather than being spelled out at
# each of the five sites that need it.
let
  # What `ghc-toolchain-bin --output-settings` writes today.
  base = "v thr debug thr_debug";
  # The same four sub-libraries in their profiled flavour (`library-profiling:
  # True` on each, see overlays/stable-haskell.nix `bootLibProfiling`).
  prof = "p thr_p debug_p thr_debug_p";
  # ...and in their dynamic flavour, which exists when stage2 is built from
  # `cabal.project.stage2.dynamic` (`shared: True` + `constraints: rts
  # +dynamic`) -- the Makefile's DYNAMIC=1.  It writes the same four names
  # (`$(SED) -i -e 's/"RTS ways","/"RTS ways","dyn debug_dyn thr_dyn
  # thr_debug_dyn /'`), prepended rather than appended; order is irrelevant,
  # `waySupported` does an `elem` on the words.  No `_p_dyn` family: the
  # profiled ways are static-only unless `profiling-shared` is also set.
  dyn  = "dyn thr_dyn debug_dyn thr_debug_dyn";
in rec {
  # Asserted before rewriting, so a change in the fork fails the compiler build
  # with a clear message instead of silently going unnoticed.
  fromToolchain = base;

  withProfiling       = "${base} ${prof}";
  # Currently unreachable: `enableSharedStage2` is False, because the .dynamic
  # project cannot be borrowed for its shared libraries without also making the
  # compiler report `GHC Dynamic: YES` (see overlays/stable-haskell.nix).
  withProfilingAndDyn = "${base} ${prof} ${dyn}";

  # The value for a given compiler.  Every site that needs it goes through
  # here: `fixRtsWays` writes it into the settings file, and lib/dummy-ghc.nix
  # echoes it back from the plan-time dummy's `--info` -- and
  # `tests.dummy-ghc-info` diffs those two byte for byte, so they must not be
  # able to disagree.
  for = { enableShared }: if enableShared then withProfilingAndDyn else withProfiling;
}
