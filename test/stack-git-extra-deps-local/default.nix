# The `gitExtraDepsLocal` stack project option (#462): packages from the
# stack.yaml's git `extra-deps` become local (`isLocal`, not `isProject`),
# like a cabal.project `source-repository-package`; git packages from a
# custom snapshot do not.  Without the option nothing changes.
{ lib, stdenv, stackProject', testSrc, compiler-nix-name, evalSystem, haskellLib, ... }:

let
  src = testSrc "stack-git-extra-deps-local";
  sha256map = {
    "https://github.com/ican-group/haskell.nix.git"."bc01ebc05a8105035c9449943046b46c8364b932" =
      "003lm3pm024vhbfmii7xcdd9v2rczpflxf7gdl2pyxia7p014i8z";
  };

  # The git extra-dep, option off (the default) and on.
  default = stackProject' { inherit src evalSystem; };
  enabled = stackProject' { inherit src evalSystem; gitExtraDepsLocal = true; };
  # The same git package from a custom snapshot, option on.
  snapshot = stackProject' {
    inherit src evalSystem sha256map;
    stackYaml = "stack-snapshot.yaml";
    gitExtraDepsLocal = true;
  };

  flags = p: { inherit (p.hsPkgs.cabal-simple) isLocal isProject; };
  locals = p: lib.attrNames (haskellLib.selectLocalPackages p.hsPkgs);
  check = name: got: want:
    lib.assertMsg (got == want)
      "stack-git-extra-deps-local: ${name}: expected ${builtins.toJSON want}, got ${builtins.toJSON got}";

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984" || stdenv.hostPlatform.isGhcjs;
  ifdInputs = {
    default-stack-nix = default.stack-nix;
    enabled-stack-nix = enabled.stack-nix;
    snapshot-stack-nix = snapshot.stack-nix;
  };
  run =
    assert check "default" (flags default) { isLocal = false; isProject = false; };
    assert check "default locals" (locals default) [];
    assert check "enabled" (flags enabled) { isLocal = true; isProject = false; };
    assert check "enabled locals" (locals enabled) [ "cabal-simple" ];
    assert check "snapshot" (flags snapshot) { isLocal = false; isProject = false; };
    assert check "snapshot locals" (locals snapshot) [];
    stdenv.mkDerivation {
      name = "stack-git-extra-deps-local";
      buildCommand = "touch $out";
    };
}
