pkgs: let baseurl = "https://github.com/input-output-hk/haskell.nix/releases/download/nix-tools-0.4.5/"; in {
  aarch64-darwin = pkgs.fetchurl { 
     name = "aarch64-darwin-nix-tools-static";
     url = "${baseurl}aarch64-darwin-nix-tools-static.zip";
     sha256 = "sha256-4CNihxEgM15PBxuBkMCb264/0tyciclVesmfVLQsQ/Y=";
  };
  x86_64-darwin = pkgs.fetchurl { 
     name = "x86_64-darwin-nix-tools-static";
     url = "${baseurl}x86_64-darwin-nix-tools-static.zip";
     sha256 = "sha256-cWILZhf7n4BmoE++6yGFTn5sjkgRaITjplVEeF9jYCI=";
  };
  aarch64-linux = pkgs.fetchurl { 
     name = "aarch64-linux-nix-tools-static";
     url = "${baseurl}aarch64-linux-nix-tools-static.zip";
     sha256 = "sha256-Ku+6Kx80GfLFXAbPuj5HWLd9+v1P7jUmt/02XWek7Y4=";
  };
  x86_64-linux = pkgs.fetchurl { 
     name = "x86_64-linux-nix-tools-static";
     url = "${baseurl}x86_64-linux-nix-tools-static.zip";
     sha256 = "sha256-iA1V2XmAKywd/FPJHfrOtb1VpBRqTqanSa+r25g0HLA=";
  };
}
