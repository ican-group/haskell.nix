# cleanGit

To filter out just the files in your git index use
`haskell-nix.haskellLib.cleanGit { src = ./.; }` where `./.` is the
root of your git repo (or a git work tree).

First it filters just the files needed to run `git index`, then
it uses the results of that to filter your directory.  It does not
need to parse the `.gitignore` files at all, but we do need to
`git add` our files before they will be included.
[cleanGit source](https://github.com/ican-group/haskell.nix/blob/master/lib/clean-git.nix).

In addition haskell.nix (including `cleanGit`) uses a version
of [`cleanSourceWith`](https://github.com/ican-group/haskell.nix/blob/master/lib/clean-source-with.nix)
with a `subdir` argument to filter out just the package it is
building.  Then it uses the info from the `cabal` file to filter
just the source dirs for the component it is building.  That way
if we modify a test in a package nix will not rebuild the library
in that package (or anything that depends on that package's library).

There is a downside to this though.  If we have a test that depends
on something outside the scope of what is described in its entry in
the in the `.cabal` file it will not see it.  For instance perhaps
it needs to run `hlint` or `doctest` on the library source.  There
are ways to fix this with a module:

Use `extraSrcFiles` to add dirs the test needs (this will not result
in a change to the `.cabal` file the test will still be built the same).
```nix
components.tests.test.extraSrcFiles = [ "subdir-needed-by-test" ];
```
Or alternatively, override the source with a suitable filter function.
```nix
components.tests.test.src = haskell-nix.haskellLib.cleanSourceWith {
    inherit src;
    subdir = "path-to-package";
    filter = ...
};
```

## Multiple Git Repositories with cleanGits

Some times it is handy to temporarily use a relative path between git
repos.  If the repos are individually cleaned this is not possible
(since the cleaned version of one repo will never include the files
of the other).

There are 3 options:

* We could `symlinkJoin` the cleaned directories together, but the
  result could not be cleaned and any change would to either
  repo would result in a rebuild of everything.

* We could add one repo to the other as a submodule,
  but adding and then removing a submodule is a pain and it does not
  work well if you have more than one repo that needs to share the
  submodule.

* We could add a `source-repository-package` but then we would have
  to commit each change before testing.

`cleanGits` allows us to specify a root directory and any number of
sub directories containing git repos.

For example if `repoA` and `repoB` are two git repos with
cabal packages and want to use the `repoB` package when building
`repoA`.  First we can add `../repoB` to `repoA/cabal.project`:

```
packages:
  ./.
  ../repoB
```

Then in `repoA/default.nix` we can use:

```nix
haskell-nix.project {
  src = haskell-nix.haskellLib.cleanSourceWith {
    src = haskell-nix.haskellLib.cleanGits {
      name = "root";
      src = ../.;    # Parent dir that contains repoA and repoB
      gitDirs = [ "repoA" "repoB" ];
    };
    subDir = "repoA";       # Where to look for the `cabal.project`
    includeSiblings = true; # Tells it not to exclude `repoB` dir
  };
}
```

