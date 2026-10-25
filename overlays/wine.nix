_final: prev:
let
  # Wine's LdrAddDllDirectory rejects `\\.\`-style device paths, which breaks
  # running Windows test executables from the store.  The three files below are
  # the same one-line fix (allow RtlPathTypeLocalDevice) rebased onto the
  # context of wine 9.x, 10.x and 11.x respectively.
  devicePathPatch = version:
    if builtins.compareVersions version "10.0" < 0
      then ./patches/wine-add-dll-directory.patch
    else if builtins.compareVersions version "11.0" < 0
      then ./patches/wine-add-dll-directory-10.patch
    else ./patches/wine-add-dll-directory-11.patch;

  # nixpkgs now carries this fix itself (it applies it as
  # `add-dll-accept-device-paths`), so listing ours in `patches` as well aborts
  # patchPhase with "Reversed (or previously applied) patch detected".  Decide
  # from the source tree instead of from the wine version or the name of
  # nixpkgs' patch: a reverse dry run succeeds only when the change is already
  # there.  That keeps working in both directions, and a tree where the patch
  # neither applies nor reverse-applies still fails loudly — which is what we
  # want if wine's context ever drifts again.
  applyDevicePathPatch = version: ''
    if patch -p1 -R --dry-run --silent < ${devicePathPatch version} >/dev/null 2>&1; then
      echo "wine already accepts device paths in LdrAddDllDirectory; not applying haskell.nix's copy"
    else
      patch -p1 < ${devicePathPatch version}
    fi
  '';

  withDevicePathsAndWithoutX = pkg: pkg.overrideAttrs (oldAttrs: {
    postPatch = (oldAttrs.postPatch or "") + applyDevicePathPatch pkg.version;
    # Avoid dependency on X11
    configureFlags = oldAttrs.configureFlags or [] ++ [ "--without-x" ];
  });
in {
  winePackages = prev.winePackages // {
    minimal = withDevicePathsAndWithoutX prev.winePackages.minimal;
  };
  wine64Packages = prev.wine64Packages // {
    minimal = withDevicePathsAndWithoutX prev.wine64Packages.minimal;
  };
}
