# 'supportedSystems' restricts the set of systems that we will evaluate for. Useful when you're evaluating
# on a machine with e.g. no way to build the Darwin IFDs you need!
{ ifdLevel # This is passed in from flake.nix
, checkMaterialization ? false
, system ? builtins.currentSystem
, evalSystem ? "aarch64-darwin"
  # NOTE: we apply checkMaterialization when defining nixpkgsArgs
, haskellNix ? import ./default.nix { inherit system ; }
}:
 let
  inherit (haskellNix) inputs;
  inherit (inputs.nixpkgs) lib;
  inherit
    (import ./ci-lib.nix { inherit lib; })
    dimension
    platformFilterGeneric
    filterAttrsOnlyRecursive;

  # short names for nixpkgs versions
  # x86_64-darwin only gets the 26.05 pin: nixpkgs unstable (26.11) dropped
  # x86_64-darwin, so importing it for that system throws.  Every other system
  # gets both the 26.05 stable pin and unstable.
  nixpkgsVersions = {
    "R2605" = inputs.nixpkgs-2605;
  } // lib.optionalAttrs (system != "x86_64-darwin") {
    "unstable" = inputs.nixpkgs-unstable;
  };

  nixpkgsArgs = {
    # set checkMaterialization as per top-level argument
    overlays = [
      haskellNix.overlay
      (final: prev: {
        haskell-nix = prev.haskell-nix // {
          inherit checkMaterialization;
          # Pin the checks whose exes cannot run on an emulated builder (musl32)
          # to the zw3rk farm's one real linux host -- see
          # `emulatorSystemFeatures` in overlays/haskell.nix.
          emulatorSystemFeatures = [ "recursive-nix" ];
        };
      })
      (import ./test/overlay.nix)
    ];
    # Needed for dwarf tests
    config = haskellNix.config // {
      permittedInsecurePackages = [
        "libdwarf-20210528"
        "libdwarf-20181024"
        "dwarfdump-20181024"
      ];
      allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
        "platform-tools"
        "ndk"
        "android-sdk-ndk"
        "android-sdk-platform-tools"
        "aarch64-unknown-linux-android-ndk-toolchain-wrapper"
        "aarch64-unknown-linux-android-ndk-toolchain"
        "armv7a-unknown-linux-androideabi-ndk-toolchain-wrapper"
        "armv7a-unknown-linux-androideabi-ndk-toolchain"
      ];
    };
  };

  compilerNixNames = nixpkgsName: nixpkgs: builtins.listToAttrs (
    (lib.mapAttrsToList (compiler-nix-name: runTests: {
      name = nixpkgs.haskell-nix.resolve-compiler-name compiler-nix-name;
      value = { inherit runTests; };
    }) (
      # GHC version to cache and whether to run the tests against them.
      # This list of GHC versions should include everything for which we
      # have a ./materialized/ghcXXX directory containing the materialized
      # cabal-install and nix-tools plans.  When removing a ghc version
      # from here (so that is no longer cached) also remove ./materialized/ghcXXX.
      # Update supported-ghc-versions.md to reflect any changes made here.
      nixpkgs.lib.optionalAttrs (builtins.elem nixpkgsName ["R2411" "R2505" "R2511" "R2605"]) {
        ghc96 = false;
        ghc98 = false;
        ghc910 = false;
        ghc912 = false;
        ghc914 = false;
      } // nixpkgs.lib.optionalAttrs (nixpkgsName == "unstable") {
        ghc96 = true;
        ghc98 = true;
        ghc910 = true;
        ghc912 = true;
        ghc914 = true;
        ghc914llvm = true;
        ghc914-sh = true;
        # ghc915 = true;
      })));
  crossSystems = nixpkgsName: nixpkgs: compiler-nix-name:
    # We need to use the actual nixpkgs version we're working with here, since the values
    # of 'lib.systems.examples' are not understood between all versions
    let lib = nixpkgs.lib;
    in lib.optionalAttrs (nixpkgsName == "unstable"
      && __match ".*llvm" compiler-nix-name == null
      && builtins.elem system ["aarch64-linux" "x86_64-linux"]) {
        static = p: p.pkgsStatic;
      } // lib.optionalAttrs (nixpkgsName == "unstable"
          && (__match ".*llvm" compiler-nix-name == null)
          && !builtins.elem compiler-nix-name ["ghc9102" "ghc9103"]) {
        inherit (lib.systems.examples) ghcjs;
      } // lib.optionalAttrs (nixpkgsName == "unstable"
          && (__match ".*llvm" compiler-nix-name == null)
          && !builtins.elem compiler-nix-name ["ghc967" "ghc984" "ghc9103"]
          && system != "x86_64-darwin") {
        inherit (lib.systems.examples) wasi32;
      } // lib.optionalAttrs (nixpkgsName == "unstable"
          && (__match ".*llvm" compiler-nix-name == null)
          && ((system == "x86_64-linux"  && !builtins.elem compiler-nix-name ["ghc902" "ghc928"])
           || (system == "x86_64-darwin" && builtins.elem compiler-nix-name []))) { # TODO add ghc versions when we have more darwin build capacity
        inherit (lib.systems.examples) mingwW64;
      } // lib.optionalAttrs (nixpkgsName == "unstable"
          && (__match ".*llvm" compiler-nix-name == null)
          && ((system == "x86_64-linux"  && !builtins.elem compiler-nix-name ["ghc8107" "ghc902" "ghc928" "ghc948"])
           || (system == "x86_64-darwin" && builtins.elem compiler-nix-name []))) { # TODO add ghc versions when we have more darwin build capacity
        inherit (lib.systems.examples) ucrt64;
      } // lib.optionalAttrs (system == "x86_64-linux" && nixpkgsName == "unstable" && !builtins.elem compiler-nix-name ["ghc902" "ghc928" "ghc948"]) {
        # Musl cross only works on linux
        # aarch64 cross only works on linux
        inherit (lib.systems.examples) musl64 aarch64-multiplatform;
      } // lib.optionalAttrs (__match ".*llvm" compiler-nix-name == null && system == "x86_64-linux" && nixpkgsName == "unstable" && !builtins.elem compiler-nix-name ["ghc902" "ghc928" "ghc948"]) {
        # Out llvm versions of GHC seem to break for musl32
        inherit (lib.systems.examples) musl32;
      } // lib.optionalAttrs (system == "x86_64-linux"
          && nixpkgsName == "unstable"
          && !builtins.elem compiler-nix-name ["ghc967" "ghc984" "ghc9103"]) {
        inherit (lib.systems.examples) aarch64-android-prebuilt;
        inherit (lib.systems.examples) armv7a-android-prebuilt;
      } // lib.optionalAttrs (system == "x86_64-linux" && nixpkgsName == "unstable" && !builtins.elem compiler-nix-name ["ghc8107" "ghc902"]) {
        # TODO fix this for the compilers we build with hadrian (ghc >=9.4)
        inherit (lib.systems.examples) aarch64-multiplatform-musl;
      } // lib.optionalAttrs (system == "aarch64-linux" && nixpkgsName == "unstable" && !builtins.elem compiler-nix-name ["ghc8107" "ghc902"]) {
        inherit (lib.systems.examples) aarch64-multiplatform-musl;
      } // lib.optionalAttrs (system == "aarch64-darwin"
          && nixpkgsName == "unstable"
          && builtins.elem compiler-nix-name ["ghc9141" "ghc914-sh"]) {
        # darwin -> linux cross-compilation (compile side only — see the tests
        # gate in the cross section below), with target binaries run under
        # hyper-linux (`hl`) on Apple Silicon via the `hyper-linux` overlay.
        # ghc9141 is the hadrian GHC 9.14; ghc914-sh the stable-haskell
        # cabalProject build.  Both the fully-static aarch64 (`aarch64-
        # multiplatform-musl`) and x86_64 (`musl64`) musl targets cross-compile;
        # note `hl` only *runs* aarch64 ELFs on this M1-class hardware (x86_64
        # guests need Rosetta's M2+ VM), which is why the test run is deferred.
        inherit (lib.systems.examples) aarch64-multiplatform-musl musl64;
      };
  isDisabled = d: d.meta.disabled or false;
