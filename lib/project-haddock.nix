# Combined haddock documentation for the libraries of a project's own
# packages: one directory with a contents page and an index across all of
# them, like `cabal haddock-project`, made from the docs the components
# already built (nothing is rebuilt with haddock here).
#
# Each component's doc output is copied whole into `<html>/<component>/`.
# Links between the project's components (haddock writes the absolute store
# path of the other component's docs) are rewritten to relative ones, so the
# project's part of the result can be moved or published as it is.  Links to
# dependencies keep pointing at the dependencies' docs in the store, which
# keeps those docs in the closure.
{ stdenv, lib, haskellLib, pkgs }:

# haskell.nix project
project:

let
  ghc = project.pkg-set.config.ghc.package;

  # A library component's docs, when it has any: v1 components only have
  # `doc` when `doHaddock` is on, v2 slices have it (but it throws) when
  # `documentation: True` is not set for the package.
  hasDoc = c: if c ? docEnabled then c.docEnabled else c ? doc;

  # `{ dir, doc }` for every documented library and sub-library of the
  # project's own packages (keyed on `dir`, since `hsPkgs` can hold a
  # package under more than one name).
  components = lib.attrValues (lib.listToAttrs (map (x: lib.nameValuePair x.dir x)
   (lib.concatLists (lib.mapAttrsToList (pname: pkg:
    let
      # The attribute name can be a unit id, so use the package's own name.
      name = pkg.identifier.name or pname;
      version = pkg.identifier.version or null;
      pkgDir = if version == null then name else "${name}-${version}";
      libs =
           lib.optional (pkg.components ? library) { dir = pkgDir; c = pkg.components.library; }
        ++ lib.mapAttrsToList (n: c: { dir = "${pkgDir}-${n}"; inherit c; })
             (pkg.components.sublibs or {});
    in map ({ dir, c }: { inherit dir; inherit (c) doc; }) (lib.filter (x: hasDoc x.c) libs)
  ) (haskellLib.selectProjectPackages project.hsPkgs)))));

  name = let n = project.args.name or null; in if n == null then "haskell-project" else n;

in stdenv.mkDerivation {
  name = "${name}-haddock";

  nativeBuildInputs = [ ghc ];

  passthru = { inherit components; };

  buildCommand = ''
    html=$out/share/doc/${name}/html
    mkdir -p $html
  '' + lib.concatMapStrings ({ dir, doc }: ''
    cp -R ${doc} $html/${dir}
  '') components + ''
    chmod -R u+w $html

    # Point links between the project's components at the copies.  The
    # replacement is relative to each file's own directory.
    find $html -name '*.html' -o -name '*.json' | while read -r f; do
      rel=$(realpath --relative-to="$(dirname "$f")" "$html")
      sed -i ${lib.concatMapStringsSep " " ({ dir, doc }:
          "-e 's|file://${doc}|'\"$rel\"'/${dir}|g' -e 's|${doc}|'\"$rel\"'/${dir}|g'"
        ) components} "$f"
    done

    # The contents page and index across all the components.
    readInterfaces=()
    while read -r iface; do
      d=$(dirname "$iface")
      readInterfaces+=("--read-interface=''${d#$html/},$iface")
    done < <(find $html -name '*.haddock' -not -path '*/src/*' | sort)
    if [ ''${#readInterfaces[@]} -gt 0 ]; then
      cd $html
      # `-B`: some haddocks (ghc914-sh) insist on a GHC libdir even here
      # ("internal error: No GhcDir found").
      ${ghc.targetPrefix}haddock \
        -B"$(${ghc.targetPrefix}ghc --print-libdir)" \
        --gen-contents --gen-index --quickjump \
        --odir=$html \
        --title=${lib.escapeShellArg name} \
        "''${readInterfaces[@]}"
    fi

    mkdir -p $out/nix-support
    echo "doc haddock $html" >> $out/nix-support/hydra-build-products
  '';
}
