final: _prev:

let
  compiler-nix-name = "ghc96";

  nix-tools = nix-tools-set {
    nix-tools = nix-tools-unchecked;
  };

  nix-tools-unchecked = nix-tools-set {};

  nix-tools-eval-on-linux = nix-tools-set {
    evalSystem = "x86_64-linux";
  };

  nix-tools-set = args:
    let
      project = final.haskell-nix.cabalProject'
        [
          {
            name = "nix-tools";
            src = ./.;

            compiler-nix-name = final.lib.mkDefault compiler-nix-name;
            # compilerSelection = p: p.haskell.compiler;

            # Test components are left enabled (haskell.nix already passes
            # `--enable-tests` when generating the plan) so that the pure test
            # suites are built and run as flake checks, and therefore as part
            # of `hydraJobs`.  Suites that need network access are opted out
            # individually via `doCheck` below rather than by disabling every
            # test component.

            modules = [
              # See ./cabal-install-patches.nix for why this patch is
              # needed.  Applied here for the regular nix-tools build,
              # and again from `static/project.nix` for the static build.
              ./cabal-install-patches.nix
              {
                # The golden `tests` suite calls `cabal update` on startup, so
                # it needs network access that the build sandbox does not
                # provide.  Keep building it (so it cannot silently stop
                # compiling) but do not run it as a check.
                packages.nix-tools.components.tests.tests.doCheck = false;
              }
            ];

            # Tools to include in the development shell
            shell.tools.cabal = {};
            shell.tools.haskell-language-server = {};
            shell.buildInputs = [ final.git ];
          }
          args
        ];

      # pick the version from the nix-tools cabal package, not that it really matters ...
      name = "nix-tools-${project.hsPkgs.nix-tools.identifier.version}";

      exes = {
        inherit (project.hsPkgs.cabal-install.components.exes)
          cabal;

        inherit (project.hsPkgs.nix-tools.components.exes)
          cabal-name
          cabal-to-nix
          default-setup
          default-setup-ghcjs
          hackage-to-nix
          hashes-to-nix
          lts-to-nix
          make-install-plan
          plan-to-nix
          stack-repos
          stack-to-nix
          truncate-index;

        inherit (project.hsPkgs.hpack.components.exes)
          hpack;

        inherit (project.hsPkgs.Cabal-syntax-json.components.exes)
          cabal2json;
      };

      warning = final.lib.mapAttrs
        (_: _:
          final.lib.warn
            ''
              The package nix-tools is now compiled with a single GHC version.
              You can use the function nix-tools-set to compile nix-tools using a specific compiler:

                nix-tools-set { compiler-nix-name = " "ghcXYZ" "; }
            ''
            toolset
        )
        final.haskell-nix.compiler;

      toolset = final.buildPackages.symlinkJoin {
        inherit name;
        paths = builtins.attrValues exes;
        buildInputs = [ final.buildPackages.makeWrapper ];
        meta.platforms = final.lib.platforms.all;
        passthru = { inherit project exes; };
      };
    in
    toolset // warning;
in
{
  inherit nix-tools nix-tools-unchecked nix-tools-eval-on-linux nix-tools-set;
}
