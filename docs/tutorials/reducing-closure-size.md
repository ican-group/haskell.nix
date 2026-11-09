# Reducing closure size (removing the gcc dependency)

By default the executables produced by haskell.nix keep a reference to
the compiler toolchain in their runtime closure.  The most visible
symptom is that a `nix why-depends` on a built executable shows a
dependency on the full `gcc` package (over 100&nbsp;MB), which then ends
up in Docker images and other deployments.

This happens because, unlike the `stdenv` used for C packages in
Nixpkgs, haskell.nix does **not** strip binaries or shrink their RPATHs
by default (see the [rationale](#why-are-these-not-the-default) below).
As a result store-path references to the toolchain — including the
`gcc` used to compile the RTS headers — survive in the output and Nix
records them as runtime dependencies.

This page describes the opt-in knobs you can use to trim those
references.

## Diagnosis

Use `nix why-depends` to confirm what is pulling `gcc` (or any other
unwanted path) into the closure:

```shell
for dep in $(nix-store -q --requisites ./result | grep gcc); do
  nix why-depends ./result "$dep"
done
```

(for a flake-based project, `nix build .#your-exe` first to get
`./result`).  Check the actual paths found this way rather than
comparing against `nixpkgs#gcc`: that is the compiler *wrapper*,
possibly from a different Nixpkgs revision, so `why-depends` can find
no dependency even when the executable retains the full compiler.
There may be more than one match (for instance `gcc-…` and
`gcc-…-lib`); look at each of them.  `--requisites` lists the whole
closure, so this also finds a `gcc` that is only reached indirectly
(`why-depends` then shows the chain); the recipes below only remove
references held by the executable itself.

The output usually points at a reference embedded in the executable
itself (frequently via the bundled RTS include files), rather than a
genuine shared-library dependency.

## Dynamically linked executables

For a normal, dynamically linked executable, set `dontStrip = false`
(to strip the binary) and `dontPatchELF = false` (to run
`patchelf --shrink-rpath`, Linux only) on the specific `exe` component:

```nix
pkgs.haskell-nix.project {
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "your-project";
    src = ./.;
  };
  compiler-nix-name = "ghc984";

  modules = [{
    packages.your-package.components.exes.your-exe = {
      dontStrip = false;
      dontPatchELF = false;
    };
  }];
}
```

Setting these on the component (rather than globally) keeps the change
scoped to the executable you ship, so libraries used for further
linking are left untouched.

`dontStrip = false` also makes haskell.nix pass
`--enable-executable-stripping` and `--enable-library-stripping` to
`Setup` (instead of the `--disable-...` flags it passes by default), so
Cabal strips as well.

The `.dwarf` variant of the component (`your-exe.dwarf`) inherits these
options, so with `dontStrip = false` its debug information is stripped
again.  If you also use `.dwarf`, set `dontStrip` back to `true` for it,
e.g. `your-exe.dwarf.override { dontStrip = true; }`.

These component options (and `postInstall` below) are applied by the
default per-component builder (`builderVersion = 1`).  The v2 slice
builder (`builderVersion = 2`, the default for the stable-haskell
compilers such as `ghc914-sh`) does not strip its outputs and ignores
them.  With v2 you can ask Cabal itself to strip the executable by
adding a per-package setting to `cabalProjectLocal`, which is passed
through to the slice's `cabal` invocation:

```nix
  cabalProjectLocal = ''
    package your-package
      executable-stripping: True
  '';
```

Check the result with the [diagnosis](#diagnosis) steps above.  See
[Post-processing a built executable](#post-processing-a-built-executable)
for an approach that works with either builder.

## Fully static executables

For a fully static executable (for example one built against
`pkgsCross.musl64` / `pkgsStatic`), `patchelf --shrink-rpath` has
nothing to shrink and stripping alone may not be enough: absolute
store paths can remain baked into the binary as plain string data,
which Nix still scans and treats as runtime dependencies.

Remove them explicitly with `remove-references-to` (or `nukeReferences`)
in a `postInstall`:

```nix
pkgs.haskell-nix.project {
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "your-project";
    src = ./.;
  };
  compiler-nix-name = "ghc984";

  modules = [{
    packages.your-package.components.exes.your-exe = {
      dontStrip = false;
      # Drop references to the compiler and its libraries that are
      # left embedded in the static binary.
      postInstall = ''
        for ref in ${pkgs.stdenv.cc.cc} ${pkgs.stdenv.cc.cc.lib}; do
          ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to \
            -t "$ref" "$out/bin/your-exe"
        done
      '';
    };
  }];
}
```

`pkgs.stdenv.cc.cc` is the unwrapped compiler (the wrapper,
`pkgs.stdenv.cc` or `pkgs.gcc`, is a different store path, so removing
references to it leaves the real compiler in the closure).  Make sure
the paths in the loop match the store paths found during
[diagnosis](#diagnosis), and add each other path that
`nix why-depends` reports as unwanted.  `nukeReferences` (`${pkgs.buildPackages.nukeReferences}/bin/nuke-refs`)
is a blunter alternative that rewrites *every* store-path reference in
the given files; only use it when you are certain the binary has no
legitimate runtime dependencies.

## Post-processing a built executable

Instead of changing how the component is built, you can copy the
executable into a new derivation and clean it up there.  This works
with both builders (and leaves the original component, and anything
that depends on it, unchanged):

```nix
let
  exe = project.hsPkgs.your-package.components.exes.your-exe;
in pkgs.runCommand "your-exe-slim" {
  nativeBuildInputs = [ pkgs.buildPackages.removeReferencesTo ];
} ''
  mkdir -p $out/bin
  cp ${exe.exePath} $out/bin/
  chmod +w $out/bin/${exe.exeName}
  remove-references-to -t ${pkgs.stdenv.cc.cc} $out/bin/${exe.exeName}
''
```

As above, use the store paths `nix why-depends` reported.
`runCommand` does not run the stdenv fixup phase, so the binary is not
stripped; to strip it as well, use `pkgs.runCommandCC` and add
`$STRIP $out/bin/${exe.exeName}`.  (`exe.exeName` includes the
`.exe` suffix when building for Windows.)  Data files and other runtime
dependencies of the executable are not copied, so check that it still
runs.

## Why are these not the default?

Stripping is not enabled by default because it has historically been
reported to occasionally break Haskell binaries — the stripper can be
too aggressive given the way Haskell code is laid out in object files
(see the discussion in
[haskell.nix#829](https://github.com/input-output-hk/haskell.nix/issues/829)
and [haskell.nix#336](https://github.com/input-output-hk/haskell.nix/pull/336#discussion_r351491851)).
Whether this is still a problem with current GHC and binutils has not
been conclusively established, so the safe choice is to leave stripping
off by default and let you opt in per component.

Because of that history, **test the affected executables after enabling
these options** — run them, run their test suites, and check anything
that relies on runtime code loading (Template Haskell is a build-time
concern and is unaffected, but plugin-style `dlopen` of Haskell objects
is worth checking).

See `dontStrip` and `dontPatchELF` in the
[Module options](../reference/modules.md) reference.
