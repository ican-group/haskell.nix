/* The function obtained when this is applied to a package set calls
 * the stack-to-nix tool on a supplied source set and then
 * imports the resulting pkgs.nix. The application of this function
 * to a source path can thus be used directly as the input to mkStackPackageSet
 *
 * see also `call-cabal-project-to-nix`!
 */
{ name ? src.name or null # optional name for better error messages
, src
, stackYaml ? "stack.yaml"
, ignorePackageYaml ? false
, cache ? null
, stack-sha256 ? null
, resolverSha256 ? null
, materialized ? null # Location of a materialized copy of the nix files
, checkMaterialization ? null # If true the nix files will be generated used to check plan-sha256 and material
, nix-tools
, evalPackages
, ... }:
let
  inherit (evalPackages) runCommand;
  inherit (evalPackages.haskell-nix) mkCacheFile materialize haskellLib;
  inherit (haskellLib.fetchResolver {
      inherit src stackYaml resolverSha256;
    }) resolver fetchedResolver;

  subDir' = src.origSubDir or "";
  subDir = evalPackages.lib.strings.removePrefix "/" subDir';
  cleanedSource = (haskellLib.cleanSourceWith {
    name = if name != null then "${name}-root-cabal-files" else "source-root-cabal-files";
    src = src.origSrc or src;
    filter = path: type: (!(src ? filter) || src.filter path type) && (
      type == "directory" ||
      # Keep any `.yaml` (not just `stackYaml`) so that when `stack.yaml` is a
      # symlink to e.g. `stack-8.6.5.yaml`, the symlink target is retained too;
      # otherwise it is filtered out and the symlink dangles (#801).
      evalPackages.lib.any (i: (evalPackages.lib.hasSuffix i path)) [ stackYaml ".yaml" ".cabal" "package.yaml" ]); });

  stackToNixArgs = builtins.concatStringsSep " " [
    "--full"
    "--stack-yaml=$SRC${subDir'}/${stackYaml}"
    (if ignorePackageYaml then "--ignore-package-yaml" else "")
    "-o ."
  ];
  stack = materialize ({
    inherit materialized;
    sha256 = stack-sha256;
    sha256Arg = "stack-sha256";
    reasonNotSafe = null;
    this = "project.stack-nix" + (if name != null then " for ${name}" else "");
  } // evalPackages.lib.optionalAttrs (checkMaterialization != null) {
    inherit checkMaterialization;
  }) (runCommand (if name == null then "stack-to-nix-pkgs" else name + "-stack-to-nix-pkgs") {
    nativeBuildInputs = [ nix-tools evalPackages.nix-prefetch-git evalPackages.cacert (evalPackages.lndir or evalPackages.xorg.lndir) ];
    # Needed or stack-to-nix will die on unicode inputs
    LOCALE_ARCHIVE = evalPackages.lib.optionalString (evalPackages.stdenv.hostPlatform.libc == "glibc") "${evalPackages.glibcLocales}/lib/locale/locale-archive";
    LANG = "en_US.UTF-8";
    LC_ALL = "en_US.UTF-8";
    preferLocalBuild = false;
  } (''
    mkdir -p $out${subDir'}
    SRC=$(mktemp -d)
    cd $SRC
    # if cleanedSource is empty, this means it's a new
    # project where the files haven't been added to the git
    # repo yet. We fail early and provide a useful error
    # message to prevent headaches (#290).
    if [ -z "$(ls -A ${cleanedSource})" ]; then
      echo "cleaned source is empty. Did you forget to 'git add -A'?"; exit 1;
    fi
    lndir -silent "${cleanedSource}/." $SRC
    ${evalPackages.lib.optionalString (subDir != "") "cd ${subDir}"}
    ${
    # If a resolver was fetched use the it instead of the original stack.yaml
    evalPackages.lib.optionalString (fetchedResolver != null)
      # Replace the resolver path in the stack.yaml with the fetched version
      ''
      rm ${stackYaml}
      cp ${src}/${stackYaml} .
      chmod +w ${stackYaml}
      substituteInPlace ${stackYaml} --replace "${resolver}" "${fetchedResolver}"
    ''}
    ${evalPackages.lib.optionalString (cache != null) ''
      cp ${mkCacheFile cache}/.stack-to-nix.cache* $out${subDir'}
    ''}
    (cd $out${subDir'} && stack-to-nix ${stackToNixArgs})

    # We need to strip out any references to $src, as those won't
    # be accessable in restricted mode.
    for nixf in $(find $out -name "*.nix" -type f); do
      substituteInPlace $nixf --replace "$SRC${subDir'}" "."
    done

    # move pkgs.nix to default.nix ensure we can just nix `import` the result.
    mv $out${subDir'}/pkgs.nix $out${subDir'}/default.nix
  ''));
in { projectNix = stack; inherit src; sourceRepos = []; }
