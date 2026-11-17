pkgs: let baseurl = "https://github.com/ican-group/haskell.nix/releases/download/nix-tools-0.4.6/"; in {
  aarch64-darwin = pkgs.fetchurl { 
     name = "aarch64-darwin-nix-tools-static";
     url = "${baseurl}aarch64-darwin-nix-tools-static.zip";
     sha256 = "sha256-qV9sDrAmmpO96qMg/BDZTz7PCxY62vzoDxd8tY6XI9E=";
  };
  x86_64-darwin = pkgs.fetchurl { 
     name = "x86_64-darwin-nix-tools-static";
     url = "${baseurl}x86_64-darwin-nix-tools-static.zip";
     sha256 = "sha256-Zh+cxBN4Y/5jQqyxsZmmA/nStvkb+lJeS2eFzBMpW7o=";
  };
  aarch64-linux = pkgs.fetchurl { 
     name = "aarch64-linux-nix-tools-static";
     url = "${baseurl}aarch64-linux-nix-tools-static.zip";
     sha256 = "sha256-2tdxmNUpExnK7vGrrpDxqDQY0XIqfTUSypLUa7tK7RE=";
  };
  x86_64-linux = pkgs.fetchurl { 
     name = "x86_64-linux-nix-tools-static";
     url = "${baseurl}x86_64-linux-nix-tools-static.zip";
     sha256 = "sha256-WiWFpXTvLlooQOu/BeTvGUwJcsfToHmjKIj4pSQ1Rk0=";
  };
}
