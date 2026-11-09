final: prev:
let
  isLinuxCross =
       prev.haskell-nix.haskellLib.isCrossHost
    && prev.stdenv.hostPlatform.isLinux
    && (prev.stdenv.hostPlatform.isAarch32
     || prev.stdenv.hostPlatform.isAarch64
     || prev.stdenv.hostPlatform.isi686
        # x86_64-linux is only a cross HOST from a non-x86_64 or non-linux
        # build platform (e.g. aarch64-darwin → musl64 under hyper-linux);
        # x86_64-linux → musl64 is native musl and isCrossHost is false.
     || prev.stdenv.hostPlatform.isx86_64);

in
{
   haskell-nix = prev.haskell-nix // final.lib.optionalAttrs isLinuxCross ({
     templateHaskell = builtins.mapAttrs (_compiler-nix-name: iserv-proxy-exes:
        let mkTH = exes:
          import ./linux-cross.nix ({
          inherit (final.stdenv) hostPlatform buildPlatform;
          inherit (final) stdenv lib;
          inherit (final.pkgsBuildBuild) writeShellScriptBin symlinkJoin runCommand makeWrapper;
          inherit (final.haskell-nix) haskellLib;
          qemu = import ./qemu-linux-user.nix {
            qemu = final.pkgsBuildBuild.qemu;
            inherit (final) lib;
            inherit (final.stdenv) hostPlatform;
            buildPlatform = final.pkgsBuildBuild.stdenv.hostPlatform;
            qemuSuffix = final.haskell-nix.haskellLib.qemuByHostPlatform final.stdenv.hostPlatform;
          };
          inherit (final) gmp;
          inherit (exes) iserv-proxy iserv-proxy-interpreter iserv-proxy-interpreter-prof;
        } // final.lib.optionalAttrs final.stdenv.buildPlatform.isDarwin {
          # qemu user-mode emulation does not exist on macOS; run the
          # (static musl) target ELF under hyper-linux instead.
          pipeCommand = "${final.pkgsBuildBuild.hyper-linux or (throw
            ("haskell.nix: Linux cross-compilation on a darwin build host "
            + "needs `hyper-linux` (github:zw3rk/hyper-linux) as a nixpkgs "
            + "overlay attribute to run target binaries for TH and tests"))
          }/bin/hl";
        });
        # Per-eval-system variants mirroring `iserv-proxy-exes.evalWith`:
        # forcing the default variant's exes runs the iserv-proxy
        # plan-to-nix IFD on the pkgsBuildBuild system, so consumers with
        # a different `evalSystem` must select their variant instead.
        in mkTH iserv-proxy-exes // {
          evalWith = builtins.mapAttrs (_evalSystem: mkTH) iserv-proxy-exes.evalWith;
        }) final.haskell-nix.iserv-proxy-exes;
     defaultModules = prev.haskell-nix.defaultModules ++ [
      ({ pkgs, buildModules, config, lib, ... }:
      let
        # This is the pkg-set config (no `evalSystem` option); derive the
        # eval platform from its `evalPackages` instead.
        withTH = final.haskell-nix.templateHaskell.${config.compiler.nix-name}
          .evalWith.${config.evalPackages.stdenv.hostPlatform.system};
      in prev.haskell-nix.haskellLib.addPackageKeys {
        inherit (withTH) configureFlags testWrapper;

        setupBuildFlags = map (opt: "--ghc-option=" + opt) withTH.ghcOptions
            ++ lib.optionals pkgs.stdenv.hostPlatform.isAarch32 (map (opt: "--gcc-option=" + opt) [ "-fno-pic" "-fno-plt" ])
               # Also for GHC #15275
            ++ lib.optionals pkgs.stdenv.hostPlatform.isAarch64 ["--gcc-option=-fPIC"];

        enableShared = lib.mkDefault false;

        doCrossCheck = true;

        packages = {
          # clock 0.7.2 needs to be patched to support cross compilation.
          clock.patches              = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isAarch32 [ ({ version }: (if version == "0.7.2" then ./patches/clock-0.7.2.patch else null)) ];

          # Set all of these to [], as these form the
          # dependency graph of the libiserv, iserv-proxy, and iserv-remote
          # packages.  Subsequently we do not want the defaults that `withTH`
          # `-fexternal-interpreter` would install here.  That would ultimately
          # result in cyclic dependencies as it injects `remote-iserv` and
          # `iserv-proxy` as a dependency into every package.
          bytestring.setupBuildFlags = [];
          containers.setupBuildFlags = [];
          binary.setupBuildFlags = [];
          filepath.setupBuildFlags = [];
          time.setupBuildFlags = [];
          Win32.setupBuildFlags = [];
          libiserv.setupBuildFlags = [];
          remote-iserv.setupBuildFlags = [];
          directory.setupBuildFlags = [];
          ghc-boot.setupBuildFlags = [];
          transformers.setupBuildFlags = [];
          ghci.setupBuildFlags = [];
          network.setupBuildFlags = [];
          unix.setupBuildFlags = [];
        };
      }
      )
     ];
   });
}
