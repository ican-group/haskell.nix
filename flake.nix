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
    # nixpkgs 26.05 is the last release supporting x86_64-darwin (unstable /
    # 26.11 dropped it), so the CI matrix uses this pin for x86_64-darwin.
    nixpkgs-2605 = { url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin"; };
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
    # hyper-linux (`hl`, github:zw3rk/hyper-linux) runs Linux ELFs on Apple
    # Silicon macOS via Hypervisor.framework.  It fills the qemu-user-mode slot
    # (which doesn't exist on macOS) when cross-compiling darwin -> linux, so
    # Template Haskell / tests can run the target binary.  This is a real flake
    # (we want its `hl` package); keep its nixpkgs on ours.
    hyper-linux = {
      url = "github:zw3rk/hyper-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # head.hackage's patches, plus the tool its CI uses to turn them into a
    # package repository.  We build the repository ourselves rather than
    # downloading the published one -- see overlays/head-hackage.nix.
    head-hackage = {
      url = "gitlab:ghc/head.hackage?host=gitlab.haskell.org";
      flake = false;
    };
    hackage-overlay-repo-tool = {
      url = "github:bgamari/hackage-overlay-repo-tool";
      flake = false;
    };

    # cabal-doctest 1.0.12 (the newest release on hackage) does not build
    # against Cabal 3.17: that release split Verbosity into VerbosityFlags and
    # VerbosityHandles, so `buildVerbosity`'s result no longer typechecks where
    # the Simple.Utils helpers want a Verbosity.  haskell-gi's custom Setup.hs
    # depends on it, so the gi-gtk test needs the fixed fork.
    #
    # Pinned to the rev rather than the branch on purpose: the same rev is
    # named as the `tag:` of the source-repository-package in
    # test/gi-gtk/default.nix, and lib/call-cabal-project-to-nix.nix checks
    # `inputMap.<url>.rev` against that tag.  Pinning keeps `nix flake update`
    # from moving one half of that pair.
    cabal-doctest = {
      url = "github:stable-haskell/cabal-doctest/641cda5a4590f2384568a9598713f3039b99258d";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , nixpkgs-unstable
    , nixpkgs-2605
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
      #
      # Keep the `or` fallback so an IMPURE evaluation (`nix build --impure`)
      # picks the evaluator's own system: that makes the linux jobs buildable
      # on a machine with no darwin builders, which is how they get tested
      # outside CI.  Pure evaluation is unaffected -- `currentSystem` is not in
      # scope there, so it still resolves to the "aarch64-darwin" literal.
      evalSystem = builtins.currentSystem or "aarch64-darwin";
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
      # NB: x86_64-darwin is still supported, but ONLY via the 26.05 nixpkgs pin
      # — nixpkgs unstable (26.11) dropped x86_64-darwin ("Nixpkgs 26.11 has
      # dropped support for x86_64-darwin").  So every unstable-based output
      # (legacyPackages, the `unstable` ci dimension, the nix-tools subflake)
      # falls back to / excludes x86_64-darwin accordingly; see the pin fallback
      # in `legacyPackages*` below and the `nixpkgsVersions` gate in ci.nix.
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

        # nixpkgs unstable (26.11) dropped x86_64-darwin, so on that platform
        # the "unstable" pkgs fall back to the 26.05 pin (the last release that
        # supports it).  Everywhere else these track the unstable nixpkgs as
        # before.
        legacyPackages = forEachSystem (system:
          import (if system == "x86_64-darwin" then nixpkgs-2605 else nixpkgs) {
            inherit config;
            overlays = [ self.overlay ];
            localSystem = { inherit system; };
          });

        legacyPackagesUnstable = forEachSystem (system:
          import (if system == "x86_64-darwin" then nixpkgs-2605 else nixpkgs-unstable) {
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

            # And the stable-haskell variant, from ./nix-tools-sh.  Same
            # independence as above: its own flake, its own lock, no dependency
            # on the haskell.nix in ./.
            #
            # It is a second copy of the subflake rather than a build variant of
            # the first because the two cannot share a source tree -- the fork
            # changes the Haskell sources (Cabal2Nix, MakeInstallPlan,
            # ProjectPlanOutput, Freeze, setup-ghcjs) to suit the stable-haskell
            # Cabal fork at 3.17, not only cabal.project.  Carrying both trees
            # here, instead of keeping the fork on an unmerged branch, is what
            # lets `nix-tools-sh-*` tags be cut from master commits exactly like
            # mainline ones; see .github/workflows/upload-artifacts-sh.yml.
            nix-tools-sh-hydraJobs =
              let
                cf = callFlake {
                  inherit system;
                  pkgs = self.legacyPackages.${system};
                  src = ./nix-tools-sh;
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
            { nix-tools = nix-tools-hydraJobs.${system} or { };
              nix-tools-sh = nix-tools-sh-hydraJobs.${system} or { };
            }
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
              # Exclude compilers that are too old to be supported.  Those
              # attributes throw (see `traceWarnOld` in overlays/bootstrap.nix),
              # which would break `nix flake check`.
              lib.filter (n: (builtins.tryEval pkgs.haskell-nix.compiler.${n}.version).success)
                (lib.attrNames pkgs.haskell-nix.compiler))
              mkHaskellNixShell;
          in
          shells // { default = shells.${defaultCompiler}; });
      };

    in
    # There used to be a `hydraJobs.nix-tools` aggregate here, grouping the four
    # `<system>.nix-tools.static.zipped.*` zips so `upload-artifacts.yml` had a
    # single check to wait on.  It was expensive out of proportion to that.
    #
    # `releaseTools.aggregate` takes its constituents as job-name strings, which
    # are Hydra metadata and create no nix dependency -- but nix-eval-jobs
    # resolves named constituents and rewrites the derivation to depend on them,
    # so the built `nix-tools.drv` really did list all four zips in `inputDrvs`.
    # nix realises every input on the build machine whether the builder script
    # reads it or not, so the aggregate dragged 476MB of zip closures onto
    # whichever single agent Hydra happened to pick.  On the darwin-hosted linux
    # builders, where import already dominates step time, that regularly hit the
    # one-hour wall and failed, then retried elsewhere and copied it all again.
    #
    # The workflow now asks the Hydra API for the eval matching the commit and
    # reads those four jobs from it directly, so nothing has to co-locate them.
    traceHydraJobs flake;

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
