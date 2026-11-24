# Finding unused code with Weeder

[Weeder](https://github.com/ocharles/weeder) finds declarations that nothing
uses, starting from a set of roots (such as `Main.main`).  It reads the `.hie`
files GHC writes with `-fwrite-ide-info`, and haskell.nix can write those for
you: with the `writeHieFiles` option a component gets an extra `hie` output
holding them.

This builds every component of the project's own packages with `.hie` files
and runs Weeder on them, failing when it finds something unused:

```nix
let
  inherit (pkgs) lib;
  inherit (pkgs.haskell-nix) haskellLib;
  project = pkgs.haskell-nix.cabalProject' {
    src = ./.;
    compiler-nix-name = "ghc96";
    # Write `.hie` files (in a `hie` output) for the project's own packages.
    modules = [{ projectPackages.writeHieFiles = true; }];
  };
  # Weeder must be built with the same GHC as the `.hie` files.
  weeder = project.tool "weeder" "latest";
  components = lib.concatMap haskellLib.getAllComponents
    (lib.attrValues (haskellLib.selectProjectPackages project.hsPkgs));
in pkgs.runCommand "weeder" { nativeBuildInputs = [ weeder ]; } ''
  mkdir hie
  ${lib.concatMapStrings (c: "cp -r --no-preserve=mode ${c.hie}/. hie/\n") components}
  weeder --config ${./weeder.toml} --hie-directory hie
  touch $out
''
```

with a `weeder.toml` next to it naming the roots, for instance:

```toml
roots = [ "^Main.main$" ]
type-class-roots = true
```

Weeder exits with code 228 when it finds unused declarations, so the
derivation fails and its log lists them:

```
wtest-0.1.0.0-LRvGzb728ko522FjXpWYee: src/Unused.hs:3:1: neverCalled
wtest-0.1.0.0-LRvGzb728ko522FjXpWYee: src/Used.hs:5:1: unusedHelper
```

Add it to the flake's `checks` (or the project's CI jobs) to keep the
project free of dead code.

Notes:

* `.hie` files are tied to the GHC version that wrote them, which is why
  Weeder comes from `project.tool` (built with the project's compiler)
  rather than from nixpkgs.
* Only the components Weeder is given are analysed.  To include tests and
  benchmarks, make sure they are built (they are part of `getAllComponents`
  above), and list any extra roots they need in `weeder.toml`.
* `writeHieFiles` is a component option of the default builder.
  `builderVersion = 2` does not support it yet.
