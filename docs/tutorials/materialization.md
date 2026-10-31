# Materialization

## What is materialization?

Capturing and storing the Nix files for a project so that they do
not need to be built (or checked).  This allows us to cache the input
of an IFD (import from derivation).

## Why use materialization?

Using functions like `project`, `cabalProject`, `stackProject`
and `hackage-package` results in a lot of dependencies (all the
dependencies of nix-tools for instance).

* They can be slow to calculate (even if no work needs to be done it
  is not unusual for it to take 5 seconds per project).

* They can be slow to build (or download) on machines that do not
  yet have them in the Nix store.

* Hydra does not show progress because it does not provide feedback until it
  has a list of jobs and the list of jobs cannot depend on the Nix expressions
  being present (although this is often blamed on IFD it would be the same if
  it wrote out JSON files and read them in)

## When is it OK to materialize?

* The Nix expressions are unlikely to change frequently (and when it does you
  are happy to manually update it).

* You are happy to script something to update the materialized Nix files
  automatically.

* You are certain that the IFD you materialize is not `system`-dependent. If it
  was you'd obtain different Nix expressions depending on which `system` the
  IFD was evaluated.

## How can we materialize the Nix files?

Lets say we want to build `hlint`.  We might start with an `hlint.nix`
file that looks like this:

```nix
let inherit (import ./. {}) sources nixpkgsArgs;
    pkgs = import sources.nixpkgs nixpkgsArgs;
    hlint = pkgs.haskell-nix.hackage-package {
      compiler-nix-name = "ghc8102";
      name = "hlint";
      version = "2.2.11";
    };
in hlint
```

Building this may result in a lot of output, but if you build
it again it should give just:

```
$ nix-build hlint.nix -A components.exes.hlint
trace: No index state specified for hlint, using the latest index state that we know about (2021-01-04T00:00:00Z)!
/nix/store/2ybrfmcp79gg75ad4pr1cbxjak70yg8b-hlint-exe-hlint-2.2.11
```

To materialize the Nix files we need to take care to pin down the inputs. Stack
projects have their inputs pinned through specifying the snapshot. For cabal
projects this means we must specify the `index-state` of hackage we want to
use:

```nix
let inherit (import ./. {}) sources nixpkgsArgs;
    pkgs = import sources.nixpkgs nixpkgsArgs;
    hlint = pkgs.haskell-nix.hackage-package {
      compiler-nix-name = "ghc8102";
      name = "hlint";
      version = "2.2.11";
      index-state = "2021-01-04T00:00:00Z";
    };
in hlint
```

Now if we build again we get a hint telling use how to calculate a suitable
sha256 hash to turn the derivation containing the Nix files into a fixed-output
derivation:

```
$ nix-build hlint.nix -A components.exes.hlint
trace: To make project.plan-nix for hlint a fixed-output derivation but not materialized, set `plan-sha256` to the output of the 'calculateMaterializedSha' script in 'passthru'.
trace: To materialize project.plan-nix for hlint entirely, pass a writable path as the `materialized` argument and run the 'updateMaterialized' script in 'passthru'.
/nix/store/2ybrfmcp79gg75ad4pr1cbxjak70yg8b-hlint-exe-hlint-2.2.11

$ nix-build hlint.nix -A project.plan-nix.passthru.calculateMaterializedSha | bash
trace: To make project.plan-nix for hlint a fixed-output derivation but not materialized, set `plan-sha256` to the output of the 'calculateMaterializedSha' script in 'passthru'.
trace: To materialize project.plan-nix for hlint entirely, pass a writable path as the `materialized` argument and run the 'updateMaterialized' script in 'passthru'.
04hdgqwpaswmyb0ili7fwi6czzihd6x0jlvivw52d1i7wv4gaqy7
```

For a Stack project all occurences of `plan-nix` and `plan-sha256` are replaced
by `stack-nix` and `stack-sha256`, respectively.  We can add the hash as
`plan-sha256`:

```nix
let inherit (import ./. {}) sources nixpkgsArgs;
    pkgs = import sources.nixpkgs nixpkgsArgs;
    hlint = pkgs.haskell-nix.hackage-package {
      compiler-nix-name = "ghc8102";
      name = "hlint";
      version = "2.2.11";
      index-state = "2021-01-04T00:00:00Z";
      plan-sha256 = "04hdgqwpaswmyb0ili7fwi6czzihd6x0jlvivw52d1i7wv4gaqy7";
    };
in hlint
```

Just adding the hash might help reuse of the cached Nix expressions, but Nix
will still calculate all the dependencies (which can add seconds to `nix-build`
and `nix-shell` commands when no other work is needed) and users who do not yet
have the dependencies in their store will have to wait while they are built or
downloaded.

Running `nix-build` again gives us a hint on what we can do next:

```
$ nix-build hlint.nix -A components.exes.hlint
trace: To materialize project.plan-nix for hlint entirely, pass a writable path as the `materialized` argument and run the 'updateMaterialized' script in 'passthru'.
/nix/store/2ybrfmcp79gg75ad4pr1cbxjak70yg8b-hlint-exe-hlint-2.2.11
```

To capture the Nix expressions we can do something like:

