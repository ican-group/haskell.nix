{ stdenv, lib, testSrc, haskell-nix, buildPackages, compiler-nix-name, evalPackages, evalSystem }:
let
  project = buildPackages.haskell-nix.project' {
    inherit compiler-nix-name evalSystem;
    src = buildPackages.fetchgit {
      url = "https://github.com/haskell/haskell-language-server.git";
      fetchSubmodules = true;
      rev = "32cd57df639d67ac0cf29882839e00532fd30c84";
      sha256 = "sha256-tMKVUn0/vk4z4pKz1pMK5lDA630/dDBieQsJ21mGJFQ=";
    };
    projectFileName = "stack-${buildPackages.haskell-nix.compiler.${compiler-nix-name}.version}.yaml";
    sha256map = {
      "https://github.com/alanz/ghc-exactprint.git"."6748e24da18a6cea985d20cc3e1e7920cb743795" = "18r41290xnlizgdwkvz16s7v8k2znc7h215sb1snw6ga8lbv60rb";
      "https://github.com/bubba/brittany.git"."c59655f10d5ad295c2481537fc8abf0a297d9d1c" = "1rkk09f8750qykrmkqfqbh44dbx1p8aq1caznxxlw8zqfvx39cxl";
      "https://github.com/hsyl20/ghc-api-compat.git"."8fee87eac97a538dbe81ff1ab18cff10f2f9fa15" = "sha256-byehvdxQxhNk5ZQUXeFHjAZpAze4Ct9261ro4c5acZk=";
    };
  };
in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (project) stack-nix;
  };
  build = project.hsPkgs.haskell-language-server.components.exes.haskell-language-server;

  # Haskell Language Server does not build for GHC 9 or 8.10.7 yet
  meta.disabled = !__elem compiler-nix-name ["ghc865" "ghc884"];
}
