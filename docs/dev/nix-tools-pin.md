## How to update [`nix-tools`](https://github.com/ican-group/haskell.nix/tree/master/nix-tools)

The `nix-tools` source lives in this repository (`./nix-tools`, and the
stable-haskell variant in `./nix-tools-sh`), but haskell.nix does not build it
from source when making plans.  It uses prebuilt static binaries from a GitHub
release, pinned in:

* `nix-tools-static.nix` -- `plan-to-nix`, `make-install-plan` and friends.
* `nix-tools-static-for-default-setup.nix` -- `default-setup`.  This has its own
  pin because changing it rebuilds every package.
* `nix-tools-static-sh.nix` -- the stable-haskell variant (opt-in per project).

So a change to the `nix-tools` source has no effect on plans until a new
release is made and the pin is bumped:

1. Merge the `nix-tools` change to `master`.

2. Push a plain tag on that `master` commit: `nix-tools-X.Y.Z`
   (or `nix-tools-sh-X.Y.Z`).  The commit must be one Hydra evaluates
   (any `master` commit is), because the release is built from the
   `<system>.nix-tools.static.zipped.*` jobs
   (`<system>.nix-tools-sh.static.zipped.*` for `nix-tools-sh`).

3. The `upload-artifacts` workflow ("Update Static Nix Tools") runs once
   Hydra has finished that commit: either straight away, if Hydra already
   had when the tag was pushed, or when hydra-github-bridge sets the
   commit's `hydra` status to `success`.  It downloads the zips from Hydra,
   publishes the GitHub release, and pushes a branch
   `update-nix-tools-static/<tag>` (`update-nix-tools-static-sh/<tag>`)
   that updates the pin file.  If the workflow cannot open the pull request
   itself, open it by hand from that branch.  If a Hydra build failed,
   restart it on Hydra: when the `hydra` status turns green the workflow
   runs again by itself.  "Run workflow" with the tag as input re-runs it by
   hand.

4. Merge the pin pull request once CI is green.

`nix-tools-static-for-default-setup.nix` is not updated by the workflow; bump
it by hand (copy the URLs and hashes from `nix-tools-static.nix`) only when the
`default-setup` change is worth a full rebuild.
