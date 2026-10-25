{ lib, config, pkgs, ... }:

let
  # hackage looks like the following:
  # { "package-name" =
  #   { "a.b.c.d" =
  #     rec { sha256 = $pkgVersionSha256;
  #           revisions =
  #           { r0 = { nix = import ../hackage/...; revNum = 0; sha256 = $revisionSha256; };
  #             default = revisions.r0; };
  #         };
  #     };
  #   };
  # }


  # However it's more convenient to deal with the leaf nodes, and as such
  # push the `sha256` of the package/version into the revision and keep the
  # revision.sha256 as revisionSha256; as well as making the revision content
  # addressable by it's revision hash.
  #
  # Thus we transform hackage into hackageConfigs, which will look like:
  # { "package-name" =
  #   { "a.b.c.d" =
  #     rec { sha256 = $packageVersionSha256;
  #           revisions =
  #           { r0 = { nix = import ../hackage/...;
  #                    sha256 = $packageVersionSha256;
  #                    revision = $revNum;
  #                    revisionSha256 = $revisionSha256;
  #                    package-description-override = ... optional revised cabal file from hackage ...; };
  #             default = revisions.r0;
  #             $revisionSha256 = revisions.r0; };
  #         };
  #     };
  #   };
  # }

  rev2Config =
    { pname, vnum, sha256 }:
    rev:
    { system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }@modArgs:
    let
      package-description-override =
        # we don't need to fetch cabal file revision zero because that's the one included in the source distribution
        if rev.revNum == 0 then null
        else
          builtins.readFile (config.evalPackages.fetchurl (
            {
              name = "${pname}-${vnum}-r${toString rev.revNum}.cabal";
              url = "https://hackage.haskell.org/package/${pname}-${vnum}/revision/${toString rev.revNum}.cabal";
              sha256 = rev.sha256;
              preferLocalBuild = false;
            }));
    in
    {
      inherit sha256;
      inherit package-description-override;
      revision = rev.revNum;
      revisionSha256 = rev.sha256;
    } // (x: (rev.nix or (import rev)) x) modArgs;

  makeContentAddressed = revisions:
    let
      f = revName: acc:
        let rev = revisions.${revName};
        in
        acc // {
          # The original revsion attribute
          ${revName} = rev;
          # The revision keyed by its sha256
          # Note: if there's a collision (e.g. a revision was reverted), pick
          # the one with the smaller revNum. They're identical, but if the
          # smaller one is r0 then we don't have to download a cabal file.
          ${rev.sha256} =
            if lib.hasAttr rev.sha256 acc && acc.${rev.sha256}.revNum < rev.revNum
            then acc.${rev.sha256}
            else rev;
        };
    in
    lib.foldr f { } (builtins.attrNames revisions);

  hackageConfigs =
    lib.flip lib.mapAttrs config.hackage.db
      (pname: lib.mapAttrs
        (vnum: version: version // {
          revisions =
            lib.mapAttrs
              (_: rev2Config { inherit pname vnum; inherit (version) sha256; })
              (makeContentAddressed version.revisions);
        }));

in
{
  options.ghc.package = lib.mkOption {
    type = lib.types.package;
    # obtain the compiler from the haskell packages.
    # this should allow us to use `config` overrides
    # in the nixpkgs setup, and properly override the
    # complier as needed.
    default =
      let baseGhc = pkgs.buildPackages.haskell-nix.compiler.${config.compiler.nix-name} or (throw ''
            This version of Nixpkgs does not contain GHC ${config.compiler.version}
            (or it is not present at attribute '${config.compiler.nix-name})').
            Either switch to a version of Nixpkgs which does have this version, or use a version
            of GHC which the current version of Nixpkgs contains.
          '');
          evalSystem = config.evalPackages.stdenv.hostPlatform.system;
      in baseGhc.evalWith.${evalSystem} or (baseGhc.override { evalSystem = evalSystem; });
    defaultText = "pkgs.buildPackages.haskell-nix.compiler.\${config.compiler.nix-name}";
  };

  options.hackage.db = lib.mkOption {
    type = lib.types.unspecified; # TODO: Worth type checking with modules? Or does that slow eval too much?
  };
  options.hackage.configs = lib.mkOption {
    type = lib.types.unspecified;
  };
  # Note: we inject rts."1.0" as invalid here. This package can only
  # be built by GHC's build system.  However it may show up in stackage
  # snapshots. As such we just null it out.
  config.hackage.configs = hackageConfigs
    // { rts."1.0".revisions.default = null; };
}
