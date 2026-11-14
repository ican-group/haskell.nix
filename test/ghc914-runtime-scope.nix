# Exercise the ghc914-sh runtime modules through the module-argument fixed
# point. This evaluates no compiler, configured source, derivation, or plan.
{ lib ? (builtins.getFlake ("path:" + toString ../.)).inputs.nixpkgs.lib }:
let
  intel = { isDarwin = true; isx86_64 = true; isLinux = false; isWindows = false; isAndroid = false; config = "x86_64-apple-darwin"; };
  armDarwin = { isDarwin = true; isx86_64 = false; isLinux = false; isWindows = false; isAndroid = false; config = "aarch64-apple-darwin"; };
  linux64 = { isDarwin = false; isx86_64 = true; isLinux = true; isWindows = false; isAndroid = false; config = "x86_64-unknown-linux-gnu"; };
  windows = { isDarwin = false; isx86_64 = true; isLinux = false; isWindows = true; isAndroid = false; config = "x86_64-w64-mingw32"; };
  apply = projectModule: { name ? "app", compiler ? "ghc914-sh", builderVersion ? 2
    , host ? linux64, build ? host, target ? host, pkgs ? null }:
    let
      suppliedPkgs = if pkgs != null then pkgs else {
        stdenv = {
          hostPlatform = host;
          buildPlatform = build;
          targetPlatform = target;
        };
      };
      project = lib.evalModules {
        modules = [ projectModule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            compiler-nix-name = lib.mkOption { type = lib.types.str; };
            builderVersion = lib.mkOption { type = lib.types.int; };
            modules = lib.mkOption { type = lib.types.listOf lib.types.anything; default = []; };
          };
          config = {
            inherit name builderVersion;
            compiler-nix-name = compiler;
            _module.args.pkgs = suppliedPkgs;
          };
        } ];
      };
      package = lib.evalModules {
        modules = [ {
          options.packages = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options.patches = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = [];
              };
            });
          };
          config.packages = {
            rts = { patches = [ "existing.patch" ]; };
            ghc = { patches = [ "existing-ghc.patch" ]; };
          };
        } ] ++ project.config.modules;
      };
    in package.config.packages;
  base = {
    rts = { patches = [ "existing.patch" ]; };
    ghc = { patches = [ "existing-ghc.patch" ]; };
  };
  withRts = patch: base // { rts = base.rts // { patches = base.rts.patches ++ [ patch ]; }; };
  withGhc = patch: base // { ghc = base.ghc // { patches = base.ghc.patches ++ [ patch ]; }; };
  elf = import ../modules/stable-haskell-rts-elf-alignment.nix;
  dll = import ../modules/stable-haskell-rts-windows-dll.nix;
  info = import ../modules/stable-haskell-ghc-macho-info-tables.nix;
  elfPatch = ../overlays/patches/ghc914-rts-elf-section-alignment.patch;
  dllPatch = ../overlays/patches/ghc914-rts-windows-dll-search-path.patch;
  infoPatch = ../overlays/patches/ghc914-macho-info-tables.patch;
in
assert apply elf { name = "ghc914-sh-stage2"; compiler = "ghc914-sh-stage1"; } == withRts elfPatch;
assert apply elf { name = "ghc914-sh-stage1"; compiler = "ghc914-sh-stage1"; } == base;
assert apply elf { name = "ghc914-sh-stage2"; compiler = "ghc914-sh"; } == base;
assert apply elf { name = "ghc914-sh-stage2"; compiler = "ghc914-sh-stage1"; host = windows; } == base;
assert apply elf { name = "application"; pkgs = throw "Unrelated project forced pkgs"; } == base;
assert apply dll { host = windows; build = linux64; compiler = "ghc914-sh"; } == withRts dllPatch;
assert apply dll { host = windows; build = linux64; compiler = "ghc9103"; } == base;
assert apply dll { host = windows; build = linux64; builderVersion = 1; } == base;
assert apply dll { host = linux64; compiler = "ghc914-sh"; } == base;
assert apply dll { host = windows; build = windows; compiler = "ghc914-sh"; } == base;
assert apply info { name = "ghc914-sh-stage1"; host = intel; compiler = "ghc914-sh"; } == withGhc infoPatch;
assert apply info { name = "ghc914-sh-stage2"; host = intel; compiler = "ghc914-sh"; } == withGhc infoPatch;
assert apply info { name = "application"; host = intel; compiler = "ghc914-sh"; } == base;
assert apply info { name = "ghc914-sh-stage2"; host = armDarwin; compiler = "ghc914-sh"; } == base;
assert apply info { name = "ghc914-sh-stage2"; host = linux64; compiler = "ghc914-sh"; } == base;
{
  elfAlignmentOnlyNativeStage2 = true;
  windowsDllSearchOnlyLinuxCross = true;
  machoInfoTablesOnBothNativeIntelStages = true;
}