in
dimension "Nixpkgs version" nixpkgsVersions (nixpkgsName: pinnedNixpkgsSrc:
  let evalPackages = import pinnedNixpkgsSrc (nixpkgsArgs // { system = evalSystem; });
  in (dimension "GHC version" (compilerNixNames nixpkgsName evalPackages) (compiler-nix-name: {runTests}:
      let pkgs = import pinnedNixpkgsSrc (nixpkgsArgs // { inherit system; });
          build = import ./build.nix { inherit pkgs evalSystem ifdLevel compiler-nix-name haskellNix; };
          platformFilter = platformFilterGeneric pkgs system;
      in filterAttrsOnlyRecursive (_: v: platformFilter v && !(isDisabled v)) ({
        # Native builds
        # TODO: can we merge this into the general case by picking an appropriate "cross system" to mean native?
        native = pkgs.lib.recurseIntoAttrs ({
          roots = pkgs.haskell-nix.roots' { inherit compiler-nix-name evalSystem; } ifdLevel;
        } // pkgs.lib.optionalAttrs runTests {
          inherit (build) tests tools maintainer-scripts maintainer-script-cache;
        } // pkgs.lib.optionalAttrs (ifdLevel >= 3) rec {
          hello = (pkgs.haskell-nix.hackage-package ({ name = "hello"; version = "1.0.0.2"; inherit evalSystem compiler-nix-name; }
            // lib.optionalAttrs (builtins.compareVersions pkgs.buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.13" >= 0) {
              shell.tools.hoogle.cabalProjectLocal = ''
                -- The following `allow-newer` are needed for
                -- constraints: hoogle >=5.0.18.4, tls ==2.0.6, warp-tls <3.4.10, aeson >=2.2.3.0
                allow-newer:
                  aeson:template-haskell,
                  aeson:containers,
                  aeson:time,
                  base64:base,
                  cborg:base,
                  cborg:containers,
                  indexed-traversable:base,
                  indexed-traversable:containers,
                  indexed-traversable-instances:base,
                  semialign:base,
                  semialign:containers,
                  serialise:base,
                  serialise:containers,
                  these:base,
                  time-compat:base,
                  uuid-types:template-haskell
              '';
          })).getComponent "exe:hello";
          # Make sure the default shell tools (hoogle) are built
          simple-shell = (hello.project.flake {}).devShells.default;
        });
      }
      //
      dimension "Cross system" (crossSystems nixpkgsName evalPackages compiler-nix-name) (crossSystemName: crossSystem:
        let pkgs =
              if builtins.isAttrs crossSystem
                then import pinnedNixpkgsSrc (nixpkgsArgs // { inherit system crossSystem; })
                else crossSystem (import pinnedNixpkgsSrc (nixpkgsArgs // { inherit system; }));
            build = import ./build.nix { inherit pkgs evalSystem ifdLevel compiler-nix-name haskellNix; };
            # darwin -> linux cross runs target binaries under hyper-linux
            # (`hl`).  Keep the tests suppressed on unqualified routes because
            # running the target's Template Haskell iserv interpreter has hit
            # an `hl` SIGBUS under the nix-daemon.  The ghc914-sh AArch64-musl
            # route below has a focused runtime qualification for annotations
            # and th-dlls; all other Darwin -> Linux routes still build only
            # the compile side here.
            isDarwinLinuxCross =
              pkgs.stdenv.buildPlatform.isDarwin && pkgs.stdenv.hostPlatform.isLinux;
            qualifiedDarwinLinuxCross =
              compiler-nix-name == "ghc914-sh"
              && pkgs.stdenv.buildPlatform.isDarwin
              && pkgs.stdenv.buildPlatform.isAarch64
              && pkgs.stdenv.hostPlatform.isAarch64
              && pkgs.stdenv.hostPlatform.isMusl;
            qualifiedDarwinLinuxTests = {
              annotations = pkgs.lib.filterAttrs
                (name: _: builtins.elem name [ "meta" "ifdInputs" "build" "build-profiled" ])
                build.tests.annotations;
              th-dlls = pkgs.lib.filterAttrs
                (name: _: builtins.elem name [ "meta" "ifdInputs" "build" ])
                build.tests.th-dlls;
            };
        in pkgs.lib.recurseIntoAttrs (pkgs.lib.optionalAttrs (ifdLevel >= 1) ({
            roots = pkgs.haskell-nix.roots' { inherit compiler-nix-name evalSystem; } ifdLevel // {
              ghc = pkgs.buildPackages.haskell-nix.compiler.${compiler-nix-name}.evalWith.${evalSystem}
                or (pkgs.buildPackages.haskell-nix.compiler.${compiler-nix-name}.override { evalSystem = evalSystem; });
            };
            # TODO: look into cross compiling ghc itself
            # ghc = pkgs.haskell-nix.compiler.${compiler-nix-name};
            # TODO: look into making tools work when cross compiling
            # inherit (build) tools;
          } // pkgs.lib.optionalAttrs (runTests && (!isDarwinLinuxCross || qualifiedDarwinLinuxCross)) {
            tests = if isDarwinLinuxCross
              then qualifiedDarwinLinuxTests
              else build.tests;
        })
        # GHCJS builds its own template haskell runner.
        // pkgs.lib.optionalAttrs (ifdLevel >= 2 && !builtins.elem crossSystemName ["ghcjs" "wasi32"])
            pkgs.haskell-nix.iserv-proxy-exes.${compiler-nix-name}
        // pkgs.lib.optionalAttrs (ifdLevel >= 3) {
          hello = (pkgs.haskell-nix.hackage-package { name = "hello"; version = "1.0.0.2"; inherit evalSystem compiler-nix-name; }).getComponent "exe:hello";
        })
      ))
    ))
    # Run once (unstable, x86_64-linux): make sure the getting-started flake
    # template stays in sync with `hix init` — see issue #2518.
    // lib.optionalAttrs (nixpkgsName == "unstable" && system == "x86_64-linux") {
      template-matches-hix-init = import ./test/template-matches-hix-init.nix {
        pkgs = import pinnedNixpkgsSrc (nixpkgsArgs // { inherit system; });
      };
    }
  )
