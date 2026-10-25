inputs: pkgs:

let

  makeZippedTools = { customPkgs, clearStripDebugFlags ? false }: 
    let 
      hsPkgs = (import ./project.nix inputs customPkgs).hsPkgs;
      
      maybeClearStripDebugFlags = drv: 
        if clearStripDebugFlags then 
          drv.overrideDerivation (_: { stripDebugFlags = []; })
        else 
          drv;

      getNixToolsExe = name: hsPkgs.nix-tools.components.exes.${name};
      getStrippedNixToolsExe = name: maybeClearStripDebugFlags (getNixToolsExe name);

      strippedNixToolsComponents = map getStrippedNixToolsExe [
        "cabal-name" 
        "cabal-to-nix" 
        "default-setup"
        "default-setup-ghcjs"
        "hackage-to-nix" 
        "hashes-to-nix" 
        "lts-to-nix" 
        "make-install-plan" 
        "plan-to-nix" 
        "stack-repos" 
        "stack-to-nix" 
        "truncate-index" 
      ];
    in 
      customPkgs.packaging.asZip {
        name = "${customPkgs.stdenv.hostPlatform.system}-nix-tools-static";
        drvs' = [ 
          hsPkgs.cabal-install.components.exes.cabal 
          hsPkgs.hpack.components.exes.hpack 
          hsPkgs.Cabal-syntax-json.components.exes.cabal2json 
        ] ++ strippedNixToolsComponents;
      };

  # There used to be a `*-no-ifd` variant of each zip here: a `runCommand` with
  # `requiredSystemFeatures = [ "recursive-nix" ]` that re-entered nix to build
  # the same fragment with `--no-allow-import-from-derivation`, meaning to prove
  # the static tools need no IFD.  It never proved that.  A flake's `nixConfig`
  # overrides the command line, and nix-tools/flake.nix sets
  # `allow-import-from-derivation = "true"`, so the flag was ignored -- the build
  # logs show plan-to-nix running inside it (ci.zw3rk.com/build/1811419).  The
  # nested build also resolved to the same derivation as the plain job above
  # (flake.nix loads ./nix-tools through its own lock, exactly as `${../.}` did),
  # so all it added was a second realisation and a copy.
  #
  # What it did cost was real: recursive-nix is unsupported by nix's external
  # derivation builders, and when it did get scheduled somewhere it could run,
  # nothing substituted, so darwin rebuilt ~470 derivations from source and hit
  # the 7200s timeout.
  #
  # Reinstating the check means removing that `nixConfig` line and running the
  # build at the top level -- no nesting, hence no recursive-nix.  Note it will
  # fail until ./project.nix is materialized: the static project genuinely does
  # use IFD today.

  zippedToolsForDarwin = makeZippedTools {
    customPkgs = pkgs;
    clearStripDebugFlags = true;
  };


  zippedToolsForLinux = makeZippedTools {
    customPkgs = pkgs.pkgsCross.musl64;
  };


  zippedToolsForLinuxArm64 = makeZippedTools {
    customPkgs = pkgs.pkgsCross.aarch64-multiplatform-musl;
  };


  allZippedTools = 
    pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-darwin" || pkgs.stdenv.hostPlatform.system == "aarch64-darwin") {
      "nix-tools-static" = zippedToolsForDarwin;
    }
    //
    pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
      "nix-tools-static" = zippedToolsForLinux;
      "nix-tools-static-arm64" = zippedToolsForLinuxArm64;
    };

in


allZippedTools

 
