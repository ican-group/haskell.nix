{ sources }:
let
  overlays = {
    wine = import ./wine.nix;
    haskell = import ./haskell.nix { inherit sources; };
    head-hackage = import ./head-hackage.nix { inherit sources; };

    # Here is where we import nix-tools into the overlays that haskell.nix is
    # going to use. To cut the evaluation time of nix-tools (which would itself
    # depend on haskell.nix), we have the option of obtaining a pre-compiled
    # and statically-linked copy nix-tools.
    nix-tools = (final: prev:
      let
        # Import the overlay from nix-tools' subdirectory
        nix-tools-pkgs = import ../nix-tools/overlay.nix final prev;

        # The static-nix-tools tarball.
        #
        # Note: nix-tools provides single derivations for each of the tools it
        # provides, and haskell.nix derivations are granual in which tools they
        # are going to need. E.g. a derivation will have
        #     nativeBuildInputs = [ nix-tools.exes.make-install-plan ... ];
        #
        # On the other hand, there is a single the binary tarball for all
        # tools, therefore we cannot just swap nix-tools for a derivation
        # created by fetchzip.
        #
        # We resolve this by adding the missing attributes to static-nix-tools,
        # pointing back to the same static-nix-tools derivation. This allows
        # downstram derivation to keep using `nix-tools.exes.make-install-plan`
        # as shown above.
        static-nix-tools' = pins:
          let
            # TODO replace once haskell-nix-examples nix-tools is in haskell.nix
            zipFile = (import pins final).${final.stdenv.hostPlatform.system};
            tarball = final.runCommand "nix-tools" {
              nativeBuildInputs = [ final.unzip ];
            } ''
              mkdir -p $out/bin
              cd $out/bin
              unzip ${zipFile}
            '';
            nix-tools-provided-exes = builtins.attrNames nix-tools-pkgs.nix-tools.exes;
          in
            # add the missing exes attributes to the tarball derivation
            tarball // { exes = final.lib.genAttrs nix-tools-provided-exes (_: tarball); };

        static-nix-tools = static-nix-tools' ../nix-tools-static.nix;
        # Any change to default-setup requires rebuilding everthing.
        # Having a dedicated file for `default-setup` allows us to update
        # the other `nix-tools` (like `make-install-plan`), without a
        # full rebuild.
        static-nix-tools-for-default-setup = static-nix-tools' ../nix-tools-static-for-default-setup.nix;

        # The stable-haskell variant, built from ../nix-tools-sh and pinned
        # separately for the same reason `default-setup` is: so it can move
        # without dragging anything else with it.
        #
        # NOTHING SELECTS THIS BY DEFAULT.  plan-to-nix and make-install-plan
        # generate plan-nix for whatever compiler they are pointed at, so making
        # these the shared default would move every existing GHC onto the
        # stable-haskell Cabal fork.  It is opt-in per project through the
        # `nix-tools` option in modules/cabal-project.nix, resolved in
        # lib/call-cabal-project-to-nix.nix; ghc9.6 .. ghc9.14 continue to use
        # ../nix-tools-static.nix.  See ../nix-tools-static-sh.nix.
        static-nix-tools-sh = static-nix-tools' ../nix-tools-static-sh.nix;

        # Version of nix-tools built with a pinned version of haskell.nix.
        pinned-nix-tools-lib = (import final.haskell-nix.sources.flake-compat {
            pkgs = final;
            inherit (final.stdenv.hostPlatform) system;
            src = ../nix-tools;
            override-inputs = {
              # Avoid downloading another `hackage.nix`.
              inherit (final.haskell-nix.sources) hackage;
            };
          }).defaultNix.lib;
      in
      {
        haskell-nix =
          prev.haskell-nix // {
            inherit (nix-tools-pkgs) nix-tools nix-tools-set;
            # either nix-tools from its overlay or from the tarball.
            #
            # Keep these prebuilt bundles.  plan-nix is the universal IFD, so a
            # from-source nix-tools turns one prebuilt bundle into three
            # per-component builds in every plan-nix derivation across the
            # whole compiler x platform matrix -- measured at 6x-89x the
            # per-job eval time on the mainline compilers (ghc967 124.8s/job
            # vs 1.4s).
            #
            # v2 projects (and every stable-haskell compiler's) plan with
            # `nix-tools-unchecked-sh`, the stable-haskell cabal fork, to match
            # the v2 builder's cabal; v1 projects keep this mainline 3.16
            # bundle.  See modules/cabal-project.nix.
            nix-tools-unchecked = static-nix-tools // {
              exes =  static-nix-tools.exes // {
                inherit (static-nix-tools-for-default-setup.exes) default-setup default-setup-ghcjs;
              };
            };
            # As above, with the stable-haskell tools.  `default-setup` still
            # comes from the shared pin on purpose: it is the one whose hash
            # rebuilds everything, and the fork has no reason to differ there,
            # so opting a project into these tools must not fork the setup used
            # to build the world.
            nix-tools-unchecked-sh = static-nix-tools-sh // {
              exes = static-nix-tools-sh.exes // {
                inherit (static-nix-tools-for-default-setup.exes) default-setup default-setup-ghcjs;
              };
            };
          };
        # For use building hadrian.  This way updating anything that modifies the
        # way hadrian is built will not cause a GHC rebuild.
        pinned-haskell-nix = pinned-nix-tools-lib.haskell-nix final.stdenv.hostPlatform.system;
      });

    bootstrap = import ./bootstrap.nix;
    compiler-llvm = import ./compiler-llvm.nix;
    ghc-packages = import ./ghc-packages.nix;
    darwin = import ./darwin.nix;
    mingw-stdio = import ./mingw-stdio.nix;
    windows = import ./windows.nix;
    armv6l-linux = import ./armv6l-linux.nix;
    hyper-linux = import ./hyper-linux.nix { inherit sources; };
    musl = import ./musl.nix;
    android = import ./android.nix;
    tools = import ./tools.nix;
    emscripten = import ./emscripten.nix;
    nix-prefetch-git-minimal = import ./nix-prefetch-git-minimal.nix;
    gobject-introspection = import ./gobject-introspection.nix;
    hix = import ./hix.nix;
    ghcjs = import ./ghcjs.nix;
    cabalPkgConfig = import ./cabal-pkg-config.nix;
    cacheCompilerDeps = import ./cache-compiler-deps.nix;
    lazy-inputs = import ../lazy-inputs;
    rcodesign = import ./rcodesign.nix;
    wasm = import ./wasm.nix;
    stable-haskell = import ./stable-haskell.nix;
    hsc2hs = import ./hsc2hs.nix;
  };

  composeExtensions = f: g: final: prev:
    let
      fApplied = f final prev;
      prev' = prev // fApplied;
    in fApplied // g final prev';

  ordered = with overlays; [
    # Hide nixpkgs haskell and haskellPackages from the haskell-nix overlays.
    # This should prevent us inadvertently depending on them.
    (_: prev: {
      haskell = { };
      haskellPackages = { };
      haskell-nix-prev = prev;
    })
    wine
    haskell
    nix-tools
    bootstrap
    compiler-llvm
    ghc-packages
    darwin
    mingw-stdio
    windows
    armv6l-linux
    hyper-linux
    musl
    android
    tools
    head-hackage
    emscripten
    nix-prefetch-git-minimal
    ghcjs
    cabalPkgConfig
    gobject-introspection
    hix
    wasm
    # Restore nixpkgs haskell and haskellPackages
    (_: prev: { inherit (prev.haskell-nix-prev) haskell haskellPackages; })
    lazy-inputs
    # After lazy-inputs (its source), before stable-haskell (a user of it).
    hsc2hs
    stable-haskell
    cacheCompilerDeps
    rcodesign
  ];
  combined = builtins.foldl' composeExtensions (_: _: { }) ordered;
in overlays // { inherit combined; }
