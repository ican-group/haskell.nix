# Exercise the project module through the real module-argument fixed point.
# This evaluates no compiler, configured source, derivation or project plan.
{ lib ? (builtins.getFlake ("path:" + toString ../.)).inputs.nixpkgs.lib
, projectModule ? import ../modules/stable-haskell-rts-macho-signed-addends.nix
}:
let
  intel = { isDarwin = true; isx86_64 = true; config = "x86_64-apple-darwin"; };
  arm = { isDarwin = true; isx86_64 = false; config = "aarch64-apple-darwin"; };
  linux = { isDarwin = false; isx86_64 = true; config = "x86_64-unknown-linux-gnu"; };
  apply = { name ? "ghc914-sh-stage2", compiler ? "ghc914-sh-stage1",
    builderVersion ? 2, host ? intel, build ? host, target ? host,
    profiling ? false, pkgs ? { stdenv = {
      hostPlatform = host; buildPlatform = build; targetPlatform = target;
    }; } }:
    let
      project = lib.evalModules {
        modules = [ projectModule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            compiler-nix-name = lib.mkOption { type = lib.types.str; };
            builderVersion = lib.mkOption { type = lib.types.int; };
            profiling = lib.mkOption { type = lib.types.bool; };
            modules = lib.mkOption { type = lib.types.listOf lib.types.anything; default = []; };
          };
          config = {
            inherit name builderVersion profiling;
            compiler-nix-name = compiler;
            # Not specialArgs: eager module selection would recurse here.
            _module.args.pkgs = pkgs;
          };
        } ];
      };
      package = lib.evalModules {
        modules = [ {
          options.packages = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                patches = lib.mkOption { type = lib.types.listOf lib.types.anything; default = []; };
                src = lib.mkOption { type = lib.types.str; };
              };
            });
          };
          config.packages = {
            rts = { patches = [ "existing.patch" ]; src = "configured-rts-source"; };
            ghc = { patches = [ "existing-ghc.patch" ]; src = "configured-ghc-source"; };
          };
        } ] ++ project.config.modules;
      };
    in package.config.packages;
  unchanged = {
    rts = { patches = [ "existing.patch" ]; src = "configured-rts-source"; };
    ghc = { patches = [ "existing-ghc.patch" ]; src = "configured-ghc-source"; };
  };
  selected = unchanged // {
    rts = unchanged.rts // { patches = unchanged.rts.patches ++ [
      ../overlays/patches/ghc914-rts-macho-signed-addends.patch
    ]; };
  };
in
assert apply {} == selected;
assert apply { profiling = true; } == selected;
assert apply { name = "ghc914-sh-stage1"; } == unchanged;
assert apply { name = "ghc914-sh-stage1"; compiler = "ghc9103"; } == unchanged;
assert apply { name = "application"; } == unchanged;
assert apply { name = "application"; compiler = "ghc914-sh"; } == unchanged;
assert apply { compiler = "ghc914-sh"; } == unchanged;
assert apply { name = "ghc914-sh-stage2"; compiler = "ghc9103"; } == unchanged;
assert apply { builderVersion = 1; } == unchanged;
assert apply { host = arm; } == unchanged;
assert apply { host = linux; } == unchanged;
assert apply { build = linux; } == unchanged;
assert apply { build = arm; } == unchanged;
assert apply { target = arm; } == unchanged;
assert apply { target = linux; } == unchanged;
assert apply { name = "application"; pkgs = throw "Unrelated project forced pkgs"; } == unchanged;
assert apply { compiler = "ghc9103"; pkgs = throw "Other compiler forced pkgs"; } == unchanged;
assert apply { builderVersion = 1; pkgs = throw "Other builder forced pkgs"; } == unchanged;
assert apply { host = linux; build = throw "Linux forced build platform"; } == unchanged;
assert apply { build = arm; target = throw "Cross host forced target platform"; } == unchanged;
{
  moduleArgumentFixedPointEvaluated = true;
  nativeIntelDarwinStage2Only = true;
  existingPatchOrderAndOtherPackageSourcesPreserved = true;
  stage1CrossOtherCompilersAndBuildersUnchanged = true;
  unrelatedProjectsAndPlatformsRemainLazy = true;
}
