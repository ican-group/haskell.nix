# Generate cache entries for dependencies of package defined in `src`

{ src
, stackYaml    ? "stack.yaml"
, sha256map    ? null
                     # An alternative to adding `# nix-sha256:` comments into the
                     # stack.yaml file:
                     #   sha256map =
                     #     { "https://github.com/jgm/pandoc-citeproc"."0.17"
                     #         = "0dxx8cp2xndpw3jwiawch2dkrkp15mil7pyx7dvd810pwc22pm2q"; };
, inputMap     ? {}
                     # Maps a dependency git url to a local path / flake
                     # input, mirroring the `cabalProject` `inputMap`
                     # argument.  When a url is present here it is used
                     # instead of fetching, so private repositories and
                     # offline builds work:
                     #   inputMap =
                     #     { "https://github.com/jgm/pandoc-citeproc"
                     #         = inputs.pandoc-citeproc; };
, branchMap    ? null
                     # A way to specify in which branch a git commit can
                     # be found
, lookupBranch ?
  if branchMap != null
    then { location, tag, ...}: branchMap."${location}"."${tag}" or null
    else _: null
, resolverSha256 ? null
, extraDepsOnly ? false
                     # Only list the git packages the stack.yaml itself
                     # names (its `extra-deps`), leaving out those that come
                     # from a custom snapshot (a `.yaml` resolver).  Used by
                     # the `gitExtraDepsLocal` option; only `url`, `rev`
                     # and `subdir` of the result are meant to be read.
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

    # `stack-repos` merges a custom snapshot's packages in when the resolver
    # names a `.yaml` file (a path, a URL or pantry's `url:`/`filepath:`
    # object), so for `extraDepsOnly` the resolver is replaced, whatever it
    # is, by a placeholder that names no file.  This uses a YAML tool rather
    # than the text `fetchResolver` matched, which misses quoted values,
    # trailing comments and CRLF line endings.  Without `extraDepsOnly` the
    # script is unchanged.
    resolverSubstitution =
      if extraDepsOnly
        then ''
          ${evalPackages.yq-go}/bin/yq -i 'del(.snapshot) | .resolver = "lts-0.0"' ${stackYaml}
        ''
        else evalPackages.lib.optionalString (fetchedResolver != null) ''
          substituteInPlace ${stackYaml} --replace "${resolver}" "${fetchedResolver}"
        '';

    repos = builtins.fromJSON (builtins.readFile (evalPackages.runCommand "stack-repos" {
        buildInputs = [ nix-tools ];
      } ''
        TMP=$(mktemp -d)
        cd $TMP
        cp -r "${maybeCleanedSource}/." $TMP
        chmod -R +w $TMP
        substituteInPlace ${stackYaml} --replace "# nix-sha256:" "nix-sha256:"
        ${resolverSubstitution}
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
    # `inputMap` may legitimately be `null` (the option type is
    # `nullOr attrs`); treat that the same as an empty map.
    inputMap' = if inputMap == null then {} else inputMap;

    # Unpack an archive file (`.tar.gz`, `.zip`, ...).  Like pantry (and
    # `fetchzip`), use the archive's top-level directory when it has just
    # one, so `subdirs` are relative to that.
    unpackArchive = archive: evalPackages.runCommand "stack-archive-source" {
        nativeBuildInputs = [ evalPackages.unzip ];
      } ''
        mkdir unpack
        cd unpack
        unpackFile ${archive}
        shopt -s dotglob
        entries=( * )
        if [ ''${#entries[@]} -eq 1 ] && [ -d "''${entries[0]}" ]; then
          mv "''${entries[0]}" $out
        else
          mkdir $out
          mv * $out/
        fi
      '';

    # The unpacked source of an archive `extra-dep` (`archive:`/`url:`, or a
    # bare http(s) URL, in the stack.yaml).  `stack-repos` gives its
    # `nix-sha256` (from a `# nix-sha256:` comment) as `sha256` and pantry's
    # `sha256` of the archive file as `archiveSha256`; a string
    # `sha256map.<url>` is a `nix-sha256` too.  With neither,
    # `builtins.fetchTarball` fetches it, which works only outside pure
    # evaluation (Nix asks for a hash there).  A path that is not a URL is
    # an archive file relative to the stack.yaml file.
    archiveSource = dep:
      let
        nix-sha256 =
          if dep.sha256 != null then dep.sha256
          else if sha256map != null && builtins.isString (sha256map.${dep.url} or null)
            then sha256map.${dep.url}
          else null;
        isUrl = evalPackages.lib.hasPrefix "http://" dep.url || evalPackages.lib.hasPrefix "https://" dep.url;
        srcDir = src.origSrcSubDir or src;
        stackYamlDir = builtins.dirOf stackYaml;
      in
        if !isUrl
          then unpackArchive (srcDir + "/${stackYamlDir}/${dep.url}")
        else if nix-sha256 != null
          then evalPackages.fetchzip { inherit (dep) url; sha256 = nix-sha256; }
        else if (dep.archiveSha256 or null) != null
          then unpackArchive (evalPackages.fetchurl { inherit (dep) url; sha256 = dep.archiveSha256; })
        else builtins.fetchTarball { inherit (dep) url; };
in with evalPackages.lib;
concatMap (dep:
        let
            is-archive = (dep.type or "git") == "archive";
            is-private = private dep.url;
            sha256 =
              if is-archive then null
              else if dep.sha256 != null
                then dep.sha256
              else if sha256map != null && sha256map ? ${dep.url}
                then sha256map.${dep.url}.${dep.rev}
              else null;
            branch = lookupBranch {
              location = dep.url;
              tag = dep.rev;
            };
            # When the dependency url is present in `inputMap` we use the
            # mapped local path / flake input directly instead of fetching
            # it.  This mirrors the `cabalProject` `inputMap` resolution in
            # `lib/call-cabal-project-to-nix.nix`.
            input =
              # An archive has no revision to check, so `inputMap.<url>` is
              # used as it is.
              if is-archive
                then inputMap'.${dep.url} or (archiveSource dep)
              else if inputMap' ? "${dep.url}/${dep.rev}"
                then inputMap'."${dep.url}/${dep.rev}"
              else if inputMap' ? ${dep.url}
                then
                  (if (inputMap'.${dep.url}.rev or null) != dep.rev
                    then throw "${inputMap'.${dep.url}.rev or "<no rev>"} may not match ${dep.rev} for ${dep.url} use \"${dep.url}/${dep.rev}\" as the inputMap key if ${dep.rev} is a branch or tag that points to ${inputMap'.${dep.url}.rev or "<no rev>"}."
                    else inputMap'.${dep.url})
              else null;
            pkgsrc =
              if input != null
                then input
              else if !is-private && sha256 != null
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
                # A mapped input is used directly as the package `src` by
                # `mkCacheModule` (see `overlays/haskell.nix`), so there is
                # no need to compute a sha256 for it.
                sha256 = if input == null && !is-private then hashPath pkgsrc else null;
            } // (optionalAttrs (subdir != "") { inherit subdir; })
              // (optionalAttrs (input != null) { inherit input; })
              // (optionalAttrs is-archive { inherit is-archive; }))
        (dep.subdirs or [ "" ])) repos
