{ stdenv, lib, haskellLib, pkgsBuildBuild
, emulatorSystemFeatures ? []
, emulatorNativeBuilderCheck ? (_: false) }:
let
  # Whether a check must build on a native builder: every check for a host
  # matching `haskell-nix.emulatorNativeBuilderCheck`.  Nothing is pinned
  # while `emulatorSystemFeatures` is empty (the default).
  needsNativeBuilder =
    emulatorSystemFeatures != [] && emulatorNativeBuilderCheck stdenv.hostPlatform;
  self = drvOrig:

# v2 slices don't have the v1-specific internals that this check
# wrapper relies on (drv.source, drv.drvAttrs, drv.configFiles,
# drv.testWrapper, ...).  For v2, just run the installed binary
# (which the slice builds to `$out/bin/<exeName>` but does not
# execute) and capture stdout.
if drvOrig.passthru.isSlice or false then
  let component = drvOrig.config;
      isTest = (drvOrig.identifier.component-type or "") == "test";
      testFlags = lib.concatStringsSep " " (component.testFlags or []);
      # Some host platforms can't execute their own binaries on
      # the build host directly: ghcjs needs `node`, windows-cross
      # needs wine.  v1's component config carries a `testWrapper`
      # list that v1's check phase prepends to the exe; reuse the
      # same shape here (it's set via the windows defaultModule
      # in `overlays/windows.nix`).
      testWrapper = component.testWrapper or [];
      testWrapperPrefix = lib.concatStringsSep " " testWrapper;
      # Build-tool deps (`build-tool-depends`, incl. the package's own exes a
      # test spawns) — v1 has these on PATH via the component's
      # nativeBuildInputs; put them on PATH here too.
      toolDepends = drvOrig.passthru.executableToolDepends or [];
      # The package's source subdir, so the test can run from a writable copy
      # of it (v1 unpacks `src` and cds into the package subdir) — needed by
      # tests that read source-relative files (golden files / fixtures).
      srcSubDirPath = drvOrig.passthru.srcSubDirPath or null;
  in stdenv.mkDerivation ({
    name = drvOrig.name + "-check";
  } // lib.optionalAttrs needsNativeBuilder {
    # The test's exes cannot run on an emulated builder (see
    # `emulatorNativeBuilderCheck` in overlays/haskell.nix).
    requiredSystemFeatures = emulatorSystemFeatures;
  } // {
    passthru = { inherit (drvOrig) identifier config exeName meta; };
    inherit (drvOrig) exeName;
    inherit (component) doCheck doCrossCheck;
    # ghcjs binaries start with `#!/usr/bin/env node`.  Put node on
    # PATH and patch the shebang to its absolute path — same as the
    # v1 branch below.  Add every host-platform lib the slice was
    # linked against (via `passthru.runtimeLibs`) so test runners
    # like wineTestWrapper can find the runtime DLLs / dylibs the
    # exe imports — mirrors v1's automatic propagatedBuildInputs
    # chain.  Use `lib.getLib` so multi-output deps (`gmp.dev`,
    # `libffi.dev`, ...) resolve to the output that ships the
    # actual `.dll` / `.so` / `.dylib`, not the `-dev` headers.
    nativeBuildInputs =
      lib.optional stdenv.hostPlatform.isGhcjs pkgsBuildBuild.nodejs
      ++ map lib.getLib (drvOrig.passthru.runtimeLibs or [])
      ++ toolDepends;
    phases = [ "buildPhase" ];
    buildPhase = ''
      mkdir -p $out

      # v2 runs the installed test binary directly (not via `cabal v2-test` in
      # a composed store), so Cabal's `getDataFileName` resolves the compiled-in
      # datadir — a `~/.cabal/store/.../<pkg>` path that isn't present here — and
      # any test reading its package's `data-files` fails with "does not exist".
      # The slice does stage each package's data-files at
      # `<slice>/store/ghc-*/<unit-id>/share`, so point every installed package's
      # `<pkg>_datadir` (the env var Cabal's `Paths_<pkg>` consults before the
      # baked-in path) at that `share` dir.  Done before `preCheck` so a
      # project's own preCheck can still override it.
      for _conf in ${drvOrig}/store/ghc-*/package.db/*.conf \
                   ${drvOrig}/store/host/*/package.conf.d/*.conf; do
        [ -e "$_conf" ] || continue
        _unitroot=$(dirname "$(dirname "$_conf")")
        # Mainline layout stages data-files at `<store>/<uid>/share`;
        # the stable-haskell fork's staged layout at `<store>/lib/<uid>/share`.
        _share=$_unitroot/$(basename "$_conf" .conf)/share
        [ -d "$_share" ] || _share=$_unitroot/lib/$(basename "$_conf" .conf)/share
        [ -d "$_share" ] || continue
        _pkgname=$(sed -n 's/^name: *//p' "$_conf" | head -1)
        [ -n "$_pkgname" ] || continue
        export "$(echo "$_pkgname" | tr '-' '_')_datadir=$_share"
      done

      # Build-tool exes the slice built ITSELF, as a PATH fallback.
      #
      # `toolDepends` above covers the tools that reach the slice as
      # separate derivations.  In a TWO-STAGE plan (the stable-haskell
      # `-target` cross compilers, keyed on `emptyGlobalPackageDb`) there
      # are none: `lib/load-cabal-plan.nix` gives those plans
      # `build-tools = []` on purpose — their tools are BUILD-stage units
      # the fork elaborates inplace, so each consuming slice's own cabal
      # builds them.  A package's own exe (`build-tool-depends:
      # pkg:pkg-tool`) is dropped from `homeBuildToolIds` too, by
      # hspkg-builder's same-package `isExcludedId`.  So
      # `executableToolDepends` is empty, nothing lands on PATH, and a
      # test that spawns its build-tool dies with
      #   <tool>: readCreateProcess: posix_spawnp: does not exist
      # — while the tool is sitting right there in the slice, at
      # `<slice>/store/host/<plat>/bin/<tool>` (the fork's staged layout
      # installs exe units into a flat bindir; see build-cabal-slice's
      # "flat bin" capture).  test/check-datadir is exactly this shape.
      #
      # APPENDED, not prepended: where `toolDepends` does supply a tool it
      # is the BUILD-platform twin (`homeDepExeSlices` looks it up through
      # `hsPkgs.pkgsBuildBuild`), which is the one that can actually run
      # here, and it must keep winning.  What we add is the HOST-stage
      # copy — the slice keeps no build twin of its own (`$out/store/build`
      # is removed at the end of build-cabal-slice) — so this rescues the
      # targets whose host binaries run on the build machine (musl32,
      # musl64, static) but not one reached only through an emulator,
      # where the exe would be spawned from inside qemu/wine.
      #
      # The complete fix is for `extraNativeBuildInputs` in
      # comp-v2-builder to keep supplying the build-platform exe slices
      # for two-stage plans; until then this closes the common case.
      for _bindir in ${drvOrig}/store/ghc-*/bin \
                     ${drvOrig}/store/host/*/bin; do
        [ -d "$_bindir" ] || continue
        PATH="$PATH:$_bindir"
      done
      export PATH
      ${lib.optionalString (srcSubDirPath != null) ''
        # Run from a writable copy of the package source so tests that read
        # source-relative paths (golden files / fixtures) find them.  v1's
        # check unpacks `src` and cds into the package subdir; mirror that
        # (the v2 slice would otherwise run the bare binary in an empty dir).
        srcdir=$(mktemp -d)
        cp -RL ${srcSubDirPath}/. "$srcdir"/
        chmod -R u+w "$srcdir"
        cd "$srcdir"
      ''}

      runHook preCheck
      exe=${drvOrig}/bin/${drvOrig.exeName}
      ${lib.optionalString stdenv.hostPlatform.isGhcjs ''
        # The slice's $out is read-only; stage the binary into a
        # writable dir before patchShebangs can rewrite it.
        bindir=$(mktemp -d)
        cp "$exe" "$bindir/${drvOrig.exeName}"
        chmod +x "$bindir/${drvOrig.exeName}"
        patchShebangs --build "$bindir/${drvOrig.exeName}"
        exe=$bindir/${drvOrig.exeName}
      ''}
      ${testWrapperPrefix} "$exe" ${lib.optionalString isTest testFlags} | tee $out/test-stdout

      # Copy over tix files, if they exist.  Mirrors v1's check
      # (`lib/check.nix:119`) so `lib/cover.nix` can pick them up at
      # `$out/share/hpc/vanilla/tix/<exeName>/<exe>.tix`.
      find . -iname '${drvOrig.exeName}.tix' -exec mkdir -p $out/share/hpc/vanilla/tix/${drvOrig.exeName} \; -exec cp {} $out/share/hpc/vanilla/tix/${drvOrig.exeName}/ \;

      runHook postCheck
    '';
  } // haskellLib.optionalHooks {
    inherit (component) preCheck postCheck;
  })
else

let
  # Work around problem running dynamicially linked Android executables with qemu.
  drv = drvOrig.override (oldAttrs: lib.optionalAttrs stdenv.hostPlatform.isAndroid { setupBuildFlags = (oldAttrs.setupBuildFlags or []) ++ ["--ghc-option=-optl-static"]; });

  component = drv.config;

# This derivation can be used to execute test component.
# The $out of the derivation is a file containing the resulting
# stdout output.
in stdenv.mkDerivation ((
  if drv ? source
    then {
      src = drv.source;
      patchPhase =
        # This `cd` is normally done in the `prePatch` of the drv
        lib.optionalString (drv.srcSubDir != "") ''
          cd ${lib.removePrefix "/" drv.srcSubDir}
        '';
    }
    else
      # This makes the derivation work a bit like `srcOnly`,
      # using the original derivation, but replacing the `buildPhase`.
      (drv.drvAttrs or drv) // {
        outputs = [ "out" ];
        separateDebugInfo = false;
      }) // {
  name = (drv.name + "-check");

  passthru = {
    inherit (drv) identifier config configFiles executableToolDepends cleanSrc env exeName meta;
    profiled = self drv.profiled;
    dwarf = self drv.dwarf;
  };

  inherit (drv) LANG LC_ALL buildInputs;
  meta = builtins.removeAttrs drv.meta ["mainProgram"];

  nativeBuildInputs = drv.nativeBuildInputs
    ++ [(pkgsBuildBuild.lndir or pkgsBuildBuild.xorg.lndir)]
    ++ lib.optional (stdenv.hostPlatform.isGhcjs) pkgsBuildBuild.nodejs;

  inherit (component) doCheck doCrossCheck;

  phases = ["unpackPhase" "patchPhase" "buildPhase"];

  # If doCheck or doCrossCheck are false we may still build this
  # component and we want it to quietly succeed.
  buildPhase = ''
    mkdir $out
    runHook preCheck

    drv=$(mktemp -d)
    lndir ${drv} $drv
    rm $drv/bin/${drv.exeName}
    cp ${drv}/bin/${drv.exeName} $drv/bin/${drv.exeName}
    patchShebangs --build $(dirname $drv/bin/${drv.exeName})
    ${toString component.testWrapper} $drv/bin/${drv.exeName} ${lib.concatStringsSep " " component.testFlags} | tee $out/test-stdout

    # Copy over tix files, if they exist
    find . -iname '${drv.exeName}.tix' -exec mkdir -p $out/share/hpc/vanilla/tix/${drv.exeName} \; -exec cp {} $out/share/hpc/vanilla/tix/${drv.exeName}/ \;

    runHook postCheck
  '';
} // haskellLib.optionalHooks {
  inherit (component) preCheck postCheck;
}
// lib.optionalAttrs needsNativeBuilder {
  # v1 counterpart of the slice branch above.
  requiredSystemFeatures = emulatorSystemFeatures;
}
// lib.optionalAttrs (drv ? LOCALE_ARCHIVE) { inherit (drv) LOCALE_ARCHIVE; }
);
in self
