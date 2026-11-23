# Troubleshooting

## Issues with building and garbage-collection

### Why am I building GHC?

It's easier to list the reverse: when will you *not* build GHC?

- You have configured the [binary cache](tutorials/getting-started.md#setting-up-the-binary-cache) correctly.
- You are using one of the GHC versions which [we support](reference/supported-ghc-versions.md).
- You are using one of the nixpkgs versions used by our CI (you can access the sources for these [through haskell.nix](tutorials/getting-started.md).

Common binary cache mistakes:

- `nix config show substituters` does not list `https://cache.zw3rk.com`
  (or `https://cache.iog.io`): the settings went into a file the Nix daemon
  does not read, or the daemon was not restarted after editing
  `/etc/nix/nix.conf`.
- Nix warns `ignoring untrusted substituter`: the cache was added in
  `~/.config/nix/nix.conf` or on the command line, which only counts for
  trusted users.  Put it in `/etc/nix/nix.conf` instead.
- Nix warns `ignoring untrusted flake configuration setting 'extra-substituters'`:
  the caches in the flake's `nixConfig` were not accepted (answer yes when
  Nix asks, or pass `--accept-flake-config`; this too needs a trusted
  user).  `/etc/nix/nix.conf` avoids the question.
- Nix warns `ignoring substitute for '...', as it's not signed by any of the keys`:
  the key for that cache is missing from `trusted-public-keys`.  Each cache
  has its own key (`loony-tools:...` for `cache.zw3rk.com`,
  `hydra.iohk.io:...` for `cache.iog.io`).
- `https://cache.nixos.org` is missing from `nix config show substituters`:
  `substituters =` (rather than `extra-substituters =`) replaced the default
  list.  Add it back, with its key `cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=`,
  or switch to the `extra-` settings.

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

### Why does `cabal build` in my shell rebuild a dependency that has public sub-libraries?

Inside a `shellFor` shell, `cabal build` is meant to reuse the
dependencies the shell already provides.  With the default builder
(`builderVersion = 1`) those are installed in the shell's GHC package
database, and the cabal-install from Hackage cannot use an installed
package for a dependency on one of its public sub-libraries
(`build-depends: provider:slib`): its solver does not know that an
installed package can have more than one library
([haskell/cabal#6039](https://github.com/haskell/cabal/issues/6039)).
It rejects the installed package and either builds it from source again
or, when no source is available, fails with an error like:

```
rejecting: provider-0.1.0.0/installed-... (does not contain library 'slib', which is required by consumer)
```

haskell.nix's own cabal-install (the one the v2 builder uses,
`project.v2-cabal-install`) lets installed units satisfy sub-library
dependencies.  Give the shell that cabal instead, in a project's
`shell` argument:

```nix
pkgs.haskell-nix.cabalProject' {
  src = ./.;
  compiler-nix-name = "ghc9103";
  shell.tools.cabal = "v2-cabal-install";
}
```

or in a `shellFor`:

```nix
project.shellFor {
  tools.cabal = "v2-cabal-install";
}
```

`"v2-cabal-install"` picks the build of it for the project's
`evalSystem`, the same derivation as `project.v2-cabal-install` (which
`tools` also accepts, since a tool can be a derivation).  It wins over a
`shell.tools.cabal = "latest"` from elsewhere, as the templates set; see
"Tools given in more than one place" in [Tools](reference/tools.md).

This cabal is a 3.19 pre-release build and keeps its `~/.cabal/store` in
its own layout, so it will not reuse what another cabal-install built
there.

Shells of projects using the v2 builder (`builderVersion = 2`) already
use this cabal by default and reuse a cabal store, so they are not
affected.

### Why does my executable depend on GHC/GCC?

You may want to set the `dontStrip` option to `false` (see https://github.com/ican-group/haskell.nix/issues/829).
This is not set by default because it can occasionally cause breakage.

### Why does `cabal build` in my shell build `happy` (or another `build-tool-depends` tool) again?

A `shellFor` shell puts the executables named in the selected packages'
`build-tool-depends` (`happy`, `alex`, `tasty-discover`, ...) on `PATH`,
pre-built.  Whether `cabal build` inside the shell uses them depends on
the builder:

* **`builderVersion = 2`**: the shell's cabal store holds the tool, and
  `cabal build` reuses it; the only things it builds are your own
  packages.
* **`builderVersion = 1`** (the default for most compilers): the shell's
  libraries are in a GHC package database, which records no executables.
  cabal-install always solves `build-tool-depends` itself, cannot take
  the tool from `PATH`, and finds no installed package that provides it.
  So it plans the tool from source and builds it into `~/.cabal/store`
  (once), or fails if it cannot download it.  Giving a v1 shell
  haskell.nix's cabal-install (`project.v2-cabal-install`) does not change
  this.

When the same package is both a library dependency and a tool, as in

```cabal
  ghc-options:        -pgmL markdown-unlit
  build-depends:      base, markdown-unlit
  build-tool-depends: markdown-unlit:markdown-unlit
```

a v1 shell can instead fail with

```
rejecting: my-pkg:markdown-unlit:exe.markdown-unlit-0.6.0/installed-...
(does not contain executable 'markdown-unlit', which is required by my-pkg)
```

since the solver sees the installed library but will not let it provide
the executable.

Ways around it:

* Use the v2 builder (`builderVersion = 2`; see
  [Migrating to builderVersion = 2](./dev/migrating-to-v2.md) and
  [Shells with `builderVersion = 2`](reference/tools.md#shells-with-builderversion--2)).
  A v2 shell links the dependencies' library *and* executable units into
  its cabal store, and `cabal build` reuses both.
* Let cabal fetch and build the tool from source (needs network access
  and a Hackage index).  This works, but rebuilds the tool.
* Use the deprecated `build-tools: markdown-unlit` field instead of
  `build-tool-depends`.  cabal then only looks for the program on `PATH`,
  where the shell has put it.

The `test/shell-build-tool-depends` (tool only, both builders) and
`test/shell-for-build-tool-depends` (library and tool from one package,
v2) tests show this.
