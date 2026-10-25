inputs@{ nixpkgs, haskellNix, ... }:

let

  supported-systems = [
    "x86_64-linux"
    "x86_64-darwin"
    "aarch64-linux"
    "aarch64-darwin"
  ];


  static-gmp-overlay = final: _prev: {
    static-gmp = (final.gmp.override { withStatic = true; }).overrideDerivation (old: {
      configureFlags = old.configureFlags ++ [ "--enable-static" "--disable-shared" ];
    });
  };


  mkNixpkgsForSystem = system: import nixpkgs {

    inherit system;

    # Also ensure we are using haskellNix config. Otherwise we won't be
    # selecting the correct wine version for cross compilation.
    inherit (haskellNix) config;

    overlays = with inputs; [
      haskellNix.overlay
      static-gmp-overlay
      (import ./packaging.nix)
    ];
  };


  # Keep it simple (from https://ayats.org/blog/no-flake-utils/)
  forAllSystems = f:
    nixpkgs.lib.genAttrs supported-systems 
      (system: f (mkNixpkgsForSystem system));


  outputs = {
    hydraJobs = forAllSystems (pkgs: {
      zipped = import ./zipped.nix inputs pkgs;
      flake = (import ./project.nix inputs pkgs).flake'.hydraJobs;
    });
  };

in

  outputs 
