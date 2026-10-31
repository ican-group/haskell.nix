pkgs: let baseurl = "https://github.com/ican-group/haskell.nix/releases/download/nix-tools-0.3.8/"; in {
  aarch64-darwin = pkgs.fetchurl { 
     name = "aarch64-darwin-nix-tools-static";
     url = "${baseurl}aarch64-darwin-nix-tools-static.zip";
     sha256 = "sha256-v3lxSxCDjQWtCSwx9T5lzcufByvFErKGLm8374KYsOs=";
  };
  x86_64-darwin = pkgs.fetchurl { 
     name = "x86_64-darwin-nix-tools-static";
     url = "${baseurl}x86_64-darwin-nix-tools-static.zip";
     sha256 = "sha256-Ltze09JIiUpMuy+jfoSghejmZ3L4NCpgr32LyX5bckU=";
  };
  aarch64-linux = pkgs.fetchurl { 
     name = "aarch64-linux-nix-tools-static";
     url = "${baseurl}aarch64-linux-nix-tools-static.zip";
     sha256 = "sha256-bpjuragBvzuki4CVleXyqTrQfRJshdoTeD3v6xl9sio=";
  };
  x86_64-linux = pkgs.fetchurl { 
     name = "x86_64-linux-nix-tools-static";
     url = "${baseurl}x86_64-linux-nix-tools-static.zip";
     sha256 = "sha256-aZOmrhp+AdCXcBaNVAeJHDobBaGzJDvEhY90mWjGadc=";
  };
}
