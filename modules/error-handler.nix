{ lib, config, ... }:
{
  options.errorHandler = lib.mkOption {
    internal = true;
    description = ''
      Functions the generated package expressions call to report a missing
      dependency (`buildDepError`, `sysDepError`, ...).
    '';
    type = lib.types.unspecified;
  };

  config.errorHandler = {
    buildDepError = pkg:
      builtins.throw ''
        The Haskell package set does not contain the package: ${pkg} (build dependency).
        If you are using Stackage, make sure that you are using a snapshot that contains the package. Otherwise you may need to update the Hackage snapshot you are using, usually by updating haskell.nix.
      '';
    sysDepError = pkg:
      builtins.throw ''
        The Nixpkgs package set does not contain the package: ${pkg} (system dependency).
        You may need to augment the system package mapping in haskell.nix so that it can be found.
      '';
    pkgConfDepError = pkg:
      builtins.throw ''
        The pkg-conf packages does not contain the package: ${pkg} (pkg-conf dependency).
        You may need to augment the pkg-conf package mapping in haskell.nix so that it can be found.
      '';
    exeDepError = pkg:
      builtins.throw ''
        The local executable components do not include the component: ${pkg} (executable dependency).
      '';
    legacyExeDepError = pkg:
      builtins.throw ''
        The Haskell package set does not contain the package: ${pkg} (executable dependency).
        If you are using Stackage, make sure that you are using a snapshot that contains the package. Otherwise you may need to update the Hackage snapshot you are using, usually by updating haskell.nix.
      '';
    setupDepError = pkg:
      builtins.throw ''
        Neither the Haskell package set or the Nixpkgs package set contain the package: ${pkg} (setup dependency).
        If this is a system dependency:
        You may need to augment the system package mapping in haskell.nix so that it can be found.
        If this is a Haskell dependency:
        If you are using Stackage, make sure that you are using a snapshot that contains the package. Otherwise you may need to update the Hackage snapshot you are using, usually by updating haskell.nix.
      '';
    buildToolDepError = tool:
      builtins.throw ''
        Neither the Haskell package set or the Nixpkgs package set contain the tool: ${tool} (build tool dependency).
        If this is a system dependency:
        You may need to augment the system package mapping in haskell.nix so that it can be found.
        If this is a Haskell dependency:
        If you are using Stackage, make sure that you are using a snapshot that contains the package. Otherwise you may need to update the Hackage snapshot you are using, usually by updating haskell.nix.
      '';
  };
}
