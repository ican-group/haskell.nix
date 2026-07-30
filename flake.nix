{
  description = "Alternative Haskell Infrastructure for Nixpkgs";

  inputs = {
    nixpkgs.follows = "nixpkgs-unstable";
    nixpkgs-2305 = { url = "github:NixOS/nixpkgs/nixpkgs-23.05-darwin"; };
    nixpkgs-2311 = { url = "github:NixOS/nixpkgs/nixpkgs-23.11-darwin"; };
    nixpkgs-2405 = { url = "github:NixOS/nixpkgs/nixpkgs-24.05-darwin"; };
    nixpkgs-2411 = { url = "github:NixOS/nixpkgs/nixpkgs-24.11-darwin"; };
    nixpkgs-2505 = { url = "github:NixOS/nixpkgs/nixpkgs-25.05-darwin"; };
    nixpkgs-2511 = { url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin"; };
    nixpkgs-unstable = { url = "github:NixOS/nixpkgs/nixpkgs-unstable"; };
    flake-compat = { url = "github:input-output-hk/flake-compat/hkm/gitlab-fix"; flake = false; };
    "hls-1.10" = { url = "github:haskell/haskell-language-server/1.10.0.0"; flake = false; };
    "hls-2.0" = { url = "github:haskell/haskell-language-server/2.0.0.1"; flake = false; };
    "hls-2.2" = { url = "github:haskell/haskell-language-server/2.2.0.0"; flake = false; };
    "hls-2.3" = { url = "github:haskell/haskell-language-server/2.3.0.0"; flake = false; };
    "hls-2.4" = { url = "github:haskell/haskell-language-server/2.4.0.1"; flake = false; };
    "hls-2.5" = { url = "github:haskell/haskell-language-server/2.5.0.0"; flake = false; };
    "hls-2.6" = { url = "github:haskell/haskell-language-server/2.6.0.0"; flake = false; };
    "hls-2.7" = { url = "github:haskell/haskell-language-server/2.7.0.0"; flake = false; };
    "hls-2.8" = { url = "github:haskell/haskell-language-server/2.8.0.0"; flake = false; };
    "hls-2.9" = { url = "github:haskell/haskell-language-server/2.9.0.1"; flake = false; };
    "hls-2.10" = { url = "github:haskell/haskell-language-server/2.10.0.0"; flake = false; };
    "hls-2.11" = { url = "github:haskell/haskell-language-server/2.11.0.0"; flake = false; };
    "hls-2.12" = { url = "github:haskell/haskell-language-server/2.12.0.0"; flake = false; };
    "hls"     = { url = "github:haskell/haskell-language-server"; flake = false; };
    hackage = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    hackage-for-stackage = {
      url = "github:input-output-hk/hackage.nix/for-stackage";
      flake = false;
    };
    hackage-internal = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    stackage = {
      url = "github:input-output-hk/stackage.nix";
      flake = false;
    };
    cabal-34 = {
      url = "github:haskell/cabal/3.4";
      flake = false;
    };
    cabal-36 = {
      url = "github:haskell/cabal/3.6";
      flake = false;
    };
    cardano-shell = {
      url = "github:input-output-hk/cardano-shell";
      flake = false;
    };
    hpc-coveralls = {
      url = "github:sevanspowell/hpc-coveralls";
      flake = false;
    };
    old-ghc-nix = {
      url = "github:angerman/old-ghc-nix/master";
      flake = false;
    };
    HTTP = {
      url = "github:phadej/HTTP";
      flake = false;
    };
    iserv-proxy = {
      url = "github:stable-haskell/iserv-proxy?ref=iserv-syms";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , nixpkgs-unstable
    , flake-compat
    , ...
    }@inputs:
    let
      callFlake = import flake-compat;

      ifdLevel = 3;
      runningHydraEvalTest = false;
      # The system that evaluation-time derivations (plan-to-nix, dummy-ghc,
      # hadrian's plan) are built on.  This is deliberately *not* the target
      # system: our Hydra has 10 darwin builders, so evaluating there is
      # fastest on darwin regardless of which platform the jobs are for.
      #
      # It has to be stated explicitly rather than left to `ci.nix`'s
      # `builtins.currentSystem or "aarch64-darwin"` default, because
      # `currentSystem` does not exist under pure evaluation (`nix-eval-jobs
      # --flake`, `nix path-info --derivation .#…`).  There the default
      # silently became the literal "aarch64-darwin", which is right for Hydra
      # but leaves any evaluator without darwin builders unable to evaluate
      # *anything* -- including the linux jobs.  CI on GitHub-hosted runners
      # overrides this to "x86_64-linux" (see .github/workflows/pipeline.yml).
      evalSystem = "aarch64-darwin";
      defaultCompiler = "ghc967";
      config = import ./config.nix;

      inherit (nixpkgs) lib;

      traceNames = prefix: builtins.mapAttrs (n: v:
        if builtins.isAttrs v
        then if v ? type && v.type == "derivation"
        then builtins.trace (prefix + n) v
        else traceNames (prefix + n + ".") v
        else v);

      traceHydraJobs = x: x // { inherit (traceNames "" x) hydraJobs; };

      # systems supported by haskell.nix
      systems = [
        "x86_64-linux"
      ] ++ (if runningHydraEvalTest then [ ] else [
        "x86_64-darwin"
        "aarch64-darwin"
      ]);

      nixpkgsArgs = {
        inherit config;
        overlays = [ self.overlay ];
      };

      forEachSystem = lib.genAttrs systems;
      forEachSystemPkgs = f: forEachSystem (system: f self.legacyPackages.${system});

      inherit
        (import ./ci-lib.nix { inherit lib; })
        stripAttrsForHydra
        filterDerivations;

      flake = {
        inherit config;
        overlay = self.overlays.combined;
        overlays = import ./overlays { sources = inputs; };

        # `nix flake init --template github:input-output-hk/haskell.nix`
        # scaffolds a new haskell.nix project (flake.nix + nix/hix.nix + a
        # `hello` package).  Kept in-repo (rather than in NixOS/templates) so
        # it stays in sync with the current `hix init` output and supported
        # GHC versions.
        templates = rec {
          default = haskell-nix;
          haskell-nix = {
            path = ./templates/haskell-nix;
            description = "A haskell.nix project: flake.nix, nix/hix.nix and a hello package.";
          };
        };

        internal = {
          nixpkgsArgs = {
            inherit config;
            overlays = [ self.overlay ];
          };

          sources = inputs;

          overlaysOverrideable =
            lib.warn
              "Using this attribute is deprecated. Import ${./overlays} directly or use the flake overlays output with override-inut."
              (import ./overlays);

          # Compatibility with old default.nix
          compat =
            lib.warn
              "Using this attribute is deprecated. You can pass the same arguments to ${./default.nix} instead"
              (import ./default.nix);
        };

        legacyPackages = forEachSystem (system:
          import nixpkgs {
            inherit config;
            overlays = [ self.overlay ];
            localSystem = { inherit system; };
          });

        legacyPackagesUnstable = forEachSystem (system:
          import nixpkgs-unstable {
            inherit config;
            overlays = [ self.overlay ];
            localSystem = { inherit system; };
          });

        # Exposed so CI can check that `allow-import-from-derivation=false` works
        # for core of haskell.nix E.g. this should always work:
        #   nix build .#roots.x86_64-linux --accept-flake-config --option allow-import-from-derivation false
        roots = forEachSystem (system:
          self.legacyPackagesUnstable.${system}.haskell-nix.roots { compiler-nix-name = defaultCompiler; });

        # Note: `nix flake check` evaluates outputs for all platforms, and haskell.nix
        # uses IFD heavily, you have to have the ability to build for all platforms
        # supported by haskell.nix, e.g. with remote builders, in order to check this flake.
        # If you want to run the tests for just your platform, run `./test/tests.sh` or
        # `nix-build -A checks.$PLATFORM`
        checks = forEachSystemPkgs (pkgs:
          builtins.listToAttrs (
            map
              (pkg: { name = pkg.name; value = pkg; })
              (lib.collect
                lib.isDerivation
                (import ./test {
                  haskellNix.sources = inputs;
                  haskellNix.nixpkgsArgs = nixpkgsArgs;
                  compiler-nix-name = defaultCompiler;
                  inherit pkgs;
                })
              )
          )
        );

        # NOTE: these are the hix cli utilities, which is a separate thing from
        # the hix.nix overlays (which extends haskell.nix with hixProject).
        packages = forEachSystemPkgs (pkgs:
          (import ./hix/default.nix { inherit pkgs; }).apps
        );

        apps = forEachSystemPkgs (pkgs:
          builtins.mapAttrs
            (name: exe: {
              type = "app";
              program = exe + "/bin/${name}";
            })
            pkgs.haskell-nix.nix-tools-unchecked.exes
        );

        allJobs = forEachSystem (system:
          stripAttrsForHydra (filterDerivations (
            # This is awkward.
            import ./ci.nix {
              inherit ifdLevel system evalSystem;
              haskellNix = self;
            }
          )));

        requiredJobs = forEachSystem (system:
          let
            inherit (self.legacyPackages.${system}) releaseTools;
          in
          lib.concatMapAttrs
            (nixpkgsVer:
              lib.concatMapAttrs (compiler-nix-name:
                lib.concatMapAttrs (crossPlatform: ghcJobs:
                  let
                    name = "required-${nixpkgsVer}-${compiler-nix-name}-${crossPlatform}";
                    value = releaseTools.aggregate {
                      name = "haskell.nix-${nixpkgsVer}-${compiler-nix-name}-${crossPlatform}";
                      meta.description = "All ${nixpkgsVer} ${compiler-nix-name} ${crossPlatform} jobs";
                      constituents = lib.collect lib.isDerivation ghcJobs;
                    };
                  in
                  lib.optionalAttrs
                    (crossPlatform != "recurseForDerivations" && crossPlatform != "meta")
                    { ${name} = value; })
              )
            )
            self.allJobs.${system}
        );

        hydraJobs = forEachSystem (system:
          let
            # Include hydraJobs from nix-tools subflake.
            # NOTE: These derivations do not depend on the haskell.nix in ./. but
            # on the version of haskell.nix locked in the subflake. They are
            # evaluated within their own flake and independently of anything
            # else. Here we only expose them in the main flake.
            nix-tools-hydraJobs =
              let
                cf = callFlake {
                  inherit system;
                  pkgs = self.legacyPackages.${system};
                  src = ./nix-tools;
                };
              in
              cf.defaultNix.hydraJobs;

            # The GHC compilers present in the CI matrix (the keys of the "GHC
            # version" dimension, under each nixpkgs pin).  Used by the
            # ci-status-matrix guard test below.
            jobs = self.allJobs.${system};
            ghcsInHydra = lib.unique (lib.concatMap
              (pin: builtins.filter (lib.hasPrefix "ghc") (builtins.attrNames jobs.${pin}))
              (builtins.filter (n: n != "meta" && n != "recurseForDerivations")
                (builtins.attrNames jobs)));
          in
          self.allJobs.${system}
          // lib.optionalAttrs (ifdLevel > 2)
            { nix-tools = nix-tools-hydraJobs.${system} or { }; }
          # Fail CI if a compiler enters/leaves the matrix without the README
          # CI-status table's generator being updated to match.  Only needs to
          # run on one system (the compiler dimension is system-independent).
          // lib.optionalAttrs (system == "x86_64-linux")
            { ci-status-matrix = import ./test/ci-status-matrix.nix {
                inherit lib;
                pkgs = self.legacyPackages.${system};
                ghcs = ghcsInHydra;
                scriptFile = ./scripts/update-ci-status.sh;
              };
            }
        );

        devShells = forEachSystemPkgs (pkgs:
          let
            mkHaskellNixShell = compiler-nix-name:
              pkgs.mkShell {
                buildInputs = [
                  pkgs.nixVersions.latest
                  pkgs.haskell-nix.cabal-install.${compiler-nix-name}
                  pkgs.haskell-nix.compiler.${compiler-nix-name}
                ];
              };
            shells = lib.genAttrs (
              # Exclude old versions of GHC to speed up `nix flake check`
              lib.attrNames (
                lib.removeAttrs pkgs.haskell-nix.compiler
                  ([ "ghc844" ] ++
                    [ "ghc861" "ghc862" "ghc863" "ghc864" ] ++
                    [ "ghc881" "ghc882" "ghc883" ] ++
                    [ "ghc8101" "ghc8102" "ghc8103" "ghc8104" "ghc810420210212" "ghc8105" "ghc8106" ] ++
                    [ "ghc901" ] ++ [ "ghc921" "ghc922" "ghc923" ])
              ))
              mkHaskellNixShell;
          in
          shells // { default = shells.${defaultCompiler}; });
      };

    in
    traceHydraJobs (lib.recursiveUpdate flake (lib.optionalAttrs (ifdLevel > 2)
      (
        let pkgs = nixpkgs.legacyPackages."x86_64-linux"; in
        {
          hydraJobs.nix-tools = pkgs.releaseTools.aggregate {
            name = "nix-tools";
            constituents = (if runningHydraEvalTest then [ ] else [
              "aarch64-darwin.nix-tools.static.zipped.nix-tools-static"
              "x86_64-darwin.nix-tools.static.zipped.nix-tools-static"
              "aarch64-darwin.nix-tools.static.zipped.nix-tools-static-no-ifd"
              "x86_64-darwin.nix-tools.static.zipped.nix-tools-static-no-ifd"
            ]) ++ [
              "x86_64-linux.nix-tools.static.zipped.nix-tools-static"
              "x86_64-linux.nix-tools.static.zipped.nix-tools-static-arm64"
              "x86_64-linux.nix-tools.static.zipped.nix-tools-static-no-ifd"
              "x86_64-linux.nix-tools.static.zipped.nix-tools-static-arm64-no-ifd"
              (pkgs.writeText "gitrev" (self.rev or "0000000000000000000000000000000000000000"))
            ];
          };
        }
      )));

  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    # This sets the flake to use the IOG nix cache.
    # Nix should ask for permission before using it,
    # but remove it here if you do not want it to.
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
    allow-import-from-derivation = "true";
  };
}
