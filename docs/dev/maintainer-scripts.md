# Updating Hackage and Stackage Nix expressions

The [`hackage.nix`](https://github.com/ican-group/hackage.nix)
and [`stackage.nix`](https://github.com/ican-group/stackage.nix)
repos and corresponding files `hackage-src.json` and
`stackage-src.json` will be regularly and automatically updated using
scripts in this repo.

To run the updater scripts manually, use:

```shell
nix-build build.nix -A maintainer-scripts.update-hackage -o update-hackage.sh
./update-hackage.sh

nix-build build.nix -A maintainer-scripts.update-stackage -o update-stackage.sh
./update-stackage.sh
```

The scripts will clone the repo, generate the latest data, then
attempt to push back to the repo and update the source JSON file.
