{ pkgs }:
let
  hash = "0z2jc4fibfxz88pfgjq3wk5j3v7sn34xkwb8h60hbwfwhhy63vx6";
  index-state = "2020-01-10T00:00:00Z";
in
pkgs.runCommand "nix-tools-test-truncate-index"
{
  outputHashAlgo = "sha256";
  outputHash = hash;
  buildInputs = [ pkgs.wget ];
} ''
  wget http://hackage.haskell.org/01-index.tar.gz
  ${pkgs.nix-tools}/bin/truncate-index -o $out -i 01-index.tar.gz -s ${index-state}
''
