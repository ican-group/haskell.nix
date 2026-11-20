# Combined haddock documentation for the libraries of a project's own
# packages: one directory with a contents page and an index across all of
# them, like `cabal haddock-project`, made from the docs the components
# already built (nothing is rebuilt with haddock here).
#
# Only each component's html directory is copied, into `<html>/<dir>/`.
# The html directory is the one holding the component's `.haddock`
# interface: `share/doc/<pkg>/html[/<sublib>]` of a v1 `doc` output, the
# target unit's `share/doc/html[/<sublib>]` in a v2 doc slice (whose
# libraries, `.hi` files, package db and `dist-newstyle` stay out).
#
# Links between the project's components (haddock writes the absolute
# store path of the other component's html directory) are rewritten to
# relative ones, so the project's part of the result can be moved or
# published as it is.  Links to dependencies keep pointing at the
# dependencies' docs in the store, which keeps those docs in the closure.
{ stdenv, lib, haskellLib, pkgs }:

# haskell.nix project
project:

let
  # A library component's docs, when it has any: v1 components only have
  # `doc` when `doHaddock` is on, v2 slices have it (but it throws) when
  # `documentation: True` is not set for the package.
  hasDoc = c: if c ? docEnabled then c.docEnabled else c ? doc;

  # `{ dir, doc, primary, key }` for every documented library and
  # sub-library of the project's own packages.  `key` is the `hsPkgs`
  # attribute it came from; `primary` says that is the package's own name
  # (v2 also lists packages under their unit ids).
  allComponents = lib.concatLists (lib.mapAttrsToList (pname: pkg:
    let
      # The attribute name can be a unit id, so use the package's own name.
      name = pkg.identifier.name or pname;
      version = pkg.identifier.version or null;
      pkgDir = if version == null then name else "${name}-${version}";
      libs =
           lib.optional (pkg.components ? library) { dir = pkgDir; c = pkg.components.library; }
        ++ lib.mapAttrsToList (n: c: { dir = "${pkgDir}-${n}"; inherit c; })
             (pkg.components.sublibs or {});
    in map ({ dir, c }: { inherit dir; inherit (c) doc; primary = pname == name; key = pname; })
         (lib.filter (x: hasDoc x.c) libs)
  ) (haskellLib.selectProjectPackages project.hsPkgs));

  # Which of two entries comes first: the one under the package's own name,
  # then by `hsPkgs` attribute name.  Not by store path, which would make
  # the choice change whenever a hash does.
  before = a: b: if a.primary != b.primary then a.primary else a.key < b.key;

  # `hsPkgs` can hold the same component under more than one name, so drop
  # repeats of the same doc output first (keeping the first by `before`).
  # Different doc outputs that would land in the same directory (v2 can plan
  # one package as several units, e.g. with different flags or for the build
  # platform) all stay, in `before` order: the first in `<dir>`, the others
  # in `<dir>-2`, `<dir>-3`, ... with a warning, rather than one of them
  # silently replacing the others.
  uniqueDocs = lib.mapAttrsToList (_: xs: builtins.head (lib.sort before xs))
    (lib.groupBy (x: builtins.unsafeDiscardStringContext "${x.doc}") allComponents);
  byDir = lib.groupBy (x: x.dir) uniqueDocs;
  components = lib.concatLists (lib.mapAttrsToList (dir: xs:
    let n = builtins.length xs; in
    lib.warnIf (n > 1)
      "projectHaddock: ${toString n} different doc outputs for ${dir}; they are kept as ${dir}, ${dir}-2, ..."
      (lib.imap1 (i: x: { inherit (x) doc; dir = if i == 1 then dir else "${dir}-${toString i}"; })
        (lib.sort before xs))
  ) byDir);

  # The haddock that reads the interfaces should be the one that wrote
  # them.  A v2 doc slice carries the compiler it was built with (that can
  # differ from the package set's `ghc`, e.g. for `-target` cross
  # compilers); a v1 doc output was made with the package set's `ghc`.
  ghc =
    let fromDocs = lib.filter (g: g != null)
          (map (x: x.doc.passthru.haddockGhc or null) components);
    in if fromDocs != [] then builtins.head fromDocs
       else project.pkg-set.config.ghc.package;

  # Wrapper and two-stage compilers may not have a `targetPrefix`.
  prefix = ghc.targetPrefix or "";

  name = let n = project.args.name or null; in if n == null then "haskell-project" else n;

