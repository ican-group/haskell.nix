# Resolve real Cabal library names through the system-package map without
# evaluating a compiler or any unrelated package provider.
let
  pkgs = {
    lib.optionalAttrs = condition: attrs: if condition then attrs else {};
    stdenv.hostPlatform = { isDarwin = false; isWindows = true; };
    unrelatedProvider = "preserved";
    buildPackages = throw "unrelated build tools must remain lazy";
    windows = throw "unrelated Windows providers must remain lazy";
  };
  systemPkgs = import ../lib/system-pkgs.nix pkgs;
  resolve = name:
    systemPkgs.${name} or (throw "missing system library: ${name}");
  checks = {
    lowercaseCrypt32 = resolve "crypt32" == null;
    legacyCrypt32 = resolve "Crypt32" == null;
    otherWindowsLibrary = resolve "kernel32" == null;
    unrelatedProvider = resolve "unrelatedProvider" == pkgs.unrelatedProvider;
    missingLibraryRejected = !(builtins.tryEval (resolve "missingLibrary")).success;
  };
in
assert builtins.all (value: value) (builtins.attrValues checks);
checks
