_super: self:

let 

  asZip = 
    { name ? null
    , drvs'
    }:
    let
      pkgs = self;
      drvs = if builtins.isList drvs' then drvs' else [ drvs' ];
      drv = if builtins.isList drvs then builtins.head drvs else drvs;
      name' = if name == null then drv.pname or drv.name else name;
      targetPlatform = drv.stdenv.targetPlatform;
      nativePackages = self.buildPackages;
      
      interpForSystem = sys:
        let s = {
          "i686-linux" = "/lib/ld-linux.so.2";
          "x86_64-linux" = "/lib64/ld-linux-x86-64.so.2";
          "aarch64-linux" = "/lib/ld-linux-aarch64.so.1";
          "armv7l-linux" = "/lib/ld-linux-armhf.so.3";
          "armv7a-linux" = "/lib/ld-linux-armhf.so.3";
        }; in s.${sys} or (builtins.abort "Unsupported system ${sys}. Supported systems are: ${builtins.concatStringsSep ", " (builtins.attrNames s)}.");
      
      fixup-nix-deps = pkgs.writeShellApplication {
        name = "fixup-nix-deps";
        text = ''
          for nixlib in $(otool -L "$1" |awk '/nix\/store/{ print $1 }'); do
              case "$nixlib" in
              *libiconv.dylib)    install_name_tool -change "$nixlib" /usr/lib/libiconv.dylib   "$1" ;;
              *libiconv.2.dylib)  install_name_tool -change "$nixlib" /usr/lib/libiconv.2.dylib "$1" ;;
              *libffi.*.dylib)    install_name_tool -change "$nixlib" /usr/lib/libffi.dylib     "$1" ;;
              *libc++.*.dylib)    install_name_tool -change "$nixlib" /usr/lib/libc++.dylib     "$1" ;;
              *libc++abi.*.dylib) install_name_tool -change "$nixlib" /usr/lib/libc++abi.dylib  "$1" ;;
              *libz.dylib)        install_name_tool -change "$nixlib" /usr/lib/libz.dylib       "$1" ;;
              *libresolv.*.dylib) install_name_tool -change "$nixlib" /usr/lib/libresolv.dylib  "$1" ;;
              *) ;;
              esac
          done
        '';
      };
    in 
      nativePackages.stdenv.mkDerivation {
        name = "${name'}.zip";
        buildInputs = with nativePackages; [ patchelf zip fixup-nix-deps ];

        phases = [ "buildPhase" "checkPhase" "installPhase" ];

        buildPhase = ''
          mkdir -p ${name'}
          for comp in ${builtins.concatStringsSep " " (map (drv: drv.out) drvs)}; do
              cp $comp/bin/* ${name'}/
          done
        ''
        # set the interpreter to the default expected location on linux. (See interpForSystem above)
        + pkgs.lib.optionalString (targetPlatform.isLinux && targetPlatform.isGnu) ''
          for bin in ${name'}/*; do
          mode=$(stat -c%a $bin)
          chmod +w $bin
          patchelf --set-interpreter ${interpForSystem targetPlatform.system} $bin
          chmod $mode $bin
          done
        '' + pkgs.lib.optionalString (targetPlatform.isWindows) ''
          # may need to copy dlls
        '' + pkgs.lib.optionalString (targetPlatform.isLinux && targetPlatform.isGnu) ''
          # need to copy referenced *.so* files.
        '' + pkgs.lib.optionalString (targetPlatform.isDarwin) ''
          for bin in ${name'}/*; do
          mode=$(stat -c%a $bin)
          chmod +w $bin
          fixup-nix-deps $bin
          chmod $mode $bin
          done
        '';

        doCheck = true;

        checkPhase = pkgs.lib.optionalString (targetPlatform.isLinux && targetPlatform.isGnu) ''
          for bin in ${name'}/*; do
          if ldd $bin |grep nix\/store; then
              echo "ERROR: $bin still depends on nix store"
              exit 1
          fi
          done
        '' + pkgs.lib.optionalString (targetPlatform.isDarwin) ''
          for bin in ${name'}/*; do
          if otool -L $bin |grep nix\/store; then
              echo "ERROR: $bin still depends on nix store"
              exit 1
          fi
          done
        '';

        # compress and put into hydra products
        installPhase = ''
          mkdir -p $out/
          (cd ${name'} && zip -r -9 $out/${name'}.zip *)

          mkdir -p $out/nix-support
          echo "file binary-dist \"$(echo $out/*.zip)\"" \
          > $out/nix-support/hydra-build-products
        '';

        passthru = {
          inherit drv drvs;
          isPackage = true;
          packageName = "${name'}.zip";
        };
      };

in 

  { 
    packaging.asZip = asZip;
  }

