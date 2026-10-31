# This is a replacement for the cleanSourceWith function in nixpkgs
# https://github.com/NixOS/nixpkgs/blob/1d9d31a0eb8e8358830528538a391df52f6a075a/lib/sources.nix#L41
# It adds a subDir argument in a way that allows descending into a subdirectory
# to compose with cleaning the source with a filter.
{ lib }: rec {

  # Like `builtins.filterSource`, except it will compose with itself,
  # allowing you to chain multiple calls together without any
  # intermediate copies being put in the nix store.
  #
  #     lib.cleanSourceWith {
  #       filter = f;
  #       src = lib.cleanSourceWith {
  #         filter = g;
  #         src = ./.;
  #       };
  #     }
  #     # Succeeds!
  #
  #     builtins.filterSource f (builtins.filterSource g ./.)
  #     # Fails!
  #
  # Parameters:
  #
  #   src:      A path or cleanSourceWith result to filter and/or rename.
  #
  #   filter:   A function (path -> type -> bool)
  #             Optional with default value: constant true (include everything)
  #             The function will be combined with the && operator such
  #             that src.filter is called lazily.
  #             For implementing a filter, see
  #             https://nixos.org/nix/manual/#builtin-filterSource
  #
  #   subDir:   Descend into a subdirectory in a way that will compose.
  #             It will be as if `src = src + "/${subDir}` and filters
  #             already applied to `src` will be respected.
  #
  #   includeSiblings: By default the siblings trees of `subDir` are excluded.
  #             In some cases it is useful to include these so that
  #             relative references to those siblings will work.
  #
  #   name:     Optional name to use as part of the store path.
  #             If you do not provide a `name` it will be derived
  #             from the `subDir`. You should provide `name` or
  #             `subDir`.  If you do not a warning will be displayed
  #             and the name used will be `source`.
  #
  #   caller:   Name of the function used in warning message.
  #             Functions that are implemented using `cleanSourceWith`
  #             (and forward a `name` argument) can use this to make
  #             the message to the use more meaningful.
  #
  # Nix <2.4 Suport with filterPath
  #
  # As of Nix >=2.4 filtering is now possible on all paths (including those in the store).
  # If you still need to support older versions of Nix and want to maximise cache hits for your project
  # you may want to consider using setting the `filterPath` attribute on `src` (must be done on
  # the original src not the output of another `cleanSourceWith`).
  #
  # To disable filtering completely replace:
  #
  #   src = ./.;
  #
  # with:
  #
  #   src = { outPath = ./.; filterPath = { path, ... }: path; };
  #
  # To disable filtering only when the path is in the store use (when Nix <2.4 is unable to filter it):
  #
  #   src = {
  #     outPath = ./.;
  #     filterPath = { path, ... }@args:
  #       if builtins.hasContext (toString path) then path else builtins.path args;
  #   };
  #
  # Currently `haskell-nix.hackage-project` (used by `hackage-package`, `tool` and `tools`) disables
  # filtering.  See `overlays/haskell.nix` for details.
  #
  # For more see https://github.com/ican-group/haskell.nix/pull/1418
  cleanSourceWith = { filter ? _path: _type: true, src, subDir ? "", name ? null
      , caller ? "cleanSourceWith", includeSiblings ? false }:
    let
      subDir' = if subDir == "" then "" else "/" + subDir;
      subDirName = __replaceStrings ["/"] ["-"] subDir;
      # In case this is mixed with older versions of cleanSourceWith
      isFiltered = src ? _isLibCleanSourceWith;
      isFilteredEx = src ? _isLibCleanSourceWithEx;
      origSrc = if isFiltered || isFilteredEx then src.origSrc else src;
      origSubDir = if isFilteredEx then src.origSubDir + subDir' else subDir';
      origSrcSubDir = toString origSrc + origSubDir;
      parentFilter = if isFiltered || isFilteredEx
        then path: type: src.filter path type
        else _path: _type: true;
      filter' = path: type:
        # Respect the parent filter
        parentFilter path type && (
           # Must include parent paths of the subdir.
           (lib.strings.hasPrefix (path + "/") (origSrcSubDir + "/"))
           ||
           # Everything else is either the child tree or sibling tree.
           ((includeSiblings || lib.strings.hasPrefix (origSrcSubDir + "/") path)
             && filter path type # Use the filter function to decide if we need it
           )
        );
      name' = if name != null
        then name
        else
          if subDirName != ""
            then if src ? name
              then src.name + "-" + subDirName
              else "source-" + subDirName
            else if src ? name
              then src.name
              else
                # No name was provided and one could not be constructed from
                # the `subDirName`.

                # We used to use `baseNameOf src` as a default here.
                # This was cute, but it lead to cache misses.  For instance if
                # `x = cleanSourceWith { src = ./.; }` then `baseName src`
                # will be different when `src` resolves to "/nix/store/X"
                # than when it is in a local directory.  If people use
                # git worktrees they also may wind up with different
                # values for `name`. Anything that depends on `x.name` will
                # propagate the issue.

                # Encourage adding a suitable `name` with:
                #   * A warning message.
                #   * A default name that gives a hint as to why there is no name.
                __trace (
                    "WARNING: `${caller}` called on ${toString src} without a `name`. "
                    + "Consider adding `name = \"${baseNameOf src}\";`") "source";
      filterPath = origSrc.filterPath or (
        if builtins.compareVersions builtins.nixVersion "2.4" >= 0
          then builtins.path
        else __trace "WARNING: Using nix <2.4 will result in inconsistent filtering of ${toString origSrc} (see lib/clean-source-with.nix)"
          (if builtins.hasContext or (lib.hasPrefix builtins.storeDir) (toString origSrc)
            then { path, ... }: path
            else builtins.path));
    in {
      inherit origSrc origSubDir origSrcSubDir;
      filter = filter';
      outPath = (filterPath { filter = filter'; path = origSrc; name = name'; }) + origSubDir;
      _isLibCleanSourceWithEx = true;
      # It is only safe for older cleanSourceWith to filter this one
      # if the we are still looking at the root of origSrc
      _isLibCleanSourceWith = origSubDir == "";
      name = name';
    };
}
