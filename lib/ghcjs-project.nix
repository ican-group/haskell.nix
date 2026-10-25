# IMPORTANT: This is for building ghcjs, not for building with
# ghcjs. To build with ghcjs then just replace `haskell-nix`
# with `pkgsCross.ghcjs.haskell-nix`.
#
# For the time being we can't really treat ghcjs like a
# regular ghc (with different target). We need this as a
# stop-gap measure until ghcjs can be treated like a regular
# ghc.
#
# `haskell-nix.ghcjsProject` wraps `haskell-nix.cabalProject'`
# for use with the ghcjs source. It is exposed to allow GHCJS
# developers to work on the GHCJS code in a nix-shell with
# `shellFor`. It takes thes the clean src (from fetched
# source or local source that has been cleaned with cleanGit.
# It configures the source and passes it onto `cabalProject`
# along with the necessary modules.
#
# It also adds `configureInputs` and `bootInputs` that a
# needed for configuring the source and booting the compiler
# once it is built.  These are added to the `hsPkgs.shellFor`
# of the project.
{ pkgs, materialized-dir }:
{ src
, compiler-nix-name
, ghc ? pkgs.buildPackages.haskell-nix.compiler.${compiler-nix-name}
, ghcjsVersion # Version in the ghcjs.cabal file (that we will replace)
, ghcVersion ? ghc.version
, happy ? pkgs.haskell-nix.tool compiler-nix-name "happy" {
    index-state = pkgs.haskell-nix.internalHackageIndexState;
    version = "1.19.12";
    materialized = materialized-dir +"/ghcjs/happy/${compiler-nix-name}";
  }
, alex ? pkgs.haskell-nix.tool compiler-nix-name "alex" {
    index-state = pkgs.haskell-nix.internalHackageIndexState;
    version = "3.2.5";
    materialized = materialized-dir + "/ghcjs/alex/${compiler-nix-name}";
  }
, cabal-install ?
  if (builtins.compareVersions ghcjsVersion "8.10.0.0" >= 0)
  then pkgs.haskell-nix.tool compiler-nix-name "cabal" {
    index-state = pkgs.haskell-nix.internalHackageIndexState;
    version = "3.8.1.0";
    materialized = materialized-dir + "/ghcjs/cabal/${compiler-nix-name}";
  }
  else pkgs.haskell-nix.tool compiler-nix-name "cabal" {
    index-state = pkgs.haskell-nix.internalHackageIndexState;
    version = "3.2.0.0";
    # Cabal 3.2.1.0 no longer supports he mix of `cabal-version`,
    # lack of `custom-setup` and `v1-install` used by ghcjs boot.
    # Using cabalProject here instead of cabalProjectLocal because
    # cabalProjectLocal gets replaced by modules/hackage-quirks.nix
    cabalProject = ''
      packages: .
      constraints: Cabal <3.2.1.0, Cabal-syntax <0
    '';
    materialized = materialized-dir + "/ghcjs/cabal/${compiler-nix-name}";
  }
, ...
}@args:
let
    isGhcjs88 = builtins.compareVersions ghcjsVersion "8.8.0.0" >= 0;
    isGhcjs810 = builtins.compareVersions ghcjsVersion "8.10.0.0" >= 0;

    # Inputs needed to configure the GHCJS source tree
    configureInputs = with pkgs; [
            perl
            autoconf
            automake
            python3
        ] ++ [
            ghc
            happy
            alex
            cabal-install
        ];

    inherit (pkgs.pkgsBuildBuild) emscriptenupstream emscripten emsdk;

    # Inputs needed to boot the GHCJS compiler
    bootInputs = with pkgs.buildPackages; [
            # We used to pin nodejs to the 12 series, as strings can only be half the length in node 14+
            # see https://github.com/nodejs/node/issues/33960
            # Large TH splices are likely broken.
            # TODO reinstate the pin of find a work around for ghcjs to send TH splice in chunks.
            nodejs-18_x
            makeWrapper
            (pkgs.buildPackages.lndir or xorg.lndir)
            gmp
            (pkgs.buildPackages.pkg-config or pkgconfig)
        ]
        ++ [ ghc cabal-install emsdk ];
    # Configured the GHCJS source
    configured-src = (pkgs.runCommandCC "configured-ghcjs-src" {
        buildInputs = configureInputs;
        inherit src;
        } ''
        export HOME=$(pwd)
        mkdir $HOME/.cabal
        touch $HOME/.cabal/config
        cp -r "$src" "$out"
        chmod -R +w "$out"
        cd "$out"

        # TODO: Find a better way to avoid impure version numbers
        sed -i 's/RELEASE=NO/RELEASE=YES/' ghc/configure.ac
        sed -i 's/${ghcjsVersion}/${ghcVersion}/' ghcjs.cabal

        ${
          # TODO: How to actually fix this?
          # Seems to work fine and produce the right files.
          pkgs.lib.optionalString (!isGhcjs88) ''
            touch ghc/includes/ghcautoconf.h
            mkdir -p ghc/compiler/vectorise
            mkdir -p ghc/utils/haddock/haddock-library/vendor
          ''
        }

        rm -rf utils/pkg-cache/ghc
        cp -r ${ghc.generated-light or ghc.generated} utils/pkg-cache/ghc

        for a in integer-gmp base unix; do
          cp ${../overlays/patches/config.sub} ghc/libraries/$a/config.sub
          cp ${../overlays/patches/config.guess} ghc/libraries/$a/config.guess
          chmod +w ghc/libraries/$a/config.*
        done

        sed -i 's/_AC_PROG_CC_C99/AC_PROG_CC_C99/' ghc/aclocal.m4

        patchShebangs .
        sed -i 's/gcc /cc /g' utils/makePackages.sh
        ./utils/makePackages.sh copy

        for a in integer-gmp base unix; do
          cp ${../overlays/patches/config.sub} lib/boot/pkg/$a/config.sub
        done
        '')  // {
          # The configured source includes /nix/store paths and so filtering can fail.
          filterPath = { path, ... }: path;
        };
        # see https://github.com/ghcjs/ghcjs/issues/751 for the happy upper bound.

    ghcjsProject = pkgs.haskell-nix.cabalProject' (
        (pkgs.lib.filterAttrs
            (n: _: !(builtins.any (x: x == n)
                ["src" "ghcjsVersion" "ghcVersion" "happy" "alex" "cabal-install"])) args) // {
        src = configured-src;
        index-state = "2021-03-20T00:00:00Z";
        inherit compiler-nix-name;
        configureArgs = pkgs.lib.optionalString (isGhcjs88 && !isGhcjs810) "--constraint='Cabal >=3.0.2.0 && <3.1'";
        # set use-host-template-haskell. This *does*
        # work as we use a patched ghc to boot anyway.
        # (we apply https://github.com/ghcjs/ghc/commit/2918d88d4ef786b5f2801f6f77ac333cc56dde75 already)
        cabalProjectLocal = ''
          package ghcjs
            flags: +use-host-template-haskell +no-wrapper-install
          package ghc-api-ghcjs
            flags: +use-host-template-haskell
          package ghcjs-th
            flags: +use-host-template-haskell
        '';
        # If a package is in both build-depends and build-tool-depends multiple versions may
        # be in the `plan.json` file.  Haskell.nix will pick the newer one, but when nbuilding
        # ghcjs 8.6 we need to use the older happy version.
        pkg-def-extras = pkgs.lib.optional (!isGhcjs88) (hackage: {
          packages.happy.revision = hackage.happy."1.19.9".revisions.default;
        });
        materialized = materialized-dir + "/ghcjs/${compiler-nix-name}";
        modules = [
            (pkgs.lib.optionalAttrs (!isGhcjs88) {
                packages.Cabal.patches = [ ./../overlays/patches/Cabal/fix-data-dir.patch ];
            })
            {
                packages.ghcjs.doHaddock = false;
                packages.ghc.flags.ghci = true;
                packages.ghci.flags.ghci = true;
                # packages.ghcjs.components.library.configureFlags = [ "-fno-wrapper-install" ];
                packages.ghcjs.components.library.build-tools = [ alex happy ];
            }
        ];
    });
in ghcjsProject // {
    # Add `configureInputs` and `bootInputs` to the shell
    hsPkgs = ghcjsProject.hsPkgs // {
        # Shell suitable for configuring and building a local copy of GHCJS
        shellFor = args: (ghcjsProject.hsPkgs.shellFor args).overrideAttrs (drv: {
            buildInputs = (drv.buildInputs or []) ++ configureInputs;
            nativeBuildInputs = (drv.nativeBuildInputs or []) ++ bootInputs;
            EMSDK = emsdk;
        });
    };
    inherit configureInputs bootInputs configured-src emscriptenupstream emscripten emsdk;
}
