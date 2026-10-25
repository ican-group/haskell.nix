final: prev:
let
  # Shared by `allPkgConfigWrapper` (plan-time solving) and
  # `cabalPkgConfigWrapper` (in-slice solving): the pkg-config module
  # universe fabricated from nixpkgs METADATA, no builds involved.
  #
  # Prefer an explicit `pc-version` when the derivation carries one:
  # some packages' `.pc` `Version:` field differs from the derivation
  # `.version` (e.g. systemd's libsystemd.pc reports `259` while the
  # derivation `.version` is `259.3`).  The real `pkg-config` reads the
  # `.pc` field, so metadata answers must report the same value or a
  # slice's UnitId (which folds the resolved pkgconfig-dep version into
  # `pkgHashPkgConfigDeps`) will fork.
  #
  # Failing that, try the `.version` attribute, or failing that look in
  # the `.name`.  Some packages like `icu` have the correct version in
  # `.name` but no `.version`.
  getVersion = p: p.pc-version or p.version or (builtins.parseDrvName (p.name or "")).version;
  pkgconfigPkgs =
    final.lib.filterAttrs (_name: p: __length p > 0 && getVersion (__head p) != "")
      (import ../lib/pkgconf-nixpkgs-map.nix final);
in
{
  # systemd's `libsystemd.pc` reports only the major version (e.g. `259`),
  # whereas the derivation `.version` is e.g. `259.3`.  Set `pc-version` so
  # `allPkgConfigWrapper` (used by plan-to-nix) reports the same value the
  # real `pkg-config` returns inside a v2 build slice, keeping the resolved
  # `libsystemd` version — and therefore the slice's UnitId — in agreement.
  # The `pkgconf-pc-version` test verifies this matches `pkg-config --modversion`.
  systemd = prev.systemd.overrideAttrs (old: {
    passthru = (old.passthru or {}) // {
      pc-version = prev.lib.versions.major prev.systemd.version;
    };
  });

  # FreeType's `freetype2.pc` advertises a libtool/ABI version (e.g. `26.2.20`)
  # that is deliberately decoupled from the release `.version` (e.g. `2.13.3`):
  # see FreeType's `docs/VERSIONS.TXT`.  `pkg-config --modversion freetype2`
  # returns the libtool number, so plan-to-nix must report the same value or
  # the v2 slice's UnitId (which folds the resolved `freetype2` version into
  # `pkgHashPkgConfigDeps`) forks — taking every transitive consumer
  # (gi-freetype2 -> gi-harfbuzz -> gi-pango -> gi-gdk3 -> gi-gtk3 -> ...) with
  # it.  The mapping is an arbitrary per-release table (no formula), so we
  # encode the known rows and fall back to `.version` for unknown releases.
  # Adding `passthru.pc-version` does not change freetype's derivation, so this
  # neither rebuilds freetype nor forces it to build during planning.
  # The `pkgconf-pc-version` test verifies this matches `pkg-config --modversion`.
  freetype = prev.freetype.overrideAttrs (old: {
    passthru = (old.passthru or {}) // {
      pc-version =
        let
          # release version -> libtool/`.pc` version, from FreeType's
          # `docs/VERSIONS.TXT`.  Add new rows here when bumping freetype.
          pcVersions = {
            "2.11.0" = "24.0.18";
            "2.11.1" = "24.1.18";
            "2.12.0" = "24.2.18";
            "2.12.1" = "24.3.18";
            "2.13.0" = "25.0.19";
            "2.13.1" = "26.0.20";
            "2.13.2" = "26.1.20";
            "2.13.3" = "26.2.20";
            "2.14.0" = "26.3.20";
            "2.14.1" = "26.4.20";
            "2.14.2" = "26.5.20";
            "2.14.3" = "26.6.20";
          };
        in pcVersions.${prev.freetype.version} or (prev.lib.warn ''
          haskell.nix: no freetype `pc-version` for ${prev.freetype.version}; using the
          release version, which freetype2.pc usually disagrees with (e.g. 2.13.3 -> 26.2.20).
          Add a row to overlays/cabal-pkg-config.nix (see the libtool column in
          https://gitlab.freedesktop.org/freetype/freetype/-/raw/master/docs/VERSIONS.TXT):
              "${prev.freetype.version}" = "<`pkg-config --modversion freetype2`>";
        '' prev.freetype.version);
    };
  });

  # This is a wrapper for `cabal configure` use only.
  #
  # When creating a plan for building a project cabal first
  # runs `pkg-config --list-all` for a list of all the available
  # packages installed on the system.
  #
  # It then gets the corresponding versions by passing that list
  # on the command line to `pkg-config --modversion`.
  #
  # This gives cabal a full picture of what versions are available
  # when building the plan.
  #
  # When we run `cabal configure` in `lib/call-cabal-project-to-nix.nix`
  # we do not want to depend on every pkg-config package in `nixpkgs`
  # that could be used.  We also do not want the user to have to specify
  # every pkg-config package that their project requires.
  #
  # Instead this wrapper provides a list based on the contents
  # of `lib/pkgconf-nixpkgs-map.nix`.  To avoid depending
  # on the packages it gets the versions for `--modversions` from
  # the `.version` attribute of the derivation.
  #
  # In most cases this `.version` will be suitable, however there
  # are some packages where that is not the case.  If these cause
  # issues we should first try to fix `lib/pkgconf-nixpkgs-map.nix`
  # or the package.  If that does not work we may need a way to include
  # overrides here.
  allPkgConfigWrapper =
    # `getVersion` / `pkgconfigPkgs` are shared with
    # `cabalPkgConfigWrapper` below — see the file-level `let`.
    prev.pkg-config.overrideAttrs (attrs:
      let
        # These vars moved from attrs to attrs.env in nixpkgs adc8900df1758eda56abd68f7d781d1df74fa531
        # ... and then 706de783c83f3e24e5ea2a28e1249320aa19f57e moved them to attrs.passthru
        # Support all three for the time being.
        targetPrefix = attrs.targetPrefix
                    or attrs.env.targetPrefix
                    or attrs.passthru.targetPrefix;
        baseBinName = attrs.baseBinName
                   or attrs.env.baseBinName
                   or attrs.passthru.baseBinName;
      in {
      installPhase = attrs.installPhase + ''
        mv $out/bin/${targetPrefix}${baseBinName} \
          $out/bin/${targetPrefix}${baseBinName}-wrapped

        cat <<EOF >$out/bin/${targetPrefix}${baseBinName}
        #!${final.stdenv.shell}
        if [[ "\$1" == "--list-all" ]]; then
          OUTPUT=\$(mktemp)
          ERROR=\$(mktemp)
        cat <<EOF2
        ${final.pkgs.lib.concatStrings (map (name: ''
          ${name}
        '') (__attrNames pkgconfigPkgs))
         }EOF2
        elif [[ "\$1" == "--modversion" ]]; then
          OUTPUT=\$(mktemp)
          ERROR=\$(mktemp)
        cat <<EOF2
        ${final.pkgs.lib.concatStrings (map (p: ''
          ${getVersion (builtins.head p)}
        '') (__attrValues pkgconfigPkgs))
        }EOF2
        else
          $out/bin/${targetPrefix}${baseBinName}-wrapped "\$@"
        fi
        EOF
        chmod +x $out/bin/${targetPrefix}${baseBinName}
      '';
  });
  # The pkg-config every v2 slice runs (`--with-pkg-config=`).  Hybrid:
  #
  #   * Real `.pc` files (this slice's realized `-dev` buildInputs, on
  #     PKG_CONFIG_PATH) answer first — configure-time `--cflags` /
  #     `--libs` queries for units the slice actually BUILDS need real
  #     paths, and `--modversion` prefers them too.
  #
  #   * Names with no realized `.pc` fall back to the SAME nixpkgs
  #     metadata plan-time solving used (`pkgconfigPkgs` above): the
  #     slice's solver must see pkgconfig-depends of units it merely
  #     SOLVES — sibling components' deps staged source-only via
  #     comp-v2-builder's `metadataSourceFrags` — without realizing
  #     their C stacks (leksah's exe:leksah webkitgtk, when the target
  #     is exe:leksah-warp).  The `pc-version` passthru discipline
  #     (see `getVersion`) keeps both answer sources equal, which is
  #     what keeps UnitIds identical whichever one answered.  A
  #     configure-time query for a metadata-only name still fails
  #     loudly (no real `.pc`) — nothing can silently link against
  #     fabricated flags.
  #
  #   * `--libs --static`: cabal 3.8 asks for linker options for both
  #     dynamic and static linking, and some derivations' `.pc` (glib)
  #     fail with `--static`.  Keep the historical workaround: make
  #     cabal lazy by returning a single (hopefully self-describing)
  #     fake option on failure.
  #     See https://github.com/input-output-hk/haskell.nix/issues/1642
  #
  # One derivation serves every slice — the metadata list is the full
  # `lib/pkgconf-nixpkgs-map.nix` universe, not a per-slice set, so
  # slices don't fork on it.
  cabalPkgConfigWrapper = prev.pkg-config.overrideAttrs (attrs: (
  let
    # These vars moved from attrs to attrs.env in nixpkgs adc8900df1758eda56abd68f7d781d1df74fa531
    # ... and then 706de783c83f3e24e5ea2a28e1249320aa19f57e moved them to attrs.passthru
    # Support all three for the time being.
    targetPrefix = attrs.targetPrefix
                or attrs.env.targetPrefix
                or attrs.passthru.targetPrefix;
    baseBinName = attrs.baseBinName
               or attrs.env.baseBinName
               or attrs.passthru.baseBinName;
    # Assoc-array entries rather than `case` branches: the lookup used to
    # be `v=$(metaversion "$name")`, and a command substitution FORKS.
    # cabal asks for every name in this universe (~3.5k), so that was 3.5k
    # forks on top of the pkg-config spawns -- and a 3.5k-branch `case` is
    # a linear scan, making the whole thing quadratic.  An array is loaded
    # once and indexed in O(1) with no subshell.
    metaVersionEntries = final.lib.concatStrings
      (final.lib.mapAttrsToList (name: ps:
        "    [${final.lib.escapeShellArg name}]=${
          final.lib.escapeShellArg (getVersion (__head ps))}\n")
        pkgconfigPkgs);
    metaNames = final.lib.concatMapStrings (n: n + "\n") (__attrNames pkgconfigPkgs);
    # `writeScript`, not `builtins.toFile`: the script references
    # derivations (the shell), which toFile forbids.
    hybrid = final.writeScript "cabal-pkg-config-hybrid" (''
      #!${final.stdenv.shell}
      real="$(dirname "$0")/${targetPrefix}${baseBinName}-wrapped"
      # Loaded lazily: `--libs` / `--cflags` and the catch-all `exec` path
      # never need it, and this is the hot script in every slice's plan.
      hsnix_load_meta() {
        [ -n "''${hsnix_meta_loaded:-}" ] && return 0
        declare -gA hsnix_meta=(
      '' + metaVersionEntries + ''
        )
        hsnix_meta_loaded=1
      }
      case "''${1:-}" in
        --list-all)
          # Real entries verbatim, then metadata names the real set
          # lacks (cabal parses only the first word of each line).
          declare -A hsnix_seen=()
          while IFS= read -r line; do
            [ -n "$line" ] || continue
            hsnix_seen[''${line%% *}]=1
            printf '%s\n' "$line"
          done < <("$real" --list-all 2>/dev/null)
          while IFS= read -r name; do
            [ -n "$name" ] || continue
            [ -n "''${hsnix_seen[$name]:-}" ] \
              || printf '%s %s\n' "$name" "(haskell.nix metadata)"
          done <<'HSNIX_NAMES'
      '' + metaNames + ''
      HSNIX_NAMES
          ;;
        --modversion)
          shift
          # Ask the real pkg-config ONCE which modules it actually has.
          #
          # cabal follows `--list-all` with `--modversion` for every name
          # it just received, and the list we hand it is the whole
          # `pkgconf-nixpkgs-map.nix` universe (~3.5k names) rather than
          # the handful with a real `.pc`.  Shelling out per name then
          # spawns thousands of processes that are certain to fail --
          # each one a nixpkgs wrapper script plus the binary it execs.
          # Measured on a cross-musl slice for a package with NO
          # pkgconfig-depends at all: the real pkg-config knew 0 modules,
          # cabal asked for 3490, and the resulting 6988 spawns were 63 of
          # the plan's 65 seconds.  Consulting `--list-all` first turns
          # that into one process.
          #
          # Answer order is unchanged where it can matter: a real `.pc`
          # still wins over metadata (a slice's UnitId folds the resolved
          # version into `pkgHashPkgConfigDeps`, so the two must agree),
          # metadata answers what the real one does not have, and the real
          # one is still tried as a last resort for the corner case of a
          # module that `--modversion` resolves but `--list-all` omits.
          declare -A hsnix_real=()
          while IFS= read -r line; do
            [ -n "$line" ] || continue
            hsnix_real[''${line%% *}]=1
          done < <("$real" --list-all 2>/dev/null)
          hsnix_load_meta
          status=0
          for name in "$@"; do
            if [ -n "''${hsnix_real[$name]:-}" ] \
               && v=$("$real" --modversion "$name" 2>/dev/null); then
              printf '%s\n' "$v"
            elif [ -n "''${hsnix_meta[$name]+x}" ]; then
              printf '%s\n' "''${hsnix_meta[$name]}"
            elif v=$("$real" --modversion "$name" 2>/dev/null); then
              printf '%s\n' "$v"
            else
              echo "Package '$name' not found (no .pc file, no haskell.nix metadata)" >&2
              status=1
            fi
          done
          exit $status
          ;;
        --libs)
          if [ "''${2:-}" = "--static" ]; then
            OUTPUT=$(mktemp)
            ERROR=$(mktemp)
            if "$real" "$@" >"$OUTPUT" 2>"$ERROR"; then
              cat "$OUTPUT"
            else
              echo "--error-pkg-config-static-failed=$ERROR"
            fi
          else
            exec "$real" "$@"
          fi
          ;;
        *)
          exec "$real" "$@"
          ;;
      esac
    '');
  in {
    installPhase = attrs.installPhase + ''
      mv $out/bin/${targetPrefix}${baseBinName} \
        $out/bin/${targetPrefix}${baseBinName}-wrapped
      cp ${hybrid} $out/bin/${targetPrefix}${baseBinName}
      chmod +x $out/bin/${targetPrefix}${baseBinName}
    '';
  }));
}
