# The `gitExtraDepsLocal` stack project option (#462): packages from the
# stack.yaml's git `extra-deps` become local (`isLocal`, not `isProject`),
# like a cabal.project `source-repository-package`; git packages from a
# custom snapshot do not.  Without the option nothing changes.
{ lib, stdenv, stackProject', mkGitExtraDepsLocalModule, testSrc, compiler-nix-name, evalSystem, haskellLib, ... }:

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
  # A git extra-dep (cabal-simple) and, from a custom snapshot, another git
  # package (cabal-sublib) from the same repository and commit but a
  # different subdir.  Only the extra-dep may become local.  The second
  # quotes the resolver and follows it with a comment.
  mixed = stackYaml: stackProject' {
    inherit src evalSystem sha256map stackYaml;
    gitExtraDepsLocal = true;
  };
  mixedPlain = mixed "stack-mixed.yaml";
  mixedQuoted = mixed "stack-mixed-quoted.yaml";

  flags = p: { inherit (p.hsPkgs.cabal-simple) isLocal isProject; };
  locals = p: lib.attrNames (haskellLib.selectLocalPackages p.hsPkgs);
  check = name: got: want:
    lib.assertMsg (got == want)
      "stack-git-extra-deps-local: ${name}: expected ${builtins.toJSON want}, got ${builtins.toJSON got}";

  # The matching itself, without fetching anything: `foo` is an extra-dep
  # spelled without `.git` in the stack.yaml; `baz` is from the same
  # repository and commit as the extra-dep `bar` but another subdir; and a
  # later (snapshot) entry also named `bar` provides `bar`'s source, so `bar`
  # is not local either.
  matched = lib.attrNames (mkGitExtraDepsLocalModule {
    cache = [
      { name = "foo"; url = "https://github.com/o/foo.git"; rev = "r1"; subdir = "."; }
      { name = "bar"; url = "https://github.com/o/r"; rev = "r2"; subdir = "a"; }
      { name = "baz"; url = "https://github.com/o/r"; rev = "r2"; subdir = "b"; }
      { name = "bar"; url = "https://github.com/o/other"; rev = "r3"; }
    ];
    extraDeps = [
      { url = "https://github.com/o/foo"; rev = "r1"; subdir = "."; }
      { url = "https://github.com/o/r.git"; rev = "r2"; subdir = "a"; }
    ];
  }).packages;

in lib.recurseIntoAttrs {
  meta.disabled = compiler-nix-name != "ghc984" || stdenv.hostPlatform.isGhcjs;
  ifdInputs = {
    default-stack-nix = default.stack-nix;
    enabled-stack-nix = enabled.stack-nix;
    snapshot-stack-nix = snapshot.stack-nix;
    mixed-stack-nix = mixedPlain.stack-nix;
    mixed-quoted-stack-nix = mixedQuoted.stack-nix;
  };
  run =
    assert check "default" (flags default) { isLocal = false; isProject = false; };
    assert check "default locals" (locals default) [];
    assert check "enabled" (flags enabled) { isLocal = true; isProject = false; };
    assert check "enabled locals" (locals enabled) [ "cabal-simple" ];
    assert check "snapshot" (flags snapshot) { isLocal = false; isProject = false; };
    assert check "snapshot locals" (locals snapshot) [];
    assert check "mixed locals" (locals mixedPlain) [ "cabal-simple" ];
    assert check "mixed snapshot package" mixedPlain.hsPkgs.cabal-sublib.isLocal false;
    assert check "mixed quoted locals" (locals mixedQuoted) [ "cabal-simple" ];
    assert check "mixed quoted snapshot package" mixedQuoted.hsPkgs.cabal-sublib.isLocal false;
    assert check "matching" matched [ "foo" ];
    stdenv.mkDerivation {
      name = "stack-git-extra-deps-local";
      buildCommand = "touch $out";
    };
}
