_inputs: pkgs:

let

  apply-hnix-patches = {
    packages.hnix.patches = [
      (builtins.toFile "hnix.patch" ''
        diff --git a/src/Nix/Options/Parser.hs b/src/Nix/Options/Parser.hs
        index 3aeb0e5..bea0ac9 100644
        --- a/src/Nix/Options/Parser.hs
        +++ b/src/Nix/Options/Parser.hs
        @@ -214,11 +214,7 @@ versionOpt = shortVersionOpt <*> debugVersionOpt
           debugVersionOpt =
             infoOption
               ( fold
        -          [ "Version: ", showVersion version
        -          , "\nCommit: ", $(gitHash)
        -          , "\n  date: ", $(gitCommitDate)
        -          , "\n  branch: ", $(gitBranch)
        -          ]
        +          [ "Version: ", showVersion version ]
               )
               (  long "long-version"
               <> help "Show long debug version form"

      ''
      )
    ];
  };


  # Shared with the regular nix-tools build (see
  # ../cabal-install-patches.nix) so both builds patch
  # cabal-install identically.
  apply-cabal-install-patches = import ../cabal-install-patches.nix;


  apply-dontStrip-to-nix-tools = {
    packages.nix-tools.components.exes = {
      cabal-name.dontStrip = false;
      cabal-to-nix.dontStrip = false;
      hackage-to-nix.dontStrip = false;
      hashes-to-nix.dontStrip = false;
      lts-to-nix.dontStrip = false;
      make-install-plan.dontStrip = false;
      plan-to-nix.dontStrip = false;
      stack-repos.dontStrip = false;
    };
    packages.cabal-install.components.exes.cabal.dontStrip = false;
    packages.hpack.components.exes.hpack.dontStrip = false;
    packages.Cabal-syntax-json.components.exes.cabal2json.dontStrip = false;
  };


  add-static-libs-to-darwin = pkgs.lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    packages.cabal-install.ghcOptions = [
      "-L${pkgs.lib.getLib pkgs.static-gmp}/lib"
    ];
    packages.hpack.ghcOptions = [
      "-L${pkgs.lib.getLib pkgs.static-gmp}/lib"
    ];
    packages.nix-tools.ghcOptions = [
      "-L${pkgs.lib.getLib pkgs.static-gmp}/lib"
    ];
    packages.Cabal-syntax-json.ghcOptions = [
      "-L${pkgs.lib.getLib pkgs.static-gmp}/lib"
    ];
  };


  static-nix-tools-project = pkgs.haskell-nix.project' {

    compiler-nix-name = "ghc96";

    src = ../.;

    # tests need to fetch hackage
    configureArgs = pkgs.lib.mkDefault "--disable-tests";

    modules = [
      apply-hnix-patches
      apply-cabal-install-patches
      apply-dontStrip-to-nix-tools
      add-static-libs-to-darwin
    ];
  };

in

static-nix-tools-project