```nix
let inherit (import ./. {}) sources nixpkgsArgs;
    pkgs = import sources.nixpkgs nixpkgsArgs;
    hlint = pkgs.haskell-nix.hackage-package {
      compiler-nix-name = "ghc8102";
      name = "hlint";
      version = "2.2.11";
      index-state = "2021-01-04T00:00:00Z";
      plan-sha256 = "04hdgqwpaswmyb0ili7fwi6czzihd6x0jlvivw52d1i7wv4gaqy7";
      materialized = ./hlint.materialized;
    };
in hlint
```

Now we can copy the Nix files needed and build with:

```
$ nix-build hlint.nix 2>&1 | grep -om1 '/nix/store/.*-updateMaterialized' | bash
$ nix-build hlint.nix -A components.exes.hlint
building '/nix/store/wpxsgzl1z4jnhfqzmzg3xxv3ljpmzr5h-hlint-plan-to-nix-pkgs.drv'...
/nix/store/2ybrfmcp79gg75ad4pr1cbxjak70yg8b-hlint-exe-hlint-2.2.11
```

## How can we check `sha256` and `materialized` are up to date?

Let's pretend we had to go back to `hlint` version `2.2.10`.
We can tell haskell.nix to check the materialization either by:

* Removing the materialization files with `rm -rf hlint.materialized`

* Temporarily adding `checkMaterialization = true;`

If we choose to add the `checkMaterialization` flag you would have:

```nix
let inherit (import ./. {}) sources nixpkgsArgs;
    pkgs = import sources.nixpkgs nixpkgsArgs;
    hlint = pkgs.haskell-nix.hackage-package {
      compiler-nix-name = "ghc8102";
      name = "hlint";
      version = "2.2.10";
      index-state = "2021-01-04T00:00:00Z";
      plan-sha256 = "04hdgqwpaswmyb0ili7fwi6czzihd6x0jlvivw52d1i7wv4gaqy7";
      materialized = ./hlint.materialized;
      checkMaterialization = true;
    };
in hlint
```

This will fail and report the details of what is wrong and how to fix it:

```
$ nix-build hlint.nix -A components.exes.hlint

...

Calculated hash for hlint-plan-to-nix-pkgs was not 04hdgqwpaswmyb0ili7fwi6czzihd6x0jlvivw52d1i7wv4gaqy7. New hash is :
    plan-sha256 = "0jsgdmii0a6b35sd42cpbc83s4sp4fbx8slphzvamq8n9x49i5b6";
Materialized nix used for hlint-plan-to-nix-pkgs incorrect. To fix run: /nix/store/6wp0zzal40ls874f5ddpaac7qmii9y4z-updateMaterialized
builder for '/nix/store/61a0vginv76w4p9ycyd628pjanav06pl-hlint-plan-to-nix-pkgs.drv' failed with exit code 1
error: build of '/nix/store/61a0vginv76w4p9ycyd628pjanav06pl-hlint-plan-to-nix-pkgs.drv' failed
(use '--show-trace' to show detailed location information)
```

Checking the materialization requires Nix to do all the work that
materialization avoids.  So while it might be tempting to leave
`checkMaterialization = true` all the time, we would be better off just
removing `materialized` and `plan-sha256`.

## How can we update the Nix files with a script?

We can simply put the commands we used earlier in a script:

```nix
#!/bin/sh

# Output new plan-sha256
nix-build hlint.nix -A project.plan-nix.passthru.calculateMaterializedSha | bash

# Update materialized Nix expressions
nix-build hlint.nix 2>&1 | grep -om1 '/nix/store/.*-updateMaterialized' | bash
```

## Can we skip making a copy and use `materialized = /nix/store/...`?

Yes and it gives us the same speed improvement, however:

* It does not help at all in `restricted-eval` mode (Hydra).

* Users will still wind up building or downloading the dependencies
  needed to build the Nix files (if they do not have them).

For those reasons it might be best to make a copy instead
of using the `/nix/store/...` path directly.

If you really want to use the `/nix/store/...` path directly
you should guard against the path not existing as passing in
a non-existing path is now an error:

```nix
let inherit (import ./. {}) sources nixpkgsArgs;
    pkgs = import sources.nixpkgs nixpkgsArgs;
    hlintPlan = /nix/store/63k3f8bvsnag7v36vb3149208jyx61rk-hlint-plan-to-nix-pkgs;
    hlint = pkgs.haskell-nix.hackage-package {
      compiler-nix-name = "ghc8102";
      name = "hlint";
      version = "2.2.11";
      index-state = "2021-01-04T00:00:00Z";
      plan-sha256 = "04hdgqwpaswmyb0ili7fwi6czzihd6x0jlvivw52d1i7wv4gaqy7";
      materialized = if __pathExists hlintPlan then hlintPlan else null;
    };
in hlint
```

Running when no building is needed is still slow in restricted evaluation mode.

```shell
$ time nix-build --option restrict-eval true -I . --option allowed-uris "https://github.com/NixOS https://github.com/input-output-hk https://github.com/ican-group" hlint.nix -A components.exes.hlint --show-trace
/nix/store/2ybrfmcp79gg75ad4pr1cbxjak70yg8b-hlint-exe-hlint-2.2.11

real	0m4.463s
user	0m4.440s
sys	0m0.461s
$ time nix-build hlint.nix -A components.exes.hlint
/nix/store/2ybrfmcp79gg75ad4pr1cbxjak70yg8b-hlint-exe-hlint-2.2.11

real	0m2.206s
user	0m1.665s
sys	0m0.332s
```
