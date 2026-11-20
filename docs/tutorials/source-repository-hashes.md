# Handling git repositories in projects

Both `stack.yaml` and `cabal.project` files can contain references
to git repositories containing the version of a particular package
that we wish to use.  This is mostly handled automatically by
`nix-tools` and `haskell.nix` however when we want to use a nix
system that is configured to use restricted mode (typically hydra)
it will need additional hashes for the referenced repositories.

When using `project`, `cabalProject` or `stackProject` functions
you can include the hash needed in a comment.

To calculate the hash use `nix-prefetch-git`:

```
$ nix-prefetch-git https://github.com/ican-group/haskell.nix.git bc01ebc05a8105035c9449943046b46c8364b932
...
{
  "url": "https://github.com/ican-group/haskell.nix.git",
  "rev": "bc01ebc05a8105035c9449943046b46c8364b932",
  "date": "2019-05-30T13:13:18+08:00",
  "sha256": "003lm3pm024vhbfmii7xcdd9v2rczpflxf7gdl2pyxia7p014i8z",
  "fetchSubmodules": false
}
```

## Cabal.project

Add a `--sha256` comment to the `cabal.project` file:

```
source-repository-package
  type: git
  location: https://github.com/ican-group/haskell.nix.git
  tag: bc01ebc05a8105035c9449943046b46c8364b932
  subdir: test/cabal-simple
  --sha256: 003lm3pm024vhbfmii7xcdd9v2rczpflxf7gdl2pyxia7p014i8z
```

## Stack

Add a `# nix-sha256` comment to the `stack.yaml` file:

```
extra-deps:
- git: https://github.com/ican-group/haskell.nix.git
  commit: bc01ebc05a8105035c9449943046b46c8364b932
  subdirs:
    - test/cabal-simple
  # nix-sha256: 003lm3pm024vhbfmii7xcdd9v2rczpflxf7gdl2pyxia7p014i8z
```

## Avoiding modifying cabal.project and stack.yaml

In some cases we cannot modify the `cabal.project` or `stack.yaml` file to add
sha256 comments. As an alternative we can pass in a `sha256map`. For instance,
pandoc includes a `cabal.project` file on hackage which includes a
`source-repository-package` stanza for `pandoc-citeproc`:

```nix
{{#include source-repository-hashes/default.nix}}
```

## Private repositories

A `--sha256` (or `sha256map`) makes haskell.nix fetch the repository with
`fetchgit`, which runs inside the Nix build sandbox.  The sandbox has no
`ssh` and none of your keys, so it can only fetch public repositories.

A `source-repository-package` with an ssh location is fetched with
`builtins.fetchGit` instead, whether or not it has a `--sha256`.  That
runs at evaluation time as you, so it uses your ssh agent and
`~/.ssh/config`:

```
source-repository-package
  type: git
  location: git@github.com:my-org/my-private-repo.git
  tag: 0123456789abcdef0123456789abcdef01234567
```

The locations treated this way are `ssh://...`, `git+ssh://...`,
`ssh+git://...` and git's scp-like `[user@]host:path`.  Submodules are
fetched too, as `fetchgit` does.

`tag` can be a full commit hash, a tag name, a branch name or an
abbreviated commit hash; the last three are resolved by fetching all of the
repository's refs.  Use the full commit hash where you can: a name can move,
so the fetch is not reproducible, and pure (flake) evaluation refuses
anything but a full hash.

A `--sha256` is optional for these, since the commit hash already pins the
content.  If one is given it is checked (a wrong one fails with "NAR hash
mismatch"), and the source gets the same store path `fetchgit` would have
given it.  A copy already in the Nix store is then used without contacting
the repository, so later evaluations do not need ssh.

Restricted evaluation (`restrict-eval`, as used by Hydra for non-flake
jobsets) refuses `builtins.fetchGit` of an ssh URL outright ("access to URI
... is forbidden in restricted mode"), even when the source is already in
the store.  There, and for private https repositories, the repository has
to come from somewhere Nix can already read.  With flakes, add it as an
input and pass it in `inputMap`, keyed by the `location` from the
`cabal.project` file.  Lock the input to the same commit as the `tag`
(haskell.nix checks this, and stops with "may not match" otherwise), or key
the entry by `"<location>/<tag>"` when `tag` is a name that points to the
locked commit:

```nix
inputs.my-private-repo = {
  url = "git+ssh://git@github.com/my-org/my-private-repo";
  flake = false;
};

# in the project arguments
inputMap = {
  "git@github.com:my-org/my-private-repo.git" = inputs.my-private-repo;
};
```
