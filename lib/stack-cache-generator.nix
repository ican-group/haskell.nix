# Generate cache entries for dependencies of package defined in `src`

{ src
, stackYaml    ? "stack.yaml"
, sha256map    ? null
                     # An alternative to adding `# nix-sha256:` comments into the
                     # stack.yaml file:
                     #   sha256map =
                     #     { "https://github.com/jgm/pandoc-citeproc"."0.17"
                     #         = "0dxx8cp2xndpw3jwiawch2dkrkp15mil7pyx7dvd810pwc22pm2q"; };
, branchMap    ? null
                     # A way to specify in which branch a git commit can
                     # be found
, lookupBranch ?
  if branchMap != null
    then { location, tag, ...}: branchMap."${location}"."${tag}" or null
    else _: null
, resolverSha256 ? null
, nix-tools
, evalPackages
, ...
}:
let
    inherit (evalPackages) runCommand;
    inherit (evalPackages.haskell-nix) haskellLib;

    # We only care about the stackYaml file.  If src is a local directory
    # we want to avoid recalculating the cache unless the stack.yaml file
    # changes.

    inherit (haskellLib.fetchResolver {
        inherit src stackYaml resolverSha256;
      }) resolver fetchedResolver;

    # Filter just the stack yaml file and any resolver yaml file it points to.
    maybeCleanedSource = haskellLib.cleanSourceWith {
      inherit src;
      filter = path: _type:
        let
          origSrc = if src ? _isLibCleanSourceWith then src.origSrc else src;
          origSubDir = if src ? _isLibCleanSourceWithEx then src.origSubDir else "";
          relPath = evalPackages.lib.removePrefix (toString origSrc + origSubDir + "/") path;

          # checks if path1 is a parent directory for path2
          isParent = path1: path2: evalPackages.lib.hasPrefix "${path1}/" path2;

        in
          (relPath == stackYaml)
          # Keep any `.yaml` so that a `stack.yaml` which is a symlink to e.g.
          # `stack-8.6.5.yaml` still has its target present (otherwise the
          # symlink dangles, #801).
          || (evalPackages.lib.hasSuffix ".yaml" relPath)
          || (resolver != null && (relPath == resolver || isParent relPath resolver))
        ;
    };

    # All repos served via ssh or git protocols are usually private
    private = url: evalPackages.lib.substring 0 4 url != "http";

    repos = builtins.fromJSON (builtins.readFile (evalPackages.runCommand "stack-repos" {
        buildInputs = [ nix-tools ];
      } ''
        TMP=$(mktemp -d)
        cd $TMP
        cp -r "${maybeCleanedSource}/." $TMP
        chmod -R +w $TMP
        substituteInPlace ${stackYaml} --replace "# nix-sha256:" "nix-sha256:"
        ${evalPackages.lib.optionalString (fetchedResolver != null) ''
          substituteInPlace ${stackYaml} --replace "${resolver}" "${fetchedResolver}"
        ''}
        stack-repos --stack-yaml ${stackYaml}
        cp repos.json $out
      ''));

    cabalName = path: builtins.readFile (evalPackages.runCommand "cabal-name" {
        buildInputs = [ nix-tools ];
      } ''
        cabal-name ${path} > $out
      '');

    hashPath = path:
        builtins.readFile (evalPackages.runCommand "hash-path" { preferLocalBuild = true; }
            "echo -n $(${evalPackages.nix}/bin/nix-hash --type sha256 --base32 ${path}) > $out");
in with evalPackages.lib;
concatMap (dep:
        let
            is-private = private dep.url;
            sha256 =
              if dep.sha256 != null
                then dep.sha256
              else if sha256map != null && sha256map ? ${dep.url}
                then sha256map.${dep.url}.${dep.rev}
              else null;
            branch = lookupBranch {
              location = dep.url;
              tag = dep.rev;
            };
            pkgsrc =
              if !is-private && sha256 != null
                then evalPackages.fetchgit {
                  inherit (dep) url rev;
                  inherit sha256;
                }
                else builtins.fetchGit ({
                  inherit (dep) url rev;
                  submodules = true;
                  allRefs = true;
                } // evalPackages.lib.optionalAttrs (branch != null) { ref = branch; });
        in map (subdir: {
                name = cabalName "${pkgsrc}/${subdir}";
                inherit (dep) url rev;
                inherit is-private;
                sha256 = if !is-private then hashPath pkgsrc else null;
            } // (optionalAttrs (subdir != "") { inherit subdir; }))
        (dep.subdirs or [ "" ])) repos
