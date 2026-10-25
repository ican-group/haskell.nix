# v2 counterpart to shell-for.nix.
#
# Unlike the v1 shell — which pre-populates a ghc-pkg database for GHC
# directly — the v2 shell pre-populates the project's cabal store.  The
# v2 builder's cabal-install (`haskell-nix.v2-cabal-install`, the
# stable-haskell fork) keeps that store under the build dir
# (`<project root>/dist-newstyle/store`), not in `~/.cabal/store`.
# That's where cabal v2-build looks for already-installed units, so once
# the store has the deps the user works on, plain `cabal build` inside
# the shell reuses them instead of rebuilding from source.
#
# The shell hook handles store composition carefully:
#   * Items are installed via `ln -s` / `lndir` so the user's cabal
#     store contains symlinks pointing at the composed store in
#     /nix/store rather than full copies.  A nix GC root is added so
#     `nix-collect-garbage` won't remove the underlying paths.
#   * If a target unit is missing (or a previously-synced symlink is
#     now broken because its target was GC'd), install it.
#   * If it exists and byte-matches the source, no-op.
#   * If it exists and differs, refuse to overwrite; running
#     `haskell-nix-cabal-store-sync --force` replaces them.
#
# This keeps the user's store in a consistent state for their other
# projects while still letting them iterate on this one.
{ lib, stdenv, pkgs, runCommand, mkShell, hsPkgs, haskellLib, ghc, haskell-nix
, compiler, composeStore, makeGhcShim, cabalProjectLocal ? null
  # The cabal-install the v2 slice builder used, and its version.  See
  # `toolDrvs` below for why the shell's `cabal` has to be that one.
, v2CabalInstall, v2CabalInstallVersion, withBuildCompiler ? false }:

{ # Same shape as shellFor's `packages`: packages the user works on.
  # Their *dependencies* are composed into the shell's cabal store;
  # the packages themselves are not.
  # Default to *project* packages (working-tree), not all *local*
  # packages.  `selectLocalPackages` also includes
  # source-repository-packages, but SRPs are pinned upstream code
  # the user doesn't iterate on — we want them pre-built into the
  # cabal store, not excluded from it.
  packages ? ps: builtins.attrValues (haskellLib.selectProjectPackages ps)
  # Extra tools built from hackage and placed on PATH.  Same shape as
  # shellFor's `tools` argument: each value is a versionOrMod passed
  # to `haskell-nix.tool`.
  #   tools = { cabal = "3.16.1.0"; hlint = { version = "3.6"; }; }
, tools ? {}
  # If true, put `hoogle` on PATH (via haskell-nix.tool).  A hoogle
  # database is *not* pre-built — v2 doesn't produce haddocks the way
  # v1 does, so the user runs `hoogle generate` themselves when they
  # want a local db.
, withHoogle ? false
  # Accepted for API parity with shellFor.  v2 slices don't currently
  # produce haddocks, so setting this has no effect beyond documenting
  # intent; the flag is silently ignored when the haddock machinery
  # would otherwise be wired in.
, withHaddock ? withHoogle
  # Put `build-tool-depends` for this shell's components on PATH.  If
  # `allToolDeps = true` (the default, matching v1's shellFor), the
  # tools come from *every* component of every hsPkg — so cabal can
  # fall back to building any hackage dep inside the shell without
  # missing a build tool.  When `false`, only the selected packages'
  # build tools are included (leaner, but `cabal build` on a dep that
  # needs e.g. `alex` will have to find or build it itself).
, allToolDeps ? true
  # How the shell's pre-built library deps are made visible to tools
  # the user runs.  One of:
  #   "cabal-store" (default) — link the composed store into the
  #     project's `dist-newstyle/store` via a shellHook (or the
  #     explicit `haskell-nix-cabal-store-sync` command).  `cabal
  #     v2-build` then reuses the units.  The shell's `ghc` is
  #     plain — `runghc` / `ghci` won't see the deps.
  #   "ghc-pkg" — skip the cabal-store sync; instead wrap `ghc`
  #     with GHC_ENVIRONMENT pointing at the composed store's
  #     package.db, so `ghc`/`ghci`/`runghc`/`ghc-pkg` see every
  #     dep directly.  `cabal v2-build` still reuses them (it
  #     queries the wrapped ghc-pkg to discover installed units),
  #     but no files are written outside the shell.
  # We surface the dep closure via exactly one of these paths to
  # avoid confusion (e.g. stale package.db vs up-to-date store).
, exposePackagesVia ? "cabal-store"
  # Other derivations whose buildInputs / nativeBuildInputs / shellHook
  # should be merged into this shell (e.g. cross-compilation shells).
, inputsFrom ? []
  # Pre-built derivations to add directly (kept for parity with the
  # pre-tools API).
, additionalTools ? []
  # Extra build inputs (C libs, pkg-config deps, etc.) to surface in
  # the shell alongside the composed cabal store.
, buildInputs ? []
, nativeBuildInputs ? []
, shellHook ? ""
, ...
}@args:

