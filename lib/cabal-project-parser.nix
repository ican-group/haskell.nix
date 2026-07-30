{ pkgs }:
let
  # Strip carriage returns so a cabal.project checked out with CRLF line
  # endings parses the same as one with LF endings.  Without this every
  # `splitString "\n"` below leaves a trailing "\r" on each line, silently
  # corrupting extracted values (locations, tags, subdirs, sha256 comments)
  # and block boundaries (see #1090).  Note: this drops string context, so
  # callers that need it (e.g. builtins.split's context trick) must derive it
  # from the original, un-normalised argument.
  normalizeCRLF = builtins.replaceStrings [ "\r\n" ] [ "\n" ];

  span = pred: list:
    let n = pkgs.lib.lists.foldr (x: acc: if pred x then acc + 1 else 0) 0 list;
    in { fst = pkgs.lib.lists.take n list; snd = pkgs.lib.lists.drop n list; };

  # Look for a index-state: field in the cabal.project file
  parseIndexState = rawCabalProject:
      let
        indexState = pkgs.lib.lists.concatLists (
          pkgs.lib.lists.filter (l: l != null)
            (builtins.map (l: builtins.match "^index-state: *(.*)" l)
              (pkgs.lib.splitString "\n" (normalizeCRLF rawCabalProject))));
      in
        pkgs.lib.lists.head (indexState ++ [ null ]);

  # Remove the indentation of the first line from all the lines
  unindent = blockLines: (pkgs.lib.foldl' ({matchString, out}: s:
    let
      m = builtins.match matchString s;
    in
      if m != null
        then {
          matchString = "(${builtins.head m})(.*)";
          out = out ++ [(builtins.elemAt m 1)];
        }
        else {
          inherit matchString out;
        }
    ) { matchString = "( *)(.*)"; out = []; } blockLines).out;

  # Strip comments except `--sha256`
  stripComments = blockLines: pkgs.lib.filter (s: s != "") (
    pkgs.lib.foldl' (out: s:
      let
        m = builtins.match "(.*)--.*" s;
      in
        if !(pkgs.lib.hasPrefix "--sha256" s) && m != null
          then out ++ [(builtins.head m)]
          else out ++ [s]
      ) [] blockLines
    );

  # Parse lines of a source-repository-package block
  parseBlockLines = blockLines:
    let
      # builtins.match strips string context. Capture the context from the input
      # lines so we can re-attach it to parsed values via string concatenation.
      # Using substring+concatenation instead of builtins.appendContext because
      # appendContext can fail for store paths that don't exist locally.
      contextStr = builtins.substring 0 0 (builtins.concatStringsSep "" blockLines);
    in (pkgs.lib.foldl' ({name, attrs}: s:
    let
      # Look for a new attribute name
      pair = builtins.match "([^ :]*): *(.*)" s;
      trim = x: let m = builtins.match "(.*[^ \t])[ \t]*" x;
        in pkgs.lib.optionalString (m != null) (contextStr + builtins.head m);

      # Function to build the next parse state when the attribute name is known
      nextState = name: value: {
          inherit name;
          # Support multi line attributes by appending the value to the named attribute
          attrs = attrs // {
            ${name} =
              if attrs ? ${name}
                then attrs.${name} + " " + value
                else value;
          };
        };
    in
      if pair != null
        then
          # First line of a new attribute
          nextState (builtins.head pair) (trim (builtins.elemAt pair 1))
        else
          if name != null
            then nextState name (contextStr + s) # Append another line to the current attribute
            else __trace "Expected attribute but found `${s}`" { inherit name attrs; }
    ) { name = null; attrs = {}; } (stripComments (unindent blockLines))).attrs;

  # Gets data for all the repositories to fetch
  # A comment like
  #   --shar256: 003lm3pm0000hbfmii7xcdd9v20000flxf7gdl2pyxia7p014i8z
  # will be trated like a field and returned here
  # (used in call-cabal-project-to-nix.nix to create a fixed-output derivation)
  extractSourceRepoPackageData = _cabalProjectFileName: sha256map: repo:
    let
      refOrRev =
        if builtins.match "[0-9a-f]{40}" repo.tag != null
          then "rev"
          else "ref";
      # Strip context for attribute name lookups
      locationNoContext = builtins.unsafeDiscardStringContext repo.location;
      tagNoContext = builtins.unsafeDiscardStringContext repo.tag;
    in {
    url = repo.location;
    "${refOrRev}" = repo.tag;
    sha256 = repo."--sha256" or (
      if sha256map != null && sha256map ? ${locationNoContext}
        then sha256map.${locationNoContext}.${tagNoContext}
        else null);
    subdirs = if repo ? subdir
      then pkgs.lib.filter (x: x != "") (pkgs.lib.splitString " " repo.subdir)
      else ["."];
  };

  # Parse a source-repository-package and return data of `type: git` repositories
  # See tests/unit.nix for examples of input and output.
  parseSourceRepositoryPackageBlock = cabalProjectFileName: sha256map: source-repo-override: indentation: block:
    let
      x = span (pkgs.lib.strings.hasPrefix (indentation + " ")) (pkgs.lib.splitString "\n" block);
      attrs = parseBlockLines x.fst;
      overrideSourceRepo = sourceRepo: (source-repo-override.${builtins.unsafeDiscardStringContext sourceRepo.url} or (pkgs.lib.id)) sourceRepo;
    in
      if attrs."type" or "" != "git"
        then {
          followingText = "\n" + indentation + "source-repository-package\n" + block;
        }
        else {
          inherit indentation;
          sourceRepo = overrideSourceRepo (extractSourceRepoPackageData cabalProjectFileName sha256map attrs);
          followingText = pkgs.lib.strings.concatStringsSep "\n" x.snd;
        };

  parseSourceRepositoryPackages = cabalProjectFileName: sha256map: source-repo-override: projectFile:
    let
      splitResult = builtins.split "\n( *)source-repository-package\n" ("\n" + normalizeCRLF projectFile);
      # builtins.split strips string context. Use substring to create a zero-length
      # string with the original context, then prepend it to carry context through
      # via concatenation (which doesn't validate paths like appendContext does).
      # (Derived from the un-normalised projectFile so the context is preserved.)
      contextStr = builtins.substring 0 0 projectFile;
      # Construct a list of strings with just the indentation amounts for each map
      indentations = builtins.concatLists (builtins.filter builtins.isList splitResult);
      blocks = builtins.filter builtins.isString (pkgs.lib.lists.drop 1 splitResult);
    in {
      initialText = contextStr + builtins.head splitResult;
      sourceRepos = pkgs.lib.zipListsWith (parseSourceRepositoryPackageBlock cabalProjectFileName sha256map source-repo-override)
        indentations blocks;
    };

  # Parse and replace repository
  # This works in a similar way to the `source-repository-package` but we are
  # able to simply replace the `repository` blocks with local `file:/nix/store` ones.
  # This works because `cabal configure` does not include any of the `/nix/sore/`
  # paths in the `plan.json` (so materialized plan-nix will still work as expected).
  # See tests/unit.nix for examples of input and output.
  parseRepositoryBlock = evalPackages: _cabalProjectFileName: sha256map: inputMap: nix-tools: block:
    let
      lines = pkgs.lib.splitString "\n" block;
      # The first line will contain the repository name.
      x = span (pkgs.lib.strings.hasPrefix " ") (__tail lines);
      attrs = parseBlockLines x.fst;
      # Strip context for attribute name lookups (context on attrs values
      # can cause "not allowed to refer to a store path" errors in attr names)
      urlNoContext = builtins.unsafeDiscardStringContext attrs.url;
      sha256 = attrs."--sha256" or (
        if sha256map != null
          then sha256map.${urlNoContext} or null
          else null);
    in rec {
      # This is `some-name` from the `repository some-name` line in the `cabal.project` file.
      name = builtins.unsafeDiscardStringContext (__head lines);
      # The $HOME/.cabal/packages/${name} after running `cabal v2-update` to download the repository
      repoContents = if inputMap ? ${urlNoContext}
        # If there is an input use it to make `file:` url and create a suitable `.cabal/packages/${name}` directory
        then evalPackages.runCommand name ({
          nativeBuildInputs = [ nix-tools.exes.cabal ] ++ evalPackages.haskell-nix.cabal-issue-8352-workaround;
          preferLocalBuild = true;
        }) ''
            HOME=$(mktemp -d)
            mkdir -p $HOME/.cabal/packages/${name}
            cat <<EOF > $HOME/.cabal/config
            repository ${name}
              url: file:${inputMap.${urlNoContext}}
              ${pkgs.lib.optionalString (attrs ? secure) "secure: ${attrs.secure}"}
              ${pkgs.lib.optionalString (attrs ? root-keys) "root-keys: ${attrs.root-keys}"}
              ${pkgs.lib.optionalString (attrs ? key-threshold) "key-threshold: ${attrs.key-threshold}"}
            EOF
            cabal v2-update ${name}
            cp -r $HOME/.cabal/packages/${name} $out
        ''
        else evalPackages.runCommand name ({
          nativeBuildInputs = [ nix-tools.exes.cabal evalPackages.curl ] ++ evalPackages.haskell-nix.cabal-issue-8352-workaround;
          LOCALE_ARCHIVE = pkgs.lib.optionalString (evalPackages.stdenv.buildPlatform.libc == "glibc") "${evalPackages.glibcLocales}/lib/locale/locale-archive";
          LANG = "en_US.UTF-8";
          preferLocalBuild = true;
        } // pkgs.lib.optionalAttrs (sha256 != null) {
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = sha256;
        }) ''
            HOME=$(mktemp -d)
            mkdir -p $HOME/.cabal/packages/${name}
            cat <<EOF > $HOME/.cabal/config
            repository ${name}
              url: ${attrs.url}
              ${pkgs.lib.optionalString (attrs ? secure) "secure: ${attrs.secure}"}
              ${pkgs.lib.optionalString (attrs ? root-keys) "root-keys: ${attrs.root-keys}"}
              ${pkgs.lib.optionalString (attrs ? key-threshold) "key-threshold: ${attrs.key-threshold}"}
            EOF
            export SSL_CERT_FILE=${evalPackages.cacert}/etc/ssl/certs/ca-bundle.crt
            cabal v2-update ${name}
            cp -r $HOME/.cabal/packages/${name} $out
        '';
      # Output of hackage-to-nix
      hackage = import (
        evalPackages.runCommand ("hackage-to-nix-" + name) {
          nativeBuildInputs = [ nix-tools.exes.hackage-to-nix ];
          LOCALE_ARCHIVE = pkgs.lib.optionalString (evalPackages.stdenv.buildPlatform.libc == "glibc") "${evalPackages.glibcLocales}/lib/locale/locale-archive";
          LANG = "en_US.UTF-8";
          preferLocalBuild = true;
        } ''
          mkdir -p $out
          hackage-to-nix $out ${repoContents}/01-index.tar ${attrs.url}
        '');
      # Directory to `lndir` when constructing a suitable $HOME/.cabal dir
      repo.${name} = repoContents;
    };

  parseRepositories = evalPackages: cabalProjectFileName: sha256map: inputMap: nix-tools: projectFile:
    let
      # This will leave the name of repository in the first line of each block
      blocks = pkgs.lib.splitString "\nrepository " ("\n" + normalizeCRLF projectFile);
      repoBlocks = builtins.map (parseRepositoryBlock evalPackages cabalProjectFileName sha256map inputMap nix-tools) (pkgs.lib.lists.drop 1 blocks);
    in {
      extra-hackages = pkgs.lib.lists.map (block: block.hackage) repoBlocks;
      repos = pkgs.lib.lists.foldl' (x: block: x // block.repo) {} repoBlocks;
    };

in {
  inherit parseIndexState parseSourceRepositoryPackages parseRepositories
    # These are only exposed for tests
    parseSourceRepositoryPackageBlock parseRepositoryBlock;
}
