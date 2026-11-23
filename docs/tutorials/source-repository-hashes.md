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
`ssh+git://...` (in any case) and git's scp-like `[user@]host:path`
(`host` may be a bracketed IPv6 address).  An scp-like location is
fetched as `ssh://[user@]host/path`, the way Nix itself reads
`user@host:path`: a relative `path` is taken from `/`, which is what
GitHub, GitLab and other forges expect.  For a path relative to your home
directory on your own server, write `host:~/path`.  Submodules are fetched
too, as `fetchgit` does.

`tag` can be a full commit hash, a tag name, a branch name or an
abbreviated commit hash; the last three are resolved by fetching all of the
repository's refs.  Use the full commit hash where you can: a name can move,
so the fetch is not reproducible; pure (flake) evaluation refuses anything
but a full hash; and Nix looks a name up again (over ssh, fetching all the
refs) once its cached answer is older than `tarball-ttl` (an hour by
default), so evaluation then needs the network again.

A `--sha256` is optional for these, since the commit hash already pins the
content.  If one is given it is checked (a wrong one fails with "NAR hash
mismatch"), and the source gets the same store path `fetchgit` would have
given it.  The hash is of the files as `nix-prefetch-git` checks them out;
`builtins.fetchGit` takes them straight from the repository, without the
checkout conversions a `.gitattributes` file can ask for (`eol`, `ident`,
`filter`), so for a repository that uses those the two differ and the
`--sha256` will not match.  Leave the `--sha256` out for such a repository.

Nix keeps what it has fetched in its own cache (`~/.cache/nix`), and
evaluating the project again uses that rather than ssh.  A copy that is
only in the Nix store, or in a binary cache, is not used: unlike
`fetchgit`'s fixed-output derivation, the source cannot be substituted,
so a machine without access to the repository (a CI runner without your
keys, for instance) cannot evaluate the project even if your binary cache
has the source.  Use `inputMap` there, as below.

Restricted evaluation (`restrict-eval`, as used by Hydra for non-flake
jobsets) refuses `builtins.fetchGit` of an ssh URL outright ("access to URI
... is forbidden in restricted mode"), even when the source is already in
the store.  There, for machines without access to the repository, and for
private https repositories, the repository has to come from somewhere Nix
can already read.  With flakes, add it as an input and pass it in
`inputMap`, keyed by the `location` from the `cabal.project` file.  Lock the input to the same commit as the `tag`
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
