# overlays/stable-haskell.nix
#
# Builds `haskell-nix.compiler.ghc914-sh` (stable-haskell GHC 9.14) using
# haskell-nix.cabalProject' to replicate the two-stage cabal build described in
# ../stable-ghc-9.14/Makefile (without invoking Hadrian).
#
# Stage flow:
#   configuredSrc  -- autoconf/configure, ghc-boot-th-next synthesis,
#                     FIXME patches, import inlining
#   stage1Project  -- cabalProject' with bootGhc (ghc9103)
#                     builds: GHC executables, ghc-toolchain-bin
#   stage1Compiler -- wrapper scripts + empty package DB
#   stage2Project  -- cabalProject' with ghcOverride = stage1Compiler
#                     builds: all boot libraries + GHC executables
#   ghc914-sh        -- final compiler with populated package DB

final: prev:
let
  pkgs         = final;
  lib          = final.lib;

  # ── Shared, eval-system-independent GHC source machinery ────────────────────
  # Hoisted OUT of `mkGhc` so it is evaluated ONCE per overlay fixpoint and
  # shared across every `mkGhc` / `evalWith` invocation.  These bindings depend
  # only on `pkgs`/`lib` and build/version constants — never on `evalSystem`
  # — so keeping a copy inside each `mkGhc` invocation (as we used to) re-built
  # the identical configured source tree per invocation, because `evalWith`
  # re-invokes `mkGhc` per eval system.  `mkConfiguredSrc`/`mkDumpSrc` here are
  # applied to a specific nixpkgs at each use: `configuredSrc`/`dumpSrc` (build
  # platform) once, and `configuredSrcEval`/`dumpSrcEval` (one mkGhc invocation's
  # eval platform) once — cross-eval-system reuse comes from `evalWith`.

  # ProjectVersion / ProjectVersionMunged as handed to GHC's ./configure —
  # the ONLY place the 3-component form may appear.  The built compiler
  # identifies itself everywhere cabal can observe (--numeric-version, the
  # ghc package's version, Project Unit Id and hence cabal's compiler id and
  # store dir name) as the MUNGED "9.14", so every haskell.nix-facing surface
  # (passthru.version, lib dir, versioned bin aliases) uses ghcVersion = the
  # munged form.  A "9.14.0" the plan-time dummy ghc reports but the real
  # compiler doesn't (or vice versa) makes cabal's plan-time and build-time
  # compiler ids differ, forking every UnitId the v2 slice builder checks
  # against plan-nix.
  ghcVersionFull   = "9.14.0";
  ghcVersionMunged = "9.14";
  ghcVersion       = ghcVersionMunged;
  ghcVersionForLib = "9.1400";

  # Platform values needed to patch the FIXME placeholders in
  # cabal.project.common.  These describe the BUILD machine (i.e. the machine
  # running the compiler), which for a native build is the host platform.
  hp           = pkgs.stdenv.hostPlatform;
  buildTriple  = hp.config;   # e.g. "aarch64-apple-darwin"
  buildArch    =
    if hp.isAarch64 then "aarch64"
    else if hp.isx86_64 then "x86_64"
    else "unknown";
  buildOS      =
    if hp.isDarwin  then "darwin"
    else if hp.isLinux   then "linux"
    else if hp.isWindows then "mingw32"
    else "unknown";
  buildVendor =
    if hp.isDarwin then "apple"
    else if hp.isLinux then "unknown"
    else "unknown";
  ghcUnregisterised = "NO";
  tablesNextToCode  = "YES";

  ghc914-shSrc = pkgs.haskell-nix.sources.ghc914-sh;

  # ── RTS ways ────────────────────────────────────────────────────────────────
  # `ghc-toolchain-bin --output-settings` hard-codes this field (see
  # lib/stable-haskell-rts-ways.nix for the FIXME it carries upstream and for
  # what goes wrong downstream), so every generated `settings` file below gets
  # it rewritten by `fixRtsWays`.  The same value is what the plan-time dummy
  # reports (lib/dummy-ghc.nix); `tests.dummy-ghc-info` diffs the two.
  shRtsWays = import ../lib/stable-haskell-rts-ways.nix;
  # `enableShared` is FALSE, and the stage2 boot libraries are built from
  # `cabal.project.stage2.static`.  This compiler ships no shared way of any
  # boot library, and now says so.
  #
  # The alternative -- make `enableShared` mean what DYNAMIC=1 means in the
  # fork's Makefile, i.e. build from `cabal.project.stage2.dynamic` -- was
  # tried (3f3cf0506, da6b6dae1) and reverted here.  Two things sink it, and
  # both are worth recording because neither is visible from the project
  # files:
  #
  #   * `cabal.project.stage2.dynamic` carries `constraints: rts +dynamic`,
  #     and rts.cabal turns that flag into `-DDYNAMIC` for EVERY way it
  #     builds, vanilla included (rts/rts.cabal `common
  #     rts-global-build-flags`).  `ghc --info`'s `GHC Dynamic` is not a
  #     settings field: it is `rts_isDynamic()`, i.e. `#if defined(DYNAMIC)`
  #     compiled into whichever rts the `ghc` binary links
  #     (rts/RtsUtils.c:421 → GHC.Platform.Ways.hostIsDynamic →
  #     GHC.Driver.Session:3573).  So a STATIC `ghc` built from that project
  #     reports `GHC Dynamic: YES` -- dropping `executable-dynamic` does not
  #     help -- and GHC then loads dynamic objects for Template Haskell and
  #     links against `libHS<dep>-ghc9.14.dylib` for every dependency, which
  #     v2 consumer plans (whose configure flags come from plan.json, not
  #     from this passthru) never built.  Hadrian gets this right by adding
  #     `-DDYNAMIC` per way; cabal has no per-way ghc-options, so the fork's
  #     project files must pick one, and they pick the one that suits a
  #     genuinely dynamic build.
  #
  #   * upstream's dynamic build only survives its dynamic EXECUTABLES because
  #     the Makefile's DYNAMIC=1 dist step repairs their rpaths afterwards
  #     (`SET_RPATH ../lib/$(HOST_PLATFORM)`, `patchelf --set-rpath $ORIGIN`).
  #     Nothing does that here, and the first casualty is not the assembled
  #     compiler but a tool cabal builds and RUNS INSIDE a slice: a
  #     dynamically-linked `alex` that dyld could not start, reported as
  #     `Error: [Cabal-1008] The program 'alex' ... could not be determined`.
  #
  # Cost of staying static: a v1 (comp-builder) consumer used to be told
  # `--enable-shared` by this passthru and then failed on the boot libraries'
  # missing dynamic way (`tests.check-datadir.run`: "Failed to load dynamic
  # interface file for Prelude ... base-4.22.0.0/Prelude.dyn_hi").  False is
  # the honest answer to that, and the one that matches what we build.
  enableSharedStage2 = false;
  # One string for the native compiler and every `-target` wrapper: they are
  # all the same stage2 `ghc-bin` binary, so their settings files all get this
  # (see the comment in lib/dummy-ghc.nix, which echoes it back).  A cross
  # target's own ways are decided by `targetSupportsShared`
  # (modules/cabal-project.nix), NOT here -- adding the dyn quartet to this one
  # string put it into the TARGET settings too, and every android boot-library
  # slice started building a DynWay it had no dynamic dependencies for.
  shRtsWaysValue = shRtsWays.for { enableShared = enableSharedStage2; };
  # Assert the value we expect to find before replacing it: if the fork ever
  # sets its own list, we want the compiler build to stop here with the actual
  # string in the log, not to overwrite it unnoticed.
  fixRtsWays = settingsFile: ''
    grep -qF '("RTS ways","${shRtsWays.fromToolchain}")' ${settingsFile} || {
      echo "ghc-toolchain no longer writes the RTS ways string we patch;" >&2
      echo "update lib/stable-haskell-rts-ways.nix.  It now says:" >&2
      grep -F '"RTS ways"' ${settingsFile} >&2
      exit 1
    }
    sed -i 's|("RTS ways","${shRtsWays.fromToolchain}")|("RTS ways","${shRtsWaysValue}")|' \
      ${settingsFile}
  '';
  # Since stable-ghc-9.14 b666dfd2bc, `ghc --info`'s `GHC Dynamic`,
  # `GHC Profiled` and `Support dynamic-too` come from four per-target settings
  # keys, not from the RTS the ghc binary links:
  #
  #   GHC Dynamic         = target is dynamic  && target ships dynamic libraries
  #   GHC Profiled        = target is profiled && target ships profiling libraries
  #   Support dynamic-too = not Windows        && target is dynamic
  #
  # Each defaults to YES when absent.  The fork's Makefile appends them to
  # every settings file it writes; ghc-toolchain-bin does not, so without this
  # every compiler here said `GHC Dynamic: YES`.  That disagreed with the
  # plan-time dummy (tests.dummy-ghc-info), and cabal took it to mean the
  # compiler is dynamic, so it compiled TH-using libraries -dynamic-too
  # against boot libraries that have no .dyn_hi ("Failed to load dynamic
  # interface file for Prelude ... base-4.22.1.0/Prelude.dyn_hi",
  # integer-logarithms).
  #
  # These values reproduce what the compilers reported before that change,
  # so plans stay as they were: dynamic-capable (keeps `Support dynamic-too`
  # YES) but shipping no dynamic libraries (`GHC Dynamic` NO: the stage2 build
  # is static, see `enableSharedStage2`), and not profiled (`GHC Profiled` NO,
  # as the Makefile also writes).
  addTargetDials = settingsFile: ''
    if grep -qF '"target is dynamic"' ${settingsFile}; then
      echo "the settings file already has the per-target dials; update" >&2
      echo "addTargetDials in overlays/stable-haskell.nix" >&2
      exit 1
    fi
    sed -i 's/\]$/,("target is dynamic","YES"),("target ships dynamic libraries","NO"),("target is profiled","NO"),("target ships profiling libraries","NO")]/' \
      ${settingsFile}
    grep -qF '("target ships dynamic libraries","NO")' ${settingsFile} || {
      echo "could not append the per-target dials to ${settingsFile}" >&2
      exit 1
    }
  '';

  # ── Configured source ──────────────────────────────────────────────────────
  # Runs autoconf/configure to generate .cabal files from .cabal.in,
  # synthesises libraries/ghc-boot-th-next, patches the FIXME platform
  # placeholders in cabal.project.common, and produces self-contained
  # (import-inlined) project files.
  # `mkConfiguredSrc buildPkgs` builds the configured GHC source tree using
  # `buildPkgs`.  Building the source requires a build machine (autoconf +
  # configure), so plan-to-nix must read the `.cabal` files from a copy built
  # on the EVAL platform (`mkConfiguredSrc evalPackages`, wired as `evalSrc` /
  # `raw-src`) to avoid an eval-time dependency on the target-platform builder.
  # The real builds use `configuredSrc = mkConfiguredSrc pkgs` (build platform).
  # The `sed` FIXME patches below use Nix-level `buildTriple`/`buildArch`/… that
  # describe the build/host platform of the compiler being produced and are
  # independent of `buildPkgs` — a darwin-built tree still yields the correct,
  # plan-equivalent `.cabal` metadata (platform `if os(…)` conditionals are
  # resolved at solve time by the dummy ghc's `--info`, not by which platform
  # generated the `.cabal`).
  mkConfiguredSrc = buildPkgs:
    (buildPkgs.stdenv.mkDerivation {
    name = "ghc914-sh-configured-src";
    src  = ghc914-shSrc;

    nativeBuildInputs = with buildPkgs; [ autoconf automake libtool python3 ];

    # Nix's default unpackPhase is fine; skip configure/install phases.
    phases = [ "unpackPhase" "buildPhase" "installPhase" ];

    buildPhase = ''
      # ── 1. Synthesise libraries/ghc-boot-th-next ─────────────────────────
      # The stage1 build uses ghc-boot-th-next (= ghc-boot-th with +bootstrap
      # flag) to avoid the ghc-internal dependency.  ghc-boot-th-next is listed
      # in AC_CONFIG_FILES so configure will process its .cabal.in → .cabal,
      # substituting all @VAR@ placeholders.  We copy the full source directory
      # (not just changelog/LICENSE) so Haskell modules are available.
      cp -r libraries/ghc-boot-th libraries/ghc-boot-th-next
      rm -f libraries/ghc-boot-th-next/ghc-boot-th.cabal.in
      sed 's/ghc-boot-th@Suffix@/ghc-boot-th-next/g' \
          libraries/ghc-boot-th/ghc-boot-th.cabal.in \
          > libraries/ghc-boot-th-next/ghc-boot-th-next.cabal.in

      # ── 2. Run autoconf + configure ─────────────────────────────────────
      # autoreconf generates ./configure from configure.ac and the m4/ macros.
      autoreconf -i

      # Several submodule libraries use build-type: Configure with their own
      # configure.ac files.  Run autoreconf -i in each so the configure script
      # is present before haskell.nix builds them.  (libffi-clib needs libtool;
      # all others only need autoconf/automake, but having libtool available
      # is harmless — autoreconf only calls libtoolize when LT_INIT is present.)
      for libdir in \
          libraries/libffi-clib \
          libraries/unix \
          libraries/directory \
          libraries/process \
          libraries/time \
          libraries/terminfo \
          libraries/ghc-internal \
          rts; do
        if [ -f "$libdir/configure.ac" ]; then
          (cd "$libdir" && autoreconf -i 2>&1 | tail -1 || true)
        fi
      done

      # rts's generated configure has no AC_CONFIG_AUX_DIR, so at run time
      # it searches `.`, `..`, `../..` for its aux files — which in this
      # tree sit at the TOP level.  The v2 builder ships each package as a
      # standalone sdist-style tarball, so `..` is empty there; copy the
      # aux files into rts/ so a sliced rts configure still finds them.
      # (rts is the only in-tree build-type: Configure package; the
      # hackage-pinned Configure packages bundle their own aux files.)
      for aux in install-sh config.guess config.sub; do
        if [ -f "$aux" ] && [ ! -f "rts/$aux" ]; then
          cp "$aux" "rts/$aux"
        fi
      done

      # rts/configure.ac hard-codes the deriveConstants probe's include
      # path as `-I$srcdir/../rts-headers/include` (upstream marks it
      # FIXME) — valid only when rts/ sits inside this tree next to
      # rts-headers/.  In a v2 slice the unpacked sdist has no such
      # sibling, but rts-headers IS an installed dependency there and
      # cabal exports GHC_PKG to the configure env — so fall back to the
      # registered include-dirs when the relative path is missing.
      sed -i 's|--gcc-flag "-I$srcdir/../rts-headers/include"|--gcc-flag "-I$(if test -d "$srcdir/../rts-headers/include"; then echo "$srcdir/../rts-headers/include"; else "$GHC_PKG" field rts-headers include-dirs --simple-output; fi)"|' \
        rts/configure

      # ghc-boot/Setup.hs's confHook falls back to `git rev-parse HEAD`
      # when $GIT_COMMIT_ID is unset.  v1 exports the variable via
      # packages.ghc-boot.preConfigure, but v2 slices don't run per-package
      # preConfigure hooks, and the sliced sdist is not a git repo — so
      # rewrite the fallback itself to the same constant v1 exports.
      # (`if True then … else do` keeps the original do-block parsing as
      # the dead else-branch, so the sed stays a one-liner.)
      sed -i 's|Nothing -> do|Nothing -> if True then return "0000000000000000000000000000000000000000" else do|' \
        libraries/ghc-boot/Setup.hs

      # The same Setup.hs generates GHC/Platform/Host.hs by splicing `show`n
      # Cabal values into source text, unparenthesised:
      #   , "hostPlatformArch = toArch " ++ show arch
      # For every arch Cabal has a nullary constructor for that is fine, but an
      # arch it does not know becomes `OtherArch "<name>"`, and the line comes
      # out as `toArch OtherArch "armv7"` -- two arguments to a one-argument
      # function, so ghc-boot does not compile at all:
      #   • The function `toArch' is applied to two visible arguments,
      #     but its type `Distribution.System.Arch -> Arch' has only one
      # armv7a-unknown-linux-androideabi is exactly that case ("armv7" is not
      # one of Cabal's known arches).  Upstream clearly meant this to work --
      # the generated code already carries `toArch (OtherArch _) = ArchUnknown`
      # and the matching `toOS (OtherOS _)` -- so the parentheses are the whole
      # fix.  `toOS` gets them too: it has the identical shape and would fail
      # the same way on an OS Cabal does not know.
      sed -i \
        -e 's|"hostPlatformArch = toArch " ++ show arch|"hostPlatformArch = toArch (" ++ show arch ++ ")"|' \
        -e 's|"hostPlatformOS   = toOS " ++ show os|"hostPlatformOS   = toOS (" ++ show os ++ ")"|' \
        libraries/ghc-boot/Setup.hs
      grep -qF 'toArch (" ++ show arch ++ ")"' libraries/ghc-boot/Setup.hs || {
        echo "ghc-boot Setup.hs: the hostPlatformArch generator moved; the" >&2
        echo "unparenthesised-OtherArch fix did not apply.  It now says:" >&2
        grep -n 'hostPlatformArch =' libraries/ghc-boot/Setup.hs >&2
        exit 1
      }

      # configure generates config.status AND all AC_CONFIG_FILES (the .cabal
      # files, ghcversion.h, …).
      ./configure \
        --with-project-version="${ghcVersionFull}" \
        --with-project-version-int="914" \
        --with-project-version-munged="${ghcVersionMunged}" \
        --with-project-version-for-lib="${ghcVersionForLib}" \
        --with-project-patch-level="0" \
        --with-project-patch-level1="0" \
        --with-project-patch-level2="0"

      # ── 3. Patch FIXME platform values in cabal.project.common ───────────
      # The file contains hard-coded "FIXME" strings for BuildPlatform etc.
      # that must be replaced before the project files are merged.
      sed -i \
        -e 's|DBuildPlatform=\\"FIXME\\"|DBuildPlatform=\\"${buildTriple}\\"|' \
        -e 's|DBuildArch=\\"FIXME\\"|DBuildArch=\\"${buildArch}\\"|' \
        -e 's|DBuildOS=\\"FIXME\\"|DBuildOS=\\"${buildOS}\\"|' \
        -e 's|DBuildVendor=\\"FIXME\\"|DBuildVendor=\\"${buildVendor}\\"|' \
        -e 's|GhcUnregisterised=\\"FIXME\\"|GhcUnregisterised=\\"${ghcUnregisterised}\\"|' \
        -e 's|TablesNextToCode=\\"FIXME\\"|TablesNextToCode=\\"${tablesNextToCode}\\"|' \
        cabal.project.common

      # ── 4. Inline imports → self-contained project files ─────────────────
      # haskell.nix reads cabalProject as a string and writes it to a temp
      # location, so "import:" directives would not resolve.  We inline them
      # here so the merged files are self-contained.  Recurses, since the
      # stage2 files import transitively: stage2.{static,dynamic} →
      # stage2.common → cabal.project.common.
      inline_imports() {
        local f="$1"
        local line imp
        while IFS= read -r line; do
          if imp=$(printf '%s' "$line" \
                   | sed -n 's/^[[:space:]]*import:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p') \
             && [ -n "$imp" ]; then
            if [ -f "$imp" ]; then
              inline_imports "$imp"
            else
              printf '%s\n' "$line"
            fi
          else
            printf '%s\n' "$line"
          fi
        done < "$f"
      }

      inline_imports cabal.project.stage1 > cabal.project.stage1.merged

      # cabal.project.stage1 constrains 'template-haskell <= 2.22'.  Cabal's
      # solver treats version triples as lists (so 2.22.0.0 > 2.22 because
      # the longer list is greater), causing any GHC 9.10+ boot compiler to
      # fail with its installed template-haskell-2.22.0.0 (or 2.23.0.0 on
      # 9.12+).  Widen to '< 3' to accept whatever the boot GHC provides.
      sed -i 's/template-haskell <= 2\.22/template-haskell < 3/' cabal.project.stage1.merged

      # For stage2: inline imports (stage2.static → stage2.common →
      # cabal.project.common).  Upstream split the former single
      # cabal.project.stage2 into a .common shared base plus .static / .dynamic
      # selectors, chosen by the Makefile's DYNAMIC; .static is the default
      # (DYNAMIC unset) and the only one we can use -- see `enableSharedStage2`
      # above for why the .dynamic one cannot be borrowed for its shared
      # libraries.  The direct hackage tarball URLs in the packages: stanza are
      # rewritten to local nix store paths by haskell.nix when
      # `replace-hackage-tarball-urls` is enabled on the project (see below).
      inline_imports cabal.project.stage2.static > cabal.project.stage2.merged

      # Drop the 'index-state:' inherited from cabal.project.common.  stage2 and
      # cross both run under 'active-repositories: :none' with every dependency
      # pinned locally, and they use the empty (2008-truncated) hackage index
      # (prepopulateHackageIndex = false), so a 2025 index-state resolves to
      # nothing yet is newer than that placeholder index → cabal aborts with
      # Cabal-7159.  Strip it at the source (both merged files) rather than in
      # the shared plan-to-nix code, so an unrelated project's index-state is
      # never touched.  stage1 keeps its index-state (separate merged file, full
      # index) — it resolves some boot tools (e.g. hpc) from hackage.
      sed -i '/^[[:space:]]*index-state:/d' cabal.project.stage2.merged

      # The source's 'constraints: build:any.ghc-internal installed' uses the
      # cross-compilation "stage" system from the stable-haskell cabal fork
      # (haskell/cabal#11179).  make-install-plan now links that fork, so the
      # 'build:' qualifier parses.  Native stage2, however, has an intentionally
      # empty stage1 package DB (no installed ghc-internal), so the constraint
      # is unsatisfiable there — strip it for the native merged file only.
      # (Cross user projects reinstate it via the boot-package injection in
      # modules/cabal-project.nix, where the build dummy's dump satisfies it.)
      sed -i '/build:any\.ghc-internal/d' cabal.project.stage2.merged

      # ── ghc-iserv-prof ────────────────────────────────────────────────────
      # GHC picks the external interpreter by way: `ghc-iserv` (vanilla),
      # `ghc-iserv-prof` (-prof), `ghc-iserv-dyn` (-dynamic).  Without the prof
      # flavour, `-fexternal-interpreter` together with profiling dies with
      #   .../lib/ghc-9.14/../bin/ghc-iserv-prof: createProcess: execvp:
      #   does not exist (No such file or directory)
      # which is every `tests.th-dlls.build-profiled-ei` job.
      #
      # utils/ghc-iserv builds exactly one executable and carries no flags, so
      # the prof flavour has to be a SECOND build of the same package -- which
      # is exactly how GHC's own bindist produces it (hadrian builds iserv
      # three times, once per way).  Duplicate the package directory under a
      # new name and add it to the stage2 project so both get built.
      cp -r utils/ghc-iserv utils/ghc-iserv-prof
      mv utils/ghc-iserv-prof/ghc-iserv.cabal utils/ghc-iserv-prof/ghc-iserv-prof.cabal
      # The generated .cabal capitalises its field names (`Name:`,
      # `Executable`), so match case-insensitively.
      sed -i -E -e 's|^([Nn]ame:[[:space:]]*)ghc-iserv[[:space:]]*$|\1ghc-iserv-prof|' \
                -e 's|^([Ee]xecutable[[:space:]]+)ghc-iserv[[:space:]]*$|\1ghc-iserv-prof|' \
        utils/ghc-iserv-prof/ghc-iserv-prof.cabal
      grep -qE '^[Nn]ame:[[:space:]]*ghc-iserv-prof$' \
        utils/ghc-iserv-prof/ghc-iserv-prof.cabal \
        || { echo "ghc-iserv-prof: package rename failed" >&2; exit 1; }
      # Add it to the EXISTING packages: stanza -- a second `packages:` field
      # does not accumulate, it replaces, which silently drops every other
      # local package from the plan.
      sed -i 's|^\([[:space:]]*\)utils/ghc-iserv$|\1utils/ghc-iserv\n\1utils/ghc-iserv-prof|' \
        cabal.project.stage2.merged
      printf '\npackage ghc-iserv-prof\n  profiling: True\n  executable-profiling: True\n' \
        >> cabal.project.stage2.merged

    '';

    installPhase = "cp -r . $out";
  });

  # The build-platform configured tree, used for the actual boot-library builds.
  configuredSrc = mkConfiguredSrc pkgs;

  # Disable cleanSourceWith filtering on a store-path source tree.  haskell.nix
  # re-bases every local package onto the project's `src` via
  # `appendSubDir`/`cleanSourceWith` (lib/load-cabal-plan.nix), which calls
  # `builtins.path` — REALISING the tree at eval time.  For our configured tree
  # (a derivation output, already in the store) that means a build-platform
  # build during plan evaluation: harmless natively, but when a darwin host
  # evaluates a linux job it forces a linux build at eval time.  Setting
  # `filterPath` to identity makes cleanSourceWith reference the store path
  # directly (a build input, resolved at BUILD time on the build platform) with
  # no eval-time `builtins.path`.  The build source stays the BUILD tree, so the
  # final derivation's drvPath is independent of the eval platform.  See the
  # `filterPath` note in lib/clean-source-with.nix (same mechanism as
  # modules/hackage-project.nix and overlays/ghc-packages.nix).
  srcNoFilter = src: src // { filterPath = { path, ... }: path; };

  # Stage2 boot library packages that need to be registered in the final
  # compiler's package DB so that `ghc-pkg list` shows them to cabal when
  # users build projects with ghc914-sh.
  bootLibraries = [
    "array"        "base"          "binary"         "bytestring"
    "Cabal"        "Cabal-syntax"  "containers"     "deepseq"
    "directory"    "exceptions"    "file-io"        "filepath"
    "ghc"          "ghc-bignum"    "ghc-boot"       "ghc-boot-th"
    "ghc-compact"  "ghc-experimental"               "ghc-heap"
    "ghc-internal" "ghc-platform"  "ghc-prim"       "ghc-toolchain"
    "ghci"         "haddock-api"   "haddock-library" "haskeline"
    "hpc"          "integer-gmp"   "libffi-clib"    "mtl"
    "os-string"    "parsec"        "pretty"         "process"
    "rts"          "rts-fs"        "rts-headers"    "semaphore-compat"
    "stm"          "template-haskell"               "text"
    "time"         "transformers"  "unix"           "xhtml"
    # terminfo (haskeline +terminfo) and system-cxx-std-lib (text +simdutf)
    # must be registered in the final compiler's package DB, else haskeline/text
    # are broken by dangling deps ("unusable due to missing dependencies").
    "terminfo"     "system-cxx-std-lib"
  ];

  # Every library the final compiler REGISTERS is built in the profiling way as
  # well as vanilla.  A native ghc914-sh registers its stage2 libraries under
  # plan-deterministic unit ids (`base-4.22.0.0`, see `v2LocalPackageSlices`),
  # and a consumer compiling with `-prof` resolves `-package-id base-4.22.0.0`
  # and then asks the module finder for `Prelude.p_hi` beside `Prelude.hi`.
  # Vanilla-only boot libs therefore fail every profiled consumer with GHC-88719
  # ("Perhaps you haven't installed the profiling libraries for package
  # 'base-4.22.0.0'?") -- `tests.cabal-simple-prof` and every dep slice under it
  # (hashable, tagged, transformers-compat, safe).  Cross targets need nothing
  # here: their compiler's global db is empty, so the boot libs are units of the
  # CONSUMER's plan and take the profiling settings from it (that is the path
  # `iserv-proxy-interpreter-prof` exercises).
  #
  # It has to be expressed in the PROJECT, not in `modules`: v2 takes its
  # configure-args from plan.json, so a module-level `enableLibraryProfiling`
  # would fork the slice's UnitId away from plan-nix's.  See
  # docs/dev/profiling.md.
  #
  # Scoped to `bootLibraries` rather than `package *` so the stage2 build tools
  # (alex, happy, happy-lib, ...) and build-stage-only units don't grow a
  # profiled library nothing can ever link -- and, more to the point, don't add
  # failure surface to the compiler build for artifacts no consumer wants.
  #
  # `library-profiling: True` on the four rts sub-libraries yields eight ways
  # (each way vanilla + profiled), which is what the `RTS ways` rewrite in
  # `fixRtsWays` advertises; without that rewrite Cabal's `waySupported` refuses
  # profiling for the `build-type: Custom` boot libs (ghc, ghc-boot) outright.
  # See lib/stable-haskell-rts-ways.nix.
  # `profiling-detail: none` is not a size or build-time tweak -- it keeps the
  # two ways' INTERFACES identical, which profiled Template Haskell depends on.
  #
  # cabal's default for a library is `exported-functions`, i.e.
  # `-fprof-auto-exported`.  The SCC annotations that inserts act as inlining
  # barriers, so the profiled build retains -- and exports -- instance-auxiliary
  # bindings that the vanilla build at `-O` optimises away.  `ghc-internal` ends
  # up with `$fQuasiQ1..26` in `GHC/Internal/TH/Syntax.p_hi` against `1..23` in
  # `Syntax.hi` (mainline GHC's own ghc-internal has 1..23 in BOTH).
  #
  # That divergence is fatal for TH: a consumer compiled `-prof` reads the
  # PROFILED interface and so refers to `$fQuasiQ26`, but its splices run in
  # GHC's in-process interpreter, which is vanilla and loads the VANILLA
  # objects -- where the binding was optimised away:
  #
  #   ghc: ^^ Could not load 'ghczminternal_GHCziInternalziTHziSyntax_
  #        zdfQuasiQ26_closure', dependency unresolved
  #   GHC.ByteCode.Linker.lookupCE ... closure:$fQuasiQ26
  #
  # -- `th-orphans`, and through it every `*.build-profiled` /
  # `*.check-profiled` job.  Note this is NOT an iserv problem: it reproduces
  # on native, where there is no external interpreter (and this compiler ships
  # no iserv binaries at all).
  #
  # Cost-centre detail is worth nothing in the boot libraries anyway -- nobody
  # profiles into `base` -- so `none` gives up nothing real.
  bootLibProfiling = lib.concatMapStrings (p: ''
    package ${p}
      library-profiling: True
      profiling-detail: none
  '') bootLibraries;

  # ── Dump source for plan-time "installed packages" ────────────────────────
  # call-cabal-project-to-nix.nix synthesises the dummy `ghc-pkg dump` (what
  # cabal's solver sees as installed) by scanning `ghc.raw-src` for
  # libraries/<name>/<name>.cabal.  The restructured stable-haskell source no
  # longer carries the hackage-pinned boot libraries in-tree (stm, process,
  # filepath, …) — they are direct tarball URLs in cabal.project.stage2 — so
  # a bare configuredSrc makes the dump miss them and user-project plans
  # (e.g. iserv-proxy) fall back to hackage versions whose bounds reject
  # base-4.22.  Overlay the missing .cabal files (from the same hackage
  # tarballs the build uses) to complete the dump.
  #
  # (name, version) pairs parsed from the merged stage2 project so the list
  # tracks upstream; filtered to bootLibraries = what actually gets
  # registered in the final compiler's DB.
  urlBootPkgsFrom = src: lib.filter (p: lib.elem p.name bootLibraries)
    (pkgs.haskell-nix.haskellLib.hackageTarballUrls
      (builtins.readFile "${src}/cabal.project.stage2.merged"));
  # NB: `urlBootPkgs` is defined per-`mkGhc` (below) reading the EVAL tree — the
  # `readFile` here REALISES the tree at eval, so it must be the eval-platform
  # copy (darwin when a darwin host evaluates a linux job), not the build tree.
  # The parsed (name, version) data is platform-independent, so the drvPaths
  # that consume it are unchanged.

  # `mkDumpSrc buildPkgs configured` builds the dump-source tree (configured tree
  # + the overlaid boot-library `.cabal` files) using `buildPkgs`.  Used as the
  # ghc914-sh compiler's `raw-src`, from which call-cabal-project-to-nix
  # synthesises the dummy `ghc-pkg dump` at plan time — so it must be buildable on
  # the eval platform (`mkDumpSrc evalPackages configuredSrcEval`).
  # Takes the ALREADY-BOUND configured tree (`configuredSrc` / `configuredSrcEval`)
  # rather than re-deriving `mkConfiguredSrc buildPkgs` — function application is
  # NOT memoised, so re-applying it here would re-instantiate the identical tree.
  mkDumpSrc = buildPkgs: configured:
    let dumpUrlBootPkgs = urlBootPkgsFrom configured;
    in buildPkgs.runCommand "ghc914-sh-dump-src" { } (''
    mkdir -p $out
    ${buildPkgs.lndir or buildPkgs.xorg.lndir}/bin/lndir -silent ${configured} $out
  '' + lib.concatMapStrings (p: ''
    mkdir -p $out/libraries/${p.name}
    cp ${buildPkgs.haskell-nix.hackageTarball { inherit (p) name version; evalPackages = buildPkgs; }}/${p.name}.cabal \
       $out/libraries/${p.name}/${p.name}.cabal
  '') dumpUrlBootPkgs
  # Cabal and Cabal-syntax are source-repository-packages (the
  # stable-haskell/Cabal fork) — neither in the GHC tree nor hackage URL
  # pins — so the lndir and urlBootPkgs overlays above both miss their
  # .cabal files.  Without them the dummy ghc-pkg dump omits the packages
  # entirely, and (worse) silently drops ghc-boot's Cabal-syntax depends
  # edge, so user-project plans (e.g. iserv-proxy) never treat Cabal-syntax
  # as pre-existing and the pruned per-component package DB has a broken
  # ghc-boot ("missing package Cabal-syntax").
  + lib.concatMapStrings (name: ''
    mkdir -p $out/libraries/${name}
    cp ${buildPkgs.haskell-nix.sources.ghc914-sh-cabal}/${name}/${name}.cabal \
       $out/libraries/${name}/${name}.cabal
  '') [ "Cabal" "Cabal-syntax" ]);

  # Build-platform dump source (for consumers that realize it on the builder).
  dumpSrc = mkDumpSrc pkgs configuredSrc;

  # NB: the eval-platform trees are NOT memoised here by eval-system.  Each
  # compiler is a single `mkGhc` invocation with one fixed `evalSystem`, so it
  # exposes a plain `configured-src-eval` / `raw-src` for ITS eval platform
  # (built once as a mkGhc `let`-binding, below).  Consumers needing a
  # DIFFERENT eval platform select the memoised per-eval-system compiler
  # variant first — `ghc.evalWith.${evalSystem}.configured-src-eval` — rather
  # than indexing an attrset of source trees; `evalWith` (attribute selection)
  # provides the cross-eval-system memoisation.

  # `evalSystem` is the eval platform (as a system string) on which plan-to-nix
  # / IFD derivations are built.  It mirrors `evalSystem` in
  # compiler/ghc/default.nix (used there for the hadrian compilers): we use it
  # instead of `buildPackages` so plan evaluation can run on a platform other
  # than the build platform.  It defaults to the `pkgsBuildBuild` system (the
  # machine running nix); `roots'` / `cabalProject'` rethread it by SELECTING
  # `ghc.evalWith.${evalSystem}` (overlays/haskell.nix) so that, e.g.,
  # `hydraJobs.x86_64-linux.…ghc914-sh.native.roots.ghc` evaluated on a darwin
  # host computes its plans on darwin instead of shipping the plan-to-nix
  # derivations to a linux builder.
  #
  # The whole compiler pipeline is a function of `evalSystem`; `evalWith`
  # (below) exposes the per-eval-system variants as a memoised attrset —
  # `evalWith.${evalSystem}` is `mkGhc { inherit evalSystem; }` — so selecting
  # one rebuilds the plans against that eval platform without re-running the
  # pipeline per call site (attribute selection is memoised, `.override` is not).
  #
  # Projects/tools derive their (read-only) `evalPackages` option from
  # `evalSystem` via the memoised `haskell-nix.evalPackages.${evalSystem}`
  # attrset, so internal cabalProject'/tool calls thread `evalSystem` rather
  # than setting `evalPackages` directly (which the read-only option forbids).
  mkGhc = { evalSystem ? pkgs.pkgsBuildBuild.stdenv.hostPlatform.system }:
  let
  # The actual eval nixpkgs, from the memoised per-system attrset (one instance
  # shared across every project on this eval platform).  Used where a nixpkgs
  # value is needed directly (mkConfiguredSrc, hackageTarball, dummy ghc, …).
  evalPackages = pkgs.haskell-nix.evalPackages.${evalSystem};
  # The eval-platform configured / dump GHC source trees for THIS invocation's
  # eval platform.  One `mkGhc` invocation has a single `evalSystem`, so these
  # are plain `let`-bindings (forced once), referenced by every eval-time use
  # site (genprimopcode/deriveConstants evalSrc, stage1/stage2 evalSrc) and
  # exposed as the compilers' plain `configured-src-eval` / `raw-src`.  Repeated
  # cross-eval-system access is memoised by `evalWith` (attribute selection on
  # the compiler), NOT by an attrset of trees keyed by system.
  #
  # When the eval platform IS the build platform (native, non-cross), the
  # eval-time tree is byte-identical to the shared outer build tree
  # `configuredSrc`/`dumpSrc` — reuse those directly so `mkConfiguredSrc` is not
  # re-instantiated in every mkGhc invocation (`built = mkGhc {}` and each
  # `evalWith.${sys}` variant are distinct invocations).  Only cross / cross-eval
  # builds a separate eval-platform tree.
  evalIsBuild = !isCrossTarget && !isCrossHost
             && evalSystem == pkgs.stdenv.hostPlatform.system;
  configuredSrcEval = if evalIsBuild then configuredSrc else mkConfiguredSrc evalPackages;
  dumpSrcEval       = if evalIsBuild then dumpSrc       else mkDumpSrc evalPackages configuredSrcEval;
  # Boot-lib (name, version) list parsed from the merged stage2 project.  Read
  # from the EVAL tree — `urlBootPkgsFrom` does `readFile`, which realises the
  # tree at eval; the build tree must never be realised on a foreign eval host.
  urlBootPkgs       = urlBootPkgsFrom configuredSrcEval;

  bootGhcName      = "ghc9103";
  # Boot from nixpkgs' GHC 9.10.3, not haskell.nix's own ghc9103.  nixpkgs'
  # aarch64-darwin ghc9103 is fully cached in cache.nixos.org (0 builds),
  # whereas haskell.nix's must be built from source (~32 derivations on
  # darwin).  It is the same GHC version, so the stage1 bootstrap is
  # equivalent.  `p.haskell.compiler` is the nixpkgs compiler set; haskell.nix
  # routes cabalProject / haskell-nix.tool through the `compilerSelection` hook
  # (modules/cabal-project.nix) — the same nixpkgs-boot pattern already used
  # for v2-cabal-install and the iserv-proxy tools (overlays/haskell.nix,
  # overlays/bootstrap.nix).
  #
  # The eval-time dummy GHC (lib/dummy-ghc.nix) reads `ghc.raw-src` to source
  # boot-package `.cabal` files during plan-to-nix, and that source derivation
  # is system-specific.  A haskell.nix compiler carries an
  # `evalWith.${evalSystem}` variant whose `raw-src` is the *eval* platform's;
  # a plain nixpkgs compiler has no such variant, so its `raw-src` tracks the
  # *build* platform.  When Hydra evaluates a foreign-system job on the eval
  # host (e.g. the x86_64-linux ghc914-sh jobs evaluated on aarch64-darwin),
  # that would drag a build-platform (x86_64-linux) `raw-src` into the eval-host
  # plan-to-nix — the exact eval-time cross realisation we must avoid.  The GHC
  # source is platform-independent, so override `raw-src` to the eval-platform
  # compiler's copy: plan-to-nix stays on the eval host, while the actual build
  # compiler (its outPath is untouched by `//`) remains build-platform.  No-op
  # when evalSystem == build system (native), where the two `raw-src`s coincide.
  bootCompilerSelection = p:
    let evalCompilers = evalPackages.haskell.compiler;
    in builtins.mapAttrs (name: ghc:
         if ghc ? raw-src && evalCompilers ? ${name}
         then ghc // { raw-src = evalCompilers.${name}.raw-src; }
         else ghc
       ) p.haskell.compiler;
  bootGhc               = pkgs.buildPackages.haskell.compiler.${bootGhcName};
  # (ghcVersion* constants hoisted to the outer `let`.)

  # ── Cross-compilation detection ──────────────────────────────────────────
  # isCrossTarget: targetPlatform != hostPlatform
  #   e.g. pkgsCross.wasi32.buildPackages (host=native, target=wasm32)
  #   → we must BUILD a cross-targeting ghc914-sh here
  # isCrossHost: buildPlatform != hostPlatform
  #   e.g. pkgsCross.wasi32 (build=native, host=wasm32)
  #   → can't build a compiler that runs on wasm32; skip
  isCrossTarget = pkgs.stdenv.targetPlatform != pkgs.stdenv.hostPlatform;
  isCrossHost   = pkgs.stdenv.buildPlatform != pkgs.stdenv.hostPlatform;

  # Target platform for cross-compilation settings
  tp = pkgs.stdenv.targetPlatform;

  # (hp / buildTriple / buildArch / buildOS / buildVendor / ghcUnregisterised /
  # tablesNextToCode and ghc914-shSrc hoisted to the outer `let`.)

  # ── source-repository-packages ────────────────────────────────────────────
  # The stable-haskell GHC source lists Cabal (from the stable-haskell fork,
  # pinned by SHA in the stage cabal.project files), hpc-bin and hsc2hs as
  # source-repository-packages in its stage1 / stage2 cabal.project files.
  # Rather than let cabal fetch them during evaluation (which fails in pure
  # mode — especially for the branch-tagged Cabal), map each to a pinned
  # lazy-input via inputMap.  The key is "${location}/${tag}" verbatim (see
  # fetchPackageRepo in lib/call-cabal-project-to-nix.nix); supplying it makes
  # haskell.nix use the pre-fetched source root and skip git rev resolution
  # (subdirs like Cabal/Cabal-syntax are appended by haskell.nix itself).
  # hsc2hs is no longer an in-tree submodule (upstream dropped submodules);
  # its source — including data/template-hsc.h, which the compiler packaging
  # steps install into lib/ghc-*/ — comes from the ghc914-sh-hsc2hs lazy-input,
  # with haskell.nix's fix to its batch cross-compilation (overlays/hsc2hs.nix).
  hsc2hsSrc = pkgs.haskell-nix.hsc2hs-patched-src;

  srpInputMap = {
    "https://github.com/stable-haskell/Cabal.git/f2e0a89e15cf6604cec9d93e26a4b3caf459b076" =
      pkgs.haskell-nix.sources.ghc914-sh-cabal;
    "https://github.com/stable-haskell/hpc-bin.git/5923da3fe77993b7afc15b5163cffcaa7da6ecf5" =
      pkgs.haskell-nix.sources.ghc914-sh-hpc-bin;
    "https://github.com/stable-haskell/hsc2hs.git/d07eea1260894ce5fe456f881fbc62366c9eb1b7" =
      pkgs.haskell-nix.hsc2hs-patched-src;
  };

  # ── External tools (built with boot GHC) ──────────────────────────────────
  # alex and happy are needed by compiler/Setup.hs (via +build-tool-depends)
  # to generate the parser/lexer files for the GHC compiler package.
  alexTool  = pkgs.haskell-nix.tool bootGhcName "alex"  { version = "3.5.2.0"; inherit evalSystem; compilerSelection = bootCompilerSelection; };
  happyTool = pkgs.haskell-nix.tool bootGhcName "happy" { version = "2.1.5";   inherit evalSystem; compilerSelection = bootCompilerSelection; };

  # genprimopcode is built from the GHC 9.14 in-tree source because the boot
  # GHC 9.10.3's copy doesn't understand attributes new in 9.14 (e.g.
  # defined_bits).  It only depends on base + array, with alex/happy for
  # Lexer.x / Parser.y (resolved from Hackage by haskell-nix.tool).
  genPrimopCodeTool = pkgs.haskell-nix.tool bootGhcName "genprimopcode" {
    src = "${configuredSrc}/utils/genprimopcode";
    # Read the tool's `.cabal` from an eval-platform configured tree so its
    # plan-to-nix does not force a build-platform `configuredSrc` at eval time.
    evalSrc = "${configuredSrcEval}/utils/genprimopcode";
    inherit evalSystem;
    compilerSelection = bootCompilerSelection;
  };

  # deriveConstants is built from the GHC 9.14 in-tree source for the same
  # reason as genprimopcode: the boot GHC 9.10.3's copy generates
  # GHC.Platform.Constants.hs with fewer constants than GHC 9.14 expects.
  # Stage1's compiler/Setup.hs calls deriveConstants to generate
  # GHC.Platform.Constants.hs; if boot GHC's deriveConstants runs instead
  # (because the boot bin dir is first in PATH), the resulting stage1 GHC
  # binary's parseConstantsHeader expects N_9.10 constants.  Stage2
  # rts.preConfigure then calls s1exe "deriveConstants" (GHC 9.14 version)
  # to generate DerivedConstants.h with N_9.14 > N_9.10 constants → panic
  # "Invalid platform constants" during the rts-lib-rts install phase.
  # Prepending this tool to PATH in preConfigure ensures the in-tree (9.14)
  # deriveConstants is used, so both .hs and .h files are generated with the
  # same N_9.14 constant count.
  deriveConstantsTool = pkgs.haskell-nix.tool bootGhcName "deriveConstants" {
    src = "${configuredSrc}/utils/deriveConstants";
    evalSrc = "${configuredSrcEval}/utils/deriveConstants";
    inherit evalSystem;
    compilerSelection = bootCompilerSelection;
  };

  # ── Stage 1 ───────────────────────────────────────────────────────────────
  # Builds GHC executables (ghc, ghc-pkg, ghc-toolchain-bin, …) using the
  # boot compiler.  The +bootstrap flag on ghc/ghci/ghc-boot/ghc-boot-th-next
  # avoids any dependency on ghc-internal.

  stage1Project = pkgs.haskell-nix.cabalProject' {
    name                 = "ghc914-sh-stage1";
    inputMap             = srpInputMap;
    # Boot-lib deps are pinned via direct hackage tarball URLs in the source's
    # cabal.project; rewrite them to local store paths (fetched via hackage.nix)
    # so plan-to-nix needs no network and no matching index-state.
    replace-hackage-tarball-urls = true;
    # NOTE: stage1 (unlike stage2/cross) does NOT set active-repositories: :none
    # — it resolves some boot tools (e.g. hpc) from hackage — so it needs the
    # full prepopulated index and must NOT set prepopulateHackageIndex = false.
    src                  = srcNoFilter configuredSrc;
    # Read `.cabal` files for plan-to-nix from an eval-platform configured tree
    # (avoids an eval-time build-platform dependency; see mkConfiguredSrc).
    evalSrc              = configuredSrcEval;
    cabalProjectFileName = "cabal.project.stage1.merged";
    compiler-nix-name    = bootGhcName;
    compilerSelection    = bootCompilerSelection;
    inherit evalSystem;
    # Stage1 only needs executables.  Disable tests/benchmarks so cabal
    # doesn't try to resolve test-only deps that conflict (e.g. temporary
    # conflicts with directory-1.3.10.0 via file-io's test suite).
    configureArgs = "--disable-tests --disable-benchmarks";
    modules = [{
      # The upstream cabal.project.stage1 leaves internal-interpreter at
      # its default (False), so GHCi.Debugger (which FFI-imports RTS
      # debugger symbols like rts_enableStopNextBreakpointAll that don't
      # exist in the boot GHC's RTS) is not compiled.
      # configuration-nix.nix forces the flag to true (for
      # reinstallableLibGhc); mkForce overrides that for stage1.
      # Must be disabled on BOTH ghci and ghc: ghc's Plugins.hs imports
      # GHCi.ObjLink behind #if HAVE_INTERNAL_INTERPRETER, and that
      # module is only exposed by ghci when the flag is true.
      packages.ghci.flags.internal-interpreter = lib.mkForce false;
      packages.ghc.flags.internal-interpreter = lib.mkForce false;
      # libffi-clib uses build-type: Configure with AX_ENABLE_BUILDDIR in its
      # configure.ac.  When configure is run from the source directory
      # (srcdir = "."), AX_ENABLE_BUILDDIR re-execs in a host-triple
      # subdirectory (e.g. aarch64-apple-darwin25.3.0/) so all generated
      # files — including libffi-clib.buildinfo — land there, NOT in the
      # package root.
      #
      # Cabal's autoconfUserHooks.confHook calls getHookedBuildInfo which reads
      # libffi-clib.buildinfo from the package root.  Fix: run configure in
      # preConfigure, then promote all three generated artifacts to the package
      # root BEFORE autoconfUserHooks.confHook runs.  autoconfUserHooks will
      # re-run configure (which regenerates the files in the subdirectory,
      # NOT overwriting our root copies) and then find the pre-promoted
      # libffi-clib.buildinfo in the root.
      #
      # The .buildinfo contains asm-sources: src/aarch64/sysv.S (on AArch64),
      # which defines _ffi_closure_trampoline_table_page.  Without this symbol,
      # GHC 9.14 binaries crash on macOS with "symbol not found in flat namespace".
      packages.libffi-clib.preConfigure = ''
        # The hackage sdist ships ./configure without the executable bit; the
        # nixpkgs configurePhase runs it directly, so restore +x first.
        chmod +x configure
        ./configure 2>&1 | tail -3 || true
        # AX_ENABLE_BUILDDIR puts all generated files into a host-triple
        # subdirectory.  Promote them to the package root.
        fficonfig=$(find . -maxdepth 2 -name fficonfig.h 2>/dev/null | head -1)
        [ -n "$fficonfig" ] && cp "$fficonfig" include/fficonfig.h
        build_dir=$(dirname "$fficonfig" 2>/dev/null)
        [ -f "$build_dir/include/ffi.h" ] && cp "$build_dir/include/ffi.h" include/ffi.h
        [ -f "$build_dir/libffi-clib.buildinfo" ] && cp "$build_dir/libffi-clib.buildinfo" libffi-clib.buildinfo
      '';

      # ghc-boot/Setup.hs embeds a git commit hash.  It reads $GIT_COMMIT_ID
      # from the environment first; only if that is unset does it call `git`.
      # There is no git repo in the Nix sandbox, so provide a dummy value.
      packages.ghc-boot.preConfigure = ''
        export GIT_COMMIT_ID="0000000000000000000000000000000000000000"
      '';

      # ── packages.ghc setup isolation ─────────────────────────────────────
      # The stage1 cabal.project includes `packages: libraries/Cabal/Cabal`,
      # so Cabal 3.14+ is built from source and is NOT in preExistingPkgs.
      # Without an override, the ghc setup's package DB gets Cabal 3.14+
      # (from the plan) instead of the boot GHC's Cabal 3.12.  The boot
      # GHC 9.10.3's Setup.hs (set by configuration-nix.nix) uses Cabal
      # 3.12 API (FilePath-based), which is incompatible with Cabal 3.14+
      # (SymbolicPath-based).
      #
      # Fix: override nonReinstallablePkgs so Cabal (and friends) come from
      # the boot GHC's package DB, and clear setup-depends so the plan's
      # Cabal 3.14+ doesn't leak into the setup's package DB.
      nonReinstallablePkgs = [
        "rts" "ghc-prim" "integer-gmp" "integer-simple" "base"
        "ghc-bignum" "system-cxx-std-lib" "ghc-internal"
        "ghc-boot" "ghc" "Cabal" "array" "binary" "bytestring"
        "containers" "deepseq" "directory" "filepath" "ghc-boot-th"
        "ghc-compact" "ghc-heap" "hpc" "mtl" "parsec" "pretty"
        "process" "stm" "exceptions" "semaphore-compat" "os-string"
        "template-haskell" "text" "time" "transformers" "unix"
        "xhtml" "terminfo"
      ];
      packages.ghc.components.setup.depends = lib.mkForce [];
      packages.ghc.package.setup-depends = lib.mkForce [];

      # ghc-boot also has build-type: Custom — its Setup.hs imports
      # System.Directory, System.FilePath, Distribution.System.  Without
      # clearing setup.depends, both the boot GHC and plan versions of
      # directory, filepath, Cabal-syntax end up in the setup's package
      # DB, causing "Ambiguous module name" errors.
      packages.ghc-boot.components.setup.depends = lib.mkForce [];
      packages.ghc-boot.package.setup-depends = lib.mkForce [];

      # ── packages.ghc source override ───────────────────────────────────────
      # Stage1 must build GHC 9.14's compiler library from the configured
      # source, not the boot GHC's.  Point packages.ghc.src at the in-tree
      # compiler/.  mkOverride 49 keeps priority over any mkForce (50) that
      # a future haskell.nix default might introduce for packages.ghc.src.
      packages.ghc.src = lib.mkOverride 49 (configuredSrc + "/compiler");

      # setup-builder.nix compiles Setup.hs directly with `ghc --make`,
      # NOT via Cabal, so MIN_VERSION_* macros are not auto-generated.
      # GHC 9.14's Setup.hs uses #if MIN_VERSION_Cabal(3,14,0) etc.
      # Insert the macro definition AFTER language pragmas but BEFORE the
      # first #if directive.  The macro evaluates to TRUE for Cabal 3.12
      # (boot GHC) which is what the setup actually compiles against.
      packages.ghc.components.setup.preBuild = ''
        if [ -f Setup.hs ]; then
          awk '/^#if/ && !ins {print "#define MIN_VERSION_Cabal(a,b,c) ((a)<3||((a)==3&&((b)<12||((b)==12&&(c)<=1))))"; ins=1} {print}' Setup.hs > Setup.hs.tmp
          mv Setup.hs.tmp Setup.hs
        fi
      '';

      # The ghc library's Setup.hs invokes genprimopcode and deriveConstants.
      # The boot GHC 9.10.3's copies predate GHC 9.14 (genprimopcode doesn't
      # understand 'defined_bits'; deriveConstants generates fewer platform
      # constants).  The boot GHC's bin dir comes first in PATH so
      # build-tools resolution won't help; explicitly prepend the in-tree
      # versions in preConfigure so they shadow any boot-installed copies.
      packages.ghc.preConfigure = ''
        export PATH=${genPrimopCodeTool}/bin:${deriveConstantsTool}/bin:$PATH
      '';

      # Two patches to GHCi/Message.hs and GHCi/Run.hs needed when
      # bootstrapping with GHC 9.10.x (base-4.20):
      #
      # (1) GHCi/Message.hs — Binary ClosureType orphan instance:
      #   When HAVE_GHC_INTERNAL is set (impl(ghc > 9.10)), InfoProv has 8
      #   fields including GHC.Internal.ClosureTypes.ClosureType.  Neither
      #   boot ghc-internal-9.1003.0 nor the in-tree source provides a Binary
      #   instance for ClosureType; add it as an orphan (Generic default).
      #
      # (2) GHCi/Run.hs — catchNoPropagate / rethrowIO stubs:
      #   These functions were added in base-4.21 (GHC 9.12).  When building
      #   with boot GHC 9.10.x (base-4.20) they are absent.  Provide trivial
      #   implementations: catchNoPropagate = catch  and  rethrowIO = throwIO.
      #   base-4.20 already allows catching ExceptionWithContext via `catch`,
      #   and ExceptionWithContext is a valid Exception, so throwIO works too.
      packages.ghci.prePatch = ''
        # ── (1) GHCi/Message.hs ─────────────────────────────────────────────
        awk '/^import GHC.InfoProv$/{
          print
          print "#ifdef HAVE_GHC_INTERNAL"
          print "import GHC.Internal.ClosureTypes (ClosureType)"
          print "#endif"
          next
        }1' GHCi/Message.hs > GHCi/Message.hs.tmp \
          && mv GHCi/Message.hs.tmp GHCi/Message.hs

        awk '/^instance Binary InfoProv where$/{
          print "#ifdef HAVE_GHC_INTERNAL"
          print "instance Binary ClosureType"
          print "#endif"
        }1' GHCi/Message.hs > GHCi/Message.hs.tmp \
          && mv GHCi/Message.hs.tmp GHCi/Message.hs

        # ── (2) GHCi/Run.hs ─────────────────────────────────────────────────
        awk '/^rethrow :: EvalOpts -> IO a -> IO a$/{
          print "#if !MIN_VERSION_base(4,21,0)"
          print "catchNoPropagate :: IO a -> (ExceptionWithContext SomeException -> IO a) -> IO a"
          print "catchNoPropagate = catch"
          print "rethrowIO :: ExceptionWithContext SomeException -> IO a"
          print "rethrowIO = throwIO"
          print "#endif"
        }1' GHCi/Run.hs > GHCi/Run.hs.tmp \
          && mv GHCi/Run.hs.tmp GHCi/Run.hs
      '';
    }];
  };

  s1 = stage1Project.hsPkgs;

  # Convenience: path to a stage1 executable.
  s1exe = pkg: exe: s1.${pkg}.components.exes.${exe}.exePath;

  # Programs rts's configure locates via AC_PATH_PROG (DERIVE_CONSTANTS,
  # GENAPPLY, PYTHON, NM, OBJDUMP) — put on the build PATH via the rts
  # components' build-tools (see the stage2 rts module).
  rtsConfigureTools = [
    deriveConstantsTool
    s1.genapply.components.exes.genapply
    pkgs.buildPackages.python3
    pkgs.stdenv.cc.bintools.bintools
  ];

  # Assemble the stage1 compiler: wrapper scripts that override the package DB
  # path (cabal puts the wrong GhcLibDir into the compiled-in settings), plus
  # an empty package DB (stage2 lists all packages as local so cabal builds
  # them all from source).
  # makeCompilerDeps wraps the runCommand derivation with a cachedDeps
  # attribute (a build-time derivation that runs `ghc-pkg list` and records
  # package IDs/versions).  Wrapping here (rather than relying on the
  # cache-compiler-deps overlay) ensures cachedDeps is present on the local
  # let binding used by stage2Project's ghcOverride — without it every
  # stage2 library build emits "WARNING: ghc.cachedDeps not found".
  stage1Compiler =
    let rawDrv = pkgs.runCommand "ghc914-sh-stage1-compiler" {
      passthru = {
        version              = ghcVersion;
        targetPrefix         = "";
        haskellCompilerName  = "ghc-${ghcVersion}";
        isHaskellNixCompiler = true;
        # Built with `cabalProject` rather than hadrian; consumed by
        # `ghc-boot-packages-src-and-nix` to skip the source-tree boot-package
        # machinery (see the comment there).
        isStableHaskell      = true;
        libDir               = "lib/ghc-${ghcVersion}";
        project              = stage1Project;
        # comp-builder.nix:44 accesses ghc.enableShared to decide whether to
        # build shared Haskell libraries -- which this compiler has no boot
        # library for (see `enableSharedStage2`).
        enableShared         = enableSharedStage2;
        # What `fixRtsWays` wrote into this compiler's settings, echoed back by
        # the plan-time dummy (lib/dummy-ghc.nix) so the two agree.
        rtsWays              = shRtsWaysValue;
        # cabal.project.stage1 hard-sets `shared: False` /
        # `executable-dynamic: False` and has no .dynamic variant.
        ghcIsDynamic         = false;
        # call-cabal-project-to-nix.nix:297 reads raw-src to locate bundled
        # package .cabal files.  Our eval-platform configured tree is the
        # fully-patched GHC source with all .cabal files generated, which is
        # exactly what is needed.  Plain value for THIS compiler's eval platform;
        # consumers reach another platform via `evalWith.${evalSystem}.raw-src`.
        raw-src              = configuredSrcEval;
        # The eval-time dummy ghc/ghc-pkg pair for THIS compiler's eval platform,
        # built once here (plain passthru, prebuilt-depends = []) and reached as
        # `ghc.evalWith.${evalSystem}.dummyGhcPkgs`.  call-cabal-project-to-nix
        # falls back to inline construction when a project adds prebuilt-depends.
        dummyGhcPkgs         = import ../lib/dummy-ghc.nix {
          pkgs = final; ghc = stage1Compiler; inherit evalPackages;
        };
        # builder/default.nix:29 uses `ghc.buildGHC or ghc` for setup-builder.
        # Setup.hs compilation (for buildType: Configure/Custom packages) requires
        # `base` and `Cabal` to be registered in the GHC's package DB.  Our
        # stage1Compiler has an empty package DB, so we direct setup-builder to
        # use the boot GHC (which has these packages) instead.
        #
        # The ghc package's custom Setup.hs imports containers (Data.Map).
        # The stage1/stage2 modules clear packages.ghc.{components.setup,
        # package.setup}-depends so the setup's package DB only contains
        # packages from the boot GHC's nonReinstallablePkgs — avoiding the
        # ghc-internal-9.1400.0 "Invalid platform constants" panic.
        buildGHC             = bootGhc;
        # `evalWith` (final block) is built from `override`; consumers select
        # `ghc.evalWith.${evalSystem}` rather than calling `.override` directly.
        # override references the outer stage1Compiler (with cachedDeps) so
        # callers always get the fully-formed version.
        override             = args: (mkGhc ({ inherit evalSystem; } // args)).stage1Compiler;
      };
      # Make bintools (ranlib, nm, ar, otool, install_name_tool) available in
      # PATH so ghc-toolchain-bin can auto-discover them.  Also make the C
      # compiler wrapper available so cc/c++ are in PATH.
      nativeBuildInputs = [ pkgs.stdenv.cc pkgs.stdenv.cc.bintools.bintools ];
    } ''
    mkdir -p $out/bin
    mkdir -p $out/lib/ghc-${ghcVersion}
    # Note: do NOT mkdir package.conf.d here; ghc-pkg init creates it below.

    # ── ghc wrapper ──────────────────────────────────────────────────────────
    # Pass -no-global-package-db so GHC ignores the compiled-in (wrong) libdir
    # and uses our empty package DB instead.
    #
    # NOTE: -no-rts is NOT baked into the wrapper.  It's needed during stage2
    # boot library builds (to bypass GHC 9.14's mkUnitState check for rts
    # sub-libraries) but must NOT be applied globally — executable linking
    # (e.g. ghc-bin) needs the RTS.  Instead, -no-rts is passed per-package
    # via ghcOptions in the stage2/cross modules and via cabalProjectLocal.
    cat > $out/bin/ghc << 'ENDSCRIPT'
#!/bin/sh
exec GHC_EXE \
  -no-global-package-db \
  -package-db PACKAGEDB \
  -BLIBDIR \
  "$@"
ENDSCRIPT
    sed -i \
      -e "s|GHC_EXE|${s1exe "ghc-bin" "ghc"}|" \
      -e "s|PACKAGEDB|$out/lib/ghc-${ghcVersion}/package.conf.d|" \
      -e "s|LIBDIR|$out/lib/ghc-${ghcVersion}|" \
      $out/bin/ghc
    chmod +x $out/bin/ghc

    # ghci is just ghc in interactive mode
    ln -s $out/bin/ghc $out/bin/ghci

    # Versioned alias.  The v2 builder writes `with-compiler: ghc-${ghcVersion}`
    # (comp-v2-builder.nix uses `ghc-<version>`), which cabal resolves by name
    # on PATH — a real GHC install ships this, our hand-rolled wrapper must too
    # (else Cabal-5490 "Cannot find the program 'ghc'").
    ln -s $out/bin/ghc $out/bin/ghc-${ghcVersion}

    # ── ghc-pkg wrapper ───────────────────────────────────────────────────────
    # Wrap ghc-pkg to always use our own (empty) package DB.  Without this
    # makeCompilerDeps (haskell.nix's cachedDeps mechanism) would call
    # ghc-pkg list using the compiled-in libdir of the exe derivation, which
    # has no package DB and would fail or list the wrong packages.
    cat > $out/bin/ghc-pkg << 'ENDSCRIPT'
#!/bin/sh
exec GHC_PKG_EXE \
  --no-user-package-db \
  --global-package-db PACKAGEDB \
  "$@"
ENDSCRIPT
    sed -i \
      -e "s|GHC_PKG_EXE|${s1exe "ghc-pkg" "ghc-pkg"}|" \
      -e "s|PACKAGEDB|$out/lib/ghc-${ghcVersion}/package.conf.d|" \
      $out/bin/ghc-pkg
    chmod +x $out/bin/ghc-pkg
    # Versioned alias so cabal (with-compiler: ghc-${ghcVersion}) finds the
    # matching ghc-pkg-${ghcVersion} next to it.
    ln -s $out/bin/ghc-pkg $out/bin/ghc-pkg-${ghcVersion}

    # ── Initialise empty package DB ───────────────────────────────────────────
    # Use the raw binary so the wrapper does not pass --global-package-db for
    # a path that does not yet exist.
    ${s1exe "ghc-pkg" "ghc-pkg"} init $out/lib/ghc-${ghcVersion}/package.conf.d

    # ── Additional tools needed by stage2 packages ───────────────────────────
    # hsc2hs is needed by rts-fs and other packages; unlit is a standard GHC
    # distribution tool.  ghc-for-component-wrapper lndir's the whole GHC
    # bin dir, so any tool placed here becomes available in stage2 builds.
    # (runghc is not a stage1 tool — it requires boot libraries.)
    ln -sf ${s1exe "hsc2hs" "hsc2hs"}  $out/bin/hsc2hs
    ln -sf ${s1exe "unlit"  "unlit"}   $out/bin/unlit
    # GHC 9.14 computes the unlit path as $topdir/../bin/unlit where topdir is
    # lib/ghc-9.14 (set by -B$NIX_GHC_LIBDIR in ghc-for-component-wrapper).
    # lib/ghc-9.14/../bin/unlit resolves to lib/bin/unlit, NOT bin/unlit.
    # ghc-for-component-wrapper.nix's lndir copies lib/bin/ from the unwrapped
    # GHC, so we must provide lib/bin/unlit (and hsc2hs) here.
    mkdir -p $out/lib/bin
    ln -sf ${s1exe "unlit"  "unlit"}   $out/lib/bin/unlit
    ln -sf ${s1exe "hsc2hs" "hsc2hs"} $out/lib/bin/hsc2hs

    # ── settings file (generated by ghc-toolchain-bin) ────────────────────────
    # ghc-toolchain-bin queries the C compiler and generates a settings file
    # describing the toolchain.  Stage2 needs this so GHC can invoke CC etc.
    #
    # ghc-toolchain-bin calls `sh config.sub <triple>` to normalise the target
    # triple; config.sub must be in the current directory (sh looks there for
    # non-absolute script arguments).  Copy it from the configured source tree.
    cp ${configuredSrc}/config.sub ./config.sub
    ${s1exe "ghc-toolchain-bin" "ghc-toolchain-bin"} \
      --disable-ld-override ${lib.optionalString hp.isDarwin
        # Darwin: bake `-fuse-ld=<lld>` into the settings' C-compiler link
        # flags.  ghc-toolchain's `--cc-link-opt` is the ghc-toolchain
        # equivalent of the classic builder's `CONF_GCC_LINKER_OPTS_STAGE2`
        # that `compiler/ghc/default.nix`'s `useLdLld` sets — a "user
        # specified linker flag" that Link.hs uses verbatim (no detection),
        # so it works despite `find_ld`/ghc-toolchain refusing to search for
        # lld on darwin (GHC #21712) and despite `--disable-ld-override`.
        # The dev-shell / v2-builder cctools `ld` (ld64-956.6 + clang/llvm
        # libLTO) SIGTRAPs on any Cocoa link (e.g. a jsaddle-wkwebview exe);
        # LLD is unaffected.  Absolute path so every consumer (dep slices,
        # exes, the interactive shell) links with this exact lld without
        # needing it on PATH.
        "--cc-link-opt=-fuse-ld=${pkgs.buildPackages.llvmPackages_21.lld}/bin/ld64.lld"} \
      --triple ${buildTriple} \
      --cc  $(type -P cc) \
      --cxx $(type -P c++) \
      --output-settings \
      -o $out/lib/ghc-${ghcVersion}/settings

    ${fixRtsWays "$out/lib/ghc-${ghcVersion}/settings"}
    ${addTargetDials "$out/lib/ghc-${ghcVersion}/settings"}

    ${lib.optionalString hp.isx86_64 ''
    # On x86_64, the RTS includes XXHash3 which uses 256-bit AVX2 vectors.
    # GHC 9.14's NCG can't handle 256-bit vectors.  Add -mno-avx2 to the
    # C compiler AND Cmm CPP flags so neither C files nor Cmm preprocessing
    # generates AVX2 code.  XXHash3 falls back to its 128-bit SSE2 path.
    # (Hadrian avoids this because it compiles RTS C directly with cc,
    # bypassing GHC's NCG.)
    sed -i \
      -e 's|("C compiler flags","\([^"]*\)")|("C compiler flags","\1 -mno-avx -mno-avx2")|' \
      -e 's|("C-- CPP flags","\([^"]*\)")|("C-- CPP flags","\1 -mno-avx -mno-avx2")|' \
      $out/lib/ghc-${ghcVersion}/settings
    ''}

    # ── ghcversion.h ─────────────────────────────────────────────────────────
    # The stage2 build needs the generated ghcversion.h header.
    mkdir -p $out/lib/ghc-${ghcVersion}/include
    cp ${configuredSrc}/rts/include/ghcversion.h \
       $out/lib/ghc-${ghcVersion}/include/
    '';
    in pkgs.haskell-nix.haskellLib.makeCompilerDeps rawDrv;

  # ── Stage 2 ───────────────────────────────────────────────────────────────
  # Builds all GHC boot libraries and executables using the stage1 compiler.

  stage2Project = pkgs.haskell-nix.cabalProject' {
    name                 = "ghc914-sh-stage2";
    # Build the boot libraries with the v2 builder (fork v2CabalInstall) so
    # per-file Cmm options (rts AutoApply_V32.cmm (-mavx2) etc.) are applied —
    # matching the stable-ghc-9.14 Makefile's `cabal build`.  v1's standalone
    # Setup.hs links the boot GHC's Cabal 3.12, which drops those options.
    builderVersion       = 2;
    # Build each local plan unit's slice in cabal `packages:` mode so it
    # registers the plan's deterministic unit id (`base-4.22.0.0`, ...)
    # — these registrations become the compiler's global package db,
    # which consumer plan-time dummy dumps must be able to predict.
    # See the option in modules/project-common.nix and the module-list
    # comment at the end of this project.
    v2LocalPackageSlices = true;
    inputMap             = srpInputMap;
    # Boot-lib deps are pinned via direct hackage tarball URLs in the source's
    # cabal.project; rewrite them to local store paths (fetched via hackage.nix)
    # so plan-to-nix needs no network and no matching index-state.
    replace-hackage-tarball-urls = true;
    # With everything pinned locally and active-repositories: :none, cabal
    # resolves nothing from hackage — but it still parses the prepopulated index
    # on startup, so the full ~1.2 GB index is a large, needless plan-to-nix cost
    # (seconds natively, minutes under emulation).  Prepopulate an empty index.
    prepopulateHackageIndex = false;
    src                  = srcNoFilter configuredSrc;
    # Eval-platform configured tree for plan-to-nix (see mkConfiguredSrc).
    evalSrc              = configuredSrcEval;
    cabalProjectFileName = "cabal.project.stage2.merged";
    # Use the stage1 compiler (exported as ghc914-sh-stage1) to build
    # all stage2 boot libraries and executables.
    compiler-nix-name    = "ghc914-sh-stage1";
    inherit evalSystem;
    # The plan step passes --enable-tests --enable-benchmarks by default.
    # GHC 9.14's base-4.22 is not yet in the transitive test-dep closure of
    # packages like `unix` (splitmix upper-bounds), so resolution would fail.
    # Disable tests and benchmarks for the plan step; they are not needed for
    # building the boot libraries.
    configureArgs = "--disable-tests --disable-benchmarks";

    # NOTE: do NOT re-enable Hackage here.  stable-haskell intentionally sets
    # `active-repositories: :none` in cabal.project.stage2.common — every boot
    # library and build tool (alex, happy, happy-lib, ...) is pinned as a direct
    # hackage tarball URL in the packages: stanza, and `replace-hackage-tarball-urls`
    # (set above) rewrites each to a local store path fetched via hackage.nix.  So
    # cabal resolves the whole plan from local packages + source-repository-packages
    # and needs no Hackage index.  Re-enabling it would force cabal to load the
    # entire ~1.2 GB index to resolve zero packages — a large, needless plan-to-nix
    # cost (worse still under emulation on a foreign build platform).
    #
    # The -no-rts ghc-options for rts, rts-fs, rts-headers, ghc-internal,
    # and libffi-clib are already set in cabal.project.stage2 (which imports
    # cabal.project.common).  Since commit a695b259d, configure-args.nix
    # extracts these from plan.json automatically — no need to duplicate
    # them here or in modules.
    # ghc-bin's `debug` flag defaults to True in the stable-haskell fork
    # (ghc/ghc-bin.cabal.in), which links the final `ghc` executable against
    # rts:threaded-debug; upstream GHC has no such flag and ships a non-debug
    # (rts_thr) compiler.  Force -debug for a release-shaped (rts_thr) compiler:
    # the debug RTS carries assertions + heap sanity checks and is slower.  This
    # is purely a perf/release choice — NOT the WHITEHOLE crash fix (both RTS
    # ways are crash-free once the source fix below is in place; verified 0/20
    # on each).  Could instead be flipped upstream (ghc-bin.cabal.in `Default:
    # False`, or cabal.project.stage2.common).
    #
    # The WHITEHOLE `ghc --make -jN` crash (THREADED_RTS not reaching the RTS
    # Cmm CPP) is fixed at the
    # source — rts.cabal's rts-threaded-flags gained `cmm-options:
    # -optc-DTHREADED_RTS` (stable-haskell/ghc#191, merged to stable-ghc-9.14) —
    # so no `package rts` ghc-options workaround is needed here.
    cabalProjectLocal = ''
      ${bootLibProfiling}
      package ghc-bin
        flags: -debug
      package haskeline
        flags: +terminfo
      package text
        flags: +simdutf
    '';

    modules = [{
      # The ghc package's custom Setup.hs imports containers, directory,
      # filepath, Cabal, process — all boot packages.  These must be in
      # nonReinstallablePkgs so makeSetupConfigFiles copies them from the
      # boot GHC's package DB (not from the plan, which would resolve to
      # stage2-built versions that depend on ghc-internal-9.1400.0).
      #
      # The nonReinstallablePkgs option uses lib.last merge (last def wins).
      # component-driver.nix sets it from preExistingPkgs (which is non-empty
      # from the plan), ignoring reinstallableLibGhc.  We must override it
      # directly with the full list of boot packages.
      #
      # For library builds this is safe: make-config-files copies these from
      # the GHC's package DB, but the stage1Compiler has an empty DB, so
      # nothing is found.  The plan's deps are then used via library.depends.
      nonReinstallablePkgs = [
        "rts" "ghc-prim" "integer-gmp" "integer-simple" "base"
        "ghc-bignum" "system-cxx-std-lib" "ghc-internal"
        "ghc-boot" "ghc" "Cabal" "array" "binary" "bytestring"
        "containers" "deepseq" "directory" "filepath" "ghc-boot-th"
        "ghc-compact" "ghc-heap" "hpc" "mtl" "parsec" "pretty"
        "process" "stm" "exceptions" "semaphore-compat" "os-string"
        "template-haskell" "text" "time" "transformers" "unix"
        "xhtml" "terminfo"
      ];

      # libffi-clib: same AX_ENABLE_BUILDDIR fix as stage1.  Run configure in
      # preConfigure and promote the generated files (fficonfig.h, ffi.h, and
      # libffi-clib.buildinfo) to the package root so autoconfUserHooks finds
      # libffi-clib.buildinfo there and picks up the platform-specific asm-sources.
      packages.libffi-clib.preConfigure = ''
        # The hackage sdist ships ./configure without the executable bit; the
        # nixpkgs configurePhase runs it directly, so restore +x first.
        chmod +x configure
        ./configure 2>&1 | tail -3 || true
        fficonfig=$(find . -maxdepth 2 -name fficonfig.h 2>/dev/null | head -1)
        [ -n "$fficonfig" ] && cp "$fficonfig" include/fficonfig.h
        build_dir=$(dirname "$fficonfig" 2>/dev/null)
        [ -f "$build_dir/include/ffi.h" ] && cp "$build_dir/include/ffi.h" include/ffi.h
        [ -f "$build_dir/libffi-clib.buildinfo" ] && cp "$build_dir/libffi-clib.buildinfo" libffi-clib.buildinfo
      '';

      # Several GHC bundled libraries (ghc-internal, unix, directory, process,
      # time, terminfo) use build-type: Configure with configure.ac entries
      # containing AC_CONFIG_AUX_DIR([..]) — they expect config.guess,
      # config.sub, install-sh etc. in the PARENT directory.  In the Nix
      # per-package sandbox the parent is an empty temp dir.  Copy the
      # auxiliary files from configuredSrc's top-level (where the top-level
      # autoreconf placed them) to ../ so configure can find them.
      packages.ghc-internal.preConfigure = ''
        for f in install-sh config.sub config.guess depcomp mkinstalldirs; do
          [ -f ${configuredSrc}/$f ] && cp ${configuredSrc}/$f ../ || true
        done
        # Ensure include/ is populated so configure can find md5.h.
        mkdir -p include
        cp -f ${configuredSrc}/libraries/ghc-internal/include/*.h include/ 2>/dev/null || true
        # The configure.ac check AC_CHECK_SIZEOF([struct MD5Context],[],
        # [#include "include/md5.h"]) fails in the Nix sandbox even when
        # include/md5.h is present.  Export the source root's include path
        # via CPPFLAGS so that Cabal's autoconfUserHooks inherits it and
        # the conftest can find "include/md5.h" from the source root.
        export CPPFLAGS="-I$(pwd) ''${CPPFLAGS:-}"
        # Also seed config.cache with the known size in case configure runs
        # from a different working directory (where it creates a new cache).
        echo 'ac_cv_sizeof_struct_MD5Context=88' > config.cache
      '';
      packages.unix.preConfigure = ''
        for f in install-sh config.sub config.guess depcomp mkinstalldirs; do
          [ -f ${configuredSrc}/$f ] && cp ${configuredSrc}/$f ../ || true
        done
      '';
      packages.directory.preConfigure = ''
        for f in install-sh config.sub config.guess depcomp mkinstalldirs; do
          [ -f ${configuredSrc}/$f ] && cp ${configuredSrc}/$f ../ || true
        done
      '';
      packages.process.preConfigure = ''
        for f in install-sh config.sub config.guess depcomp mkinstalldirs; do
          [ -f ${configuredSrc}/$f ] && cp ${configuredSrc}/$f ../ || true
        done
      '';
      packages.time.preConfigure = ''
        for f in install-sh config.sub config.guess depcomp mkinstalldirs; do
          [ -f ${configuredSrc}/$f ] && cp ${configuredSrc}/$f ../ || true
        done
      '';
      packages.terminfo.preConfigure = ''
        for f in install-sh config.sub config.guess depcomp mkinstalldirs; do
          [ -f ${configuredSrc}/$f ] && cp ${configuredSrc}/$f ../ || true
        done
      '';

      # The per-package source root is extracted from the raw ghc914-sh source
      # (git checkout), which does not include the autoreconf-generated
      # configure script.  Copy it from configuredSrc (where rts autoreconf
      # was run) so autoconfUserHooks can run it to generate ghcautoconf.h,
      # DerivedConstants.h, AutoApply*.cmm.h, EventLog*.h, and rts.buildinfo.
      #
      # rts/configure.ac uses AC_PATH_PROG for five external programs
      # (mirrored from the stable-ghc-9.14/Makefile STAGE2_CABAL_BUILD):
      #   DERIVE_CONSTANTS  – stage1 deriveConstants tool
      #   GENAPPLY          – stage1 genapply tool
      #   NM                – nm (from bintools)
      #   OBJDUMP           – objdump (from bintools)
      #   PYTHON            – python3 (for EventLog header generation)
      # Setting them here ensures they are in the cabal-build environment that
      # Cabal's autoconfUserHooks.confHook inherits when it calls ./configure.
      # The per-package source root is an isolated rts/ directory extracted
      # from configuredSrc.  The rts configure.ac uses AC_CONFIG_AUX_DIR([..])
      # so the generated configure script searches for autoconf auxiliary files
      # (install-sh, config.sub, config.guess) in the PARENT directory.  In the
      # per-package source root layout there is no parent containing these files.
      #
      # Copy the auxiliary files from the configuredSrc top level (where the
      # top-level autoreconf placed them) to "../" (= one level above the rts/
      # source root in the Nix build sandbox) so configure can find them.
      #
      # Running configure explicitly in preConfigure generates ghcautoconf.h,
      # DerivedConstants.h, AutoApply*.cmm.h, and rts/EventLog*.h into
      # $PWD/include/ (= the mutable source copy).  Cabal's install phase
      # looks for install-includes files in the source root's include-dirs
      # ("include" and "."), so the generated headers must be there.
      #
      # autoconfUserHooks also calls configure (with --srcdir=...) — this is
      # harmless since configure is idempotent; it also succeeds because
      # $srcdir/.. = configuredSrc has install-sh.
      packages.rts.preConfigure = ''
        for f in install-sh config.sub config.guess depcomp mkinstalldirs; do
          [ -f ${configuredSrc}/$f ] && cp ${configuredSrc}/$f ../ || true
        done
        cp ${configuredSrc}/rts/configure .
        chmod +x configure
        export DERIVE_CONSTANTS=${s1exe "deriveConstants" "deriveConstants"}
        export GENAPPLY=${s1exe "genapply" "genapply"}
        export NM=${pkgs.stdenv.cc.bintools.bintools}/bin/nm
        export OBJDUMP=${pkgs.stdenv.cc.bintools.bintools}/bin/objdump
        export PYTHON=${pkgs.python3}/bin/python3
        # rts/configure.ac uses AC_DEFINE_UNQUOTED([USE_LIBDW], [$CABAL_FLAG_libdw])
        # and similar for other flags.  If the CABAL_FLAG_xxx variable is unset,
        # AC_DEFINE_UNQUOTED emits '#define USE_LIBDW' with no value, and clang
        # then rejects '#if USE_LIBDW' with "expected value in expression".
        # Set numeric (0/1) values here; Cabal's autoconfUserHooks inherits them
        # when it calls configure again in the configure phase.
        export CABAL_FLAG_libdw=0
        export CABAL_FLAG_libbfd=0
        export CABAL_FLAG_libzstd=0
        export CABAL_FLAG_static_libzstd=0
        export CABAL_FLAG_libnuma=0
        export CABAL_FLAG_unregisterised=0
        export CABAL_FLAG_tables_next_to_code=${if tablesNextToCode == "YES" then "1" else "0"}
        export CABAL_FLAG_leading_underscore=${if hp.isDarwin then "1" else "0"}
        ./configure
      '';

      # The v2 builder runs rts's configure through cabal itself (no
      # preConfigure hook, and cabal exports the CABAL_FLAG_* env
      # natively), so the five AC_PATH_PROG programs above must be
      # discoverable on the slice's PATH instead.  build-tools feed both
      # builders' PATHs (v1: make-config-files; v2: the slice's
      # extraNativeBuildInputs); the env-var exports in preConfigure
      # still win for v1 (AC_PATH_PROG checks the variable first).
      # configure runs per SLICE, so the flavour sublibs need the tools
      # as much as the main library does.
      packages.rts.components.library.build-tools = rtsConfigureTools;
      packages.rts.components.sublibs = lib.genAttrs
        [ "nonthreaded-nodebug" "threaded-nodebug"
          "nonthreaded-debug" "threaded-debug" ]
        (_: { build-tools = rtsConfigureTools; });

      # ghc-boot has build-type: Custom.  Its Setup.hs:
      # 1. Embeds a git commit hash via confHook — reads $GIT_COMMIT_ID
      # 2. Generates GHC/Platform/Host.hs via postConf
      # Both work naturally with the Custom Setup.hs; we just need to
      # provide GIT_COMMIT_ID (no git in the Nix sandbox).
      packages.ghc-boot.preConfigure = ''
        export GIT_COMMIT_ID="0000000000000000000000000000000000000000"
      '';

      # ── packages.ghc source override ───────────────────────────────────────
      # In stage2 the ghc source comes from configuredSrc (GHC 9.14), not
      # the boot GHC (9.10.3).  mkOverride 49 keeps priority over any
      # mkForce (50) default a future haskell.nix might set.
      packages.ghc.src = lib.mkOverride 49 (configuredSrc + "/compiler");

      # ── packages.ghc setup isolation ─────────────────────────────────────
      # The custom Setup.hs imports Data.Map (containers).  In the stage2
      # plan, containers resolves to the local GHC 9.14 version which
      # transitively depends on ghc-internal-9.1400.0.  The boot GHC
      # (9.10.3) compiles Setup.hs and panics when it encounters
      # ghc-internal-9.1400.0 in the setup's package DB ("Invalid platform
      # constants").
      #
      # Fix: clear setup depends so the setup's package DB only contains
      # packages from the boot GHC's package DB (via nonReinstallablePkgs).
      # The boot GHC has containers, Cabal, base, directory, filepath,
      # process — everything the custom Setup.hs needs.
      packages.ghc.components.setup.depends = lib.mkForce [];
      packages.ghc.package.setup-depends = lib.mkForce [];
      packages.ghc-boot.components.setup.depends = lib.mkForce [];
      packages.ghc-boot.package.setup-depends = lib.mkForce [];

      # setup-builder.nix compiles Setup.hs directly with `ghc --make`,
      # NOT via Cabal, so the MIN_VERSION_* macros are not auto-generated.
      # GHC 9.14's Setup.hs uses #if MIN_VERSION_Cabal(3,14,0) etc.
      # Insert the macro definition AFTER language pragmas (GHC scans
      # pragmas first, then runs CPP) but BEFORE the first #if directive.
      packages.ghc.components.setup.preBuild = ''
        if [ -f Setup.hs ]; then
          awk '/^#if/ && !ins {print "#define MIN_VERSION_Cabal(a,b,c) ((a)<3||((a)==3&&((b)<12||((b)==12&&(c)<=1))))"; ins=1} {print}' Setup.hs > Setup.hs.tmp
          mv Setup.hs.tmp Setup.hs
        fi
      '';

      # GHC's compiler package has build-type: Custom.  The custom Setup.hs
      # generates primop-*.hs-incl, GHC/Platform/Constants.hs, and
      # GHC/Settings/Config.hs in its postConf hook.  It calls
      # genprimopcode and deriveConstants from PATH.  Prepend the in-tree
      # (9.14) versions so they shadow any boot-installed copies (same
      # approach as stage1).
      packages.ghc.preConfigure = ''
        export PATH=${genPrimopCodeTool}/bin:${deriveConstantsTool}/bin:$PATH
      '';

      # compiler/Setup.hs calls alex and happy to generate parser/lexer source
      # (needed when +build-tool-depends flag is set on the ghc library).
      # Although cabalProjectLocal re-enables Hackage so cabal can resolve
      # build-tool-depends automatically, we also add them explicitly here as a
      # belt-and-braces measure.
      packages.ghc.components.library.build-tools = [
        alexTool
        happyTool
      ];

      # GHC 9.14's ghc-pkg reads a settings file at startup (for ABI hash
      # validation etc.).  It computes the settings path from a compiled-in
      # topdir — on Unix, getBaseDir returns Nothing so the topdir is
      # hardcoded at build time to the derivation output, i.e.
      # $out/lib/settings.  Without a settings file, ANY ghc-pkg invocation
      # (including `recache`) fails with:
      #   "Settings file doesn't exist: <ghc-pkg-derivation>/lib/settings"
      # Provide the settings file in the ghc-pkg derivation output via
      # postInstall so that we can use the raw binary for `recache` when
      # assembling the final ghc914-shCompiler.
      # GHC 9.14's ghc and ghc-pkg binaries read a settings file at startup.
      # On Unix, getBaseDir returns Nothing so the topdir is the compiled-in
      # derivation output path ($out/lib/settings).  Without it, ANY invocation
      # fails with "Settings file doesn't exist".
      # Provide the settings file in each exe derivation via postInstall.
      packages.ghc-pkg.components.exes.ghc-pkg.postInstall = ''
        mkdir -p $out/lib
        cp ${stage1Compiler}/lib/ghc-${ghcVersion}/settings $out/lib/settings
      '';
      packages.ghc-bin.components.exes.ghc.postInstall = ''
        mkdir -p $out/lib
        cp ${stage1Compiler}/lib/ghc-${ghcVersion}/settings $out/lib/settings
      '';
    }
    # GHC 9.14's unit resolver checks that all dependencies listed in .conf
    # files are present in the package DB.  When a package's per-component DB
    # contains ghc-internal.conf, GHC follows its depends field and expects to
    # find rts:nonthreaded-nodebug (baked in by GHC 9.14's unit wiring).  If
    # it is absent, GHC fails with:
    #   <command line>: unknown unit: rts:nonthreaded-nodebug (dependency of ghc-internal)
    #
    # Fix: set `additional-prebuilt-depends` at the PACKAGE level (not
    # components.library) so it applies to ALL component types (library,
    # exes, tests, etc.) via the package → component option inheritance.
    #
    # Excluded packages (to avoid circular dependency through
    # rts:nonthreaded-nodebug's own dependency chain):
    #   rts, libffi-clib, rts-fs, rts-headers  — deps of rts:nonthreaded-nodebug
    #
    # The three other rts sub-libs (threaded-nodebug, nonthreaded-debug,
    # threaded-debug) have `build-depends: rts` and are handled via
    # cabalProjectLocal with `ghc-options: -no-rts` (which bypasses the
    # mkUnitState wiring check).
    ({ config, lib, ... }: let
        # Not every target has all four RTS ways (the JS backend builds only
        # nonthreaded-nodebug), so look the sublibs up tolerantly.
        rtsSublibs = lib.filter (x: x != null)
          (map (n: config.hsPkgs.rts.components.sublibs.${n} or null) [
            "nonthreaded-nodebug"
            "threaded-nodebug"
            "nonthreaded-debug"
            "threaded-debug"
          ]);
        # Every package that (transitively) depends on base has
        # ghc-internal.conf in its per-component package DB.
        # ghc-internal.conf depends on ALL rts sub-libraries via GHC 9.14's
        # unit wiring.  We must add them to the package DB of every package.
        #
        # We cannot use `builtins.attrNames config.packages` here because
        # that creates infinite recursion (config.packages depends on these
        # settings).  Use a static list instead.
        #
        # Excluded (rts:nonthreaded-nodebug's own dep closure):
        #   rts, libffi-clib, rts-fs, rts-headers
        pkgsNeedingRts = [
          # Core boot libraries:
          "ghc-prim" "ghc-bignum" "ghc-internal" "base" "array" "binary"
          "bytestring" "containers" "deepseq" "exceptions" "filepath"
          "ghc-boot-th" "ghc-compact" "ghc-experimental" "ghc-heap"
          "hpc" "integer-gmp" "mtl" "os-string" "parsec" "pretty"
          "process" "semaphore-compat" "stm" "template-haskell" "text"
          "time" "transformers" "unix" "xhtml" "terminfo" "directory"
          "file-io" "haskeline"
          # GHC compiler packages:
          "ghc" "ghc-boot" "ghc-boot-th-next" "ghc-platform" "ghci"
          "ghc-toolchain" "Cabal" "Cabal-syntax"
          "haddock-api" "haddock-library"
          # Exe packages:
          "ghc-bin" "ghc-pkg" "hsc2hs" "runghc" "unlit"
          "ghc-toolchain-bin" "haddock"
          "genprimopcode" "deriveConstants"
          # Hackage build-tool deps (also rebuilt in stage2):
          "happy-lib" "happy" "alex"
        ];
      in {
        # Package-level: inherited by ALL component types via package → component
        # option inheritance (package.nix passes options via lib.mkDefault).
        # Filter to only include packages actually present in the plan.
        packages = lib.genAttrs
          (lib.filter (name: config.packages ? ${name}) pkgsNeedingRts)
          (_: { additional-prebuilt-depends = rtsSublibs; });
    })
    {

      # The rts package's install phase invokes GHC (ghcLink = LinkExecutable
      # Dynamic), which would panic in GHC 9.14's mkUnitState because the rts
      # sub-libraries (rts:nonthreaded-nodebug etc.) are not yet registered.
      # The primary fix is -no-rts in the stage1 wrapper (see stage1Compiler
      # above).  These two settings are additional mitigations that suppress
      # the GHC invocations that trigger the panic:
      #
      # 1. enableLibraryForGhci = false: sets the haskell.nix component
      #    parameter directly so comp-builder.nix emits --disable-library-for-ghci
      #    (without also emitting --enable-library-for-ghci).  This prevents
      #    Cabal from calling GHC to create the GHCi merged .o file.
      #
      # 2. configureFlags = ["--disable-shared"]: prevents Cabal from invoking
      #    GHC to build the rts shared library (.dylib).  The rts shared
      #    library is not needed for a functional stage2 compiler.
      packages.rts.components.library.enableLibraryForGhci = false;
      packages.rts.components.library.configureFlags = ["--disable-shared"];
      # -no-rts for rts, rts-fs, rts-headers, ghc-internal, libffi-clib is
      # now handled by cabal.project.stage2 ghc-options stanzas, extracted
      # automatically via configure-args.nix.  Only unlit still needs it
      # here (it's not covered by the cabal.project files).
      packages.unlit.ghcOptions = ["-no-rts"];
    }
    # Boot-library unit ids MUST be deterministic: a consumer project's
    # plan-time dummy `ghc-pkg dump` (lib/dummy-ghc.nix) has to present
    # the same installed ids cabal later sees against the real global db
    # — a dep's id enters the depending unit's `--dependency=<dep>=<id>`
    # configure arg and therefore its UnitId hash, so with unpredictable
    # boot-lib ids the v2 slice builder's plan-nix/slice unit-id equality
    # can never hold for projects built with this compiler.  The fork
    # elaborates `packages:`-local units to deterministic ids
    # (`base-4.22.0.0`, `rts-1.0.3-threaded-nodebug`, ...), and
    # `v2LocalPackageSlices = true` (set above) makes each slice build
    # its target the same local way, so the ids each slice REGISTERS
    # equal the plan's — enforced per slice by the unit-id check.
    # (A previous `--ipid=\$pkgid-inplace` `configureFlags` module here
    # became a silent no-op when stage2 moved to the v2 builder — v2
    # only applies configure options recorded in plan-nix — leaving the
    # global db with unpredictable hashed ids.)
  ];
  };

  s2 = stage2Project.hsPkgs;

  # Convenience: path to a stage2 executable.
  s2exe = pkg: exe: s2.${pkg}.components.exes.${exe}.exePath;

  # haddock-api's library slice, which carries haddock's resource
  # directory (`share/{html,latex,doc}`) under its cabal-store unit dir.
  # `null` when the stage2 plan has no haddock-api (then the `haddock`
  # link below stays a plain symlink).
  haddockApiLib =
    if s2 ? haddock-api && s2.haddock-api.components ? library
    then s2.haddock-api.components.library
    else null;

  # For each boot library, the path to its registered .conf file(s).
  # We check `s2 ? name` first to handle any packages missing from the plan.
  # Look a boot library up in a project's hsPkgs by VERSIONED key when we
  # know the version (the hackage-URL boot libs, via urlBootPkgs).  On
  # Windows the plan legitimately contains a SECOND version of some boot
  # libs (cabal breaks the Win32 → hsc2hs → process → Win32 build-tool
  # cycle with an older universe inside the Win32:hsc2hs:exe scope), so the
  # name-only redirect throws "Multiple versions".  The versioned key picks
  # the real (local) unit; the exe-scope duplicates remain private to the
  # tool build, as cabal intends.
  bootLibKey = name:
    let p = lib.findFirst (p: p.name == name) null urlBootPkgs;
    in if p == null then name else "${name}-${p.version}";

  bootLibConfs = lib.concatMap (name:
    let
      key     = bootLibKey name;
      hasPkg  = s2 ? ${key};
      hasLib  = hasPkg && (s2.${key}.components ? library);
      # Component OUTPUT roots — the assembly script's `copyBootConfs`
      # finds the conf(s) inside, handling both the v1 layout
      # (`$out/package.conf.d`) and the v2 slice layouts (`$out/store/...`).
      libDrv  = lib.optionalString hasLib "${s2.${key}.components.library}";
    in lib.optional hasLib libDrv
  ) bootLibraries
  # Include rts sub-libraries so the final compiler's package DB contains
  # rts:nonthreaded-nodebug etc.  These are needed for GHC 9.14's mkUnitState
  # wiring when users compile projects with ghc914-sh.
  ++ lib.optionals (s2 ? rts && s2.rts.components ? sublibs) (
    lib.concatMap (sublibName:
      let hasSub = s2.rts.components.sublibs ? ${sublibName};
      in lib.optional hasSub
           "${s2.rts.components.sublibs.${sublibName}}"
    ) [ "nonthreaded-nodebug" "threaded-nodebug" "nonthreaded-debug" "threaded-debug" ]
  );

  # Copy every boot-lib component's package conf(s) into the compiler's
  # global DB, resolving layout differences:
  #  * v1 components expose `$compOut/package.conf.d` with absolute paths;
  #  * v2 slices keep the conf inside their cabal store —
  #    `store/ghc-*/package.db` (mainline cabal) or the stable-haskell
  #    fork's staged `store/host/<platform>/package.conf.d` — with
  #    `''${pkgroot}`-relative fields, which we resolve against the
  #    slice's store dir while copying (composed dep units are reachable
  #    next to the db through the slice's lndir symlinks).
  copyBootConfsFn = ''
    copyBootConfs() {
      local compOut=$1 db pkgrootDir conf
      if [ -d "$compOut/package.conf.d" ]; then
        cp "$compOut/package.conf.d"/*.conf \
           $out/lib/ghc-${ghcVersion}/package.conf.d/ 2>/dev/null || true
        return 0
      fi
      for db in "$compOut"/store/ghc-*/package.db \
                "$compOut"/store/host/*/package.conf.d; do
        [ -d "$db" ] || continue
        pkgrootDir=$(dirname "$db")
        for conf in "$db"/*.conf; do
          [ -e "$conf" ] || continue
          sed "s|\''${pkgroot}|$pkgrootDir|g" "$conf" \
            > $out/lib/ghc-${ghcVersion}/package.conf.d/$(basename "$conf")
        done
      done
    }
  '';

  # ── Final ghc914-sh compiler ────────────────────────────────────────────────
  ghc914-shCompiler =
    let rawDrv = pkgs.runCommand "ghc914-sh-compiler" {
      passthru = {
        version              = ghcVersion;
        targetPrefix         = "";
        haskellCompilerName  = "ghc-${ghcVersion}";
        isHaskellNixCompiler = true;
        # Built with `cabalProject` rather than hadrian; consumed by
        # `ghc-boot-packages-src-and-nix` to skip the source-tree boot-package
        # machinery (see the comment there).
        isStableHaskell      = true;
        libDir               = "lib/ghc-${ghcVersion}";
        # No shared way of any boot library is built (see
        # `enableSharedStage2`), so this is False and `RTS ways` carries no dyn
        # family.
        enableShared         = enableSharedStage2;
        rtsWays              = shRtsWaysValue;
        # The stage2 `ghc` binary is statically linked, and -- the part that is
        # not obvious -- `GHC Dynamic` follows the rts it links, not that link
        # mode: it is `rts_isDynamic()`, so `constraints: rts +dynamic` alone
        # would flip it.  Both halves have to be told the truth separately.
        ghcIsDynamic         = false;
        # stage2 builds text with +simdutf (see cabalProjectLocal), so the
        # installed text depends on system-cxx-std-lib.  The dummy ghc-pkg
        # dump synthesis reads this to add that depends edge (the flag
        # conditional in text.cabal is invisible to it).
        enableTextSimdutf    = true;
        # Real `ghc --info` "Project Unit Id" — the ghc library's unit id.
        # The stage2 plan elaborates the local `ghc` unit to the plain
        # MUNGED `ghc-<version>` id and its local-mode slice registers the
        # same (v2LocalPackageSlices).  dummy-ghc.nix emits this value so
        # cabal's plan-time view matches the real compiler (it defaults to
        # ghc-<full-version>-inplace otherwise).
        projectUnitId        = "ghc-${ghcVersion}";
        # call-cabal-project-to-nix.nix:297 reads raw-src to synthesise the
        # dummy ghc-pkg dump for plan-time.  Use the dump tree (configuredSrc +
        # the hackage-pinned boot libraries' .cabal files) so user-project plans
        # see the full installed-package set.  Plain value for THIS compiler's
        # eval platform; another platform is reached via
        # `evalWith.${evalSystem}.raw-src`.
        raw-src              = dumpSrcEval;
        # Eval-time dummy pair for THIS compiler's eval platform (plain passthru,
        # prebuilt-depends = []); reached as `evalWith.${evalSystem}.dummyGhcPkgs`.
        dummyGhcPkgs         = import ../lib/dummy-ghc.nix {
          pkgs = final; ghc = ghc914-shCompiler; inherit evalPackages;
        };
        # The stage2 boot-lib project, for debugging single boot libs
        # (e.g. `…compiler.ghc914-sh.stage2Project.hsPkgs.rts.components
        # .sublibs.nonthreaded-nodebug`) without assembling the compiler.
        inherit stage2Project;
        # The stage1 project (ghc-bin and friends, built with the boot GHC).
        inherit stage1Project;
        # The plan-nix derivations that must be realised (via IFD) to
        # evaluate this compiler.  `haskell-nix.roots` links them (and the
        # `evalWith` variant's when the eval system differs from the build
        # system) so CI pushes them to the binary cache and later
        # evaluations substitute the plans instead of building them mid-eval.
        plan-nixes           = {
          stage1 = stage1Project.plan-nix;
          stage2 = stage2Project.plan-nix;
        };
        # The bare configured tree on the BUILD platform, for consumers that
        # want the source (e.g. the cross section's nativeConfiguredSrc), not
        # the dump view.
        configured-src       = configuredSrc;
        # The bare configured tree on THIS compiler's EVAL platform, for
        # consumers that read .cabal files at plan time (the cross section's
        # nativeConfiguredSrcEval, the boot-package injection in
        # modules/cabal-project.nix).  A different eval platform is reached via
        # `evalWith.${evalSystem}.configured-src-eval`.
        configured-src-eval  = configuredSrcEval;
        # override references the outer ghc914-shCompiler (with cachedDeps).
        override             = args: (mkGhc ({ inherit evalSystem; } // args)).ghc914-shCompiler;
      };
    } ''
    mkdir -p $out/bin
    mkdir -p $out/lib/ghc-${ghcVersion}

    # ── Executables ──────────────────────────────────────────────────────────
    # -B matters: without it topdir falls back to the libdir baked into the
    # ghc-bin exe derivation, which ships only a settings file — so
    # $topdir-relative tool lookups (unlit at $topdir/../bin/unlit, needed
    # for literate sources like happy's) fail.  Callers that need a
    # different libdir (ghc-for-component-wrapper's -B$NIX_GHC_LIBDIR)
    # still win: GHC honours the LAST -B on the command line and "$@"
    # comes after ours.
    cat > $out/bin/ghc << 'ENDSCRIPT'
#!/bin/sh
exec GHC_EXE \
  -no-global-package-db \
  -package-db PACKAGEDB \
  -BLIBDIR \
  "$@"
ENDSCRIPT
    sed -i \
      -e "s|GHC_EXE|${s2exe "ghc-bin" "ghc"}|" \
      -e "s|PACKAGEDB|$out/lib/ghc-${ghcVersion}/package.conf.d|" \
      -e "s|LIBDIR|$out/lib/ghc-${ghcVersion}|" \
      $out/bin/ghc
    chmod +x $out/bin/ghc

    ln -s $out/bin/ghc $out/bin/ghci

    # ── ghc-pkg wrapper ───────────────────────────────────────────────────────
    # Wrap ghc-pkg to always use our populated package DB.  This lets
    # makeCompilerDeps (haskell.nix's cachedDeps mechanism) enumerate the
    # boot libraries by running `ghc-pkg list` with the right package DB.
    cat > $out/bin/ghc-pkg << 'ENDSCRIPT'
#!/bin/sh
exec GHC_PKG_EXE \
  --no-user-package-db \
  --global-package-db PACKAGEDB \
  "$@"
ENDSCRIPT
    sed -i \
      -e "s|GHC_PKG_EXE|${s2exe "ghc-pkg" "ghc-pkg"}|" \
      -e "s|PACKAGEDB|$out/lib/ghc-${ghcVersion}/package.conf.d|" \
      $out/bin/ghc-pkg
    chmod +x $out/bin/ghc-pkg

    ln -sf ${s2exe "hsc2hs"  "hsc2hs"}  $out/bin/hsc2hs
    ln -sf ${s2exe "unlit"   "unlit"}   $out/bin/unlit

    # ── runghc wrapper ────────────────────────────────────────────────────────
    # runghc has to be TOLD where ghc is; a bare symlink cannot tell it.
    # Given no `-f`, runghc calls `getExecPath` and looks for `ghc` -- and
    # failing that `ghc-stage2` -- next to its own *resolved* executable
    # (utils/runghc/Main.hs, `findGhc`).  `getExecPath` follows symlinks, so
    # `ln -s` lands that search in the runghc component's own store dir,
    # whose bin/ contains nothing but runghc, and every invocation dies with
    #   runghc: /nix/store/…-runghc-exe-runghc-9.14.0/bin/ghc-stage2:
    #   executeFile: does not exist (No such file or directory)
    # A real bindist never hits this: there `ghc` is a real sibling file.
    # `tests.shell-for.run` and `tests.with-packages.run` are the jobs that
    # notice (both call `''${env.ghc}/bin/runghc`), on both platforms.
    #
    # Callers that pass their own `-f` still win, exactly as with `-B` in the
    # `ghc` wrapper above: runghc's flag monoid keeps the LAST `-f`
    # (`RunGhcFlags _ <> right@(RunGhcFlags (Just _)) = right`), and `"$@"`
    # comes after ours -- so ghc-for-component-wrapper.nix's
    # `-f $wrappedGhc/bin/ghc` is unaffected.
    #
    # It points at `$out/bin/ghc`, not at the bare ghc-bin exe, so the
    # `-package-db`/`-B` that wrapper supplies still apply.  That is also
    # what makes the v2 shell work: it exposes deps through GHC_ENVIRONMENT,
    # an env var, which survives the exec into `$out/bin/ghc` -- the same
    # composition its own `ghc` wrapper already relies on.
    cat > $out/bin/runghc << 'ENDSCRIPT'
#!/bin/sh
exec RUNGHC_EXE -f RUNGHC_GHC "$@"
ENDSCRIPT
    sed -i \
      -e "s|RUNGHC_EXE|${s2exe "runghc" "runghc"}|" \
      -e "s|RUNGHC_GHC|$out/bin/ghc|" \
      $out/bin/runghc
    chmod +x $out/bin/runghc

    # `hpc` comes from the `hpc-bin` source-repository-package the fork's
    # stage2 project lists (srpInputMap above), and a real bindist installs
    # it next to ghc.  haskell.nix's coverage reports put the compiler on
    # PATH and then just run `hpc` (lib/cover.nix:94), so without this link
    # every coverage job dies at the very end with
    #   line 53: hpc: command not found
    # -- `tests.coverage.run`, `tests.coverage-no-libs.run`, and the
    # per-package `*-coverage-report` drvs under them.
    ln -sf ${s2exe "hpc-bin" "hpc"}     $out/bin/hpc
    # `haddock` likewise: a real bindist installs it next to ghc, and that
    # is the only place Cabal looks -- `guessHaddockFromGhcPath` probes
    # `haddock{,-<ver>,-ghc-<ver>}` in the *configured compiler's* bin/
    # (build-cabal-slice mirrors that dir into its solver-tools farm for
    # exactly this reason).  Without the link any component built with
    # `documentation: True` dies after compiling, in the haddock phase:
    #   Error: [Cabal-7620]
    #   The program 'haddock' version >=2.0 is required but it could not
    #   be found.
    # -- `tests.sublib-docs.run` and every other doc-enabled slice.  The
    # exe is already built (utils/haddock is in the fork's stage2
    # project, and `haddock` is in pkgsNeedingRts above); it was just
    # never linked in.
    ${lib.optionalString (s2 ? haddock) (if haddockApiLib == null then ''
    ln -sf ${s2exe "haddock" "haddock"} $out/bin/haddock
    '' else ''
    # ...but a bare symlink is not enough, for the same reason `runghc`
    # above needs a wrapper: the stage2 haddock-api is built with
    # `+in-ghc-tree` (see the `flags:` fragment in its slice), so
    # `Haddock.getHaddockLibDir` takes the `#ifdef IN_GHC_TREE` branch and
    # asks GHC's `getBaseDir` where the resources are -- i.e.
    # `dirname(dirname(realpath(argv0)))/lib` -- instead of consulting the
    # Cabal-generated `Paths_haddock_api` datadir.  `getExecutablePath`
    # follows the symlink, so that resolves inside the *haddock exe's own
    # slice*, which has no `lib/`, and haddock dies just before writing
    # html with
    #   Haddock's resource directory does not exist!
    # (only the last two fallbacks -- the relative `resources` and
    # `haddock-api/resources` of a source checkout -- are tried, and both
    # miss).  cabal reports that as `Warning: Failed to build documentation
    # for <unit>` and then does NOT install the unit, so the slice's
    # unit-id check fails with "Missing (in plan but not produced)"
    # -- `tests.sublib-docs.run` and every other doc-enabled slice.
    #
    # A real bindist has haddock next to ghc with the resources in
    # `lib/`, which is precisely what we reconstruct here: copy the
    # resource dir out of haddock-api's slice and pass it as `--lib`.
    # Callers that supply their own `--lib` still win: `getHaddockLibDir`
    # keeps the LAST `Flag_Lib`, and `"$@"` comes after ours.
    haddockRes=
    for d in ${haddockApiLib}/store/*/*/lib/haddock-api-*/share; do
      if [ -d "$d/html" ]; then haddockRes=$d; break; fi
    done
    if [ -z "$haddockRes" ]; then
      echo "ERROR: haddock resources not found under ${haddockApiLib}" >&2
      exit 1
    fi
    mkdir -p $out/lib/haddock
    cp -RL "$haddockRes"/. $out/lib/haddock/
    chmod -R u+w $out/lib/haddock
    cat > $out/bin/haddock << 'ENDSCRIPT'
#!/bin/sh
exec HADDOCK_EXE --lib=HADDOCK_LIB "$@"
ENDSCRIPT
    sed -i \
      -e "s|HADDOCK_EXE|${s2exe "haddock" "haddock"}|" \
      -e "s|HADDOCK_LIB|$out/lib/haddock|" \
      $out/bin/haddock
    chmod +x $out/bin/haddock
    '')}

    # Versioned aliases, as in a standard GHC bindist (a real bindist of
    # this source would install ghc-${ghcVersion}).  Tooling relies on the
    # versioned names: ghc-for-component-wrapper.nix wraps ghc-${ghcVersion}
    # when present, comp-v2-builder writes `with-compiler: ghc-${ghcVersion}`
    # (= ghc-<passthru.version>, resolved on PATH), and cabal's
    # "tool near compiler" lookup probes `<tool>-<numeric-version>` names.
    v=${ghcVersion}
    ln -s $out/bin/ghc     $out/bin/ghc-$v
    ln -s $out/bin/ghci    $out/bin/ghci-$v
    ln -s $out/bin/ghc-pkg $out/bin/ghc-pkg-$v
    ln -s $out/bin/runghc  $out/bin/runghc-$v
    ln -s $out/bin/hpc     $out/bin/hpc-$v
    ${lib.optionalString (s2 ? haddock) ''
    ln -s $out/bin/haddock $out/bin/haddock-ghc-$v
    ''}
    # GHC 9.14 looks for unlit at $topdir/../bin/unlit where topdir = lib/ghc-9.14
    # (set via -B$NIX_GHC_LIBDIR in ghc-for-component-wrapper.nix).
    # lib/ghc-9.14/../bin/ resolves to lib/bin/, so unlit must be there.
    # ghc-for-component-wrapper lndir's the compiler then re-links lib/bin/
    # if it exists, so we provide lib/bin/{unlit,hsc2hs} here.
    mkdir -p $out/lib/bin
    ln -sf ${s2exe "unlit"   "unlit"}   $out/lib/bin/unlit
    ln -sf ${s2exe "hsc2hs"  "hsc2hs"} $out/lib/bin/hsc2hs
    # ghc-iserv lands here for the same reason, and is found the same way:
    # GHC resolves the external interpreter as $topdir/../bin/ghc-iserv, so
    # `-fexternal-interpreter` (and anything that implies it) dies with
    #   .../lib/ghc-9.14/../bin/ghc-iserv: createProcess: posix_spawnp:
    #   does not exist (No such file or directory)
    # unless lib/bin/ghc-iserv exists.  utils/ghc-iserv is a package in the
    # fork's cabal.project.stage2, so the exe is already built -- it was just
    # never linked into the compiler.  A real bindist installs it in libexec
    # (= lib/bin here), not in bin/, so it goes only here.
    ${lib.optionalString (s2 ? ghc-iserv) ''
    ln -sf ${s2exe "ghc-iserv" "ghc-iserv"} $out/lib/bin/ghc-iserv
    ''}
    # ...and the profiling flavour.  GHC resolves the external interpreter as
    # $topdir/../bin/ghc-iserv-prof whenever the splice is compiled -prof, so
    # `-fexternal-interpreter` + profiling needs this one too.  Built from the
    # duplicated utils/ghc-iserv-prof package (see mkConfiguredSrc) because
    # utils/ghc-iserv has a single exe and no flags.
    ${lib.optionalString (s2 ? ghc-iserv-prof) ''
    ln -sf ${s2exe "ghc-iserv-prof" "ghc-iserv-prof"} $out/lib/bin/ghc-iserv-prof
    ''}

    # ── settings + support files ─────────────────────────────────────────────
    # Copy settings BEFORE ghc-pkg init/recache — the stage2 ghc-pkg binary
    # (built with GHC 9.14) expects a settings file at $libdir/settings.
    cp ${stage1Compiler}/lib/ghc-${ghcVersion}/settings \
       $out/lib/ghc-${ghcVersion}/settings

    # ── Package DB ───────────────────────────────────────────────────────────
    # Populate package DB with .conf files from all stage2-built boot
    # libraries, then recache.
    #
    # The stage2 ghc-pkg binary has a settings file at its derivation
    # output ($out/lib/settings) thanks to the postInstall hook above.
    # Use it directly with --global-package-db to point at our output DB.
    mkdir -p $out/lib/ghc-${ghcVersion}/package.conf.d

    ${copyBootConfsFn}
    for compOut in ${lib.concatStringsSep " " bootLibConfs}; do
      copyBootConfs "$compOut"
    done

    ${s2exe "ghc-pkg" "ghc-pkg"} recache \
      --no-user-package-db \
      --global-package-db $out/lib/ghc-${ghcVersion}/package.conf.d
    cp -r ${stage1Compiler}/lib/ghc-${ghcVersion}/include \
          $out/lib/ghc-${ghcVersion}/include
    cp ${hsc2hsSrc}/data/template-hsc.h \
       $out/lib/ghc-${ghcVersion}/template-hsc.h
    cp ${configuredSrc}/driver/ghc-usage.txt  $out/lib/ghc-${ghcVersion}/
    cp ${configuredSrc}/driver/ghci-usage.txt $out/lib/ghc-${ghcVersion}/
    '';
    in pkgs.haskell-nix.haskellLib.makeCompilerDeps rawDrv;

  # ═══════════════════════════════════════════════════════════════════════════
  # ── Cross-compilation support (isCrossTarget) ──────────────────────────────
  # Active when targetPlatform != hostPlatform, i.e. in
  # pkgsCross.wasi32.buildPackages (host=native, target=wasm32).
  #
  # The stable-haskell GHC is a runtime multi-target compiler, so no cross
  # GHC is built: `crossCompiler` (below) registers the target inside a
  # symlink copy of the native ghc914-sh and wraps its binaries with
  # `-B<wrapper libdir> -target=<triple>`.  Boot libraries for the target
  # are NOT shipped with the compiler — each project's cabal plan builds
  # them from source (boot-package injection in modules/cabal-project.nix
  # plus the empty target dummy dump in lib/call-cabal-project-to-nix.nix).
  # ═══════════════════════════════════════════════════════════════════════════

  # The native ghc914-sh compiler, already built for the build platform.
  # In case 2, buildPackages = (native, native, native) = case 1.
  # Thread evalSystem so the native bootstrap's own plan-to-nix runs on the
  # eval platform too (the built binaries are unchanged — evalSystem is
  # eval-only); otherwise a cross build evaluated on a foreign host (e.g. ucrt64
  # from darwin) ships the bootstrap plans to a build-platform builder.  Select
  # the per-eval-system native compiler variants (memoised attribute selection),
  # NOT `.override` (function application, re-evaluated per call).
  nativeSghc914       = pkgs.buildPackages.haskell-nix.compiler.ghc914-sh.evalWith.${evalSystem};
  nativeStage1        = pkgs.buildPackages.haskell-nix.compiler."ghc914-sh-stage1".evalWith.${evalSystem};
  # The bare configured source tree on the BUILD platform (NOT the dump view —
  # raw-src points at the dump tree, which must not leak into build inputs or
  # every cross derivation would change with it).  Used for build-time
  # references (${nativeConfiguredSrc}/… copies in the crossCompiler assembly,
  # boot package sources).
  nativeConfiguredSrc = nativeSghc914.configured-src;
  # The same bare configured tree built on the EVAL platform, for plan-to-nix
  # evalSrc (so reading .cabal files at plan time needs no build-platform IFD).
  nativeConfiguredSrcEval = nativeSghc914.configured-src-eval;

  # ghc-toolchain-bin from the native stage1 build (runs natively).
  nativeGhcToolchainBin =
    nativeStage1.project.hsPkgs.ghc-toolchain-bin.components.exes.ghc-toolchain-bin.exePath;

  # Target C compiler and bintools — runs natively, targets the cross
  # platform.  pkgs.targetPackages in case 2 = pkgsCross.wasi32.
  # For ghcjs there is no targetPackages.stdenv.cc (nixpkgs ships no C
  # compiler for js-unknown-ghcjs) — referencing it throws "no C compiler
  # provided for this platform".  GHC's JS backend uses emscripten instead,
  # mirroring toolsForTarget in compiler/ghc/default.nix.
  isGhcjsTarget  = tp.isGhcjs or false;
  targetCC       = if isGhcjsTarget
    then pkgs.buildPackages.emscripten
    else pkgs.targetPackages.stdenv.cc;
  targetBintools = if isGhcjsTarget then targetCC else targetCC.bintools.bintools;
  # Tool paths used when generating the target settings and building the rts.
  # emscripten is a plain package (no cc-wrapper targetPrefix/bintools).
  targetCCPath   = if isGhcjsTarget
    then "${targetCC}/bin/emcc"
    else "${targetCC}/bin/${targetCC.targetPrefix}cc";
  targetCXXPath  = if isGhcjsTarget
    then "${targetCC}/bin/em++"
    else "${targetCC}/bin/${targetCC.targetPrefix}c++";
  targetNMPath   = if isGhcjsTarget
    then (if builtins.pathExists (targetCC + "/share/emscripten/emnm")
      then "${targetCC}/share/emscripten/emnm"
      else "${targetCC}/share/emscripten/tools/emnm.py")
    else "${targetCC.bintools}/bin/${targetCC.bintools.targetPrefix}nm";
  # Targets GHC has no native code generator for -- arm32 and friends --
  # go through the LLVM backend, and then need `llc`/`opt` and the
  # `llvm-targets` data-layout table.  Same predicate as `useLLVM`'s
  # default in compiler/ghc/default.nix, so this wrapper agrees with the
  # hadrian compilers about which targets are LLVM targets.
  targetNeedsLLVM = !(tp.isx86 || tp.isAarch64
                   || (tp.isGhcjs or false) || (tp.isWasm or false));
  # LLVM's ARM AsmPrinter reads a `Subtarget` that only `runOnMachineFunction`
  # ever sets, so it is still null for a module that defines no functions at
  # all -- and `doFinalization` still walks @llvm.global_ctors for such a
  # module, so `llc` segfaults:
  #   #3 llvm::ARMAsmPrinter::emitXXStructor(...)
  #   #4 llvm::AsmPrinter::emitXXStructorList(...)
  #   `llc' failed in phase `LLVM Compiler'. (Exit code: -11)
  # GHC produces exactly that shape: per Note [Initializers and finalizers in
  # Cmm] the initializers are C functions living in the ForeignStubs, so the
  # Haskell module carries the ctor array plus a bare declaration.  Six lines
  # of IR reproduce it and LLVM 17..21 are all affected, so there is no
  # version to move to.
  #
  # `overlays/patches/ghc-armv7a-android-llvm-fix.patch` is the other way out
  # and is already applied to the bootstrap GHCs (overlays/bootstrap.nix): it
  # makes `llvm.global_ctors` non-builtin so `aliasify` renames it and LLVM
  # never sees the special global.  That dodges the crash by not emitting the
  # initializers at all, which silently drops cost-centre / IPE / ticky / HPC
  # registration.  Patching llc keeps them working.
  #
  # Overriding here rather than in the package set keeps the rebuild to this
  # one derivation -- nothing else uses this instance, it is only ever the
  # llc/opt pair named in a cross target's settings.
  llvmForTarget   = pkgs.buildPackages.llvmPackages.llvm.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./patches/llvm-arm-asmprinter-null-subtarget.patch ];
    # LLVM's lit suite wedges on the very last of its 59920 tests on this
    # builder -- 59919 report and every one of them is clean (0 FAIL, 0 XPASS,
    # 0 UNRESOLVED, including 1522 CodeGen/ARM), then the run never returns.
    # That is a pre-existing hang, not something the patch above provokes, but
    # it costs an hour per build for a compiler we only want as the llc/opt
    # pair.  The patch's own validation is recorded in the commit message.
    doCheck = false;
  });
  targetOBJDUMPPath = if isGhcjsTarget
    then "${pkgs.buildPackages.llvmPackages.llvm}/bin/llvm-objdump"
    else "${targetCC.bintools}/bin/${targetCC.bintools.targetPrefix}objdump";

  # ── libffi for wasm ────────────────────────────────────────────────────
  # GHC 9.14's rts.cabal excludes the libffi-clib build-depends on wasm32
  # (and javascript): `if !flag(use-system-libffi) && !arch(javascript) &&
  # !arch(wasm32)`.  The wasm rts instead expects ffi.h / libffi.a from the
  # toolchain, which nixpkgs' wasi32 cc does not provide.  Build the same
  # libffi-wasm that compiler/ghc/default.nix uses for hadrian wasm builds
  # (headers in $dev/include, libffi.a/.so in $out/lib).
  libffiWasm = pkgs.buildPackages.runCommand "libffi-wasm" {
      nativeBuildInputs = [
        # Built with the ghc914-sh boot compiler (mainline pins ghc912 here,
        # but bootGhcName is already required for every other ghc914-sh tool,
        # so reusing it avoids building an extra GHC just for this).
        (pkgs.buildPackages.haskell-nix.tool bootGhcName "libffi-wasm" {
          src = pkgs.buildPackages.haskell-nix.sources.libffi-wasm;
          inherit evalSystem;
          compilerSelection = bootCompilerSelection;
        })
        pkgs.targetPackages.buildPackages.llvmPackages.clang
        pkgs.targetPackages.buildPackages.llvmPackages.llvm
        pkgs.buildPackages.binaryen
      ];
      outputs = ["out" "dev"];
      NIX_NO_SELF_RPATH = true;
    } ''
      mkdir cbits
      cp ${pkgs.buildPackages.haskell-nix.sources.libffi-wasm}/cbits/* cbits/
      libffi-wasm
      wasm32-unknown-wasi-clang -Wall -Wextra -mcpu=mvp -Oz -DNDEBUG -Icbits -c cbits/ffi.c -o cbits/ffi.o
      wasm32-unknown-wasi-clang -Wall -Wextra -mcpu=mvp -Oz -DNDEBUG -Icbits -c cbits/ffi_call.c -o cbits/ffi_call.o
      wasm32-unknown-wasi-clang -Wall -Wextra -mcpu=mvp -Oz -DNDEBUG -Icbits -c cbits/ffi_closure.c -o cbits/ffi_closure.o

      mkdir -p $dev/include
      cp cbits/*.h $dev/include
      mkdir -p $out/lib
      llvm-ar -r $out/lib/libffi.a cbits/*.o

      wasm32-unknown-wasi-clang -Wall -Wextra -mcpu=mvp -Oz -DNDEBUG -Icbits -fPIC -fvisibility=default -shared -Wl,--keep-section=target_features,--strip-debug cbits/*.c -o libffi.so
      wasm-opt --low-memory-unused --debuginfo -Os libffi.so -o $out/lib/libffi.so
    '';

  # GHC runs utils/jsffi/dyld.mjs as the wasm Template Haskell interpreter and
  # hands it ONE library directory: the last `libraries:` entry of the C
  # compiler's `-print-search-dirs`.  Upstream that is the wasi-sdk sysroot's
  # lib dir, where ghc-wasm-meta installs libffi.so next to libc.so, so the
  # dyld finds every system library there.  nixpkgs' wasilibc and our
  # libffi-wasm are separate store paths, so the dir GHC passes holds neither
  # (`findSystemLibrary(libffi.so): not found in /lib/wasm32-wasi`).  Do what
  # compiler/ghc/default.nix does for the mainline wasm GHCs: flatten both
  # into one dir (`wasmDyldLib`) and run dyld.mjs through a node wrapper
  # (`wasmDyldNode`) that substitutes that dir for GHC's argument.  The
  # wrapper also replaces dyld.mjs's `#!/usr/bin/env -S node` shebang, which
  # names a path the nix build sandbox does not have.
  wasmDyldLib = pkgs.buildPackages.runCommand "lib-wasm" { } ''
    mkdir -p $out/lib
    for d in ${pkgs.targetPackages.wasilibc}/lib ${pkgs.targetPackages.wasilibc}/lib/wasm32-wasi ${libffiWasm}/lib; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        # -f skips the per-target subdirectory and its `wasm32-wasip1` alias.
        [ -f "$f" ] || continue
        ln -sfn "$f" "$out/lib/$(basename "$f")"
      done
    done
  '';
  wasmDyldNode = pkgs.buildPackages.writeShellScriptBin "node" ''
    SCRIPT=$1
    shift
    # GHC's libdir argument; replaced by the flattened wasmDyldLib.
    shift
    exec ${pkgs.buildPackages.nodejs_24}/bin/node \
      --disable-warning=ExperimentalWarning \
      --max-old-space-size=65536 \
      --no-turbo-fast-api-calls \
      --wasm-lazy-validation \
      "$SCRIPT" \
      "${wasmDyldLib}/lib" \
      "$@"
  '';

  # ── Native tools for cross boot-package builds ────────────────────────────
  # Boot packages (rts, …) build from source inside each cross project's own
  # plan (see the boot-package injection in modules/cabal-project.nix).
  # rts/configure locates programs via AC_PATH_PROG that are not cabal-level
  # dependencies (DERIVE_CONSTANTS, GENAPPLY, NM, OBJDUMP, PYTHON); the v2
  # builder runs configure through cabal (no per-package preConfigure hooks),
  # so the injection module puts them on the rts slices' PATH via the
  # crossCompiler's `bootPkgTools` passthru.  (lib:ghc's genprimopcode /
  # deriveConstants tools are NOT needed here — they are ordinary
  # build-tool-depends satisfied from the injected utils/ subdirs, planned
  # as build-stage units.)  deriveConstants is built natively from the
  # in-tree 9.14 source, same rationale as the native deriveConstantsTool
  # above; genapply comes from the native stage1 build.
  crossDeriveConstantsTool = pkgs.buildPackages.haskell-nix.tool bootGhcName "deriveConstants" {
    src = "${nativeConfiguredSrc}/utils/deriveConstants";
    evalSrc = "${nativeConfiguredSrcEval}/utils/deriveConstants";
    inherit evalSystem;
    compilerSelection = bootCompilerSelection;
  };

  # rts/configure's AC_PATH_PROG probes look for plain `nm` / `objdump` on
  # PATH, but they must be able to read TARGET objects (deriveConstants
  # parses target .o symbols).  Cross bintools ship prefixed names only, so
  # expose unprefixed aliases.
  targetBintoolsUnprefixed = pkgs.buildPackages.runCommand
    "${tp.config}-bintools-unprefixed" { } (''
      mkdir -p $out/bin
      ln -s ${targetOBJDUMPPath} $out/bin/objdump
    '' + (if isGhcjsTarget then ''
      # emscripten's `nm` is the raw python script share/emscripten/tools/emnm.py,
      # which self-locates via `os.path.abspath(__file__)` to put
      # share/emscripten on sys.path (`from tools import shared`).  A SYMLINK
      # makes __file__ resolve to $out/bin/nm → it looks for `tools` under
      # $out/bin → `ModuleNotFoundError: No module named 'tools'`, and every
      # deriveConstants / ghc-toolchain `nm` call fails.  nixpkgs' emscripten
      # ships wrapped `bin/emar`/`bin/emranlib` (env + `exec …/emar.py`) but NO
      # `bin/emnm`, so derive an nm wrapper from the emar wrapper: same
      # environment (NODE_PATH / EM_* / locate_cache.sh) but exec emnm.py by its
      # REAL absolute path so its self-location works.
      sed 's,${targetCC}/share/emscripten/emar\.py,${targetNMPath},' \
        ${targetCC}/bin/emar > $out/bin/nm
      # If the emar wrapper's shape changed and the sed didn't match, the
      # "nm" would silently exec emar.py — fail here instead.
      grep -qF '${targetNMPath}' $out/bin/nm || {
        echo "emnm wrapper: sed pattern did not match ${targetCC}/bin/emar" >&2
        exit 1
      }
      chmod +x $out/bin/nm
    '' else ''
      ln -s ${targetNMPath} $out/bin/nm
    ''));


  # ── Cross compiler: per-target wrapper around the native ghc914-sh ────────
  # The stable-haskell GHC is a runtime multi-target compiler: `ghc
  # -target=<triple>` (ghc/Main.hs) swaps the session topdir to
  # `$topdir/targets/<triple>/lib`, so a "cross compiler" is just the NATIVE
  # compiler plus a target registration: a `settings` file naming the cross
  # toolchain, a global `package.conf.d`, and the $topdir support files.
  # This derivation creates that registration inside a symlink copy of the
  # native compiler's tree and wraps the native binaries with
  # `-B<here> -target=<triple>` — no cross-targeting GHC is built at all.
  #
  # The target's global package.conf.d is EMPTY on purpose: unlike a hadrian
  # bindist this compiler ships no target boot libraries.  Each project's
  # cabal plan builds rts, base, … from source alongside the user's own
  # packages (the stable-haskell cabal fork's build/host stage system; the
  # boot sources are injected as a source-repository-package — see the
  # boot-package injection in modules/cabal-project.nix and the empty target
  # dummy dump in lib/call-cabal-project-to-nix.nix).
  crossCompiler =
    let
      targetTriple = tp.config;
      # Raw stage2 executables of the native compiler.  The wrappers call
      # these rather than ${nativeSghc914}/bin/ghc{,-pkg} because the native
      # wrappers inject the NATIVE global package db (-package-db/
      # --global-package-db), which must not leak into a target session —
      # the target's (empty) global db is resolved from the target settings'
      # "Relative Global Package DB" under the -target topdir instead.
      nativeS2exe = pkg: exe:
        nativeSghc914.stage2Project.hsPkgs.${pkg}.components.exes.${exe}.exePath;
      # `populatedDb`: null → empty target global db (the two-stage
      # "boot-from-source" wrapper, `crossCompilerBoot`); a derivation of
      # `*.conf` files → register them into the target global db, turning this
      # into a bindist-style wrapper that ships target boot libraries (the
      # ghcjs `crossCompilerFull`, needed so GHC's JS external interpreter can
      # find the `ghci` package for Template Haskell).
      # `self`: the makeCompilerDeps-wrapped variant itself, so the plan-time
      # dummy (dummyGhcPkgs) reflects THIS variant's emptyGlobalPackageDb.
      mkRawDrv = { populatedDb ? null, self }: pkgs.buildPackages.runCommand "ghc914-sh-cross-${targetTriple}" {
      passthru = {
        version              = ghcVersion;
        targetPrefix         = "";
        haskellCompilerName  = "ghc-${ghcVersion}";
        isHaskellNixCompiler = true;
        # Built with `cabalProject` rather than hadrian; consumed by
        # `ghc-boot-packages-src-and-nix` to skip the source-tree boot-package
        # machinery (see the comment there).
        isStableHaskell      = true;
        # This `-target` wrapper links only ghc, ghc-pkg, hsc2hs and
        # friends from the native stage2: there is no target haddock, so
        # nothing built with it can have `documentation: True` (a slice
        # asking for docs warns `The program 'haddock' ... could not be
        # found`, skips the install and ships an empty unit).
        hasHaddock           = false;
        libDir               = "lib/ghc-${ghcVersion}";
        # The GHC JavaScript backend is static-only: emscripten's wasm-ld
        # rejects GHC's ELF shared-lib link flags (e.g. `-h <soname>`), so a
        # `--enable-shared` build of any lib (rts-fs, …) fails.  Never build
        # shared libraries for ghcjs (nor for static/musl).
        enableShared         = !(tp.isStatic or false) && !(tp.isMusl or false)
                            && !(tp.isGhcjs or false);
        # Same settings file and the same stage2 `ghc-bin` binary as the native
        # compiler (this is a `-target` wrapper around it), so both of these are
        # the NATIVE values -- `GHC Dynamic` describes the binary that runs, not
        # the target it emits code for.
        rtsWays              = shRtsWaysValue;
        ghcIsDynamic         = false;
        # The target registration ships NO boot libraries (see the comment
        # above).  lib/call-cabal-project-to-nix.nix keys off this to make
        # the plan-time dummy `ghc-pkg dump` empty, so cabal plans every
        # boot package (rts, base, …) from source.
        # ALWAYS true, even for the populated (ghcjs bindist) variant: the flag
        # governs PLAN resolution (empty plan-time dummy → the fork's two-stage
        # from-source boot-lib build, which is the tested path leksah relies on).
        # Populating the real wrapper's global db with ghci+closure is
        # INDEPENDENT — it only affects what GHC sees at compile time, so TH's JS
        # interpreter can resolve `ghci`.  Flipping this to false dropped leksah
        # onto haskell.nix's single-stage cross path (load-cabal-plan.nix
        # lookupExeDependency), which is under-tested here and broke on e.g.
        # old-time's build-tool resolution.
        emptyGlobalPackageDb = true;
        # `--info` "Project Unit Id" is compiled into the native binaries —
        # it does not vary with -target, so mirror the native passthru
        # (the plain `ghc-<version>` id the local-mode `ghc` slice
        # registers; see the native compiler's projectUnitId).
        projectUnitId        = "ghc-${ghcVersion}";
        # The dump view of the native compiler's source (used only for the
        # BUILD side of plan-time dummies; the target dump is empty, see
        # emptyGlobalPackageDb).  Plain values delegating to the native
        # compiler variant already selected for THIS eval platform.
        raw-src              = nativeSghc914.raw-src;
        # Eval-time dummy pair for THIS compiler's eval platform (plain passthru,
        # prebuilt-depends = []); reached as `evalWith.${evalSystem}.dummyGhcPkgs`.
        # The target dump is empty (emptyGlobalPackageDb); the build-side dummy
        # comes from buildGHC = nativeSghc914.
        dummyGhcPkgs         = import ../lib/dummy-ghc.nix {
          pkgs = final; ghc = self; inherit evalPackages;
        };
        # The bare configured GHC source tree (build platform) and its
        # eval-platform builder — the boot-package injection module reads
        # boot package sources and .cabal files from these.
        configured-src       = nativeConfiguredSrc;
        configured-src-eval  = nativeConfiguredSrcEval;
        # Evaluating the cross wrapper forces the NATIVE stage1/stage2
        # plans (the wrapper links the native stage2 executables); there
        # are no cross-specific compiler plans — boot packages are planned
        # inside each user project (see emptyGlobalPackageDb above).
        plan-nixes           = nativeSghc914.plan-nixes;
        # buildGHC is used by setup-builder.nix and make-config-files.nix
        # to compile Setup.hs natively, and by the v2 builder as the
        # build compiler of two-stage slices (`--with-build-compiler`).
        # Without it, the cross compiler itself would be used, producing
        # target binaries that can't run on the build machine.
        buildGHC             = nativeSghc914;
        # Programs rts/configure locates via AC_PATH_PROG that are not
        # cabal-level dependencies; the boot-package injection module
        # (modules/cabal-project.nix) puts them on the rts slices' PATH.
        # All run on the build machine; nm/objdump read TARGET objects.
        bootPkgTools = [
          crossDeriveConstantsTool
          nativeStage1.project.hsPkgs.genapply.components.exes.genapply
          pkgs.buildPackages.python3
          targetBintoolsUnprefixed
        ];
        # libffi for the wasm rts — referenced by the injected
        # `package rts` extra-include-dirs/extra-lib-dirs on wasm targets.
        libffi-wasm          = libffiWasm;
        override             = args: (mkGhc ({ inherit evalSystem; } // args)).crossCompiler;
      };
      nativeBuildInputs = [ targetCC targetBintools ];
    } ''
    mkdir -p $out/bin
    mkdir -p $out/lib/ghc-${ghcVersion}${lib.optionalString isGhcjsTarget ("\n" + ''
    # emcc keeps its cache in EM_CACHE, and nixpkgs' wrapper defaults that to
    # a fixed directory under /tmp (share/emscripten/locate_cache.sh):
    # `/tmp/<emscripten>_cache`, or `/tmp/_cache` when emcc is run by
    # absolute path, as ghc-toolchain-bin does below.  Darwin sandboxes share
    # /tmp, so whichever build user creates that directory first owns it
    # (mode 755), and emcc fails for every other `_nixbldN` on that machine --
    # which surfaced as ghc-toolchain's "checking whether Cc works... Command
    # failed: emcc -c" on some builders and not others.  Give this build its
    # own writable cache, as every other emscripten consumer here already does
    # (compiler/ghc/default.nix, builder/comp-builder.nix,
    # builder/build-cabal-slice.nix).
    export EM_CACHE=$(mktemp -d)
    if [ -d ${targetCC}/share/emscripten/cache ]; then
      cp -r ${targetCC}/share/emscripten/cache/* $EM_CACHE/
      chmod +w -R $EM_CACHE
    fi'')}

    # ── Native compiler tree (symlinked) ─────────────────────────────────
    # The wrapper's -B names $out/lib/ghc-${ghcVersion} as the base topdir,
    # and `-target` resolves the registration underneath it — so the base
    # must carry everything the native layout provides (native settings,
    # native global package.conf.d, include/, template-hsc.h, …) for
    # consumers that treat the wrapper as a normal compiler root, plus the
    # targets/ directory added below.
    ${pkgs.buildPackages.lndir or pkgs.buildPackages.xorg.lndir}/bin/lndir -silent \
      ${nativeSghc914}/lib/ghc-${ghcVersion} $out/lib/ghc-${ghcVersion}

    # ── Target registration ──────────────────────────────────────────────
    tdir=$out/lib/ghc-${ghcVersion}/targets/${targetTriple}
    mkdir -p $tdir/lib $tdir/bin

    # Target-platform settings from ghc-toolchain-bin (probes the cross cc).
    # ghc-toolchain-bin calls `sh config.sub <triple>`; config.sub must be
    # in the current directory.
    cp ${nativeConfiguredSrc}/config.sub ./config.sub
    ${nativeGhcToolchainBin} \
      --disable-ld-override \
      --triple ${targetTriple} \
      --cc  ${targetCCPath} \
      --cxx ${targetCXXPath} \
      ${
        # ghc-toolchain probes PATH for `<triple>-{ar,ranlib,nm}` / plain
        # names, but emscripten ships them as em{ar,ranlib} and emnm —
        # never found, and ar/ranlib/nm discovery is fatal.  Name them
        # explicitly, mirroring the AR/RANLIB/NM exports the hadrian build
        # uses for GHC >= 9.12 (compiler/ghc/default.nix).  The empty
        # non-ghcjs case keeps this script byte-identical to before, so
        # other targets' wrapper drvs are unchanged.
        lib.optionalString isGhcjsTarget
          "--ar ${targetCC}/bin/emar --ranlib ${targetCC}/bin/emranlib --nm ${targetNMPath} "
      }--output-settings \
      -o $tdir/lib/settings

    # ghc-toolchain probes don't know the session is cross (it only sees
    # the target triple), so fix up "cross compiling" — the plan-time
    # dummy ghc reports YES for cross targets and the real compiler must
    # agree, and YES also makes GHC default TH evaluation to the external
    # interpreter instead of loading target objects in-process.
    sed -i 's|("cross compiling","NO")|("cross compiling","YES")|' \
      $tdir/lib/settings

    ${fixRtsWays "$tdir/lib/settings"}
    ${addTargetDials "$tdir/lib/settings"}

    ${lib.optionalString targetNeedsLLVM ''
    # ── LLVM backend ─────────────────────────────────────────────────────
    # Two things the `-target` registration has to supply that a hadrian
    # bindist gets from its own build, and that nothing else here provides:
    #
    #   * `$topdir/llvm-targets` AND `$topdir/llvm-passes`, the two tables
    #     `GHC.Driver.Config.LlvmConfigCache` reads: triple -> (data layout,
    #     cpu, features) for the `llc` command line, and -O level -> `opt`
    #     `-passes=` string.  The `-target` session's topdir is $tdir/lib, so
    #     a copy under the NATIVE tree (which `lndir` brings in) is not where
    #     GHC looks, and the compile dies with
    #       .../targets/<triple>/lib/llvm-<file>: openFile: does not exist
    #     That is two files, and they failed the rts -- so all four rts ways,
    #     so every armv7a-android job.
    #
    #     Copy BOTH.  `initLlvmConfigCache` reads them under
    #     `unsafeInterleaveIO`, so they fail at first use rather than at
    #     startup, and their uses differ: llvm-targets is needed by every
    #     compile, llvm-passes only once `opt` runs -- i.e. only at -O.  That
    #     staggering is why fixing llvm-targets alone looked like it worked:
    #     the rts's unoptimised .cmm files compiled, and the first `-O` one
    #     then died on llvm-passes instead.
    #
    #   * absolute `llc`/`opt`/`llvm-as` paths.  ghc-toolchain hard-codes
    #     the bare names (`llc_cmd = "llc" -- FIXME`, ghc-toolchain's
    #     exe/Main.hs), GHC execs them from PATH, and nothing puts LLVM on a
    #     slice build's PATH.  It shows up only as the non-fatal
    #       Warning: Couldn't figure out LLVM version!
    #     immediately before the failure above, which is why the missing
    #     file is the visible symptom.  The hadrian compilers get the same
    #     absolute paths from `export LLC=/OPT=` in compiler/ghc/default.nix,
    #     which ./configure bakes into their settings.
    #
    #     `llvm-as` is NOT llvm-as.  Despite the setting name, GHC runs this
    #     one through `runGenericAsPhase` -- the same code path as the plain
    #     C-compiler assembler -- so it hands it `-fPIC -U__PIC__ -D__PIC__`,
    #     `-x assembler`, `-c`, `-o` and `-I` flags.  Those are clang driver
    #     flags; LLVM's actual `llvm-as` takes a single positional .ll and
    #     dies with
    #       llvm-as: Unknown command line argument '-fPIC'
    #       `llvm-as' failed in phase `LLVM assembler'. (Exit code: 1)
    #     ghc-toolchain agrees: it advertises the flag as "Assembler used for
    #     LLVM backend (typically clang)" and probes for `clang`, then throws
    #     the result away and emits the literal string via
    #     `llvm_as_cmd = "llvm-as" -- FIXME`.  So point it at the target cc
    #     (the same wrapper `--cc` above gets), NOT at ${llvmForTarget}.
    #
    # All three names are in `tests.dummy-ghc-info`'s `ignoredFields`, so
    # the plan-time dummy needs no matching change.
    cp ${nativeConfiguredSrc}/llvm-targets $tdir/lib/llvm-targets
    cp ${nativeConfiguredSrc}/llvm-passes  $tdir/lib/llvm-passes
    grep -qF '("${targetTriple}",' $tdir/lib/llvm-targets || {
      echo "llvm-targets has no entry for ${targetTriple}; GHC would fail" >&2
      echo "with \`Unknown target\`.  Add one the way the hadrian build" >&2
      echo "does (compiler/ghc/default.nix patches this file)." >&2
      exit 1
    }
    # llvm-passes is a Haskell [(Int, String)] literal keyed by -O level;
    # GHC `read`s it and looks up the level, so a file that parsed but had
    # no entry for the level in use would fail only at that -O.
    for lvl in 0 1 2; do
      grep -qE "^\($lvl, \"-passes=" $tdir/lib/llvm-passes || {
        echo "llvm-passes has no entry for -O$lvl; GHC would fail with" >&2
        echo "\`Can't find LLVM opt flags\` when compiling at that level." >&2
        cat $tdir/lib/llvm-passes >&2
        exit 1
      }
    done
    sed -i \
      -e 's|("LLVM llc command","llc")|("LLVM llc command","${llvmForTarget}/bin/llc")|' \
      -e 's|("LLVM opt command","opt")|("LLVM opt command","${llvmForTarget}/bin/opt")|' \
      -e 's|("LLVM llvm-as command","llvm-as")|("LLVM llvm-as command","${targetCCPath}")|' \
      $tdir/lib/settings
    for f in llc opt; do
      grep -qF "${llvmForTarget}/bin/$f" $tdir/lib/settings || {
        echo "llvm settings: $f was not given an absolute path; the names" >&2
        echo "ghc-toolchain writes must have changed.  It now says:" >&2
        grep -F '"LLVM ' $tdir/lib/settings >&2
        exit 1
      }
    done
    grep -qF '("LLVM llvm-as command","${targetCCPath}")' $tdir/lib/settings || {
      echo "llvm settings: the LLVM assembler is not the target cc.  It must" >&2
      echo "be a clang-compatible driver (GHC passes it -fPIC/-x/-c), not" >&2
      echo "LLVM's llvm-as.  It now says:" >&2
      grep -F '"LLVM ' $tdir/lib/settings >&2
      exit 1
    }
    ''}

    ${lib.optionalString isGhcjsTarget ''
    # ghc-toolchain-bin resolves every tool command to an absolute path from
    # `--cc` EXCEPT "JavaScript CPP command", which it leaves as the bare
    # `emcc` (it isn't derived from --cc the way the C/Haskell/C-- CPP
    # commands are).  GHC's JS backend then execvp's bare `emcc` to
    # preprocess the rts `.js` sources and fails with
    #   ghc: JavaScript C pre-processor: could not execute: `emcc'
    # because emscripten isn't on the slice build's PATH.  Point it at the
    # same absolute emcc every other command already uses.
    sed -i 's|("JavaScript CPP command","emcc")|("JavaScript CPP command","${targetCCPath}")|' \
      $tdir/lib/settings

    # `ar command` must produce GNU-format archives.  emar is llvm-ar, whose
    # DEFAULT format on a macOS build host is darwin: member data 8-aligned
    # with '\n' padding COUNTED IN the ar size field.  Mach-O readers
    # tolerate the inline pad, wasm ones don't — a cbits wasm `.o` (time's
    # HsTime.o) archived that way reads back as <valid wasm>+pad, and
    # wasm-ld / llvm-nm fail "section too large" at the TH-interpreter and
    # final links.  Cabal takes its `ar` from this settings entry too (the
    # "Using ar found on system at" configure line), so this one swap covers
    # both GHC-internal and cabal archive creation.  (The ghcjsArWrapper /
    # ghc-shim settings-swap in the builders is DEAD CODE here — it engages
    # only for targetPrefix != "", and this wrapper's prefix is "".)
    mkdir -p $out/libexec
    printf '%s\n' \
      '#!${pkgs.buildPackages.runtimeShell}' \
      'exec ${targetCC}/bin/emar --format=gnu "$@"' \
      > $out/libexec/emar-gnu
    chmod +x $out/libexec/emar-gnu
    sed -i "s|(\"ar command\",\"[^\"]*\")|(\"ar command\",\"$out/libexec/emar-gnu\")|" \
      $tdir/lib/settings
    grep -qF "$out/libexec/emar-gnu" $tdir/lib/settings || {
      echo "ghcjs settings: ar command swap did not match" >&2
      exit 1
    }
    ''}

    ${lib.optionalString (tp.isWasm or false) ''
    # Patch settings to match the Hadrian-built WASM cross compiler:
    # - Tables next to code = NO (WASM separates code/data address spaces;
    #   YES causes linker "symbol type mismatch" on stg_*_info symbols)
    # - Merge objects via wasm-ld -r
    # - libffi on the linker's search path.  Where libffi lives is a
    #   property of THIS TOOLCHAIN -- nixpkgs' wasi toolchain ships none, so
    #   we build `libffiWasm` (the one hadrian's wasm bindists use) -- and
    #   the rts advertises `extra-libraries: ffi` under `+use-system-libffi`
    #   for every one of its way sub-libraries.  Carrying the directory only
    #   in those packages' `library-dirs` makes every downstream link depend
    #   on which units happen to be in its closure and on cabal having
    #   recorded the field; when that fell through, the executable link died
    #   as
    #     wasm32-unknown-wasi-wasm-ld: error: unable to find library -lffi
    #   (`wasi32.tests.c-ffi.run` and its neighbours).  A toolchain fact
    #   belongs in the toolchain, so put it where every wasm link sees it.
    #   `modules/cabal-project.nix`'s `rtsWasmExtras` keeps the matching
    #   `extra-include-dirs` / `extra-lib-dirs`: the rts still needs ffi.h
    #   to compile, and its own shared-lib link uses them directly.
    #   `tests.dummy-ghc-info` is unaffected -- "C compiler link flags" is
    #   one of its `ignoredFields` (cabal does not consult it for
    #   elaboration), so the plan-time dummy needs no matching change.
    #
    # - `-Wno-int-conversion`.  wasi-libc's `clockid_t` is
    #   `const struct __clockid *`, a POINTER, while `time`'s
    #   `Data.Time.Clock.Internal.CTimespec` imports `clock_gettime` with a
    #   `CClockId` = `Word32` argument.  The `capi` shim GHC writes for it
    #   therefore hands an integer to a pointer parameter, and clang 21
    #   makes `-Wint-conversion` an ERROR by default:
    #     ghc_tmp_28_1.c:12:205: error: incompatible integer to pointer
    #       conversion passing 'HsWord32' to parameter of type 'clockid_t'
    #     `wasm32-unknown-wasi-cc' failed in phase `C Compiler'
    #   The value itself round-trips (hsc2hs read the same constants back
    #   out as integers), so demoting the diagnostic is the fix, and it
    #   belongs in the toolchain because it is a property of wasi-libc, not
    #   of `time` -- every capi import of a wasi "handle" typedef hits it.
    #   `time` is a boot library, so this one error took out most of both
    #   wasi32 clusters.  "C compiler flags" is in `tests.dummy-ghc-info`'s
    #   `ignoredFields`, so the plan-time dummy needs no matching change.
    sed -i \
      -e 's|("Tables next to code","YES")|("Tables next to code","NO")|' \
      -e 's|("C compiler flags","\([^"]*\)")|("C compiler flags","\1 -Wno-int-conversion")|' \
      -e 's|("Merge objects command","")|("Merge objects command","${pkgs.buildPackages.llvmPackages.lld}/bin/wasm-ld")|' \
      -e 's|("Merge objects flags","")|("Merge objects flags","-r")|' \
      -e 's|("Merge objects supports response files","NO")|("Merge objects supports response files","YES")|' \
      -e 's|("C compiler link flags","\([^"]*\)")|("C compiler link flags","\1 -L${libffiWasm}/lib")|' \
      $tdir/lib/settings
    # Assert it landed: a sed that silently matches nothing would leave the
    # link exactly as broken as before, only harder to spot.
    grep -qF -- '-L${libffiWasm}/lib' $tdir/lib/settings || {
      echo "wasm settings: could not add libffi to the C compiler link flags;" >&2
      grep -F '"C compiler link flags"' $tdir/lib/settings >&2
      exit 1
    }
    grep -qF -- '-Wno-int-conversion' $tdir/lib/settings || {
      echo "wasm settings: could not add -Wno-int-conversion to the C" >&2
      echo "compiler flags;" >&2
      grep -F '"C compiler flags"' $tdir/lib/settings >&2
      exit 1
    }
    ''}

    ${lib.optionalString tp.isx86_64 ''
    # Same workaround as the native x86_64 stage1 settings: the RTS's
    # XXHash3 uses 256-bit AVX2 vectors that GHC 9.14's NCG can't handle,
    # so keep AVX out of both the C and Cmm CPP flags (XXHash3 falls back
    # to its 128-bit SSE2 path).
    sed -i \
      -e 's|("C compiler flags","\([^"]*\)")|("C compiler flags","\1 -mno-avx -mno-avx2")|' \
      -e 's|("C-- CPP flags","\([^"]*\)")|("C-- CPP flags","\1 -mno-avx -mno-avx2")|' \
      $tdir/lib/settings
    ''}

    # Empty global package DB for the target ("Relative Global Package DB"
    # in the generated settings is `package.conf.d`, relative to the target
    # libdir).  Boot libraries are built by each project's own plan.
    ${nativeS2exe "ghc-pkg" "ghc-pkg"} init $tdir/lib/package.conf.d
    ${lib.optionalString (populatedDb != null) ''
    # Bindist mode (ghcjs): register the prebuilt target boot-library closure
    # (ghci + the boot libs the project uses) into the target global db, so
    # GHC's JS external interpreter can resolve the "ghci" package + its unit
    # closure at Template-Haskell time (GHC/Runtime/Interpreter/JS.hs:171).
    # The .conf files embed absolute /nix/store lib paths (the harvest rewrote
    # their ''${pkgroot}-relative dirs to the source slices' absolute paths),
    # so each slice's libs are retained in this wrapper's runtime closure.
    cp ${populatedDb}/*.conf $tdir/lib/package.conf.d/
    # `--no-user-package-db --global-package-db` (the native wrapper's proven
    # recache form, see the stage2 assembly above) — NOT `--package-db`: that
    # keeps the default global db in ghc-pkg's stack, forcing topdir discovery
    # from the exe's own location, and the v2-slice-built ghc-pkg exe carries
    # no lib/settings there ("Settings file doesn't exist" → "Fallback: Can't
    # find package database" → exit 1).
    ${nativeS2exe "ghc-pkg" "ghc-pkg"} recache \
      --no-user-package-db \
      --global-package-db $tdir/lib/package.conf.d
    ''}

    # $topdir support files for the target session (topdir = $tdir/lib).
    cp ${nativeConfiguredSrc}/driver/ghc-usage.txt  $tdir/lib/
    cp ${nativeConfiguredSrc}/driver/ghci-usage.txt $tdir/lib/
    mkdir -p $tdir/lib/include
    cp ${nativeConfiguredSrc}/rts/include/ghcversion.h $tdir/lib/include/
    cp ${hsc2hsSrc}/data/template-hsc.h $tdir/lib/template-hsc.h
    # The generated settings' "unlit command" is $topdir/../bin/unlit, which
    # under the target topdir resolves to $tdir/bin.
    ln -sf ${nativeSghc914}/bin/unlit  $tdir/bin/unlit
    ln -sf ${nativeSghc914}/bin/hsc2hs $tdir/bin/hsc2hs

    ${lib.optionalString (tp.isWasm or false) ''
    # JSFFI runtime scripts; GHC resolves them at $topdir/dyld.mjs etc.
    # (compiler/GHC/Driver/Config/Interpreter.hs), so they live in the
    # target libdir.
    for f in ${nativeConfiguredSrc}/utils/jsffi/*.mjs; do
      [ -e "$f" ] && cp "$f" $tdir/lib/
    done
    # Run dyld.mjs through `wasmDyldNode` (see there): its own
    # `#!/usr/bin/env -S node` is not in the build sandbox, and GHC's libdir
    # argument does not hold libffi.so / libc.so.  The wrapper is a shell
    # script, so name the shell as the interpreter and the wrapper as its
    # argument: Linux follows a `#!` that points at another script, but
    # macOS refuses it (ENOEXEC) and the exec fallback then runs dyld.mjs
    # itself with sh ("dyld.mjs: line 3: //: is a directory").
    chmod u+w $tdir/lib/dyld.mjs
    sed -i '1s|^#!.*$|#!${pkgs.buildPackages.runtimeShell} ${wasmDyldNode}/bin/node|' $tdir/lib/dyld.mjs
    ''}
    ${lib.optionalString isGhcjsTarget ''
    # Template Haskell on the JS backend runs each splice by executing it with
    # node against the prebuilt interpreter script; GHC resolves it at
    # `$topdir/ghc-interp.js` (the target libdir).  A hadrian-built ghcjs GHC
    # ships it, but this runCommand wrapper must place it under the target
    # registration itself, else TH-using packages fail with
    # `Cannot find module .../ghc-interp.js`.
    cp ${nativeConfiguredSrc}/ghc-interp.js $tdir/lib/ghc-interp.js
    ''}

    # ── ghc wrapper ──────────────────────────────────────────────────────
    # -B and -target are both last-wins in GHC's argv handling, so callers
    # passing their own -B (e.g. -B$NIX_GHC_LIBDIR) or -target still win.
    cat > $out/bin/ghc << 'ENDSCRIPT'
#!/bin/sh
exec GHC_EXE \
  -BTOPDIR \
  -target=TARGET \
  "$@"
ENDSCRIPT
    sed -i \
      -e "s|GHC_EXE|${nativeS2exe "ghc-bin" "ghc"}|" \
      -e "s|TOPDIR|$out/lib/ghc-${ghcVersion}|" \
      -e "s|TARGET|${targetTriple}|" \
      $out/bin/ghc
    chmod +x $out/bin/ghc${lib.optionalString isGhcjsTarget ''

    # The JS backend has exactly ONE rts flavour: rts.cabal marks the three
    # non-vanilla way sub-libraries `buildable: False` under
    # `arch(javascript)`, so `rts:nonthreaded-nodebug` is the only one that
    # ever exists.  GHC nevertheless picks the rts unit from the session's
    # ways (`rtsWayUnitId`, compiler/GHC/Driver/DynFlags.hs), so the
    # `-threaded` that almost every cabal `executable` / `test-suite` stanza
    # carries makes it ask for `rts:threaded-nodebug` and panic:
    #   The RTS for rts:threaded-nodebug is missing from the package
    #   database while building unit <exe> ... (GHC/Unit/State.hs:1653)
    # `-threaded` is a no-op on JS (the JS rts is single-threaded), and
    # threaded is an RTS-ONLY way (`wayRTSOnly`, GHC/Platform/Ways.hs) so
    # dropping it changes no library name and no interface -- only which rts
    # unit gets wired in.  Cancel it with `-single-threaded`
    # (`removeWayDynP WayThreaded`, GHC/Driver/Session.hs).
    #
    # It has to come AFTER "$@": GHC's flag handling is last-wins, and the
    # package's own ghc-options reach GHC in a cabal response file this
    # wrapper cannot rewrite.  The `-B` the v2 ghc shim prepends
    # (builder/ghc-shim.nix, `makeWrapper --add-flags`) still lands before
    # them, so nothing else moves.
    #
    # `-no-rts` -- which the panic message itself suggests -- is NOT an
    # alternative: it skips the sanity check but the wiring below it still
    # looks the way's abi hash up in pkgs2 and panics with "rtsWayUnitId not
    # found in wired-in packages".
    #
    # `-debug` would need the same treatment (`rts:nonthreaded-debug` is
    # equally unbuildable here) but GHC has no `-no-debug` to cancel it with;
    # no test package uses it, so leave that to the upstream fix, which
    # belongs in stable-haskell/ghc: `rtsWayUnitId` should ignore the
    # RTS-only ways when the target platform is JS.
    sed -i 's|^  "$@"$|  "$@" -single-threaded|' $out/bin/ghc
    grep -qF -- '"$@" -single-threaded' $out/bin/ghc || {
      echo "ghcjs ghc wrapper: could not append -single-threaded; the" >&2
      echo "wrapper script above must have changed.  It now says:" >&2
      cat $out/bin/ghc >&2
      exit 1
    }
    ''}

    ln -s $out/bin/ghc $out/bin/ghci

    # ── ghc-pkg wrapper ──────────────────────────────────────────────────
    # Explicit --global-package-db (the target db); ghc-pkg then skips its
    # own target/topdir inference entirely.
    cat > $out/bin/ghc-pkg << 'ENDSCRIPT'
#!/bin/sh
exec GHC_PKG_EXE \
  --no-user-package-db \
  --global-package-db PACKAGEDB \
  "$@"
ENDSCRIPT
    sed -i \
      -e "s|GHC_PKG_EXE|${nativeS2exe "ghc-pkg" "ghc-pkg"}|" \
      -e "s|PACKAGEDB|$tdir/lib/package.conf.d|" \
      $out/bin/ghc-pkg
    chmod +x $out/bin/ghc-pkg

    ln -sf ${nativeSghc914}/bin/hsc2hs  $out/bin/hsc2hs
    ln -sf ${nativeSghc914}/bin/runghc  $out/bin/runghc
    ln -sf ${nativeSghc914}/bin/unlit   $out/bin/unlit

    # Versioned aliases, as in a standard GHC bindist (see the native
    # compiler assembly above).
    v=${ghcVersion}
    ln -s $out/bin/ghc     $out/bin/ghc-$v
    ln -s $out/bin/ghci    $out/bin/ghci-$v
    ln -s $out/bin/ghc-pkg $out/bin/ghc-pkg-$v
    ln -s $out/bin/runghc  $out/bin/runghc-$v
    mkdir -p $out/lib/bin
    ln -sf ${nativeSghc914}/bin/unlit   $out/lib/bin/unlit
    ln -sf ${nativeSghc914}/bin/hsc2hs  $out/lib/bin/hsc2hs
    '';
    in
    let
      # TH-on-JS is handled at the PROJECT level (the boot-package injection
      # composes the project's own ghci slice into every host package's dep
      # db via additional-prebuilt-depends — see modules/cabal-project.nix).
      # An earlier "bootstrap tier" instead baked a separately-built ghci
      # closure into this wrapper's target global db; that can never share
      # unit-ids with the project's own boot libs, so the JS interpreter
      # loaded ghc-internal's jsbits twice and died
      # ("Identifier 'h$base_o_rdonly' has already been declared").
      crossCompilerBoot = makeCompilerDeps' (mkRawDrv { self = crossCompilerBoot; });
      makeCompilerDeps' = pkgs.haskell-nix.haskellLib.makeCompilerDeps;
    in crossCompilerBoot;

  # ── Dev shells for hacking on the stable-haskell GHC tree ─────────────────
  # Consumed by a flake.nix in the GHC checkout.  The user drives the build
  # with cabal / the top-level Makefile; these shells supply the toolchain
  # from haskell.nix, reusing the same boot compiler and tools as the ghc914-sh
  # build itself.  Two starting points:
  #
  #  * from-boot   — nothing prebuilt: the boot GHC (ghc9103) is GHC0, for
  #                  `make stage1` (and then stage2) from a clean tree.
  #  * from-stage1 — haskell.nix's cached ghc914-sh-stage1 serves as the stage1
  #                  compiler, so only stage2 needs rebuilding:
  #                  `make stage2 STAGE1_PATH=$STAGE1_PATH`.
  ghc914-shShells =
    let
      # nixpkgs boot GHC — same choice as the ghc914-sh build (see bootGhc above).
      bootGhc = pkgs.buildPackages.haskell.compiler.${bootGhcName};
      commonTools = [
        # haskell.nix's patched cabal-install understands the project files;
        # the Makefile's `stable-cabal` target can still build the in-repo
        # one (from the stable-haskell/Cabal srp) if preferred.
        #
        # The `-sh` bundle specifically: these are the ghc914-sh dev shells, and
        # the project files they are for use the fork's stage system
        # (build:/host: stage-qualified constraints), which the shared 3.16
        # cabal does not understand.
        pkgs.buildPackages.haskell-nix.nix-tools-unchecked-sh.exes.cabal
        alexTool
        happyTool
      ] ++ (with pkgs.buildPackages; [
        autoconf automake libtool python3 gnumake pkg-config
      ]);
    in {
      from-boot = pkgs.mkShell {
        name = "ghc914-sh-dev-from-boot";
        packages = commonTools ++ [ bootGhc ];
        # `GHC0 ?=` in the Makefile respects the environment.
        GHC0 = "${bootGhc}/bin/ghc";
        shellHook = ''
          echo "ghc914-sh dev shell — starting from the boot GHC (${bootGhc.version})"
          echo "  make stage1          # build stage1 with GHC0=$GHC0"
          echo "  make stage2          # then stage2 with the in-tree stage1"
        '';
      };
      from-stage1 = pkgs.mkShell {
        name = "ghc914-sh-dev-from-stage1";
        packages = commonTools ++ [ bootGhc stage1Compiler ];
        GHC0 = "${bootGhc}/bin/ghc";
        # `STAGE1_PATH :=` in the Makefile ignores the environment, so it has
        # to be overridden on the make command line (see shellHook).
        STAGE1_PATH = "${stage1Compiler}";
        shellHook = ''
          echo "ghc914-sh dev shell — starting from haskell.nix's prebuilt stage1"
          echo "  make stage2 STAGE1_PATH=$STAGE1_PATH"
          echo "or drive cabal directly:"
          echo "  cabal build --project-file cabal.project.stage2.static \\"
          echo "    -w $STAGE1_PATH/bin/ghc all"
        '';
      };
    };

  in {
    inherit isCrossTarget isCrossHost
            stage1Compiler ghc914-shCompiler crossCompiler
            ghc914-shShells;
  };

  built = mkGhc { };
  inherit (built) isCrossTarget isCrossHost
                  stage1Compiler ghc914-shCompiler crossCompiler
                  ghc914-shShells;

in {
  haskell-nix = prev.haskell-nix // pkgs.lib.optionalAttrs (!isCrossTarget && !isCrossHost) {
    # Dev shells for the stable-haskell GHC source tree (native only).
    ghc914-sh-shells = ghc914-shShells;
  } // {
    # Attach a per-eval-system dummy `ghc`/`ghc-pkg` pair to every
    # haskell.nix compiler so `call-cabal-project-to-nix` reuses one shared
    # dummy per (compiler, evalSystem) instead of re-deriving it on every
    # `cabalProject` (the eval-time cost that made a trivial plan take
    # minutes — see lib/dummy-ghc.nix).  Keyed by the same systems as
    # `haskell-nix.evalPackages`; `genAttrs` keeps each entry lazy.  This
    # runs in the last overlay so `base` already carries ghc914-sh.
    compiler =
      let base = prev.haskell-nix.compiler // (
        # Case 2: isCrossTarget (e.g. pkgsCross.wasi32.buildPackages)
        #   ghc914-sh = cross compiler with target boot libraries
        if isCrossTarget then {
          ghc914-sh = crossCompiler;
        }
        # Case 3: isCrossHost (e.g. pkgsCross.wasi32)
        #   We can't build a compiler that RUNS on the cross host, but the
        #   attribute still has to exist: per-compiler attrsets derived from
        #   `haskell-nix.compiler` in cross-host pkgs — `iserv-proxy-exes`
        #   and (via overlays/windows.nix / overlays/armv6l-linux.nix)
        #   `templateHaskell` — otherwise have no ghc914-sh entry, which
        #   breaks evaluation for any target that wires cross-TH (Windows,
        #   aarch64-linux, android).  Point it at the buildPackages cross
        #   compiler; anything that actually compiles uses buildPackages'
        #   GHC anyway.
        else if isCrossHost then {
          ghc914-sh = pkgs.buildPackages.haskell-nix.compiler.ghc914-sh;
        }
        # Case 1: native
        else {
          "ghc914-sh-stage1" = stage1Compiler;
          ghc914-sh           = ghc914-shCompiler;
        }
      );
      in builtins.mapAttrs (_name: c:
        if builtins.isAttrs c && (c.isHaskellNixCompiler or false)
        then
          # Memoised per-eval-system compiler variants.  `ghc.evalWith.${evalSystem}`
          # returns the compiler with its whole plan-to-nix / configured-src /
          # dummy pipeline computed for that eval platform, shared across every
          # consumer — because attribute selection IS memoised, whereas
          # `.override { evalSystem = ...; }` (function application) is NOT, so
          # each call site used to re-run the pipeline (re-deriving configured-src
          # etc.) from scratch.  Consumers should select `evalWith.${evalSystem}`
          # rather than calling `.override { evalSystem = evalSystem; }`.  Lazy
          # per entry.  Bound in a `let` (an `//`-attrset is not recursive) so the
          # per-eval-system dummy below reuses the same memoised variant.
          let evalWith = lib.mapAttrs (evalSystem: _evalPackages:
                c.override { inherit evalSystem; }) final.haskell-nix.evalPackages;
          in c // {
          inherit evalWith;
          # NB: `dummyGhcPkgs` is a PLAIN passthru on each compiler variant (built
          # inside mkGhc / the hadrian compiler for that variant's own eval
          # platform), reached as `ghc.evalWith.${evalSystem}.dummyGhcPkgs` — not
          # an attrset keyed by eval-system attached here.
        }
        else c) base;
  };
}
