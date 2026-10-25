{
  inputs = {
    nixpkgs.follows = "haskellNix/nixpkgs";
    haskellNix.url = "github:input-output-hk/haskell.nix";
  };

  
  outputs = inputs@{ self, nixpkgs, haskellNix, ... }:
    let
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      inherit (nixpkgs) lib;

      # keep it simple (from https://ayats.org/blog/no-flake-utils/)
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (haskellNix.legacyPackages.${system}.extend self.overlays.default));

      mkTarball = pkgs:
        let
          toolset =
            let pkgs' = pkgs.extend self.overlays.default; in
            # We need to use haskell.nix compilers here
            pkgs'.nix-tools-set { compilerSelection = lib.mkForce (p: p.haskell-nix.compiler); };

          # tarball filename e.g. nix-tools-0.1.0.0-x86_64-unknown-linux-musl.tar.gz
          tarball-filename = "${toolset.name}-${pkgs.stdenv.hostPlatform.config}.tar.gz";
        in
        pkgs.runCommand tarball-filename
          { preferLocalBuild = true; }
          ''
            mkdir -p ${toolset.name}/bin
            cp --verbose --target-directory ${toolset.name}/bin ${toolset}/bin/*

            mkdir -p $out
            tar cvzf $out/${tarball-filename} ${toolset.name}

            mkdir -p $out/nix-support
            echo "file binary-dist $out/${tarball-filename}" >> $out/nix-support/hydra-build-products
          '';
    
      static-nix-tools-outputs = import ./static/outputs.nix inputs;
    
    in {

      inherit static-nix-tools-outputs;

      # this is not per-system!
      overlays.default = import ./overlay.nix;

      legacyPackages = forAllSystems (pkgs: pkgs);

      lib = {
        nix-tools = system: (haskellNix.legacyPackages.${system}.extend self.overlays.default).nix-tools;
        haskell-nix = system: (haskellNix.legacyPackages.${system}.extend self.overlays.default).haskell-nix;
      };

      project = forAllSystems (pkgs: pkgs.nix-tools.project);

      packages = forAllSystems (pkgs:
        lib.mapAttrs'
          (_n: v: { name = v.exeName; value = v; })
          pkgs.nix-tools.project.flake'.packages);

      checks = forAllSystems (pkgs:
        pkgs.nix-tools.project.flake'.checks // {
          truncate-index = import ./tests/truncate-index.nix { inherit pkgs; };
        });

      devShells = forAllSystems (pkgs:
        { default = pkgs.nix-tools.project.shell; });

      hydraJobs = forAllSystems
        (pkgs:
          # project's hydraJobs
          pkgs.nix-tools-eval-on-linux.project.flake'.hydraJobs
          # tarballs with static builds.
          // lib.optionalAttrs (pkgs.stdenv.buildPlatform.system == "x86_64-linux")
            { binary-tarball = mkTarball pkgs.pkgsCross.musl64; }
          # aarch64-multiplatform-musl cross compile is currently broken
          # // lib.optionalAttrs (pkgs.stdenv.buildPlatform.system == "aarch64-linux")
          #   { binary-tarball = mkTarball pkgs.pkgsCross.aarch64-multiplatform-musl; }
          // {
            static = static-nix-tools-outputs.hydraJobs.${pkgs.stdenv.hostPlatform.system};
            haskellNixSource = inputs.haskellNix.outPath;
          }
        );
    };

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
      "https://cache.zw3rk.com"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk="
    ];
    allow-import-from-derivation = "true";
  };
}
