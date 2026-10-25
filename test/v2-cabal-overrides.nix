# Source-only regression: no Cabal planner, compiler or package build.
{ system ? builtins.currentSystem
, pkgs ? (import ../default.nix { inherit system; }).pkgs
, componentBuilder ? ../builder/comp-v2-builder.nix
}:
let
  inherit (pkgs) lib runCommand;
  stageCabalFile = import ../builder/stage-cabal-file.nix;
  # Capture the real component builder's source passthru lazily. None of
  # these compiler/store inputs may be needed to produce package sources.
  build = import componentBuilder {
    inherit lib runCommand;
    buildCabalStoreSlice = args:
      let result = args // args.passthru // { overrideAttrs = _: result; };
      in result;
    stdenv = throw "source regression forced stdenv";
    composeStore = throw "source regression forced store composition";
    ghc = throw "source regression forced a compiler";
    hsPkgs = throw "source regression forced Haskell dependencies";
    pkgs = throw "source regression forced package tools";
    haskellLib = throw "source regression forced source cleaning";
  };
  # Real Hackage archives and revised Cabal files. The fixture overrides
  # add an independent field; compare every byte to retain all revisions.
  inputs = {
    "1.6.7" = {
      sha256 = "a436261e5f5e83d85080f57a5509c8224c9e75a6e56d0c43a7d2967052b634ca";
      cabal = ./v2-cabal-overrides/1.6.7.cabal;
    };
    "1.6.8" = {
      sha256 = "e80b133d708ffee6db6fd21b13a430e6b27a8ae2c47a848d0cdd5bd006a01b8e";
      cabal = ./v2-cabal-overrides/1.6.8.cabal;
    };
  };
  archive = version: pkgs.fetchurl {
    url = "https://hackage.haskell.org/package/crypton-x509-system-${version}/crypton-x509-system-${version}.tar.gz";
    inherit (inputs.${version}) sha256;
  };
  override = version:
    builtins.readFile inputs.${version}.cabal + "\nx-v2-override-marker: retained\n";
  # Explicit fixture selection: the upstream Windows selector is tested
  # separately; its 1.6.8 boundary fix is independent of this V2 regression.
  patchFor = { version }:
    if lib.versionOlder version "1.6.8"
    then ../overlays/patches/crypton-x509-system-1.6.patch
    else ../overlays/patches/crypton-x509-system.patch;
  source = version: extra: build ({
    componentId = { ctype = "lib"; cname = "crypton-x509-system"; };
    component = {};
    pkgSet = {};
    name = "crypton-x509-system";
    package = { identifier = { name = "crypton-x509-system"; inherit version; }; isLocal = false; };
    src = archive version;
    cabalFile = override version;
  } // extra);
  patchCase = version: {
    name = "patched-${version}";
    component = source version { patches = [ patchFor ]; };
    expected = lib.replaceStrings [ "Crypt32" ] [ "crypt32" ] (override version);
  };
  hookVersion = "1.6.8";
  localSource = runCommand "v2-cabal-override-local-source" {} ''
    mkdir -p "$out/package"
    tar -xzf ${archive hookVersion} --strip-components=1 -C "$out/package"
  '';
  hookCase = {
    name = "local-hook";
    component = source hookVersion {
      src = localSource + "/package";
      package = { identifier = { name = "crypton-x509-system"; version = hookVersion; }; isLocal = true; };
      postPatch = ''printf '\nx-v2-hook-marker: retained\n' >> crypton-x509-system.cabal'';
    };
    expected = override hookVersion + "\nx-v2-hook-marker: retained\n";
  };
  untouched = source "1.6.8" {};
  checkCase = { name, component, expected, checkTar ? true }:
    let
      fragment = component.v2SourceFrag;
      expectedFile = builtins.toFile "${name}-expected.cabal" expected;
      directory = "$out/${name}";
    in ''
      mkdir -p "${directory}"
      tar -xOzf ${fragment.tarball} \
        ${fragment.pkgName}-${fragment.pkgVersion}/${fragment.pkgName}.cabal \
        > "${directory}/tar.cabal"
      ${lib.optionalString checkTar ''cmp ${expectedFile} "${directory}/tar.cabal"''}
      ${stageCabalFile { inherit fragment; target = "${directory}/own-index.cabal"; }}
      ${stageCabalFile {
        inherit fragment;
        copyOptions = " -f --no-preserve=mode";
        singleLine = true;
        target = "${directory}/build-tool-index.cabal";
      }}
      ${stageCabalFile { inherit fragment; target = "${directory}/export-index.cabal"; }}
      for index in own build-tool export; do
        cmp ${expectedFile} "${directory}/$index-index.cabal"
      done
      echo "PASS ${name}: effective Cabal metadata agrees across indexes"
    '';
in
# Unpatched Hackage keeps both original tar bytes and revised-index path.
assert toString untouched.pkgTarball == toString (archive "1.6.8");
assert untouched.v2SourceFrag.cabalFile != null;
runCommand "v2-cabal-overrides" {
  preferLocalBuild = true;
  allowSubstitutes = false;
} (lib.concatMapStrings checkCase [
  (patchCase "1.6.7")
  (patchCase "1.6.8")
  hookCase
  { name = "untouched"; component = untouched; expected = override "1.6.8"; checkTar = false; }
])
