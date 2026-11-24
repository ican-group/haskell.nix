{ pkgs
, ghcjsSrcJson ? ./ghcjs-src.json
, ghcjsSrc ? pkgs.buildPackages.fetchgit (builtins.fromJSON (builtins.readFile ghcjsSrcJson))
, ghcjsVersion ? "8.6.0.0.10"
, ghcVersion ? "8.6.5"
, compiler-nix-name ? if builtins.compareVersions ghcjsVersion "8.8.0.0" > 0
  then "ghc884"
  else "ghc865"
, ghc ? pkgs.buildPackages.ghc
}:
let
    isGhcjs88 = builtins.compareVersions ghcjsVersion "8.8.0.0" >= 0;
    isGhcjs810 = builtins.compareVersions ghcjsVersion "8.10.0.0" >= 0;

    project = pkgs.buildPackages.haskell-nix.ghcjsProject {
        src = ghcjsSrc;
        inherit ghcjsVersion compiler-nix-name;
        index-state = "2020-04-25T00:00:00Z";
#        plan-sha256 = "1wy2lr08maxyi7r8jiwf2gj6pdayk5vxxwh42bj4s2gg4035z0yc";
#        materialized = ../../materialized/ghcjs;
    };

    inherit (project.hsPkgs) ghcjs;

    all-ghcjs = pkgs.buildPackages.symlinkJoin {
        name = "ghcjs-${ghcjsVersion}-symlinked";
        paths = [
            (ghcjs.getComponent "exe:ghcjs-boot")
        ] ++ (if isGhcjs88
          then [
            (ghcjs.getComponent "exe:ghcjs")
            (ghcjs.getComponent "exe:ghcjs-pkg")
            (ghcjs.getComponent "exe:private-ghcjs-hsc2hs")
            (ghcjs.getComponent "exe:haddock")
            (ghcjs.getComponent "exe:ghcjs-dumparchive")
            (ghcjs.getComponent "exe:private-ghcjs-run")
            (ghcjs.getComponent "exe:private-ghcjs-unlit")
          ]
          else [
            (ghcjs.getComponent "exe:private-ghcjs-ghcjs")
            (ghcjs.getComponent "exe:private-ghcjs-ghcjs-pkg")
            (ghcjs.getComponent "exe:private-ghcjs-run")
            (ghcjs.getComponent "exe:private-ghcjs-unlit")
            (ghcjs.getComponent "exe:private-ghcjs-hsc2hs")
            (ghcjs.getComponent "exe:private-ghcjs-haddock")
            (ghcjs.getComponent "exe:private-ghcjs-ghcjs-dumparchive")
          ]);
    };
    libexec = "libexec/${builtins.replaceStrings ["darwin" "i686"] ["osx" "i386"] pkgs.stdenv.buildPlatform.system}-${ghc.name}/ghcjs-${ghcVersion}";
    booted-ghcjs = pkgs.stdenv.mkDerivation {
      name = "ghcjs-${ghcVersion}";
      src = project.configured-src;

      nativeBuildInputs = project.bootInputs
       ++ pkgs.lib.optional isGhcjs88 pkgs.buildPackages.procps;
      passthru = {
        inherit all-ghcjs bundled-ghcjs project;
        configured-src = project.configured-src + "/ghc";
        # Used to detect non haskell-nix compilers (accidental use of nixpkgs compilers can lead to unexpected errors)
        isHaskellNixCompiler = true;
      } // ghcjs.components.exes;
      dontUpdateAutotoolsGnuConfigScripts = true;
      dontConfigure = true;
      dontInstall = true;
      buildPhase = ''
        export HOME=$TMP
        export EM_CACHE=$(mktemp -d)
        mkdir $HOME/.cabal
        touch $HOME/.cabal/config
        cd lib/boot
        ${if isGhcjs88
          then ''
            mkdir -p $out/bin
            mkdir -p $out/lib
            lndir ${all-ghcjs}/bin $out/bin
            chmod -R +w $out/bin
            rm $out/bin/ghcjs-boot
            cp ${ghcjs.getComponent "exe:ghcjs-boot"}/bin/ghcjs-boot $out/bin
            rm $out/bin/haddock
            cp ${ghcjs.getComponent "exe:haddock"}/bin/haddock $out/bin

            wrapProgram $out/bin/ghcjs --add-flags "-B$out/lib"
            wrapProgram $out/bin/haddock --add-flags "-B$out/lib"
            wrapProgram $out/bin/ghcjs-pkg --add-flags "--global-package-db=$out/lib/package.conf.d"
          ''
          else ''
            mkdir -p $out
            lndir ${all-ghcjs} $out
            mkdir -p $out/lib/ghcjs-${ghcVersion}
            rm $out/bin/ghcjs-boot
            cp ${ghcjs.getComponent "exe:ghcjs-boot"}/bin/ghcjs-boot $out/bin
            wrapProgram $out/bin/ghcjs-boot --set ghcjs_libexecdir $out/bin
            mv $out/${libexec}/* $out/bin

            wrapProgram $out/bin/private-ghcjs-ghcjs --add-flags "-B$out/lib"
            wrapProgram $out/bin/private-ghcjs-haddock --add-flags "-B$out/lib"
            wrapProgram $out/bin/private-ghcjs-ghcjs-pkg --add-flags "--global-package-db=$out/lib/package.conf.d"
          ''
        }
        # Avoid timeouts while unix package runs hsc2hs (it does not print anything
        # for more than 900 seconds).
        {
        for n in {1..50}; do
          if [ ! -f $TMP/done ]; then
            sleep 300
            echo Keep alive $n
          fi
        done
        } &
        ${
          # Unsets NIX_CFLAGS_COMPILE so the osx version of iconv.h is not used by mistake
          if isGhcjs810 then ''
            env -u NIX_CFLAGS_COMPILE PATH=$out/bin:$PATH \
              $out/bin/ghcjs-boot --with-emsdk=${project.emsdk} --no-haddock \
              || (echo failed > $TMP/done; false)
            ''
          else if isGhcjs88 then ''
            env -u NIX_CFLAGS_COMPILE PATH=$out/bin:$PATH \
              $out/bin/ghcjs-boot -j1 --with-emsdk=${project.emsdk} --no-prof --no-haddock \
              || (echo failed > $TMP/done; false)
            ''
          else ''
            env -u NIX_CFLAGS_COMPILE PATH=$out/bin:$PATH \
              $out/bin/ghcjs-boot -j1 --with-ghcjs-libdir=$out --with-emsdk=${project.emsdk} \
              || (echo failed > $TMP/done; false)
          ''
        }
        echo ok > $TMP/done
      '';
      # We hard code -j1 as a temporary workaround for
      # https://github.com/ghcjs/ghcjs/issues/654
      # enableParallelBuilding = true;
    };
    ghcjs-relocatable-bin = pkgs.stdenv.mkDerivation {
        name = "ghcjs-relocatable-bin-${ghcVersion}";
        src = all-ghcjs;
        dontConfigure = true;
        dontInstall = true;
        dontPatchShebangs = true;
        dontPatchELF = true;
        buildPhase = ''
            # Copy the ghcjs executables
            mkdir -p $out/bin
            cp $src/${libexec}/* $out/bin

            # Add readlink (needed by bundleRootDir)
            cp ${pkgs.coreutils}/bin/readlink $out/bin

          '' + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # Make the executables location independent using install_name_tool and @executable_path

            # Copy the libraries needed into place
            cp ${pkgs.gmp}/lib/libgmp.10.dylib $out/bin
            cp ${pkgs.ncurses}/lib/libncursesw.6.dylib $out/bin
            cp ${pkgs.libffi}/lib/libffi.6.dylib $out/bin

            # Set the ID of the libraries
            chmod -R +w $out/bin
            install_name_tool -id "@executable_path/libgmp.10.dylib" "$out/bin/libgmp.10.dylib"
            install_name_tool -id "@executable_path/libncursesw.6.dylib" "$out/bin/libncursesw.6.dylib"
            install_name_tool -id "@executable_path/libffi.6.dylib" "$out/bin/libffi.6.dylib"

            # Modify all the references so we look for the libraries in the system location or
            # @executable_path (the directory containing the exetubable itself).
            for fn in $out/bin/*; do
              install_name_tool -change "${pkgs.libiconv}/lib/libiconv.dylib" /usr/lib/libiconv.dylib "$fn"
              install_name_tool -change "${pkgs.stdenv.libc}/lib/libSystem.B.dylib" /usr/lib/libSystem.B.dylib "$fn"
              install_name_tool -change "${pkgs.gmp}/lib/libgmp.10.dylib" "@executable_path/libgmp.10.dylib" "$fn"
              install_name_tool -change "${pkgs.ncurses}/lib/libncursesw.6.dylib" "@executable_path/libncursesw.6.dylib" "$fn"
              install_name_tool -change "${pkgs.libffi}/lib/libffi.6.dylib" "@executable_path/libffi.6.dylib" "$fn"
            done
          '')

          + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            # Make the executables location independent using patchelf and $ORIGIN.
            chmod -R +w $out/bin
            # This interpreter setting will not work on nixOS, but this bundle is
            # not really needed on nixOS systems.
            patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 $out/bin/*
            patchelf --set-rpath '$ORIGIN' $out/bin/*
            # Link the libraries needed into place
            ln -s ${pkgs.gmp}/lib/libgmp.so.* $out/bin
            ln -s ${pkgs.ncurses}/lib/libncursesw.so.* $out/bin
            ln -s ${pkgs.libffi}/lib/libffi.so.* $out/bin
          '');
    };
    # This is a way to find the location of the root directory of this bundle
    # when one of the wrapper scripts runs.  By using readlink (to avoid
    # issues with symlinks that might be made to the script) and dirname
    # we can find the directory even when it may have been moved.
    bundleRootDir = ''"$(dirname "$(dirname "$(readlink -f "$0")")")"'';
    bundled-ghcjs = {
        compilerName ? "ghcjs", # Name for the compiler wrapper
        db ? null,    # A ghcjs package database this argument should can
                      # be `project.(shellFor { ... }).configFiles` or
                      # the result of a `makeConfigFiles` call.
        hostDb ? null # Like db, but this will be passed as the `-host-package-db`.
      }:
      let
        libDeps = pkgs.lib.concatMapStrings (lib: "${lib} ") (pkgs.lib.unique (
                 [booted-ghcjs ghc db hostDb pkgs.ncurses pkgs.gmp pkgs.libffi]
              ++ (pkgs.haskell-nix.haskellLib.flatLibDepends db.component)
              ++ (pkgs.haskell-nix.haskellLib.flatLibDepends hostDb.component)
              ));    
      in pkgs.stdenv.mkDerivation {
        name = "${compilerName}-${ghcVersion}-bundle";
        src = booted-ghcjs;
        nativeBuildInputs = [ pkgs.makeWrapper (pkgs.lndir or pkgs.xorg.lndir) ];
        dontConfigure = true;
        dontInstall = true;
        dontPatchShebangs = true;
        dontPatchELF = true;
        buildPhase = ''
            # Copy the ghcjs executables
            mkdir -p $out/bin
            lndir ${ghcjs-relocatable-bin}/bin $out/bin

            # Make the executables writeable for patchelf and install_name_tool
            chmod -R +w $out/bin

            # And links for the /lib directory of all the dependencies
            # including the booted ghcjs
            for lib in ${ libDeps }; do
              if [ -d $lib/lib ]; then
                mkdir -p $out/$(basename $lib)
                lndir -silent $lib $out/$(basename $lib)
              fi
            done

          '' + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            rm -rf $out/$(basename ${hostDb})/lib/links
            cp -rL ${hostDb}/lib/links $out/$(basename ${hostDb})/lib
            chmod -R +w $out/$(basename ${hostDb})/lib/links

            # Modify all the references so we look for the libraries in the system location or
            # @executable_path (the directory containing the exetubable itself).
            for fn in $out/$(basename ${hostDb})/lib/links/*; do
              install_name_tool -change "${pkgs.libiconv}/lib/libiconv.dylib" /usr/lib/libiconv.dylib "$fn"
              install_name_tool -change "${pkgs.stdenv.libc}/lib/libSystem.B.dylib" /usr/lib/libSystem.B.dylib "$fn"
              install_name_tool -change "${pkgs.gmp}/lib/libgmp.10.dylib" "@executable_path/libgmp.10.dylib" "$fn"
              install_name_tool -change "${pkgs.ncurses}/lib/libncursesw.6.dylib" "@executable_path/libncursesw.6.dylib" "$fn"
              install_name_tool -change "${pkgs.libffi}/lib/libffi.6.dylib" "@executable_path/libffi.6.dylib" "$fn"
            done
          '') + ''

            # Wrap the programs to add the ghcjs library dir and package DB directories
            wrapProgram $out/bin/ghcjs \
              --add-flags '"-B${bundleRootDir}/$(basename ${booted-ghcjs})/lib/ghcjs-${ghcVersion}"' \
              --add-flags '"-package-db ${db}/${db.packageCfgDir}"' ${
                pkgs.lib.optionalString (hostDb != null)
                  " --add-flags '-host-package-db=${hostDb}/${hostDb.packageCfgDir}'"
              }
            wrapProgram $out/bin/ghcjs-pkg --add-flags '"--global-package-db=${db}/${db.packageCfgDir}"'
            wrapProgram $out/bin/haddock-ghcjs --add-flags '"-B${bundleRootDir}/$(basename ${booted-ghcjs})/lib/ghcjs-${ghcVersion}"'

            # Fix the bang pattern to use the systems bash.
            # Replace the absolute output path ($out) with bundleRootDir
            # (this will fix the references to the unwarpped executables).
            # Replace the `/nix/store` refs (in the package DB paths) with
            # bundleRootDir.
            sed -i \
              -e 's|${pkgs.stdenv.shell}|/usr/bin/env -S bash|' \
              -e "s|$out/|"'${bundleRootDir}/|g' \
              -e 's|/nix/store/|${bundleRootDir}/|g' \
              $out/bin/ghcjs $out/bin/haddock-ghcjs $out/bin/ghcjs-pkg

            # Update the ghcjs and ghc settings files so that `cc` looked up in the PATH.
            rm $out/$(basename ${booted-ghcjs})/lib/ghcjs-${ghcVersion}/settings
            sed -e 's|/nix/store/.*/bin/cc|cc|' \
             < ${booted-ghcjs}/lib/ghcjs-${ghcVersion}/settings \
             > $out/$(basename ${booted-ghcjs})/lib/ghcjs-${ghcVersion}/settings
            rm $out/$(basename ${ghc})/lib/ghc-${ghcVersion}/settings
            sed -e 's|/nix/store/.*/bin/cc|cc|' \
             < ${ghc}/lib/ghc-${ghcVersion}/settings \
             > $out/$(basename ${ghc})/lib/ghc-${ghcVersion}/settings

            # Update the ghcjs settings files so that `node` looked up in the PATH.
            rm $out/$(basename ${booted-ghcjs})/lib/ghcjs-${ghcVersion}/nodeSettings.json
            sed -e 's|/nix/store/.*/bin/node|node|' \
             < ${booted-ghcjs}/lib/ghcjs-${ghcVersion}/nodeSettings.json \
             > $out/$(basename ${booted-ghcjs})/lib/ghcjs-${ghcVersion}/nodeSettings.json

            # Update the ghcjs settings files so that `node` looked up in the PATH.
            rm $out/$(basename ${booted-ghcjs})/lib/ghcjs-${ghcVersion}/ghc_libdir
            sed -e 's|/nix/store/|../../../|' \
             < ${booted-ghcjs}/lib/ghcjs-${ghcVersion}/ghc_libdir \
             > $out/$(basename ${booted-ghcjs})/lib/ghcjs-${ghcVersion}/ghc_libdir
          '' + (pkgs.lib.optionalString (compilerName != "ghcjs") ''
            # Rename the wrappers based on the `compilerName` arg
            mv $out/bin/ghcjs         $out/bin/${compilerName}
            mv $out/bin/ghcjs-pkg     $out/bin/${compilerName}-pkg
            mv $out/bin/haddock-ghcjs $out/bin/haddock-${compilerName}
          '');
      };
in booted-ghcjs
