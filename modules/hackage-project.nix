{ lib, config, pkgs, haskellLib, ... }:
let
  inherit (config) name version;
  fullName = name + lib.optionalString (version != "latest") "-${version}";
in {
  _file = "haskell.nix/modules/hackage-project.nix";
  options = {
    version = lib.mkOption {
      type = lib.types.str;
      default = "latest";
      description = ''Version of the hackage package to use (defaults to "latest")'';
    };
  };
  config = {
    src = lib.mkDefault {
      outPath =
        config.evalPackages.runCommand "from-hackage-${fullName}" {} ''
          mkdir $out
          echo "extra-packages: ${fullName}" > $out/cabal.project
          # The stable-haskell cabal fork rejects a project with neither
          # `packages:` nor `optional-packages:` (Cabal-7168).  A hackage tool
          # has no local packages, so give it an `optional-packages:` glob that
          # matches nothing here — it satisfies the check without adding any
          # package (UnitId-neutral).
          echo "optional-packages: ./*" >> $out/cabal.project
        '';
      # Disable git cleanSourceWith filtering
      filterPath = { path, ... }: path;
    };
  };
}
