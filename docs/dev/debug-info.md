# Building with DWARF debug info

Under the **v1** builder, every component derivation exposed a
`.dwarf` attribute that re-built that component with `enableDWARF =
true`.  As a side-effect that overlay also swapped the GHC for its
`.dwarf` variant — the same GHC distribution but with its own RTS /
`ghc-internal` libraries compiled with `-g`, so DWARF info covers
both the user's source and the runtime.

Under the **v2** builder this overlay-rebuild path no longer exists.
v2 reads its configure-args from `plan.json`, and `plan.json` doesn't
know the haskell.nix module-level `enableDWARF` flag.  Producing a
DWARF variant by overriding the flag after the fact would emit
`--enable-debug-info` Setup configure args that aren't in plan-nix,
the slice's UnitId would diverge from plan-nix's recorded UnitId,
and the slice would fail its UnitId check.

## How to build DWARF-enabled binaries with v2

The two ingredients v1's `.dwarf` overlay used to fold together are
now expressed separately at project level:

### 1. `debug-info:` in cabal.project — DWARF in the user's source

Move the configure-time toggle to `cabal.project` (or the project's
`cabalProjectLocal` argument) so plan-nix records it.  Project-wide:

```cabal
package *
  debug-info: 2
```

Per-package:

```cabal
package my-exe-pkg
  debug-info: 2
```

The slice's UnitId will then match plan-nix and the produced binary
carries DWARF debug info for the package's own modules.  Plain
`nix build .#…components.exes.foo` gives you a debug-info exe; no
separate `.dwarf` attribute needed.

### 2. `compilerSelection` — DWARF in the RTS / `ghc-internal`

If you also need DWARF entries for the GHC runtime (so backtraces
through `ghc-internal` / `base` symbols resolve to source lines),
swap the project's GHC for its `.dwarf` variant via the
`compilerSelection` argument to `cabalProject'` / `project'`:

```nix
project = cabalProject' {
  inherit compiler-nix-name evalSystem;
  src = ...;
  compilerSelection = p:
    pkgs.lib.mapAttrs (_: c: c.dwarf) p.haskell-nix.compiler;
  cabalProjectLocal = ''
    package *
      debug-info: 2
  '';
};
```

Routing the swap via `compilerSelection` keeps everything that
derives from the compiler (plan-nix, the slice's GHC, dummy-ghc)
on the same DWARF variant — every package's UnitId stays
consistent across the project.  Per-slice overrides via the old
`.dwarf` passthru would have diverged from plan-nix.

`c.dwarf` is the DWARF-enabled GHC drv.  Drop the `.dwarf` and the
selection falls back to the regular compiler; if a compiler in the
selection has no `.dwarf` variant the `compilerSelection` attribute
lookup will error loudly — better than silently producing a binary
where RTS symbols are missing from the DWARF dump.

## Why not just rebuild?

A reproducible `.dwarf` overlay would require re-solving plan-nix
with the debug-info toggles applied (so the recorded UnitIds are
the debug-info ones) **and** re-running the project with the DWARF
GHC variant.  Neither belongs in the per-component slice path; the
right place to express "DWARF build" is where every other
UnitId-affecting toggle lives — in `cabal.project` and the
project's `compilerSelection`.
