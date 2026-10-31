# Troubleshooting

## Issues with building and garbage-collection

### Why am I building GHC?

It's easier to list the reverse: when will you *not* build GHC?

- You have configured the [binary cache](tutorials/getting-started.md) correctly.
- You are using one of the GHC versions which [we support](reference/supported-ghc-versions.md).
- You are using one of the nixpkgs versions used by our CI (you can access the sources for these [through haskell.nix](tutorials/getting-started.md).

If you think you are doing all of these and you still find you're building GHC, drop us a line.

### Why am I building lots of Haskell packages?

We don't generally cache much of Hackage (there's a lot of it!), except for the parts which are used by our tests.
So this is expected, unfortunately. However, if you are building from a recent branch without significant dependencies 
changes, most of those dependencies should be cached and you should not be building core things like `Cabal` or `ghc-lib`.

If this happens, chances are nix cache are either:
* Incorrectly configured: Check the aforementioned links,
* Overriding global configuration in `/etc/nix/nix.conf` with local `~/.config/nix/nix.conf`. This can happen if for example
  one project is using `nix flake` with some locally configured repositories, while another project is not. 
  Use `nix show-config` to check which caches are defined, then update or remove `~/.config/nix/nix.conf`.

### How do I prevent the evaluation-time dependencies of my project from being garbage-collected?

The `haskell-nix.roots "ghc884"` should include all the evaluation-time dependencies
and the main build time dependencies of a project using ghc 8.8.4.
So you can add that to the relevant GC root.
In practice, if you're using a CI system like Hydra/Hercules, this means adding it to a job in `release.nix`/`ci.nix`.

## General troubleshooting when using `cabalProject`/`stackProject`/`project`

### Does the cabal/stack build work?

In `haskell.nix`, we strive to take the build configuration from the cabal/stack configuration files.
So if you have a problem with your cabal/stack configuration, it is likely that you will have a problem with the `haskell.nix` build too.

So the first thing to do is make sure that the build works with `cabal` or `stack` as normal.
If it *does* work, then the `haskell.nix` one should as well.
If, on the other hand, there is a failure, the `cabal` or `stack` build is usually easier to debug (or at least it is no longer a `haskell.nix` problem).

### Is the `haskell.nix` configuration completely in line with the cabal/stack configuration?

The `haskell.nix` configuration can come apart from the cabal/stack configuration in a number of ways:

#### Compiler version

(Cabal users only. For stack users this comes from the snapshot, so stack and `haskell.nix` will agree.)

The compiler version used by `haskell.nix` is selected by the `compiler-nix-name` argument; or if you do not specify it, by some default version (we recommend specifying it!).
Cabal does not provide an easy way to pin a *version* of the compiler (`with-compiler` lets you pick a particular executable, which is nearly but not quite what we want).
Hence, the two can come apart.

Make sure you are using the same compiler for the cabal build as for the `haskell.nix` build.

#### Hackage index state

(Cabal users only. For stack users, package versions come from the snapshot, so stack and `haskell.nix` will agree.)

Cabal has the concept of the Hackage "index state".
This is a timestamp, and it tells Cabal to behave "as if" it was seeing Hackage at that point in time.
Pinning it is generally good for reproducibility regardless of whether you use `haskell.nix` (you can do so in `cabal.project`).

If you do not set an `index-state` in `cabal.project`, then Cabal will use the latest one based on when you last called `cabal update`, and `haskell.nix` will use the latest one it knows about from `hackage.nix`.
These may not be the same!
So if you use `haskell.nix` we strongly recommend pinning the `index-state`.

#### Nix-only configuration options

You can set configuration options in your Nix code that are not present in the cabal/stack configuration.
For example, you might enable profiling.

Where possible, try to do the configuration in your cabal/stack configuration, e.g. setting `profiling: true` in `cabal.project`.
This will ensure that the two builds agree.

If you want or need to set some of them in Nix, try bringing the two into sync temporarily for troubleshooting.

## Other specific issues

### Why does the build complain about some files being missing?

Sometimes your build works fine outside `haskell.nix`, but inside the `haskell.nix` build, cabal complains that some file is missing.
What is going on?

The answer is that `haskell.nix` *thoroughly* cleans the source *by following what is mentioned as required in the cabal file*.
So we only include Haskell sources if they appear in a `hs-source-dirs` somewhere; and we only include non-Haskell files if they are included in `extra-source-files` or similar.

This is good practice anyway: if you do not include such files in `extra-source-files` then they will not be included in `cabal sdist`, which will cause problems if you ever upload your package to Hackage.
But `haskell.nix` is very picky about it.

### Why does my executable depend on GHC/GCC?

You may want to set the `dontStrip` option to `false` (see https://github.com/ican-group/haskell.nix/issues/829).
This is not set by default because it can occasionally cause breakage.
