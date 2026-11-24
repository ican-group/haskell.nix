{
  description = "Lazy Input for Haskell.nix";

  inputs = {
    # Only the `flake-parts` test uses it (haskell.nix's flake module does
    # not need flake-parts itself; the flake that imports the module has it).
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs: inputs;
}