let
  selectedPackages = packages hsPkgs;

  # All components of the selected packages (library, sublibs, exes,
  # tests, benchmarks).  From these we derive the set of external
  # library deps that should land in the cabal store.
  selectedComps = lib.concatMap haskellLib.getAllComponents selectedPackages;

  # Mirrors v1's `selectedConfigs`: include each non-Simple
  # package's `setup.config` so that setup-depends (e.g. Custom
  # build-type packages' `conduit` / `Cabal` / etc.) end up in the
  # shell env.  Without this, `runghc script.hs` inside the shell
  # can't see conduit, because pkg's library `build-depends` lists
  # only `base`.
  selectedSetupConfigs = lib.filter (c: c != null)
    (map (p: p.setup.config or null)
      (lib.filter (p: (p.buildType or "Simple") != "Simple") selectedPackages));

  # Resolve a `component.depends` entry to its haskell.nix package
  # value (`hsPkgs.<name>`).  A dep is either:
  #   * a package record (has `.components`) — return as-is, OR
  #   * a sublib slice (has `.passthru.identifier.name`) — look up
  #     the package the slice comes from in `hsPkgs`.
  depPkg = d:
    if d ? components then d
    else hsPkgs.${d.passthru.identifier.name or ""} or null;

  # Build-tool exe (`executableToolDepends` entry) → its package.
  exePkg = t: hsPkgs.${t.passthru.identifier.name or ""} or null;

  # Set of package names the user is iterating on — anything in
  # this set is excluded from the shell's pre-built cabal store, so
  # cabal compiles those packages from the working tree.
  # Mirrors v1's `removeSelectedInputs` semantics: a project package
  # is *only* excluded if it's in `selectedPackages`.  With the
  # default `packages = selectProjectPackages`, every project pkg
  # is excluded (matches "the cabal-project I'm developing").  With
  # an explicit `packages = ps: [ ps.foo ]`, only `foo` is excluded
  # — sibling project pkgs that `foo` depends on get pre-built into
  # the store like any external dep.
  selectedPkgNames = builtins.listToAttrs
    (map (p: { name = p.identifier.name or ""; value = true; })
      (lib.filter (p: p ? identifier) selectedPackages));
  pkgIsSelected = p:
    p != null && (p ? identifier)
    && (selectedPkgNames ? ${p.identifier.name});

  # All components of the selected packages' unit-id fragments
  # plus their setup configs (Custom-build packages' setup-depends).
  # v2 plan-nix puts each cabal unit-id in its own `hsPkgs` entry —
  # `selectedPackages` already enumerates every fragment, so a
  # straight `concatMap getAllComponents` covers every component
  # without an extra closure walk.
  selectedAllComps = selectedComps ++ selectedSetupConfigs;

  # External dep predicate: keep deps whose resolved package isn't
  # in `selectedPkgNames`.  This *includes* sibling project pkgs
  # the user didn't select (so they get pre-built), and SRPs (same
  # story).
  isExternal = d:
    let dp = depPkg d; in
    (d ? identifier)
    && (dp == null || !(pkgIsSelected dp));

  # `haskellLib.dependToLib` resolves a `component.depends` entry
  # to its library derivation: for a top-level lib dep that's
  # `p.components.library`, but for a sublib dep the entry is
  # already the sublib derivation and gets returned unchanged.
  # Filtering out selected packages here is what gives the shell
  # its "selected pkgs aren't pre-installed in the cabal store"
  # property — the user iterates on them, so cabal compiles them
  # from the working tree on demand.
  ownLibDepSlices = lib.filter (s: s != null)
    (map haskellLib.dependToLib
      (lib.filter isExternal
        (lib.concatMap (c: c.config.depends or c.depends or [])
          selectedAllComps)));
  # Same exclusion for build-tool exes carried via
  # `passthru.executableToolDepends` — keep prebuilt external tools
  # (alex, happy, hsc2hs, ...) so cabal sees them in the store, but
  # drop tools whose source is a selected package so cabal rebuilds
  # them from the user's tree.  Also filter to v2 slices (have
  # `passthru.isSlice`) to skip nixpkgs-side tools like
  # `gcc` or `pkgconf` which aren't haskell-nix-built.
  ownBuildToolSlices = lib.filter
    (t: t != null
        && t ? passthru
        && (t.passthru.isSlice or false)
        && !(pkgIsSelected (exePkg t)))
    (lib.concatMap (c: c.executableToolDepends or []) selectedAllComps);
  ownDepSlices = ownLibDepSlices ++ ownBuildToolSlices;

  # When the user combines this shell with other v2 shells via
  # `inputsFrom` (notably the cross shells the haskell-nix overlay
  # adds when `crossPlatforms` is set), each of those carries its
  # own `passthru.depSlices`.  Without merging them in, the main
  # shell's `composedStore` only contains native slices and
  # `haskell-nix-cabal-store-sync` only seeds those into the
  # project's cabal store — the cross slices that a downstream
  # `${prefix}cabal build` needs would be missing.
  inputsFromDepSlices = lib.concatMap
    (d: (d.passthru or {}).depSlices or [])
    inputsFrom;
  depSlices = haskellLib.uniqueWithName (ownDepSlices ++ inputsFromDepSlices);

  # Composed dep store for the shell.  The same `composeStore`
  # helper that the per-component `.store` attribute uses, applied
  # to the union of every dep slice across the user's selected
  # packages.  Sized linearly with the number of distinct units
  # (lndir → tree of symlinks) rather than the bytes those units
  # take on disk.
  composedStore = composeStore {
    name = "shell-store";
    slices = depSlices;
  };

  # `lndir` reproduces a directory tree as a tree of symlinks —
  # used for installing unit dirs (which are subtrees of files) so
  # the user's cabal store ends up with symlinks pointing into
  # /nix/store rather than full copies.
  lndir = pkgs.buildPackages.lndir or pkgs.buildPackages.xorg.lndir;

  # Standalone sync script placed on PATH as
  # `haskell-nix-cabal-store-sync`.  The shell hook invokes it
  # without arguments; the user can re-run it with `--force` to
  # overwrite conflicting entries.  Its behaviour:
  #   1. Register a nix GC root for the composed-store /nix/store
  #      path so the symlinks we install survive nix-collect-garbage.
  #   2. Scan: compare every conf / unit-dir / lib file in the
  #      composed store against the target cabal store; classify
  #      each as new, same, or conflict.  A previously-synced
  #      symlink whose target has been GC'd counts as new.
  #   3. Bail out if any conflicts exist and `--force` was not
  #      given.
  #   4. Print a cabal-style summary of what will be added.
  #   5. Install missing items (and conflicting items under
  #      `--force`) via `ln -s` for files and `lndir` for unit
  #      directory trees.
  #   6. Recache the merged package.db only when something was
  #      actually installed.
  cabalStoreSync = pkgs.pkgsBuildBuild.writeShellScriptBin "haskell-nix-cabal-store-sync" ''
    set -eu

    # The stable-haskell cabal fork keeps a PROJECT-LOCAL store under the build
    # dir (distStoreDirLayout = <builddir>/store), NOT a shared ~/.cabal/store —
    # so seed that.  BUILDDIR is a positional arg; a project built with a custom
    # `--builddir` passes the same value here.  The default is the fork's own
    # default builddir, `dist-newstyle`, under the PROJECT ROOT -- found the way
    # cabal finds it, as the nearest directory at or above $PWD holding a
    # `cabal.project`, else $PWD -- so entering the shell from a subdirectory
    # seeds the store `cabal build` will actually use.  One store per builddir,
    # never shared between unrelated projects — matching `cabal build`'s own
    # behaviour.
    force=0
    projectRoot=$PWD
    while [ ! -e "$projectRoot/cabal.project" ] && [ "$projectRoot" != / ]; do
      projectRoot=$(dirname "$projectRoot")
    done
    [ -e "$projectRoot/cabal.project" ] || projectRoot=$PWD
    buildDir=$projectRoot/dist-newstyle
    for arg in "$@"; do
      case "$arg" in
        --force) force=1 ;;
        -*) echo "usage: haskell-nix-cabal-store-sync [--force] [BUILDDIR]" >&2; exit 2 ;;
        *) buildDir=$arg ;;
      esac
    done

    src="${composedStore}"
    tgt_base="$buildDir/store"
    ghc_pkg="${ghc}/bin/${ghc.targetPrefix or ""}ghc-pkg"
    lndir="${lndir}/bin/lndir"

    mkdir -p "$tgt_base"

    # The stable-haskell fork's staged store reaches build-stage units
    # (setup/build-tool deps) through a `build -> host` link — natively
    # build==host (same toolchain, same unit ids).  The slice builder makes
    # this inside each slice's store (`ln -sn host $storeDir/build`);
    # replicate it in the user's store so `cabal build`'s receipt-based reuse
    # (`improveInstallPlanWithStoreUnits` scans <store>/build/<platform>/units
    # as well) recognises those build-stage neighbours — without it nothing
    # flips to Installed and everything rebuilds.  ($tgt_base is the local
    # <builddir>/store, so this link lives per-builddir alongside the deps.)
    if [ -d "$src/host" ] && [ "$(readlink "$tgt_base/build" 2>/dev/null)" != host ]; then
      if [ -d "$tgt_base/build" ] && [ ! -L "$tgt_base/build" ]; then
        echo "haskell-nix-cabal-store-sync: $tgt_base/build is a directory; expected a \`build -> host\` link." >&2
        echo "  Remove it (it holds build-stage units cabal can rebuild) and re-enter the shell." >&2
        exit 1
      fi
      rm -f "$tgt_base/build"
      ln -s host "$tgt_base/build"
    fi

    # ---- Fast path: same composedStore, already synced -----------
    # After a successful run we drop a marker file at
    # `<store>/.haskell-nix-shell-markers/<basename-of-src>`.
    # If that marker is present (and `--force` not set), the cabal
    # store is already in sync with this shell's slices and we can
    # skip the per-file scan entirely.  Different shells (different
    # `composedStore`) have distinct basenames, so alternating
    # shells doesn't invalidate each other's markers.
    markers_dir="$tgt_base/.haskell-nix-shell-markers"
    marker="$markers_dir/$(basename "$src")"
    if [ "$force" != "1" ] && [ -f "$marker" ]; then
      exit 0
    fi

    # ---- Register nix GC root ------------------------------------
    # Without a gcroot, nix-collect-garbage would happily delete
    # `$src` (and the slice paths it references), leaving every
    # symlink we install below pointing at nothing.  Each unique
    # composedStore (different deps → different nix hash) gets its
    # own gcroot file; stale gcroots from earlier shells just stay
    # under `.haskell-nix-gcroots/` until the user removes them.
    if command -v nix-store >/dev/null 2>&1; then
      gcroot_dir="$tgt_base/.haskell-nix-gcroots"
      mkdir -p "$gcroot_dir"
      gcroot_link="$gcroot_dir/$(basename "$src")"
      if [ ! -L "$gcroot_link" ] || [ "$(readlink "$gcroot_link")" != "$src" ]; then
        nix-store --realise "$src" --add-root "$gcroot_link" --indirect >/dev/null
      fi
    fi

    # `[ -e PATH ]` follows symlinks, so it's false both when the
    # path doesn't exist and when it's a symlink whose target has
    # been GC'd — exactly the cases we want to treat as "missing"
    # so the install pass below replaces them.

    # `new_items` / `conflicts`: rel paths (relative to $src) to
    # install; a rel path may contain slashes (e.g.
    # `host/<platform>/package.conf.d/foo.conf`).
    new_items=()
    conflicts=()

    # A "store root" is any dir under $src that holds a package db.
    # Two layouts are supported:
    #   * mainline cabal   — `<src>/ghc-<ver>/`, db at `package.db`,
    #                         unit dirs as siblings, libs as flat files.
    #   * stable-haskell   — `<src>/host/<platform>/`, db at
    #     fork (v2 slices)    `package.conf.d`, unit store entries under
    #                         `units/`, per-unit lib dirs `lib/<unit-id>/`.
    # `.conf` files are `''${pkgroot}`-relative, so faithfully mirroring a
    # root's subtree (symlinks for files, lndir for dir trees) is all
    # cabal/ghc-pkg need — pkgroot resolves to wherever the copied
    # `package.conf.d` / `package.db` ends up in the target store.
    roots=()
    for d in "$src"/ghc-*/ "$src"/host/*/; do
      d="''${d%/}"
      [ -d "$d" ] || continue
      [ -L "$d" ] && continue   # skip the fork's inert build->host link
      if [ -d "$d/package.db" ] || [ -d "$d/package.conf.d" ]; then
        roots+=("$d")
      fi
    done

    # classify_file REL — a single file/symlink entry (a .conf, a fork
    # unit-store symlink, or a mainline flat lib file).  Already the
    # right symlink? skip.  `[ ! -e ]` treats a GC'd (dangling) symlink
    # as missing, so it gets reinstalled.
    classify_file () {
      local rel=$1 s="$src/$1" t="$tgt_base/$1"
      if [ ! -e "$t" ]; then
        new_items+=("$rel")
      elif [ -L "$t" ] && [ "$(readlink "$t")" = "$s" ]; then
        : # already linked correctly
      elif ! diff -q "$s" "$t" >/dev/null 2>&1; then
        conflicts+=("$rel")
      fi
    }

    # classify_tree REL — a directory tree (a mainline unit dir, or a
    # fork per-unit lib dir), installed via lndir.  Probe one leaf
    # symlink to see if the tree already came from this source.
    classify_tree () {
      local rel=$1 s="$src/$1" t="$tgt_base/$1" probe target
      if [ ! -e "$t" ]; then
        new_items+=("$rel")
      else
        probe=$(find "$t" -type l -print -quit 2>/dev/null)
        if [ -n "$probe" ]; then
          target=$(readlink "$probe")
          case "$target" in
            "$s"/*) return ;;
          esac
        fi
        if ! diff -qr "$s" "$t" >/dev/null 2>&1; then
          conflicts+=("$rel")
        fi
      fi
    }

    # classify_entry REL — dispatch on the source type: a real dir (not
    # a symlink) is an lndir tree; anything else (file or symlink) is a
    # single symlink.
    classify_entry () {
      local s="$src/$1"
      if [ -d "$s" ] && [ ! -L "$s" ]; then
        classify_tree "$1"
      else
        classify_file "$1"
      fi
    }

    # ---- Pass 1: scan --------------------------------------------
    for root in "''${roots[@]}"; do
      rootRel="''${root#$src/}"
      if [ -d "$root/package.conf.d" ]; then dbName=package.conf.d; else dbName=package.db; fi

      # package-db confs
      for conf in "$root/$dbName"/*.conf; do
        [ -e "$conf" ] || continue
        classify_entry "$rootRel/$dbName/$(basename "$conf")"
      done

      # unit store entries: under `units/` (fork) or db-siblings (mainline)
      if [ -d "$root/units" ]; then
        for u in "$root/units"/*; do
          [ -e "$u" ] || continue
          classify_entry "$rootRel/units/$(basename "$u")"
        done
      else
        for u in "$root"/*/; do
          u="''${u%/}"
          [ -d "$u" ] || continue
          case "$(basename "$u")" in
            lib|bin|units|package.db|package.conf.d|incoming) continue ;;
          esac
          classify_entry "$rootRel/$(basename "$u")"
        done
      fi

      # libs: per-unit dirs (fork) or flat files (mainline), both under lib/
      if [ -d "$root/lib" ]; then
        for l in "$root/lib"/*; do
          [ -e "$l" ] || continue
          classify_entry "$rootRel/lib/$(basename "$l")"
        done
      fi
    done

    # ---- Bail on conflicts (unless --force) ----------------------
    if [ "''${#conflicts[@]}" -gt 0 ] && [ "$force" != "1" ]; then
      echo "" >&2
      echo "haskell.nix v2 shell: cabal store has entries that differ from" >&2
      echo "this shell's slices; refusing to overwrite:" >&2
      for c in "''${conflicts[@]}"; do
        echo "  $c" >&2
      done
      echo "" >&2
      echo "To replace these with the shell's versions, run:" >&2
      echo "  haskell-nix-cabal-store-sync --force" >&2
      echo "" >&2
      exit 1
    fi

    # ---- Nothing to do? ------------------------------------------
    if [ "''${#new_items[@]}" -eq 0 ] && [ "''${#conflicts[@]}" -eq 0 ]; then
      exit 0
    fi

    # ---- Summary (cabal-style) -----------------------------------
    echo ""
    if [ "''${#new_items[@]}" -gt 0 ]; then
      echo "The following are being linked into your cabal store:"
      for p in "''${new_items[@]}"; do
        echo " - $p"
      done
    fi
    if [ "''${#conflicts[@]}" -gt 0 ] && [ "$force" = "1" ]; then
      echo ""
      echo "The following are being overwritten (--force):"
      for c in "''${conflicts[@]}"; do
        echo " - $c"
      done
    fi
    echo ""

    # ---- Pass 2: install -----------------------------------------
    install_entry () {
      local rel=$1 s="$src/$1" t="$tgt_base/$1"
      mkdir -p "$(dirname "$t")"
      if [ -d "$s" ] && [ ! -L "$s" ]; then
        # Directory tree — lndir mirrors it as a tree of symlinks.
        if [ -d "$t" ] || [ -L "$t" ]; then
          chmod -R u+w "$t" 2>/dev/null || true
          rm -rf "$t"
        fi
        mkdir -p "$t"
        "$lndir" -silent "$s" "$t"
      else
        # Single file or symlink — replace with a symlink to source.
        if [ -e "$t" ] || [ -L "$t" ]; then
          rm -f "$t"
        fi
        ln -s "$s" "$t"
      fi
    }

    for p in "''${new_items[@]}"; do
      install_entry "$p"
    done
    if [ "$force" = "1" ]; then
      for c in "''${conflicts[@]}"; do
        install_entry "$c"
      done
    fi

    # ---- Pass 3: recache each store root's package db ------------
    # We install confs as symlinks; ghc-pkg needs a real writable
    # `package.cache` describing the merged set, so regenerate one per
    # store root (there was at least one install, or we'd have exited).
    for root in "''${roots[@]}"; do
      rootRel="''${root#$src/}"
      if [ -d "$root/package.conf.d" ]; then dbName=package.conf.d; else dbName=package.db; fi
      db="$tgt_base/$rootRel/$dbName"
      [ -d "$db" ] || continue
      for f in package.cache package.cache.lock; do
        if [ -L "$db/$f" ]; then rm -f "$db/$f"; fi
      done
      "$ghc_pkg" --package-db="$db" recache 2>/dev/null || true
    done

    # ---- Drop sync marker for this composedStore -----------------
    # Lets the next invocation skip the per-file scan via the
    # fast path at the top of this script.
    mkdir -p "$markers_dir"
    : >"$marker"
  '';

  v2ShellHook = ''
    haskell-nix-cabal-store-sync || return 1
  '';

  # Write the project's `cabalProjectLocal` (after all module
  # mkIfs have merged) to a file on shell startup.  For native
  # targets the file is `cabal.project.local`, which cabal picks
  # up automatically.  For cross targets it's
  # `cabal.project.<targetPrefix>local` (the cross `cabal` doesn't
  # auto-discover that path; tests can pull it in with
  # `import: cabal.project.<targetPrefix>local` from their own
  # `cabal.project.local`).
  #
  # If the target file is missing, write it.  If it exists and
  # differs, show the diff and print a command the user can run
  # to force replacement.  Skipped entirely when the project has
  # no `cabalProjectLocal` content.
  # A two-stage project (`withBuildCompiler`) is planned with
  # `--with-build-compiler` / `--with-build-hc-pkg` pointing at the BUILD
  # platform's compiler -- see `lib/call-cabal-project-to-nix.nix`, which
  # passes both to `make-install-plan`.  Nothing was passing them in the
  # shell, so a `cabal build` there saw no build-stage compiler, found
  # nothing installed for that stage, and resolved it out of hackage
  # instead: `ghcjs.tests.cabal-sublib-shell` picked
  # `build:base-4.19.1.0` / `ghc-prim-0.6.1` / `ghc-bignum-1.3` and died
  # with "Dependency on unbuildable library from ghc-bignum", while the
  # host stage resolved correctly to the injected `base-4.22.0.0`.
  #
  # The fork accepts both as cabal.project fields (verified against
  # cabal-install 3.17.0.1: an unrecognised field warns "Unknown field",
  # these two do not), so write them into the generated project-local
  # rather than into a `cabal` wrapper -- the wrapper is only built when
  # `targetPrefix != ""`, and the ghcjs cross compiler has no prefix, so
  # a wrapper would miss exactly the case that showed the bug.
  #
  # A native shell needs them too: the fork cabal's build stage otherwise
  # finds no installed `base` either and plans `build:base-4.18.3.0` from
  # hackage the same way (seen with ghc9141).  There the build compiler is
  # the shell's own.  A mainline single-stage cross shell is left alone, as
  # its slices are.
  buildCompilerFields =
    let buildGhc =
          if withBuildCompiler then ghc.buildGHC or null
          else if !haskellLib.isCrossHost then ghc
          else null;
    in lib.optionalString (buildGhc != null) ''
      with-build-compiler: ${buildGhc}/bin/${buildGhc.targetPrefix or ""}ghc
      with-build-hc-pkg: ${buildGhc}/bin/${buildGhc.targetPrefix or ""}ghc-pkg
    '';
  # Every hash-affecting line the slices' composed cabal.project carries
  # has to appear here too.  A UnitId is a hash of cabal-install's
  # `PackageHashInputs`, and `pkgHashProgramArgs` is one of them: a
  # `<prog>-options` field changes the UnitId of EVERY package in the
  # project, including ones that never run that program.  So a stanza
  # present on one side and not the other makes the shell's cabal compute
  # ids that match nothing in the composed store, and it rebuilds from
  # source exactly what the store was there to provide -- silently, since
  # a from-source build of a dep is not an error.
  #
  # `hsc2hs-options: --via-asm` is the one such stanza: Windows-gated, and
  # not a restatement of a cabal default (the rest of the slices' global
  # `package *` block -- library-vanilla, optimization, ... -- happens to
  # match what an unconfigured cabal already does, which is why the shell
  # agrees on every other target).  It must stay byte-identical to
  # `hsc2hsViaAsmProject` in `builder/comp-v2-builder.nix`, where the
  # rationale for `--via-asm` itself lives.
  hsc2hsViaAsmProject =
    lib.optionalString (stdenv.hostPlatform.isWindows or false) ''
      package *
        hsc2hs-options: --via-asm
    '';
  # --- The boot-package injection, as the SHELL needs it ------------------
  #
  # `modules/cabal-project.nix`'s `injectStableHaskellBootPackages` writes
  # two stanzas that are right for a slice and wrong here, each delimited by
  # a marker pair (the rationale for both lives beside the markers there):
  #
  #   haskell.nix:boot-packages  a `packages:` block listing every boot
  #                              library's source dir.  A slice has to build
  #                              them; the shell already has them, as
  #                              `installed` units in the composed store.
  #   haskell.nix:boot-pins      `base source, rts source, ...` constraints,
  #                              telling the solver NOT to use an installed
  #                              instance.  Here we want exactly the opposite.
  #
  # Left alone they cost the shell far more than a few redundant rebuilds.
  # `improveInstallPlanWithStoreUnits` (the fork's store-entry reuse, live at
  # ProjectPlanning.hs:635 and driven from `phaseImprovePlan`) only promotes a
  # unit to Installed when it has a receipt, is NOT local, AND every one of
  # its dependencies is itself pre-existing/installed/improved.  A local boot
  # library fails that third guard for everything above it, so the sibling
  # library `tests/cabal-sublib-shell` exists to check gets rebuilt too --
  # then the freshly built rts collides with the store's at link time
  # (`wasm-ld: error: duplicate symbol: __rts_fopen`).
  #
  # Neither edit touches a unit-id: `PackageHashInputs` contains no field
  # derived from `packages:` or from a solver pin, so the ids the shell
  # computes stay bit-identical to the slices' -- which is the whole point,
  # since reuse is keyed on them.  (`package-db:` would NOT be safe here:
  # `pkgHashPackageDbs` IS a hash input.  See `solverShim` below for how the
  # composed db is made visible without naming it in the project.)
  #
  # Gated on `withBuildCompiler`, which `modules/cabal-project.nix` sets in
  # exactly one place -- this injection -- so no other project is affected.
  # The pins are rewritten to `installed` -- but only for the packages the
  # composed store ACTUALLY holds, and that set is not knowable at eval time.
  #
  # Two independent reasons a blanket flip cannot work:
  #
  #   * The store holds the dependency CLOSURE of the packages the shell was
  #     asked for, not the whole boot set.  For `test/cabal-sublib-shell` that
  #     is base, ghc-prim, ghc-internal, rts + its ways, rts-fs, rts-headers,
  #     libffi-clib and provider -- no `unix`, no `array`, no `Cabal`.  An
  #     `installed` pin for a unit the store lacks fails the solve outright
  #     (`rejecting: host:unix ... requires installed instance`).
  #   * `Cabal` and `Cabal-syntax` arrive as a `source-repository-package`,
  #     which cabal treats as a LOCAL package -- a user target -- and therefore
  #     requires from source at exactly the SRP's version.  `Cabal installed`
  #     contradicts that in EVERY project, including ones that never depend on
  #     Cabal, because the solver resolves all local packages and not just the
  #     build targets.
  #
  # Dropping the pins instead is also wrong: they carry the boot libraries'
  # VERSIONS as well as their provenance, and without them the solver happily
  # takes an older hackage `ghc-prim-0.13.0` over the store's 0.13.1, moving
  # every downstream unit-id off the store it was supposed to reuse.
  #
  # So the flip is done at BUILD time, from the composed db itself, which is
  # exact by construction.  `compose-store.nix` deliberately keeps the slice
  # closure out of nix eval (it follows `nix-support/transitive-deps` in bash),
  # so `depSlices` here lists only the DIRECT deps -- three entries for the
  # sublib test, against thirteen units in the store.  Reading the db is the
  # only way to get the real set, and it is the same trick `discoverDbs`
  # already uses.
  # Gated on `withBuildCompiler`, which `modules/cabal-project.nix` sets in
  # exactly one place -- the boot-package injection this undoes -- so no other
  # project is affected.
  #
  # NOT additionally gated on `targetPrefix != ""`, as an earlier version of
  # this was: ghc914-sh is a `-target` compiler (one ghc with `targets/<triple>/`
  # subdirs), not a prefixed cross compiler, so `targetPrefix` is EMPTY for
  # every one of its targets and that conjunct made the whole mechanism dead
  # code on all of them.  The same mistake is why `crossCabalWrapper` below is
  # never created here, and why the shim has to reach cabal by PATH order
  # instead (`solverShim` comes first in `nativeBuildInputs`).
  applyShellBootFix = withBuildCompiler;
  cabalProjectLocalContent =
    lib.optionalString (cabalProjectLocal != null && cabalProjectLocal != "")
      cabalProjectLocal
    + buildCompilerFields + hsc2hsViaAsmProject;
  # Raw text, both marker blocks intact; the rewrite happens at build time.
  cabalProjectLocalRaw =
    pkgs.pkgsBuildBuild.writeText "cabal.project.local.in" cabalProjectLocalContent;
  cabalProjectLocalFile =
    if !applyShellBootFix then cabalProjectLocalRaw
    else pkgs.pkgsBuildBuild.runCommand "cabal.project.local" {
      preferLocalBuild = true;
    } ''
      ${discoverDbs}
      # Every package name registered in the composed store.  Parsed straight
      # out of the confs rather than via `ghc-pkg list` so hidden units (the
      # `z-rts-z-<way>` sub-libraries) are seen too, and so this needs no
      # working compiler on PATH.  Boot package names are alphanumerics and
      # hyphens, so each is its own regex.
      : > names
      for conf in "$composedPkgDb"/*.conf; do
        [ -e "$conf" ] || continue
        awk '/^name:/ { print $2; exit }' "$conf" >> names
      done
      sort -u names -o names
      # Except the packages of the forked-Cabal source-repository-package
      # (modules/cabal-project.nix): an SRP is LOCAL, so the solver must take
      # it from source whatever the store holds, and `Cabal installed` is
      # unsatisfiable (`rejecting: host:Cabal == host:source:Cabal-3.17.0.1
      # (... requires installed instance)`).  The store does hold them
      # whenever the shell's closure needs Cabal (ghcjs does).
      #
      # And, transitively, every installed unit that depends on them: cabal
      # hides ALL installed instances of a local package, so an installed
      # unit built against one is "broken" to the solver (`rejecting:
      # host:ghc-boot == host:installed:ghc-boot-9.14-... (package is broken,
      # missing dependency Cabal-syntax-3.17.0.0-...)`), and pinning it
      # `installed` fails the solve.  Those stay `source` too.
      for conf in "$composedPkgDb"/*.conf; do
        [ -e "$conf" ] || continue
        # One line per unit: name, id, then the ids it depends on.  Any
        # field's value may sit on the following indented lines (`id:` does
        # in a `ghc-pkg register`ed conf), so collect each field whole.
        awk '
          /^[^ \t]/ { f = $1; sub(/:$/, "", f)
                      v = $0; sub(/^[^:]*:/, "", v); val[f] = val[f] " " v
                      next }
          { val[f] = val[f] " " $0 }
          END { split(val["name"], nm, " "); split(val["id"], ui, " ")
                print nm[1], ui[1], val["depends"] }
        ' "$conf"
      done > units
      awk '
        { n++; uname[n] = $1; uid[n] = $2; udeps[n] = ""
          for (i = 3; i <= NF; i++) udeps[n] = udeps[n] " " $i }
        END {
          excl["Cabal"] = 1; excl["Cabal-syntax"] = 1
          do {
            changed = 0
            for (i = 1; i <= n; i++) if (uname[i] in excl) exclId[uid[i]] = 1
            for (i = 1; i <= n; i++) if (!(uname[i] in excl)) {
              m = split(udeps[i], ds, " ")
              for (k = 1; k <= m; k++)
                if (ds[k] in exclId) { excl[uname[i]] = 1; changed = 1; break }
            }
          } while (changed)
          for (x in excl) print x
        }
      ' units > excluded
      grep -vxFf excluded names > names.keep || true
      mv names.keep names
      # Both marker blocks are rewritten AGAINST THAT SET, per package:
      #
      #   in the store  ->  drop it from `packages:` (so it is not local, and
      #                     `improveInstallPlanWithStoreUnits` can promote the
      #                     units above it) and pin it `installed`.
      #   not in store  ->  leave it in `packages:` and leave the pin `source`.
      #
      # Doing only the first half for everything is what an earlier attempt
      # did, and it cannot work: the store holds the dependency CLOSURE of the
      # packages the shell was asked for, not the whole boot set.  An
      # `installed` pin for a unit the store lacks fails the solve
      # (`rejecting: host:unix ... requires installed instance`), and `Cabal`
      # is worse -- it arrives as a `source-repository-package`, which cabal
      # treats as a LOCAL user target requiring the SRP's exact version from
      # source, so `Cabal installed` is unsatisfiable in every project,
      # including ones that never depend on Cabal.
      #
      # Dropping the pins wholesale instead is also wrong: they carry the boot
      # libraries' VERSIONS, and without them the solver takes an older
      # hackage `ghc-prim-0.13.0` over the store's 0.13.1 and every downstream
      # unit-id moves off the store it was meant to reuse.
      #
      # It has to be done here rather than in nix because the store's contents
      # are not knowable at eval time: `compose-store.nix` deliberately follows
      # `nix-support/transitive-deps` in bash to keep the slice closure out of
      # eval, so `depSlices` lists only the DIRECT deps -- three entries for
      # the sublib test, against thirteen units in the store.
      #
      # `packages:` and its entries live inside the marker block together, so
      # the block is buffered and re-emitted; if nothing survives, the
      # `packages:` keyword is dropped too rather than left with no entries.
      awk -v namesfile=names '
        function flushPkgs(   i) {
          # Re-emit the ORIGINAL `packages:` line, not a constructed one: nix
          # strips the common indentation of an indented string, so its real
          # column is not the one it has in modules/cabal-project.nix, and an
          # indented `packages:` reads to cabal as a continuation of the
          # previous field rather than a new one.
          if (nkept > 0) { print pkgsHeader
                           for (i = 1; i <= nkept; i++) print kept[i] }
          nkept = 0
        }
        BEGIN { while ((getline n < namesfile) > 0) if (n != "") have[n] = 1 }

        /-- <<< haskell.nix:boot-packages/ { flushPkgs(); inpkgs = 0; print; next }
        inpkgs {
          line = $0
          sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
          if (line == "packages:") { pkgsHeader = $0; next }
          if (line == "") next
          base = line; sub(/.*\//, "", base)
          if (!(base in have)) kept[++nkept] = $0
          next
        }
        /-- >>> haskell.nix:boot-packages/ { inpkgs = 1; print; next }

        /-- <<< haskell.nix:boot-pins/ { inpins = 0 }
        inpins { for (n in have) gsub(n " source", n " installed") }
        /-- >>> haskell.nix:boot-pins/ { inpins = 1 }
        { print }
      ' ${cabalProjectLocalRaw} > $out
    '';
  cabalProjectLocalSync = pkgs.pkgsBuildBuild.writeShellScriptBin "haskell-nix-cabal-project-local-sync" ''
    set -eu

    force=0
    case "''${1:-}" in
      --force) force=1 ;;
      "") ;;
      *) echo "usage: haskell-nix-cabal-project-local-sync [--force]" >&2; exit 2 ;;
    esac

    # Next to the project's `cabal.project` (found as cabal finds it, and as
    # `haskell-nix-cabal-store-sync` does), so a shell entered from a
    # subdirectory still writes the file cabal reads.
    projectRoot=$PWD
    while [ ! -e "$projectRoot/cabal.project" ] && [ "$projectRoot" != / ]; do
      projectRoot=$(dirname "$projectRoot")
    done
    [ -e "$projectRoot/cabal.project" ] || projectRoot=$PWD
    target=$projectRoot/cabal.project.${ghc.targetPrefix or ""}local
    source=${cabalProjectLocalFile}

    install_it () {
      install -m u+rw,go+r "$source" "$target"
    }

    if [ ! -e "$target" ]; then
      install_it
      echo "Wrote $target (haskell.nix defaults)"
    elif diff -q "$target" "$source" > /dev/null 2>&1; then
      : # already in sync
    elif [ "$force" = "1" ]; then
      install_it
      echo "Overwrote $target with haskell.nix defaults (--force)"
    else
      echo
      echo "Existing $target differs from haskell.nix's defaults:"
      echo
      diff -u "$target" "$source" || true
      echo
      echo "To replace it with the haskell.nix defaults, run:"
      echo "  haskell-nix-cabal-project-local-sync --force"
      echo
    fi
  '';
  cabalProjectLocalShellHook = ''
    haskell-nix-cabal-project-local-sync || true
  '';

  # For cross-compilation shells, expose a `${prefix}cabal` wrapper
  # that auto-passes the right `--with-compiler=` etc. so the user
  # can run plain `${prefix}cabal build` without remembering the
  # cross-GHC paths.  Mirrors v1's wrapper at `shell-for.nix:183`.
  # The wrapper points at a tiny symlink farm (`ghcShim`) that
  # exposes the cross GHC's binaries under both the prefixed name
  # (so cabal's UnitId-hash sees the same `--with-compiler=` path
  # as the slices) and the unprefixed name (so cabal v2-build's
  # "near compiler" lookup finds plain `ghc-pkg`).
  targetPrefix = ghc.targetPrefix or "";
  # Two-pass: see `build-cabal-slice.nix`'s `ghcShim` for the
  # rationale.  GHC 9.14.1's cross GHCs ship both `<prefix>foo`
  # AND `foo` in their bin/ (e.g. `deriveConstants`); the previous
  # single-pass loop crashed when iteration hit the prefixed name
  # first and synthesised an alias before the real unprefixed
  # iteration ran.
  ghcShim = pkgs.pkgsBuildBuild.runCommand "${ghc.name}-shim" {
    preferLocalBuild = true;
  } ''
    mkdir -p $out/bin
    for f in ${ghc}/bin/*; do
      base=$(basename "$f")
      ln -s "$f" "$out/bin/$base"
    done
    ${lib.optionalString (targetPrefix != "") ''
      for f in ${ghc}/bin/${targetPrefix}*; do
        base=$(basename "$f")
        unprefixed=''${base#${targetPrefix}}
        [ -e "$out/bin/$unprefixed" ] || ln -s "$f" "$out/bin/$unprefixed"
      done
    ''}
  '';
  # --- Making the composed store visible to the SHELL's solver ------------
  #
  # `cabalProjectLocalFile` above pins the boot libraries `installed` instead of
  # `source`.  That pin is unsatisfiable on its own: this compiler ships an
  # empty global package db (`emptyGlobalPackageDb` -- the very reason the
  # injection exists), and cabal builds its installed-package index from
  # `ghc-pkg dump --global`, so the solver would reject every pin with
  # "requires installed instance".  The units it needs ARE on disk, in the
  # composed store, but cabal only consults that AFTER solving
  # (`improveInstallPlanWithStoreUnits`).
  #
  # The composed db therefore has to reach the solver as the GLOBAL db.  It
  # cannot be named in the project: `pkgHashPackageDbs` is a unit-id hash
  # input rendered as `package-dbs:`, so a `package-db:` field would move
  # every id and miss the store it was pointing at.  `GHC_PACKAGE_PATH` is no
  # use either -- `--global` ignores it.  What works is the trick
  # `build-cabal-slice.nix` already uses for slices: a `ghc-pkg` that carries
  # `--global-package-db <composedDb>`.  ghc-pkg's flag handling is last-wins
  # and the compiler's own wrapper puts its baked flag before "$@", so ours
  # overrides it -- and the db stack stays `[GlobalPackageDB]`, leaving the
  # hash untouched.
  #
  # Mirror `ghcShim` (the dir cabal actually uses) rather than the raw
  # compiler bin/, because on cross cabal gets an ABSOLUTE `--with-compiler=`
  # and takes `ghc-pkg` from that path's own bin/, so a PATH-only override
  # would be inert.  `ghc` must be a real file, not a symlink: Cabal's
  # `guessToolFromGhcPath` canonicalizes the configured ghc path and probes
  # the REAL directory's ghc-pkg first (cabal#7390), which would find the
  # compiler's own ghc-pkg and skip the override.
  solverShim = pkgs.pkgsBuildBuild.runCommand "${ghc.name}-v2-solver-shim" {
    preferLocalBuild = true;
  } ''
    ${discoverDbs}
    mkdir -p $out/bin
    for f in ${shellGhc}/bin/*; do
      ln -sf "$f" "$out/bin/$(basename "$f")"
    done
    for g in ${shellGhc}/bin/${targetPrefix}ghc ${shellGhc}/bin/${targetPrefix}ghc-${ghc.version}; do
      [ -e "$g" ] || continue
      gName=$(basename "$g")
      rm -f "$out/bin/$gName"
      # cabal does NOT learn the global db from `ghc-pkg`: it asks the
      # COMPILER -- `ghc --print-global-package-db` -- and builds its
      # installed-package index from whatever that prints.  This compiler
      # ships an empty global db, so without this interception the solver
      # sees no installed instance for anything and every `installed` boot
      # pin fails; the `ghc-pkg --global-package-db` override just below is
      # necessary but was never sufficient on its own.
      #
      # Safe for unit-ids: `pkgHashPackageDbs` is rendered by PackageHash.hs
      # as `unwords . map show` over the db STACK, and `show GlobalPackageDB`
      # is the constructor name with no path in it.  The stack stays
      # `[GlobalPackageDB]`, so pointing `global` at the composed db moves no
      # hash -- which is why this is legal where a `package-db:` field in the
      # project would not be.
      printf '#!/bin/sh\nfor a in "$@"; do\n  [ "$a" = "--print-global-package-db" ] || continue\n  echo %s\n  exit 0\ndone\nexec %s "$@"\n' \
        "$composedPkgDb" "$g" > "$out/bin/$gName"
      chmod +x "$out/bin/$gName"
    done
    # Cabal's near-compiler lookup asks for `ghc-pkg`, not `<prefix>ghc-pkg`
    # (the shim exposes both), so the unprefixed alias needs the override too.
    for gp in ${shellGhc}/bin/${targetPrefix}ghc-pkg* ${shellGhc}/bin/ghc-pkg*; do
      [ -e "$gp" ] || continue
      gpName=$(basename "$gp")
      rm -f "$out/bin/$gpName"
      printf '#!/bin/sh\nexec %s --global-package-db %s "$@"\n' \
        "$gp" "$composedPkgDb" > "$out/bin/$gpName"
      chmod +x "$out/bin/$gpName"
    done
  '';
  # Only the injected (two-stage) projects need the override; everything else
  # keeps the plain shim, so no currently-working shell changes behaviour.
  cabalCompilerDir = if applyShellBootFix then solverShim else ghcShim;
  crossCabalWrapper = lib.optional (targetPrefix != "")
    (pkgs.pkgsBuildBuild.writeShellScriptBin "${targetPrefix}cabal" ''
      exec cabal \
        --with-compiler=${cabalCompilerDir}/bin/${targetPrefix}ghc \
        --with-hsc2hs=${ghcShim}/bin/${targetPrefix}hsc2hs \
        $(builtin type -P "${targetPrefix}pkg-config" &> /dev/null \
          && echo "--with-pkg-config=${targetPrefix}pkg-config") \
        "$@"
    '');

  # Build tools from hackage via haskell-nix.tool.  Use the project's
  # compiler so the tools are compatible with the shell's GHC.
  compilerNixName = compiler.nix-name;

  # `cabal` is not an ordinary tool here.  The whole point of the v2
  # shell is that the composed cabal store already holds the project's
  # dependencies, so `cabal build` reuses them instead of rebuilding.
  # Reuse is keyed on UnitId, and a UnitId is a hash of cabal-install's
  # own `PackageHashInputs` rendering — so a *different cabal-install*
  # computes different UnitIds for byte-identical inputs, misses every
  # unit in the store, and rebuilds the world from source.  Silently:
  # nothing errors, the shell just stops being useful.
  #
  # `v2CabalInstall` is the stable-haskell fork build
  # (`haskell-nix.v2-cabal-install`), and `v2CabalInstallVersion` is its
  # version.
  #
  # `tools.cabal = {}` resolves to whatever cabal-install is newest in
  # the project's hackage index, which drifts every time a new one is
  # released, while the slices are built by `v2CabalInstall` (pinned in
  # `builder/default.nix`).  On 2026-08-15 that drift happened —
  # cabal-install 3.18.1.0 reached the index, slices stayed on 3.16.1.0
  # — and `test/cabal-sublib-shell` went red because the shell's cabal
  # rebuilt the sublib it was supposed to reuse.
  #
  # So when the caller has not pinned a version, hand back the very
  # binary that built the slices rather than an independently-solved
  # one.  `"latest"` counts as not pinning: it is what the templates and
  # `hix init` write, it means "any recent cabal", and the newest
  # cabal-install on hackage is never the right one here (it does not
  # even read the v2 store's `host/` layout).  The binary carries
  # haskell.nix's cabal-install patches (see `v2-cabal-install` in
  # overlays/haskell.nix); none of them affect hashing.  A caller who
  # *does* pin a version still gets exactly what they asked for — with a
  # warning when it isn't the version the slices were built with, since
  # the consequence (a silent from-source rebuild of every dependency)
  # is otherwise indistinguishable from the shell simply not working.
  #
  # The same binary is `project.v2-cabal-install`, for a shell built
  # some other way than `shellFor`.
  cabalTool = versionOrMod:
    let
      pinned = if lib.isString versionOrMod
                 then versionOrMod
                 else versionOrMod.version or null;
    in
      if pinned == null || pinned == "latest" then v2CabalInstall
      else lib.warnIf (pinned != v2CabalInstallVersion)
        ("shellFor: tools.cabal is pinned to ${pinned}, but this project's v2 "
         + "slices were built with cabal-install ${v2CabalInstallVersion}.  The "
         + "two compute different UnitIds, so `cabal build` in this shell will "
         + "rebuild every dependency from source instead of reusing the composed "
         + "cabal store.  Drop the pin to get the matching cabal.")
        (pkgs.pkgsBuildBuild.haskell-nix.tool compilerNixName "cabal" versionOrMod);

  # A tool value is normally a hackage version string / module spec passed
  # to `haskell-nix.tool`.  A prebuilt DERIVATION is taken as-is and put
  # straight on PATH — needed for tools that can't be rebuilt through
  # `haskell-nix.tool` under a from-source `compiler-nix-name` (which has
  # no nixpkgs-prebuilt GHC), notably the v2 store layout's own fork cabal
  # `haskell-nix.v2-cabal-install`.  A v2 shell that keeps mainline cabal
  # ("latest") gets a cabal that reads the old `ghc-<ver>/package.db`
  # layout and re-plans the whole composed store from scratch.  That case
  # is checked first: a derivation is neither a version string nor a
  # module spec, so `cabalTool` could not read a version out of it.
  toolDrvs = lib.mapAttrsToList
    (name: versionOrMod:
      if lib.isDerivation versionOrMod
        then versionOrMod
      else if name == "cabal"
        then cabalTool versionOrMod
        else pkgs.pkgsBuildBuild.haskell-nix.tool compilerNixName name versionOrMod)
    tools;

  # withHoogle: ensure hoogle is on PATH.  If the user already listed
  # it in `tools` use theirs, otherwise pick a sensible default.
  hoogleDrvs = lib.optional
    (withHoogle && !(tools ? hoogle))
    (pkgs.pkgsBuildBuild.haskell-nix.tool compilerNixName "hoogle" {});

  # Collect build-tool-depends for the shell — these are the
  # executables cabal would otherwise have to find or build when it
  # hits a `build-tool-depends` stanza.  v2 components expose them
  # via `.passthru.executableToolDepends` (comp-v2-builder mirrors
  # v1's shape).
  buildToolComponents =
    if allToolDeps
      then lib.concatMap haskellLib.getAllComponents
             (lib.filter (x: !(x.isRedirect or false)) (builtins.attrValues hsPkgs))
      else selectedComps;
  # Drop tools whose source is a selected package — those are
  # things the user is iterating on (e.g. cardano-wallet's own exes
  # that other selected packages list as build-tool-depends).
  # Mirrors `ownBuildToolSlices` and v1's `removeSelectedInputs`.
  # Without this, any selected exe that's a build-tool of another
  # selected package gets pre-built and pulled into the shell
  # closure.
  buildToolDrvs = haskellLib.uniqueWithName
    (lib.filter (t: t != null && !(pkgIsSelected (exePkg t)))
      (lib.concatMap (c: c.executableToolDepends or []) buildToolComponents));

  # Merge inputs from any `inputsFrom` shells (typical nix pattern).
  inputsFromBuildInputs       = lib.concatMap (d: d.buildInputs       or []) inputsFrom;
  inputsFromNativeBuildInputs = lib.concatMap (d: d.nativeBuildInputs or []) inputsFrom;
  inputsFromShellHook         = lib.concatMapStrings (d: (d.shellHook or "") + "\n") inputsFrom;

  # v1's `shellFor` exposes a wrapped ghc at `env.ghc` with a
  # package-db containing the shell's library deps, so callers can
  # use `env.ghc/bin/runghc` or `env.ghc/bin/ghc-pkg list` without
  # needing cabal.  v2 composes its deps into the cabal store
  # instead, so the plain ghc sees none of them.  Mirror v1's API
  # by surfacing the composed store via a GHC package-environment
  # file — lists each composed unit as `package-id <id>` so GHC
  # exposes not just the main library of each dep but also its
  # public sublibs (which GHC hides by default when you only stack
  # the package-db via `GHC_PACKAGE_PATH`).
  # Locating the two package dbs the shell has to stack.  BOTH come in
  # more than one layout and NEITHER can be spelled reliably during
  # eval, so discover them at build time from what is actually on disk
  # — the same way `build-cabal-slice.nix`'s `discoverStore` does.
  #
  # Composed store (`compose-store.nix` already handles both when it
  # recaches):
  #
  #   mainline cabal       <store>/ghc-<ver>[-inplace]/package.db
  #   stable-haskell fork  <store>/host/<platform>/package.conf.d
  #
  # Mainline names that dir `ghc-<version>-<abi>` (just `ghc-<version>`
  # when abi is empty): GHC ≥ 9.8 reports `Project Unit Id:
  # ghc-<version>-inplace`, from which cabal infers `compiler-abi:
  # inplace`, while earlier GHCs omit the field.  The fork instead
  # takes its layout from `distStoreDirLayout`, so for ghc914-sh no
  # `ghc-<ver>-inplace` dir exists at all and pointing
  # GHC_PACKAGE_PATH at one makes `ghc-pkg list` die with
  # `getDirectoryContents:openDirStream: does not exist`.
  #
  # The fork's platform dir is named after the compiler's own `--info`
  # "Target platform" (DistDirLayout.hs `betterPlatform`), which is NOT
  # nixpkgs' `hostPlatform.config`: GHC says `x86_64-unknown-linux`
  # where nixpkgs says `x86_64-unknown-linux-gnu`.  That is why the
  # name comes from `--info` rather than a nix string — and why it must
  # be matched BY NAME: on cross the composed store also carries the
  # BUILD platform's dir (build-stage units, reached through the
  # `build` -> `host` link), so taking the first entry under `host/`
  # could silently pick the wrong platform.  Fail loudly instead.
  #
  # Compiler global db:
  #
  #   nixpkgs GHC ≥ 9.6   <ghc>/lib/ghc-<ver>/lib/package.conf.d
  #   assembled sh ghc    <ghc>/lib/ghc-<ver>/package.conf.d
  #   older layouts       <ghc>/lib/package.conf.d
  #
  # Getting this one wrong is SILENT: stdenv sets `shopt -s nullglob`,
  # so a missing dir just makes the `*.conf` walk below yield nothing
  # and the env file ends up listing no boot packages whatsoever.
  #
  # Mainline shapes are probed first throughout, so nothing changes for
  # the compilers that already work.
  discoverDbs = ''
    composedPkgDb=
    for d in ${composedStore}/ghc-*; do
      [ -d "$d/package.db" ] || continue
      composedPkgDb=$d/package.db
      break
    done
    if [ -z "$composedPkgDb" ] && [ -d ${composedStore}/host ]; then
      hostPlatformDir=$(${ghc}/bin/${ghc.targetPrefix or ""}ghc --info 2>/dev/null \
        | sed -n 's/.*("Target platform","\([^"]*\)").*/\1/p' | head -1)
      if [ -z "$hostPlatformDir" ]; then
        echo "shell-for-v2: ${ghc.targetPrefix or ""}ghc --info gave no Target platform," >&2
        echo "  so the host dir under ${composedStore}/host cannot be identified" >&2
        exit 1
      fi
      if [ ! -d "${composedStore}/host/$hostPlatformDir/package.conf.d" ]; then
        echo "shell-for-v2: no package.conf.d for target platform '$hostPlatformDir'" >&2
        echo "  under ${composedStore}/host" >&2
        exit 1
      fi
      composedPkgDb=${composedStore}/host/$hostPlatformDir/package.conf.d
    fi
    if [ -z "$composedPkgDb" ]; then
      echo "shell-for-v2: no package db found under ${composedStore}" >&2
      exit 1
    fi

    globalPkgDb=
    for d in ${ghc}/lib/ghc-${ghc.version}/lib/package.conf.d \
             ${ghc}/lib/ghc-${ghc.version}/package.conf.d \
             ${ghc}/lib/package.conf.d; do
      [ -d "$d" ] || continue
      globalPkgDb=$d
      break
    done
    if [ -z "$globalPkgDb" ]; then
      echo "shell-for-v2: no global package db found under ${ghc}" >&2
      exit 1
    fi
  '';
  # Use `pkgsBuildBuild.runCommand` (build-build stdenv) rather
  # than `pkgs.runCommand` (cross stdenv).  `packageEnv` and
  # `wrappedGhc` end up in the shell's `nativeBuildInputs`; if
  # they're constructed against the cross-host stdenv, mkShell's
  # nativeBuildInputs splicing eventually evaluates the cross
  # stdenv's `cc.isClang` (via setup-hook chains) and throws "no C
  # compiler provided for this platform" on platforms like ghcjs.
  # The shell is a build-platform tool — its helpers belong on the
  # build platform too.
  packageEnv = pkgs.pkgsBuildBuild.runCommand "${ghc.name}-v2-shell-env-file"
    { preferLocalBuild = true; } ''
      mkdir -p $out
      ${discoverDbs}
      {
        echo "clear-package-db"
        echo "global-package-db"
        echo "package-db $composedPkgDb"
        # A package-env file explicitly lists which packages are
        # visible — listed dbs alone aren't enough to expose them,
        # unlike plain `-package-db`.  Walk both the boot db
        # (base, directory, ghc-prim, ...) and the composed store
        # and emit `package-id <id>` for every unit.  Cabal pretty-
        # prints long `id:` values onto the next line indented;
        # short boot ids fit on the same line — handle both.
        emit_package_id() {
          awk '
            /^id:/ {
              if (NF >= 2) { print "package-id " $2; exit }
              getline; print "package-id " $1; exit
            }
          ' "$1"
        }
        # ...but never list an RTS way.  GHC links one RTS into every
        # process and GHCi carries its symbols as built-ins, so exposing
        # another copy makes the interpreter load a second one:
        #
        #   GHC runtime linker: fatal error: I found a duplicate
        #   definition for symbol hs_atomic_xor32
        #   whilst processing object file .../HSrts-1.0.3-threaded-nodebug.o
        #   The symbol was previously defined in (GHCi built-in symbols)
        #
        # ghc914-sh registers the RTS once per way, each way a public
        # sub-library of `rts`: the package NAME is therefore the
        # mangled `z-rts-z-threaded-nodebug`, the id is
        # `rts-1.0.3-threaded-nodebug`, and each carries its own
        # `hs-libraries: HSrts-1.0.3-<way>`.  All four are dropped, not
        # just the way ghc itself was built with -- every way exports
        # the same symbols, so any of them collides.
        #
        # Matching on the mangled name is what makes this safe for the
        # compilers that are green today: only a fork that registers
        # per-way RTS sub-libraries has a `z-rts-z-*` to match, so every
        # mainline env file comes out byte-identical.  The plain `rts`
        # conf stays listed either way -- it declares no `hs-libraries`
        # (it is the header/shim package GHC special-cases) so it loads
        # nothing -- and so do `rts-fs` and `rts-headers`, which are
        # ordinary libraries that merely share the prefix.
        for conf in "$globalPkgDb"/*.conf "$composedPkgDb"/*.conf; do
          [ -e "$conf" ] || continue
          case "$(awk '/^name:/ { print $2; exit }' "$conf")" in
            z-rts-z-*) continue ;;
          esac
          emit_package_id "$conf"
        done
      } > $out/env
    '';
  # Shared base shim — same one a slice's `cabal v2-build` uses
  # via `--with-compiler=`, so the shell's ghc behaves like the
  # slice's ghc (cabal near-compiler aliases, ghcjs settings
  # patch, native-musl iserv aliases).  No ghcjs ar wrapping is
  # needed in the shell (no cabal v2-build link step here).
  baseShim = makeGhcShim { inherit ghc; };

  # `ghc-pkg` exposure mode: layer makeWrapper env vars on top of
  # the shim so `ghc -e ...` / `ghc-pkg list` see the composed
  # store.  Wrapping a wrapper is fine — the outer one exec's
  # `baseShim/bin/...` which in turn exec's real ghc with `-B`.
  wrappedGhc = pkgs.pkgsBuildBuild.runCommand "${ghc.name}-v2-shell-env"
    { nativeBuildInputs = [ pkgs.pkgsBuildBuild.makeWrapper ];
      preferLocalBuild = true;
      passthru = {
        inherit (ghc) version meta;
        targetPrefix = ghc.targetPrefix or "";
      };
    } ''
      mkdir -p $out/bin
      ${discoverDbs}
      prefix="${ghc.targetPrefix or ""}"
      # Symlink every shim binary so PATH-driven invocations
      # (alex, happy, hsc2hs, unlit, ...) still find them.
      for f in ${baseShim}/bin/*; do
        ln -s "$f" $out/bin/$(basename "$f")
      done
      # ghc / ghci / runghc / runhaskell / haddock honour
      # GHC_ENVIRONMENT and will pick up our package-id list.
      for prg in ghc ghci ghc-${ghc.version} ghci-${ghc.version} \
                 runghc runhaskell \
                 haddock; do
        if [ -e ${baseShim}/bin/$prefix$prg ]; then
          rm -f $out/bin/$prefix$prg
          makeWrapper \
            ${baseShim}/bin/$prefix$prg \
            $out/bin/$prefix$prg \
            --set GHC_ENVIRONMENT "${packageEnv}/env"
        fi
      done
      # ghc-pkg doesn't read GHC_ENVIRONMENT; use GHC_PACKAGE_PATH
      # so `ghc-pkg list` etc. show the composed store's units.
      for prg in ghc-pkg ghc-pkg-${ghc.version}; do
        if [ -e ${baseShim}/bin/$prefix$prg ]; then
          rm -f $out/bin/$prefix$prg
          makeWrapper \
            ${baseShim}/bin/$prefix$prg \
            $out/bin/$prefix$prg \
            --set GHC_PACKAGE_PATH "$composedPkgDb:"
        fi
      done
    '';

  # Pick exactly one path for surfacing the dep closure.  In
  # `cabal-store` mode the shell ghc IS the same shim a slice's
  # `cabal v2-build` uses — same `-B<libdir>` flag, same cabal
  # near-compiler aliases, same musl iserv aliases.  In `ghc-pkg`
  # mode we layer env-var wrappers on top to make `ghc-pkg list`
  # and `ghc -e ...` see the composed store directly.
  shellGhc = if exposePackagesVia == "ghc-pkg" then wrappedGhc else baseShim;
  shellSyncTools = lib.optional (exposePackagesVia == "cabal-store") cabalStoreSync
    ++ [ cabalProjectLocalSync ];
  shellSyncHook = lib.optionalString (exposePackagesVia == "cabal-store") v2ShellHook;

in
mkShell {
  nativeBuildInputs =
       # The solver shim must precede `shellGhc`: it mirrors it and adds a
       # `ghc-pkg` carrying `--global-package-db <composedStore>`, which is
       # how the injected boot pins below become satisfiable.  There is no
       # cabal wrapper to route it through -- see `applyShellBootFix`.
       lib.optional applyShellBootFix solverShim
    ++ [ shellGhc
         # Also include the raw `ghc` so its
         # `depsTargetTargetPropagated` chain reaches the shell's
         # build env — slices already get this via their own
         # `nativeBuildInputs = [ ghc ... ]`; the shim alone (a
         # `runCommand` drv) drops the propagation.  Concretely:
         # wasm32-wasi-ghc propagates `libffi-wasm.out` so the wasm
         # cc-wrapper adds `-L<libffi-wasm>/lib` to
         # `NIX_LDFLAGS_FOR_TARGET`, letting `wasm-ld -lffi` resolve
         # when `cabal v2-build` links a wasm exe inside the shell.
         ghc
       ]
    ++ shellSyncTools
    ++ crossCabalWrapper
    ++ toolDrvs
    ++ hoogleDrvs
    ++ buildToolDrvs
    ++ additionalTools
    # On Darwin the apple-sdk overlay sets `DEVELOPER_DIR` to the
    # nix-store SDK path (just headers/libs, no tools), so the
    # `/usr/bin/git` xcrun shim fails with `tool 'git' not found`.
    # Nix-managed git on PATH bypasses the shim entirely.  Cheap to
    # include unconditionally — most v2 shell users want git on
    # PATH anyway, and `gitMinimal` keeps the closure small.
    ++ [ pkgs.buildPackages.gitMinimal ]
    # `pkg-config` on PATH unconditionally.  cabal's solver probes
    # `pkg-config <name>` whenever a package declares
    # `pkgconfig-depends:` (e.g. `zlib +pkg-config` in this project);
    # if it's missing cabal silently flips `+pkg-config` to
    # `-pkg-config`, and the resulting unit-id diverges from
    # plan-nix's (which was solved with `cabalPkgConfigWrapper`
    # available) — cabal then rebuilds the lib from source instead
    # of reusing the slice in the cabal store.  v1's shell got
    # pkg-config in through each slice's pkgconfig-depends closure
    # via stdenv propagation; v2 slices flow through the cabal store
    # rather than via `buildInputs`, so we add it directly.  Always
    # on, even when no selected pkg has pkgconfig-depends — keeps
    # the unit-id stable if the user adds a pkgconfig dep later, and
    # matches v1's "always present" feel.  `cabalPkgConfigWrapper`
    # is the real pkg-config plus a `--libs --static` failure shim
    # (issue #1642), not the fake `allPkgConfigWrapper` used during
    # plan-nix evaluation.
    ++ [ pkgs.buildPackages.cabalPkgConfigWrapper ]
    ++ nativeBuildInputs
    ++ inputsFromNativeBuildInputs;
  buildInputs = buildInputs
    # Surface every selected component's and dep slice's C-side deps
    # (`component.libs`, `component.pkgconfig`, `component.frameworks`)
    # in the shell.  Each v2 slice exposes these as
    # `passthru.runtimeLibs` (`comp-v2-builder.nix`, the same set
    # that lands in the slice's own `extraBuildInputs`).  Without
    # this, the `pkg-config` we just added to nativeBuildInputs
    # doesn't find any of the project's pkgconfig deps — e.g.
    # `pkg-config --exists zlib` fails because no `zlib.pc` is on
    # `PKG_CONFIG_PATH` — and cabal's solver flips `+pkg-config`
    # off for the affected Haskell packages, diverging the unit-ids
    # from plan-nix.  Mirrors v1's `systemInputs` line in
    # `shell-for.nix:108`, which collects the same set via
    # `c.buildInputs ++ c.propagatedBuildInputs` propagation.
    ++ lib.concatMap (s: s.passthru.runtimeLibs or [])
         (selectedAllComps ++ depSlices)
    ++ inputsFromBuildInputs;
  shellHook =
    cabalProjectLocalShellHook + "\n"
    + shellSyncHook + "\n"
    + inputsFromShellHook
    + shellHook;
  # Expose the composed dep store via passthru (and not as a
  # top-level attr) — recent nixpkgs's `mkDerivation` folds
  # unknown top-level attrs into `env` and type-checks each value,
  # which under cross targets like ghcjs forces evaluation of
  # the host stdenv's `bashInteractive` while checking
  # `isDerivation`, hitting `stdenv.cc.isClang` against a stdenv
  # with no cc and throwing "no C compiler provided for this
  # platform".
  passthru = {
    # Mirror the `.store` attr a v2 component exposes so callers can
    # build the composed dep store standalone with
    # `nix-build -A <project>.shell.store`.
    store = composedStore;
    inherit composedStore depSlices cabalStoreSync cabalProjectLocalSync crossCabalWrapper;
    ghc = shellGhc;
  };
}
