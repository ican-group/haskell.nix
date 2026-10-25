final: prev: {
  haskell = prev.haskell // {
      compiler = __mapAttrs (name: ghc: final.haskell-nix.haskellLib.makeCompilerDeps ghc // {
        inherit (final.haskell-nix.compiler.${name}) raw-src configured-src;
    }) prev.haskell.compiler;
  };
  # Apply makeCompilerDeps to any haskell-nix compiler that does not already
  # have a cachedDeps attribute.  Compilers built via compiler/ghc/default.nix
  # are already wrapped in makeCompilerDeps, so this is a no-op for them.
  # Compilers assembled from runCommand wrappers (e.g. stable-haskell bootstrap
  # compilers) need this to suppress the "WARNING: ghc.cachedDeps not found"
  # trace and to give make-config-files.nix correct envDeps/exactDeps data.
  haskell-nix = prev.haskell-nix // {
    compiler = __mapAttrs (name: ghc:
      if ghc ? cachedDeps then ghc
      else final.haskell-nix.haskellLib.makeCompilerDeps ghc
    ) prev.haskell-nix.compiler;
  };
}
