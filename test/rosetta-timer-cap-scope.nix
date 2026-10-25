# Exercise the actual opt-in overlay and module without compiler IFD/builds.
{ lib ? (builtins.getFlake ("path:" + toString ../.)).inputs.nixpkgs.lib }:
let
  overlay = import ../overlays/rosetta-timer-wait-cap.nix;
  apply = { linux ? true, x86_64 ? true,
    build ? "x86_64-unknown-linux-gnu", host ? "x86_64-unknown-linux-gnu",
    target ? "x86_64-unknown-linux-gnu", name ? "ghc914-sh-stage2",
    compiler ? "ghc914-sh-stage1", list ? false }:
    let
      platform = {
        buildPlatform.config = build;
        hostPlatform = { config = host; isLinux = linux; isx86_64 = x86_64; };
        targetPlatform.config = target;
      };
      # Returning the supplied modules lets this fixture exercise the real
      # wrapper. A call to final.cabalProject' would recurse and fail this test.
      prev = {
        inherit lib;
        stdenv = platform;
        haskell-nix = { cabalProject' = m: m; untouched = "preserved"; };
      };
      pkgs = prev // overlay pkgs prev;
      caller = { config.name = name; };
      supplied = pkgs.haskell-nix.cabalProject' (if list then [ caller ] else caller);
      project = lib.evalModules {
        modules = (if builtins.isList supplied then supplied else [ supplied ]) ++ [ {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            compiler-nix-name = lib.mkOption { type = lib.types.str; };
            src = lib.mkOption { type = lib.types.path; };
            modules = lib.mkOption { type = lib.types.listOf lib.types.anything; default = []; };
          };
          config = {
            compiler-nix-name = compiler;
            src = ../.;
            # Not specialArgs: exercise the module-argument fixed point.
            _module.args.pkgs.stdenv = platform;
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
            default = {};
          };
          config.packages = {
            ghc-internal.patches = [ "existing.patch" ];
            rts.patches = [ "existing-rts.patch" ];
          };
        } ] ++ project.config.modules;
      };
    in assert pkgs.haskell-nix.untouched == "preserved";
       assert project.config.name == name;
       assert project.config.compiler-nix-name == compiler;
       assert project.config.src == ../.;
       assert package.config.packages.rts.patches == [ "existing-rts.patch" ];
       package.config.packages.ghc-internal.patches;
  unchanged = [ "existing.patch" ];
  selected = unchanged ++ [ ../overlays/patches/ghc914-timer-manager-wait-cap.patch ];
  # A cross project can delegate compiler selection to native buildPackages.
  # The outer target package set is inactive; its native compiler keeps the
  # hook, exactly once, rather than losing it or patching the target library.
  nestedForwarded = let
    native = {
      inherit lib;
      stdenv = {
        buildPlatform.config = "x86_64-unknown-linux-gnu";
        hostPlatform = { config = "x86_64-unknown-linux-gnu"; isLinux = true; isx86_64 = true; };
        targetPlatform.config = "x86_64-unknown-linux-gnu";
      };
      haskell-nix.cabalProject' = m: m;
    };
    nativeFinal = native // overlay nativeFinal native;
    cross = native // {
      stdenv = native.stdenv // { targetPlatform.config = "armv7a-unknown-linux-androideabi"; };
      haskell-nix.cabalProject' = m: nativeFinal.haskell-nix.cabalProject' m;
    };
    crossFinal = cross // overlay crossFinal cross;
  in crossFinal.haskell-nix.cabalProject' { name = "ghc914-sh-stage2"; };
in
assert apply {} == selected;
assert apply { list = true; } == selected;
assert apply { linux = false; } == unchanged;
assert apply { x86_64 = false; } == unchanged;
assert apply { build = "aarch64-unknown-linux-gnu"; } == unchanged;
assert apply { host = "aarch64-apple-darwin"; } == unchanged;
assert apply { target = "armv7a-unknown-linux-androideabi"; } == unchanged;
assert apply { name = "ghc914-sh-stage1"; compiler = "ghc9103"; } == unchanged;
assert apply { name = "simplex-chat"; compiler = "ghc914-sh"; } == unchanged;
assert apply { name = "iserv-proxy"; compiler = "ghc914-sh"; } == unchanged;
assert apply { compiler = "ghc914-sh"; } == unchanged;
assert nestedForwarded == [ ../modules/stable-haskell-timer-wait-cap.nix { name = "ghc914-sh-stage2"; } ];
{
  nativeX86LinuxStage2Only = true;
  moduleArgumentFixedPointEvaluated = true;
  callerModulesAndExistingPackagePatchesPreserved = true;
  configuredSourceAndBootstrapSelectionUnchanged = true;
  crossOriginNativeCompilerHookPreserved = true;
  compilerIFDOrBuildPerformed = false;
}
