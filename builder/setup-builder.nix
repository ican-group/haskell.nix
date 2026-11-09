{ pkgs, stdenv, lib, buildPackages, haskellLib, ghc, nonReinstallablePkgs, hsPkgs, makeSetupConfigFiles, llvmPackages }@defaults:

let self =
{ component, package, name, src, enableDWARF ? false, flags ? {}, revision ? null, patches ? [], defaultSetupSrc
, preUnpack ? component.preUnpack, postUnpack ? component.postUnpack
, prePatch ? component.prePatch, postPatch ? component.postPatch
, preBuild ? component.preBuild , postBuild ? component.postBuild
, preInstall ? component.preInstall , postInstall ? component.postInstall
, cleanSrc ? haskellLib.cleanCabalComponent package component "setup" src
, nonReinstallablePkgs ? defaults.nonReinstallablePkgs
, smallAddressSpace ? false
}@drvArgs:

let
  ghc = (if enableDWARF then (x: x.dwarf) else (x: x)) (
        (if smallAddressSpace then (x: x.smallAddressSpace) else (x: x)) defaults.ghc);

  cleanSrc' = haskellLib.rootAndSubDir cleanSrc;

  fullName = "${name}-setup";

  configFiles = makeSetupConfigFiles {
    inherit (package) identifier;
    inherit fullName flags component enableDWARF nonReinstallablePkgs;
  };
  hooks = haskellLib.optionalHooks {
    prePatch =
        # If the package is in a sub directory `cd` there first.
        # In some cases the `cleanSrc.subDir` will be empty and the `.cabal`
        # file will be in the root of `src` (`cleanSrc.root`).  This
        # will happen when:
        #   * the .cabal file is in the projects `src.origSrc or src`
        #   * the package src was overridden with a value that does not
        #     include an `origSubDir`
        (lib.optionalString (cleanSrc'.subDir != "") ''
            cd ${lib.removePrefix "/" cleanSrc'.subDir}
          ''
        ) + lib.optionalString (prePatch != null) "\n${prePatch}";

    inherit
      preUnpack postUnpack
      postPatch
      preBuild postBuild
      preInstall postInstall
      ;
  };

  # the build-tools version might be depending on the version of the package, similarly to patches
  executableToolDepends = 
    let inherit (component) pkgconfig build-tools; in
    (lib.concatMap (c: if c.isHaskell or false
      then builtins.attrValues (c.components.exes or {})
      else [c]) 
      (builtins.filter (x: !(isNull x))
      (map 
        (p: if builtins.isFunction p
          then p { inherit  (package.identifier) version; inherit revision; }
          else p) build-tools))) ++
    lib.optional (pkgconfig != []) buildPackages.cabalPkgConfigWrapperReal;

  drv =
    stdenv.mkDerivation ({
      name = "${ghc.targetPrefix}${fullName}";
      src = cleanSrc'.root;
      buildInputs = component.libs
        ++ component.frameworks
        ++ builtins.concatLists component.pkgconfig
        ++ configFiles.libDeps
        ++ [ghc]; # Needs to be a build input so that the boot libraries are included
      nativeBuildInputs = [ghc] ++ executableToolDepends ++ (lib.optional (ghc.useLdLld or false) llvmPackages.bintools);

      passthru = {
        inherit (package) identifier;
        config = component;
        srcSubDir = cleanSrc'.subDir;
        srcSubDirPath = cleanSrc'.root + cleanSrc'.subDir;
        cleanSrc = cleanSrc';
        dwarf = self (drvArgs // { enableDWARF = true; });
        smallAddressSpace = self (drvArgs // { smallAddressSpace = true; });
        exeName = "Setup";
      };

      meta = {
        homepage = package.homepage or "";
        description = package.synopsis or "";
        license = haskellLib.cabalToNixpkgsLicense package.license;
        platforms = if component.platforms == null then lib.platforms.all else component.platforms;
      };

      outputs = ["out" "configFiles"];
      phases = ["unpackPhase" "patchPhase" "buildPhase" "installPhase" "installCheckPhase"];
      buildPhase = ''
        mkdir -p $configFiles
        ${configFiles.script}
        runHook preBuild
        if [[ ! -f ./Setup.hs  && ! -f ./Setup.lhs ]]; then
          cat ${defaultSetupSrc} > Setup.hs
        fi
        for f in Setup.hs Setup.lhs; do
          if [ -f $f ]; then
            echo Compiling package $f
            ghc $f -threaded -package-env $configFiles/ghc-environment --make -o ./Setup
          fi
        done
        [ -f ./Setup ] || (echo Failed to build Setup && exit 1)
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        install ./Setup $out/bin/Setup
        runHook postInstall
      '';
      doInstallCheck = true;
      # Our aarch64-linux build sometimes wind up with files full of 0.
      # This seems similar to an issue we had before that turned out
      # to be low level disk issue in `cp` itself.
      # This check might not prevent it, but may prevent invalid results
      # making it into the store and nic cache (where they can be hard to
      # remove).
      installCheckPhase = ''
        diff ./Setup $out/bin/Setup
      '';
    }
    // lib.optionalAttrs (patches != []) {
      patches = map (p:
        if builtins.isFunction p
          then p { inherit (package.identifier) version; }
          else p) patches;
    }
    // hooks
  );
in drv; in self
