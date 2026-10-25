# Opt-in experimental workaround: append after the haskell.nix overlay.
# This is intentionally absent from the default overlay list.
final: prev:
let
  inherit (prev.stdenv) buildPlatform hostPlatform targetPlatform;
  active = hostPlatform.isLinux && hostPlatform.isx86_64
    && buildPlatform.config == hostPlatform.config
    && hostPlatform.config == targetPlatform.config;
in prev.lib.optionalAttrs active {
  haskell-nix = prev.haskell-nix // {
    # The final package fixed point exposes this hook to compiler bootstrap
    # projects too. Call the previous implementation, not this wrapper.
    cabalProject' = projectModule: prev.haskell-nix.cabalProject' (
      [ ../modules/stable-haskell-timer-wait-cap.nix ]
      ++ (if builtins.isList projectModule then projectModule else [ projectModule ])
    );
  };
}