in stdenv.mkDerivation {
  name = "${name}-haddock";

  nativeBuildInputs = [ ghc ];

  passthru = { inherit components; };

  # `copyDocs <doc output> <dir>` copies the component's html directory
  # (found through its single `.haddock` file) to `$html/<dir>` and records
  # `<original html dir> <dir> <interface file name>` in `$TMPDIR/map`.  The
  # original directory is canonicalised, as the doc slices' package confs
  # (and so the links haddock wrote) are.
  #
  # The link rewrite then only touches html, json and js files that mention
  # one of the original html directories (`grep -lF`; never the binary
  # `.haddock` interfaces, which a length-changing edit would corrupt),
  # first replacing each with a placeholder and then the placeholder with
  # that file's relative path to `$html`, which is its depth below `$html`
  # in `../`s.
  #
  # `-B`: some haddocks (ghc914-sh) insist on a GHC libdir even for
  # `--gen-contents` ("internal error: No GhcDir found").
  buildCommand = ''
    html=$out/share/doc/${name}/html
    mkdir -p $html
    : > $TMPDIR/map

    copyDocs() {
      local doc="$1" dir="$2" ifaces
      mapfile -t ifaces < <(find "$doc" -name '*.haddock' -type f)
      case ''${#ifaces[@]} in
        0) echo "projectHaddock: no haddock interface in $doc, skipping $dir" >&2
           return ;;
        1) ;;
        *) echo "projectHaddock: more than one haddock interface in $doc:" "''${ifaces[@]}" >&2
           exit 1 ;;
      esac
      local src
      src=$(dirname "$(readlink -f "''${ifaces[0]}")")
      cp -R "$src" "$html/$dir"
      printf '%s %s %s\n' "$src" "$dir" "$(basename "''${ifaces[0]}")" >> $TMPDIR/map
    }
  '' + lib.concatMapStrings ({ dir, doc }: ''
    copyDocs ${doc} ${lib.escapeShellArg dir}
  '') components + ''
    chmod -R u+w $html

    sedArgs=()
    : > $TMPDIR/srcs
    while read -r src dir iface; do
      printf '%s\n' "$src" >> $TMPDIR/srcs
      sedArgs+=(-e "s|file://$src|@PROJECT_HADDOCK_ROOT@/$dir|g" -e "s|$src|@PROJECT_HADDOCK_ROOT@/$dir|g")
    done < $TMPDIR/map
    if [ -s $TMPDIR/srcs ]; then
      { grep -rlF --include='*.html' --include='*.json' --include='*.js' \
          -f $TMPDIR/srcs $html || true; } | while read -r f; do
        r=''${f#$html/}
        d=''${r//[^\/]/}
        rel=.
        for ((i = 0; i < ''${#d}; i++)); do
          if [ "$rel" = . ]; then rel=..; else rel=$rel/..; fi
        done
        sed -i "''${sedArgs[@]}" -e "s|@PROJECT_HADDOCK_ROOT@|$rel|g" "$f"
      done
    fi

    readInterfaces=()
    while read -r src dir iface; do
      readInterfaces+=("--read-interface=$dir,$html/$dir/$iface")
    done < $TMPDIR/map
    if [ ''${#readInterfaces[@]} -gt 0 ]; then
      cd $html
      ${prefix}haddock \
        -B"$(${prefix}ghc --print-libdir)" \
        --gen-contents --gen-index --quickjump \
        --odir=$html \
        --title=${lib.escapeShellArg name} \
        "''${readInterfaces[@]}"
    fi

    mkdir -p $out/nix-support
    echo "doc haddock $html" >> $out/nix-support/hydra-build-products
  '';
}
