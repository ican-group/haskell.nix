# While creating the nix build plan, we take care to create package derivations
# that do not include any reference to the plan itself or how it is created.
#
# This allows haskell.nix to share packages between plans (at least when they
# have identical dependencies). If the package derivations included the hash of
# the plan derivation, different plans would always produce different packages
# and there could not be any sharing of packages between plans.
#
# Any wrangling of the project dependencies (e.g. fetching package indices,
# source-repository-packages or any other asset required for building) *has* to
# be performed during planning. The nix build plan will import any remote asset
# through a fixed-output derivations (i.e. a call to a fetcher).
#
# tl;dr: the builder must not re-introduce any reference to the build plan.

{ pkgs, buildPackages, pkgsBuildBuild, evalPackages, stdenv, lib, haskellLib, ghc, compiler-nix-name, fetchurl, nonReinstallablePkgs, hsPkgs, compiler, builderVersion ? 1, crossTemplateHaskellSupport ? true, v2LocalPackageSlices ? false, v2LocalPackageSliceNames ? [], cabalProjectLocal ? null, withBuildCompiler ? false }:

let
  # Builds a single component of a package.
  comp-builder = haskellLib.weakCallPackage pkgs ./comp-builder.nix {
    inherit ghc haskellLib makeConfigFiles haddockBuilder ghcForComponent hsPkgs compiler nonReinstallablePkgs;
  };

  # Alternative component builder that runs cabal v2-build and emits
  # a cabal-store slice rather than going through Setup.hs.  Selected
  # when the project sets `builderVersion = 2` (the default).  See
  # builder/comp-v2-builder.nix for the per-kind behaviour.
  #
  # The patched fork cabal-install it runs is defined in the overlay
  # (`haskell-nix.v2-cabal-install`, overlays/haskell.nix — see the
  # comments there for the pins and the fork rationale) so there is one
  # memoised instance per eval system and `haskell-nix.roots` can link
  # its plan-nix.  Select the variant matching this project's eval
  # platform (without this the tool's plan-to-nix would default to the
  # pkgsBuildBuild system, forcing IFD on (e.g.) x86_64-linux when the
  # eval host is darwin).
  v2CabalInstall =
    let v2ci = pkgsBuildBuild.haskell-nix.v2-cabal-install;
    in v2ci.evalWith.${evalPackages.stdenv.hostPlatform.system} or v2ci;

  # The one place the v2 builder's cabal-install VERSION is written
  # down.  `shell-for-v2.nix` reads it too: a v2 shell whose `cabal`
  # is a *different* cabal-install from the one that built the slices
  # computes different UnitIds, so nothing in the composed store
  # matches and cabal rebuilds every dependency from source.
  #
  # Keep this in step with `version` in `haskell-nix.v2-cabal-install`
  # (overlays/haskell.nix).  It is not mainline's 3.16.1.0 here: this
  # branch builds the v2 cabal from the stable-haskell fork, which is
  # 3.17.0.1.
  v2CabalInstallVersion = "3.17.0.1";

  # Shared helper that wraps a real ghc into a "shim" with cabal-
  # near-compiler aliases, ghcjs settings patch, and native-musl
  # iserv aliases.  Used by both `build-cabal-slice` and the v2
  # shell so a user's shell ghc matches the slice's ghc as closely
  # as the use case allows.
  makeGhcShim = import ./ghc-shim.nix {
    inherit stdenv lib pkgsBuildBuild haskellLib;
  };

  buildCabalStoreSlice = import ./build-cabal-slice.nix {
    inherit stdenv lib ghc pkgs pkgsBuildBuild buildPackages haskellLib makeGhcShim;
    cabal-install = v2CabalInstall;
  };

  # Helper that composes a list of v2 slices into one cabal-store
  # layout.  Used by `comp-v2-builder` to attach a `.store`
  # derivation to each slice (containing the component's
  # *dependencies* — not the component itself), and by the v2 shell
  # to compose the user-facing dep store.
  composeStore = import ./compose-store.nix {
    inherit lib ghc;
    inherit (pkgs) runCommand;
    lndir = pkgs.buildPackages.lndir or pkgs.buildPackages.xorg.lndir;
  };
  # If the host platform has cross-TH plumbing (currently only
  # windows via overlays/windows.nix) it lives at
  # `pkgs.haskell-nix.templateHaskell.<compiler-nix-name>`.  Pull
  # it out here so comp-v2-builder doesn't need its own
  # compiler-nix-name lookup just to wrap the ghc we already have.
  # Honour the project-level `crossTemplateHaskellSupport` switch
  # so projects that the wrapper itself depends on (iserv-proxy)
  # can opt out, breaking the otherwise-circular dep on the
  # wrapped ghc's inputs.
  templateHaskell =
    if !crossTemplateHaskellSupport then null
    else
      let th = pkgs.haskell-nix.templateHaskell.${compiler-nix-name} or null;
      # Select the variant for this project's eval platform so forcing
      # the iserv exes doesn't run their plan-to-nix IFD on the default
      # (pkgsBuildBuild) system.
      in if th == null then null
         else th.evalWith.${evalPackages.stdenv.hostPlatform.system} or th;

  comp-v2-builder = haskellLib.weakCallPackage pkgs ./comp-v2-builder.nix {
    inherit ghc hsPkgs buildCabalStoreSlice templateHaskell haskellLib composeStore
      v2LocalPackageSlices v2LocalPackageSliceNames;
    # The host platform's iserv-proxy executables (eval-platform variant,
    # as for `templateHaskell` above), for the `-pgmi` bridge's profiled
    # interpreter in comp-v2-builder.nix.  Lazy: only forced for a slice
    # that runs `-fexternal-interpreter` with profiling.
    iservProxyExes =
      if !crossTemplateHaskellSupport then null
      else
        let e = pkgs.haskell-nix.iserv-proxy-exes.${compiler-nix-name} or null;
        in if e == null then null
           else e.evalWith.${evalPackages.stdenv.hostPlatform.system} or e;
  };

  haddockBuilder = haskellLib.weakCallPackage pkgs ./haddock-builder.nix {
    inherit ghc ghcForComponent haskellLib makeConfigFiles nonReinstallablePkgs;
  };

  setup-builder = haskellLib.weakCallPackage pkgs ./setup-builder.nix {
    ghc = (ghc.buildGHC or ghc);
    hsPkgs = hsPkgs.buildPackages;
    # We need to use the buildPackages stdenv to build the setup-builder.
    # in the native case, it would be the same in the cross case however
    # we *really* want to build the Setup.hs on the build machine and not
    # have the stdenv confuse it with the target/host env.
    inherit (buildPackages) stdenv;
    inherit buildPackages;
    inherit haskellLib nonReinstallablePkgs makeSetupConfigFiles;
  };

  # Wraps GHC to provide dependencies in a way that works for both the
  # component builder and for nix-shells.
  ghcForComponent = import ./ghc-for-component-wrapper.nix {
    inherit lib ghc haskellLib;
    inherit (pkgs) stdenv;
    inherit (buildPackages.buildPackages) runCommand makeWrapper;
    lndir = buildPackages.buildPackages.lndir or buildPackages.buildPackages.xorg.lndir;
  };

  # Builds a derivation which contains a ghc package-db of
  # dependencies for a component.
  makeConfigFiles = haskellLib.weakCallPackage pkgs ./make-config-files.nix {
    inherit ghc haskellLib nonReinstallablePkgs;
  };
  # When building setup depends we need to use the build systems GHC and Packages
  makeSetupConfigFiles = haskellLib.weakCallPackage buildPackages ./make-config-files.nix {
    inherit haskellLib nonReinstallablePkgs;
    ghc = (ghc.buildGHC or ghc);
  };


  hoogleLocal = let
    # Use hoogle.nix from at least nixpkgs 22.05
    nixpkgs = if lib.versionAtLeast lib.trivial.release "22.05"
      then pkgs.path
      else pkgs.haskell-nix.sources.nixpkgs-2205;
    nixpkgsHoogle = import (nixpkgs + /pkgs/development/haskell-modules/hoogle.nix);
  in { packages ? [], hoogle }:
    let
      haskellPackages = {
        # For musl we can use haddock from the buildGHC
        ghc = if stdenv.targetPlatform.isMusl
          then ghc.buildGHC
          else ghc;
        inherit packages hoogle;
      };
    in haskellLib.weakCallPackage pkgs nixpkgsHoogle {
      inherit haskellPackages;
    } (p: p.packages);

  # `shellFor` dispatches on the project's `builderVersion`.  The
  # primary derivation per component is whichever builder
  # `builderVersion` selects, so the shell has to match.  See
  # `builder/shell-for-v2.nix` for the v2 semantics; v2 is the only
  # shell that supports public sublibs (`library <n>`).
  #
  # `mkShell = pkgs.buildPackages.mkShell` so the shell derivation
  # lives on the *build* platform regardless of the host (cross)
  # platform.  Without this, cross targets like ghcjs route through
  # `pkgs.mkShell` → host-stdenv `bashInteractive` →
  # `stdenv.cc.isClang`, which throws "no C compiler provided for
  # this platform" because the ghcjs cross-stdenv has no cc.  The
  # user-facing shell is meant to be opened on the build host
  # anyway, so build-platform mkShell is the right choice for both
  # cross and native (where buildPackages == pkgs).
  shellForV1 = haskellLib.weakCallPackage pkgs ./shell-for.nix {
    inherit hsPkgs ghcForComponent makeConfigFiles hoogleLocal haskellLib pkgsBuildBuild evalPackages compiler ghc;
    inherit (buildPackages) mkShell glibcLocales llvmPackages;
  };
  shellForV2 = haskellLib.weakCallPackage pkgs ./shell-for-v2.nix {
    inherit hsPkgs haskellLib ghc compiler composeStore makeGhcShim cabalProjectLocal
            v2CabalInstall v2CabalInstallVersion withBuildCompiler;
    inherit (buildPackages) mkShell;
    haskell-nix = pkgs.haskell-nix;
  };
  shellFor = if builderVersion == 2 then shellForV2 else shellForV1;

  # Same as haskellPackages.ghcWithPackages and ghcWithHoogle in nixpkgs.
  withPackages = {withHoogle}: packages: (shellForV1 {
    name = ghc.name + "-with-packages";
    packages = _: [];
    additional = packages;
    inherit withHoogle;
  }).ghc;

in {
  # Build a Haskell package from its config.
  # TODO: this pkgs is the adjusted pkgs, but pkgs.pkgs is unadjusted
  build-package = haskellLib.weakCallPackage pkgs ./hspkg-builder.nix {
    inherit haskellLib ghc compiler-nix-name comp-builder comp-v2-builder setup-builder builderVersion;
  };

  inherit shellFor makeConfigFiles;

  ghcWithPackages = withPackages { withHoogle = false; };
  ghcWithHoogle = withPackages { withHoogle = true; };
}
