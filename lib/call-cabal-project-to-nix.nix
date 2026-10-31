{ pkgs, cacert, index-state-hashes, haskellLib }:
{ name          ? src.name or null # optional name for better error messages
, src
, evalSrc ? src
, materialized-dir ? ../materialized
, compiler-nix-name    # The name of the ghc compiler to use eg. "ghc884"
, index-state   ? null # Hackage index-state, eg. "2019-10-10T00:00:00Z"
, index-sha256  ? null # The hash of the truncated hackage index-state
, plan-sha256   ? null # The hash of the plan-to-nix output (makes the plan-to-nix step a fixed output derivation)
, materialized  ? null # Location of a materialized copy of the nix files
, checkMaterialization ? null # If true the nix files will be generated used to check plan-sha256 and material
, cabalProjectFileName ? "cabal.project"
, cabalProject         ? null
, cabalProjectLocal    ? null
, cabalProjectFreeze   ? null
, caller               ? "callCabalProjectToNix" # Name of the calling function for better warning messages
, compilerSelection    ? p: builtins.mapAttrs (_: x: x.evalWith.${evalPackages.stdenv.hostPlatform.system} or (x.override { evalSystem = evalPackages.stdenv.hostPlatform.system; })) p.haskell-nix.compiler
, ghcOverride   ? null # Used when we need to set ghc explicitly during bootstrapping
, configureArgs ? "" # Extra arguments to pass to `cabal v2-configure`.
                     # `--enable-tests --enable-benchmarks` are included by default.
                     # If the tests and benchmarks are not needed and they
                     # cause the wrong plan to be chosen, then we can use
                     # `configureArgs = "--disable-tests --disable-benchmarks";`
, sha256map     ? null
                     # An alternative to adding `--sha256` comments into the
                     # cabal.project file:
                     #   sha256map =
                     #     { # For a `source-repository-package` use the `location` and `tag` as the key
                     #       "https://github.com/jgm/pandoc-citeproc"."0.17"
                     #         = "0dxx8cp2xndpw3jwiawch2dkrkp15mil7pyx7dvd810pwc22pm2q";
                     #       # For a `repository` use the `url` as the key
                     #       "https://raw.githubusercontent.com/input-output-hk/hackage-overlay-ghcjs/bfc363b9f879c360e0a0460ec0c18ec87222ec32"
                     #         = "sha256-g9xGgJqYmiczjxjQ5JOiK5KUUps+9+nlNGI/0SpSOpg=";
                     #     };
, inputMap ? {}
                     # An alternative to providing a `sha256` handy for flakes
                     # cabal.project file:
                     #   inputs.pandoc-citeproc.url = "github:jgm/pandoc-citeproc/0.17";
                     #   inputs.pandoc-citeproc.flake = false;
                     #   outputs = inputs:
                     #     ...
                     #     inputMap."https://github.com/jgm/pandoc-citeproc" = inputs.inputs.pandoc-citeproc;
, extra-hackage-tarballs ? {}
, source-repo-override ? {} # Cabal seems to behave incoherently when
                            # two source-repository-package entries
                            # provide the same packages, making it
                            # impossible to override cabal.project
                            # with e.g. a cabal.project.local. In CI,
                            # we want to be able to test against the
                            # latest versions of various dependencies.
                            #
                            # This argument is a map from url to
                            # a function taking the existing repoData
                            # and returning the new repoData in its
                            # place. E.g.
                            #
                            # { "https://github.com/input-output-hk/plutus-apps" = orig: orig // { subdirs = (orig.subdirs or [ "." ]) ++ [ "foo" ]; }; }
                            #
                            # would result in the "foo" subdirectory of
                            # any plutus-apps input being used for a
                            # package.
, evalPackages
, supportHpack ? false      # Run hpack on package.yaml files with no .cabal file
, ignorePackageYaml ? false # Ignore package.yaml files even if they exist
, prebuilt-depends ? []
, prepopulateHackageIndex ? true # When false, prepopulate an *empty* hackage
                            # index in CABAL_DIR instead of the full ~1.2 GB one.
                            # cabal parses this index on every invocation even
                            # with `active-repositories: :none`, so projects that
                            # resolve nothing from hackage (all packages pinned
                            # locally) set this false to avoid a large needless
                            # cost in the plan-to-nix step.
, withBuildCompiler ? false # When true, pass a *build*-platform dummy ghc +
                            # ghc-pkg to make-install-plan via
                            # --with-build-compiler / --with-build-hc-pkg (the
                            # stable-haskell cabal fork's cross "stage" system).
                            # See dummy-build-ghc below.
, ...
}@args:
let
  inherit (evalPackages.haskell-nix) materialize dotCabal;

  # These defaults are here rather than in modules/cabal-project.nix to make them
  # lazy enough to avoid infinite recursion issues.
  # Using null as the default also improves performance as they are not forced by the
  # nix module system for `nix-tools-unchecked`.
  # (v2 projects and the stable-haskell compilers set it to the fork's
  # bundle instead -- see modules/cabal-project.nix.)
  nix-tools = if args.nix-tools or null != null
    then args.nix-tools
    else evalPackages.haskell-nix.nix-tools-unchecked;

  nameAndSuffix = suffix: if name == null then suffix else name + "-" + suffix;

  ghc' =
    if ghcOverride != null
      then ghcOverride
    # NB: the stable-haskell two-stage cross plans (`withBuildCompiler`) do NOT
    # need a different compiler here.  The plan-to-nix dummy reports the cross
    # target from `mkDummyGhcPkg`'s `pkgs` (= `final.buildPackages`, whose
    # `targetPlatform` is the cross target), and the target-OS `os()`/`arch()`
    # conditionals (e.g. Win32) are handled by the boot-package injection in
    # `modules/cabal-project.nix` — neither depends on the compiler selected
    # here.  So the build-hosted compiler below is correct for these plans too.
    # Reaching for a target-hosted compiler instead (`compilerSelection pkgs`)
    # forces the compiler's host=target splice, which the ghcjs backend rejects
    # with a "build ghcjs with ghcjs" throw and which never makes sense for any
    # cross target.
      else
      # Do note that `pkgs = final.buildPackages` in the `overlays/haskell.nix`
      # call to this file. And thus `pkgs` here is the proper `buildPackages`
      # set and we do not need, nor should pick the compiler from another level
      # of `buildPackages`, lest we want to get confusing errors about the Win32
      # package.
      #
      # > The option `packages.Win32.package.identifier.name' is used but not defined.
      #
      (compilerSelection pkgs.buildPackages)."${compiler-nix-name}";

in let
  ghc = if ghc' ? latestVersion
    then __trace "WARNING: ${ghc'.version} is out of date, consider using upgrading to ${ghc'.latestVersion}." ghc'
    else ghc';
  subDir' = evalSrc.origSubDir or "";
  subDir = pkgs.lib.strings.removePrefix "/" subDir';

  cleanedSource = haskellLib.cleanSourceWith {
    name = if name != null then "${name}-root-cabal-files" else "source-root-cabal-files";
    src = evalSrc.origSrc or evalSrc;
    filter = path: type: (!(evalSrc ? filter) || evalSrc.filter path type) && (
      type == "directory" ||
      pkgs.lib.any (i: (pkgs.lib.hasSuffix i path)) [ ".cabal" "package.yaml" ]); };

  # When there is no `cabal.project` file `cabal-install` behaves as if there was
  # one containing `packages: ./*.cabal`.  Even if there is a `cabal.project.local`
  # containing some other `packages:`, it still includes `./*.cabal`.
  #
  # We could write to `cabal.project.local` instead of `cabal.project` when
  # `cabalProject == null`.  However then `cabal-install` will look in parent
  # directories for a `cabal.project` file. That would complicate reasoning about
  # the relative directories of packages.
  #
  # Instead we treat `cabalProject == null` as if it was `packages: ./*.cabal`.
  #
  # See: https://github.com/ican-group/haskell.nix/pull/1588
  #      https://github.com/ican-group/haskell.nix/pull/1639
  #
  rawCabalProject = ''
    ${
      if cabalProject == null
        then ''
          -- Included to match the implicit project used by `cabal-install`
          packages: ./*.cabal
        ''
        else cabalProject
    }
    ${
      pkgs.lib.optionalString (cabalProjectLocal != null && cabalProjectLocal != "") ''
        -- Added from `cabalProjectLocal` argument to the `cabalProject` function
        ${cabalProjectLocal}
      ''
    }
  '';

  index-state-max =
    if index-state != null
    then index-state
    else pkgs.lib.last (builtins.attrNames index-state-hashes);

  # If a hash was not specified find a suitable cached index state to
  # use that will contain all the packages we need.  By using the
  # first one after the desired index-state we can avoid recalculating
  # when new index-state-hashes are added.
  # See https://github.com/ican-group/haskell.nix/issues/672
  cached-index-state = if index-sha256 != null
    then index-state-max
    else
      let
        suitable-index-states =
          builtins.filter
            (s: s > index-state-max) # This compare is why we need zulu time
            (builtins.attrNames index-state-hashes);
      in
        if builtins.length suitable-index-states == 0
          then index-state-max
          else pkgs.lib.head suitable-index-states;

  # Lookup hash for the index state we found
  index-sha256-found = if index-sha256 != null
    then index-sha256
    else index-state-hashes.${cached-index-state} or null;

in
  assert (if index-sha256-found == null
    then throw "Unknown index-state ${index-state-max}, the latest index-state I know about is ${pkgs.lib.last (builtins.attrNames index-state-hashes)}. You may need to update to a newer hackage.nix." else true);

let
  # Deal with source-repository-packages in a way that will work in
  # restricted-eval mode (as long as a sha256 is included).
  # Replace source-repository-package blocks that have a sha256 with
  # packages: block containing nix store paths of the fetched repos.

  hashPath = path:
    builtins.readFile (pkgs.runCommand "hash-path" { preferLocalBuild = true; }
      "echo -n $(${pkgs.nix}/bin/nix-hash --type sha256 --base32 ${path}) > $out");

  replaceSourceRepos = projectFile:
    let
      fetchPackageRepo = fetchgit: repoData:
        let
          fetched =
            if inputMap ? "${repoData.url}/${repoData.rev or repoData.ref}"
              then inputMap."${repoData.url}/${repoData.rev or repoData.ref}"
            else if inputMap ? ${repoData.url}
              then
                (if inputMap.${repoData.url}.rev != (repoData.rev or repoData.ref)
                  then throw "${inputMap.${repoData.url}.rev} may not match ${repoData.rev or repoData.ref} for ${repoData.url} use \"${repoData.url}/${repoData.rev or repoData.ref}\" as the inputMap key if ${repoData.rev or repoData.ref} is a branch or tag that points to ${inputMap.${repoData.url}.rev}."
                  else inputMap.${repoData.url})
            else if repoData.sha256 != null
            then fetchgit { inherit (repoData) url sha256; rev = repoData.rev or repoData.ref; }
            else
              let drv = builtins.fetchGit
                ({ inherit (repoData) url ; }
                  # fetchGit does not accept "null" as rev and ref, so when it's null
                  # we have to omit the argument completely.
                  // pkgs.lib.optionalAttrs (repoData ? ref) { inherit (repoData) ref; }
                  // pkgs.lib.optionalAttrs (repoData ? rev) { inherit (repoData) rev; });
              in __trace "WARNING: No sha256 found for source-repository-package ${repoData.url} ref=${repoData.ref or "(unspecified)"} rev=${repoData.rev or "(unspecified)"} download may fail in restricted mode (hydra)"
                (__trace "Consider adding `--sha256: ${hashPath drv}` to the ${cabalProjectFileName} file or passing in a sha256map argument"
                 drv);
        in {
          # Download the source-repository-package commit and add it to a minimal git
          # repository that `cabal` will be able to access from a non fixed output derivation.
          location = evalPackages.runCommand "source-repository-package" {
              nativeBuildInputs = [ evalPackages.rsync evalPackages.gitMinimal ];
            } ''
            mkdir $out
            rsync -a --prune-empty-dirs --chmod=u+w "${fetched}/" "$out/"
            cd $out
            git init -b minimal
            git add --force .
            GIT_COMMITTER_NAME='No One' GIT_COMMITTER_EMAIL= git commit -m "Minimal Repo For Haskell.Nix" --author 'No One <>'
          '';
          inherit (repoData) subdirs;
          inherit fetched;
          tag = "minimal";
        };

      # Parse the `source-repository-package` blocks
      sourceRepoPackageResult = pkgs.haskell-nix.haskellLib.parseSourceRepositoryPackages
        cabalProjectFileName sha256map source-repo-override projectFile;

      sourceRepoFixedProjectFile =
        sourceRepoPackageResult.initialText +
        pkgs.lib.strings.concatMapStrings (block:
            if block ? sourceRepo
              then
                let
                  f = fetchPackageRepo evalPackages.fetchgit block.sourceRepo;
                in ''

                  ${block.indentation}source-repository-package
                  ${block.indentation}  type: git
                  ${block.indentation}  location: file://${f.location}
                  ${block.indentation}  subdir: ${builtins.concatStringsSep " " f.subdirs}
                  ${block.indentation}  tag: ${f.tag}
                '' + block.followingText
              else block.followingText
          ) sourceRepoPackageResult.sourceRepos;

      # we need the repository content twice:
      # * at eval time (below to build the fixed project file)
      #   Here we want to use evalPackages.fetchgit, so one can calculate
      #   the build plan for any target without a remote builder
      # * at built time  (passed out)
      #   Here we want to use plain pkgs.fetchgit, which is what a builder
      #   on the target system would use, so that the derivation is unaffected
      #   and, say, a linux release build job can identify the derivation
      #   as built by a darwin builder, and fetch it from a cache
      sourceReposEval = builtins.map (x: (fetchPackageRepo evalPackages.fetchgit x.sourceRepo)) sourceRepoPackageResult.sourceRepos;
      sourceReposBuild = builtins.map (x: (fetchPackageRepo pkgs.fetchgit x.sourceRepo).fetched) sourceRepoPackageResult.sourceRepos;

      # Parse the `repository` blocks
      repoResult = pkgs.haskell-nix.haskellLib.parseRepositories
        evalPackages cabalProjectFileName sha256map inputMap nix-tools sourceRepoFixedProjectFile;
    in {
      sourceRepos = sourceReposBuild;
      inherit (repoResult) repos extra-hackages;
      # The input text with every `source-repository-package` block
      # rewritten to a `file://` minimal git repo in the store.  Only
      # `plan-to-nix` consumed this before (via `makeFixedProjectFile`);
      # `fixedCabalProjectLocal` below hands the same rewrite to the v2
      # shell, which writes the text out for the *user's* cabal to read.
      fixedProjectFile = sourceRepoFixedProjectFile;
      makeFixedProjectFile = ''
        HOME=$(mktemp -d)
        cp -f ${evalPackages.writeText "cabal.project" sourceRepoFixedProjectFile} ./cabal.project
        chmod +w -R ./cabal.project
      '' + pkgs.lib.strings.concatStrings (
            map (f: ''
              git config --global --add safe.directory ${f.location}/.git
            '') sourceReposEval
          );
      # This will be used to replace refernces to the minimal git repos with just the index
      # of the repo.  The index will be used in lib/import-and-filter-project.nix to
      # lookup the correct repository in `sourceReposBuild`.  This avoids having
      # `/nix/store` paths in the `plan-nix` output so that it can  be materialized safely.
      replaceLocations = pkgs.lib.strings.concatStrings (
            pkgs.lib.lists.zipListsWith (n: f: ''
              (cd $out${subDir'}
              substituteInPlace $tmp${subDir'}/dist-newstyle/cache/plan.json --replace file://${f.location} ${builtins.toString n}
              for a in $(grep -rl file://${f.location} .plan.nix/*.nix); do
                substituteInPlace $a --replace file://${f.location} ${builtins.toString n}
              done)
            '')
              (pkgs.lib.lists.range 0 ((builtins.length sourceReposEval) - 1))
              sourceReposEval
          );
    };

  # `cabalProjectRewrite` (identity by default) is a `text -> text` hook set by
  # project modules that need to transform the assembled cabal.project before
  # plan-to-nix — e.g. `modules/replace-hackage-tarball-urls.nix`, which
  # rewrites direct Hackage tarball URLs to local eval-platform store paths.
  fixedProject = replaceSourceRepos
    ((args.cabalProjectRewrite or (p: p)) rawCabalProject);

  # `cabalProjectLocal` alone, with the same `source-repository-package`
  # rewrite `fixedProject` applies to the whole project.
  #
  # The v2 shell writes the project's `cabalProjectLocal` out as
  # `cabal.project.local` (`cabal.project.<targetPrefix>local` when
  # cross) so that a plain `cabal build` in the shell sees the same
  # project settings the slices were built with.  Handing it the *raw*
  # text hands the user `location: https://github.com/...` blocks, and
  # cabal then clones them over the network on the first
  # `cabal build` -- which fails outright inside a nix build (no network:
  # `fatal: unable to access ...: SSL certificate ... unable to get local
  # issuer certificate`, tests/cabal-sublib-shell) and, in an interactive
  # shell, silently re-fetches sources haskell.nix has already fetched.
  # Worse, a `tag:` naming a branch (the boot-package injection's
  # `tag: stable-haskell/master`) is not even pinned, so the user can get
  # different sources than the slices were built from.
  #
  # Rewriting through `replaceSourceRepos` points every block at the
  # minimal git repo in the store that `plan-to-nix` already used, so
  # the clone is local and resolves to exactly the sources the plan was
  # computed from.  The rewrite is by-content, so these are the *same*
  # derivations `fixedProject` builds -- no extra work.
  fixedCabalProjectLocal =
    if cabalProjectLocal == null || cabalProjectLocal == ""
      then cabalProjectLocal
      else (replaceSourceRepos cabalProjectLocal).fixedProjectFile;

  platformString = p: with p.parsed; "${cpu.name}-${vendor.name}-${kernel.name}";

  # Build the dummy `ghc` + `ghc-pkg` pair that `make-install-plan` runs
  # against during plan-to-nix.  Parameterised over the pkgs level and the
  # compiler so the same machinery synthesises BOTH the project's target
  # pair AND (for the stable-haskell cabal fork's cross "stage" system) a
  # *build*-platform pair — see `withBuildCompiler` / `dummy-build-ghc` below.
  # The dummy `ghc`/`ghc-pkg` pair lives in lib/dummy-ghc.nix so it can also be
  # a plain passthru on each per-eval-system compiler variant
  # (`ghc.evalWith.${evalSystem}.dummyGhcPkgs`, overlays/stable-haskell.nix).
  # Interface here is unchanged (`{ pkgs, ghc }`), closing over `evalPackages` +
  # `prebuilt-depends`.
  mkDummyGhcPkg = { pkgs, ghc }:
    import ./dummy-ghc.nix { inherit pkgs ghc evalPackages prebuilt-depends; };

  # The project's own (target) dummy pair.  `ghc` is already the compiler
  # variant selected for this project's eval platform (`compilerSelection` →
  # `evalWith.${evalSystem}`), so its plain `dummyGhcPkgs` passthru (attached
  # inside overlays/stable-haskell.nix / the hadrian compiler) is the memoised
  # pair for this (compiler, evalSystem) — repeated cabalProjects sharing a
  # compiler reuse it instead of re-deriving it here.  Fall back to inline
  # construction when the compiler carries none (e.g. a custom ghc) or the
  # project adds `prebuilt-depends` (which the memoised, prebuilt-depends-free
  # dummy deliberately omits).
  # The `-w` dummy shapes how cabal resolves the plan's `arch()`/`os()`
  # conditionals and which boot packages it treats as pre-installed.
  #
  # `ghc` above is `compilerSelection pkgs.buildPackages`, i.e.
  # `final.buildPackages.buildPackages`, whose targetPlatform collapses back to
  # the native BUILD platform — so `ghc.dummyGhcPkgs` reports the build host.
  # For a NATIVE plan that's correct.  But for a STABLE-HASKELL CROSS plan the
  # `-w` dummy must report the TARGET platform (else cabal resolves every
  # conditional for the build host — e.g. ghcjs `rts` pulling in the
  # darwin-only `libffi-clib`, every `arch(javascript)`/`os(ghcjs)` guard
  # silently false) and present an EMPTY global package db (so the plan builds
  # rts/base/… from source, as the fork's boot-package injection expects).
  #
  # `pkgs` here IS `final.buildPackages`, whose targetPlatform is the cross
  # target, so a dummy built from it reports the right platform.  We can't take
  # the real cross compiler (accessing `pkgs.haskell-nix.compiler` target-hosted
  # throws "build ghcjs with ghcjs"), and don't need to: only its
  # `emptyGlobalPackageDb` flag matters to the dummy's `ghc-pkg dump`, so reuse
  # the build compiler `ghc` with that flag set.
  #
  # Gated on the fork: a MAINLINE compiler's cross plan needs the OPPOSITE — a
  # NON-empty dump so boot libs stay pre-existing (single-stage cross can't
  # build rts/base from source).  Mainline compilers carry no `dummyGhcPkgs`
  # memoisation (fork-only passthru), so they fall through to the fresh
  # `mkDummyGhcPkg { inherit pkgs ghc; }` — target platform, non-empty dump —
  # exactly the pre-fork behaviour.
  inherit (
    let memoised = ghc.dummyGhcPkgs or null;
    in if (ghc.isStableHaskell or false)
          && pkgs.stdenv.targetPlatform != pkgs.stdenv.hostPlatform
       then mkDummyGhcPkg {
              inherit pkgs;
              ghc = ghc // { emptyGlobalPackageDb = true; };
            }
       else if prebuilt-depends == [] && memoised != null
       then memoised
       else mkDummyGhcPkg { inherit pkgs ghc; }
  ) dummy-ghc dummy-ghc-pkg;

  # A dummy pair instantiated for the BUILD platform (pkgs.buildPackages,
  # whose targetPlatform is the build platform) and the build-platform
  # compiler of the same name.  `ghc --info` then reports the build (native)
  # platform and `ghc-pkg dump --global` lists the build boot libraries
  # (esp. ghc-internal) as installed.  This satisfies the fork's
  # `build:any.ghc-internal installed` constraint AND is the cross cycle
  # break: build-tool-depends (e.g. hsc2hs) resolve in the build scope and
  # reuse the *installed* build-stage process/base instead of rebuilding
  # them from source, so the Windows process -> Win32 edge never forms.
  # Referenced only when the project sets `withBuildCompiler` (so a normal
  # project never forces the build-platform compiler's source).
  buildDummyGhcPkg = mkDummyGhcPkg {
    pkgs = pkgs.buildPackages;
    ghc = (compilerSelection pkgs.buildPackages)."${compiler-nix-name}";
  };
  dummy-build-ghc = buildDummyGhcPkg.dummy-ghc;
  dummy-build-ghc-pkg = buildDummyGhcPkg.dummy-ghc-pkg;

  # A `.cabal` directory as it would have been at `cached-index-state`,
  # carrying a PREPOPULATED (offline) hackage index plus any extra hackage
  # repos the project declares.  `make-install-plan` runs against it below,
  # and it is re-exported (`dotCabalDir`) so consumers that have to solve
  # without network access can point cabal at the very same index the plan
  # was computed from -- notably the v2 shell tests, whose sandbox has no
  # `~/.cabal` and whose compiler ships an empty global package db, leaving
  # the solver with no way to resolve boot deps such as `unix`.
  # We may include some packages that will be excluded by `index-state-max`,
  # which is what cabal uses (cached-index-state >= index-state-max).
  dotCabalDir = dotCabal {
    inherit nix-tools extra-hackage-tarballs prepopulateHackageIndex;
    extra-hackage-repos = fixedProject.repos;
    index-state = cached-index-state;
    sha256 = index-sha256-found;
  };

  plan-json = materialize ({
    inherit materialized;
    sha256 = plan-sha256;
    sha256Arg = "plan-sha256";
    this = "project.plan-json" + (if name != null then " for ${name}" else "");
  } // pkgs.lib.optionalAttrs (checkMaterialization != null) {
    inherit checkMaterialization;
  }) (evalPackages.runCommand (nameAndSuffix "plan-to-nix-pkgs") {
    nativeBuildInputs =
      # The things needed from nix-tools
      [ nix-tools.exes.make-install-plan
        nix-tools.exes.plan-to-nix
        nix-tools.exes.cabal
      ]
      ++ pkgs.lib.optional supportHpack nix-tools.exes.hpack
      ++ [dummy-ghc dummy-ghc-pkg evalPackages.rsync evalPackages.gitMinimal evalPackages.allPkgConfigWrapper ]
      # The stable-haskell cabal fork configures a C toolchain during plan
      # elaboration (its cross "stage" system) and does `requireProgram gcc`,
      # but haskell.nix plans against a dummy GHC and never put a C compiler on
      # PATH.  Provide a `gcc` that execs the build `cc` so the probe succeeds.
      # The C-compiler identity is not part of pkgHashConfigInputs (cabal-install
      # PackageHash.hs hashes compiler-id/platform/program-args, not cc), so this
      # does not shift UnitIds.
      # Gated on the fork (v2 projects and stable-haskell compilers, the ones
      # modules/cabal-project.nix gives it): adding it unconditionally puts
      # an extra input derivation on EVERY project's plan-nix, so no plan-nix
      # built before this change could be substituted for any compiler.
      ++ pkgs.lib.optionals ((args.builderVersion or 1) == 2 || (ghc.isStableHaskell or false))
           [ (evalPackages.writeShellScriptBin "gcc" ''exec ${evalPackages.stdenv.cc}/bin/cc "$@"'') ]
      # The build-platform dummy pair for the fork's cross stage system.
      # Appended AFTER the target dummy-ghc/dummy-ghc-pkg so the target pair
      # still wins on PATH for `-w ghc` (earlier nativeBuildInputs entries take
      # PATH precedence); the build pair is referenced by full store path in
      # --with-build-compiler / --with-build-hc-pkg below.
      ++ pkgs.lib.optionals withBuildCompiler [ dummy-build-ghc dummy-build-ghc-pkg ];
    # Needed or stack-to-nix will die on unicode inputs
    LOCALE_ARCHIVE = pkgs.lib.optionalString (evalPackages.stdenv.buildPlatform.libc == "glibc") "${evalPackages.glibcLocales}/lib/locale/locale-archive";
    LANG = "en_US.UTF-8";
    # Pin the unit-id format that `make-install-plan`'s patched
    # cabal uses to the *build* platform's OS.  Without this the
    # format tracks the eval system (which on a Darwin host
    # evaluating a Linux derivation gives the `VeryShort` form),
    # and plan-nix unit-ids fork from what slice cabal v2-build
    # computes on Linux.  See
    # nix-tools/cabal-install-patches/installed-package-id-os-override.patch.
    CABAL_INSTALLED_PACKAGE_ID_OS = pkgs.stdenv.buildPlatform.parsed.kernel.name;
    meta.platforms = pkgs.lib.platforms.all;
    preferLocalBuild = false;
    outputs = [
      "out"           # The results of plan-to-nix
      # These two output will be present if in cabal configure failed.
      # They are used to provide passthru.json and passthru.freeze that
      # check first for cabal configure failure.
      "freeze"  # The `cabal.project.freeze` file created by `cabal v2-freeze`
    ];
  } ''
    tmp=$(mktemp -d)
    cd $tmp
    # if cleanedSource is empty, this means it's a new
    # project where the files haven't been added to the git
    # repo yet. We fail early and provide a useful error
    # message to prevent headaches (#290).
    if [ -z "$(ls -A ${cleanedSource})" ]; then
      echo "cleaned source is empty. Did you forget to 'git add -A'?"
      ${pkgs.lib.optionalString (__length fixedProject.sourceRepos == 0) ''
        exit 1
      ''}
    else
      rsync -a --chmod=u+w ${cleanedSource}/ ./
    fi
    # Decide what to do for each `package.yaml` file.
    for hpackFile in $(find . -name package.yaml); do (
      # Look to see if a `.cabal` file exists
      shopt -u nullglob
      for cabalFile in $(dirname $hpackFile)/*.cabal; do
        if [ -e "$cabalFile" ]; then
          echo Ignoring $hpackFile as $cabalFile exists
        else
          ${
          # warning: this may not generate the proper cabal file.
          # hpack allows globbing, and turns that into module lists
          # without the source available (we cleanSourceWith'd it),
          # this may not produce the right result.
          if supportHpack
            then '' 
              echo No .cabal file found, running hpack on $hpackFile
              hpack $hpackFile
            ''
            else ''
              echo "WARNING $hpackFile has no .cabal file and \`supportHpack\` was not set."
            ''
          }
        fi
      done
      )
    done
    ${pkgs.lib.optionalString (subDir != "") "cd ${subDir}"}
    ${fixedProject.makeFixedProjectFile}
    ${pkgs.lib.optionalString (cabalProjectFreeze != null) ''
      cp ${evalPackages.writeText "cabal.project.freeze" cabalProjectFreeze} \
        cabal.project.freeze
      chmod +w cabal.project.freeze
    ''}
    export SSL_CERT_FILE=${evalPackages.cacert}/etc/ssl/certs/ca-bundle.crt
    export GIT_SSL_CAINFO=${evalPackages.cacert}/etc/ssl/certs/ca-bundle.crt

    export CABAL_DIR=${dotCabalDir}

    make-install-plan ${
          # Setting the desired `index-state` here in case it is not
          # in the cabal.project file. This will further restrict the
          # packages used by the solver (cached-index-state >= index-state-max).
          # Cabal treats `--index-state` > the last known package as an error,
          # so we only include this if it is < cached-index-state.
          pkgs.lib.optionalString (prepopulateHackageIndex && index-state != null && index-state < cached-index-state) "--index-state=${index-state}"
        } \
        -w ${
          # We are using `-w` rather than `--with-ghc` here to override
          # the `with-compiler:` in the `cabal.project` file.
          ghc.targetPrefix}ghc \
        --with-ghc-pkg=${ghc.targetPrefix}ghc-pkg${
          # Appended to the line above rather than written on a line of its own:
          # an `optionalString` that occupies a line still emits that line's
          # indentation and trailing `\` when it yields "", which changes this
          # buildCommand — and hence every project's plan-nix hash — in the
          # (overwhelmingly common) case where there is no build compiler.
          pkgs.lib.optionalString withBuildCompiler
            " --with-build-compiler=${dummy-build-ghc}/bin/ghc --with-build-hc-pkg=${dummy-build-ghc-pkg}/bin/ghc-pkg"} \
        --enable-tests \
        --enable-benchmarks \
        ${pkgs.lib.optionalString (ghc.targetPrefix == "js-unknown-ghcjs-")
            "--ghcjs --with-ghcjs=js-unknown-ghcjs-ghc --with-ghcjs-pkg=js-unknown-ghcjs-ghc-pkg"} \
        ${configureArgs}

    mkdir -p $out

    cp cabal.project.freeze $freeze
    # Not needed any more (we don't want it to wind up in the $out hash)
    rm cabal.project.freeze

    # ensure we have all our .cabal files (also those generated from package.yaml) files.
    # otherwise we'd need to be careful about putting the `cabal-generator = hpack` into
    # the nix expression.  As we already called `hpack` on all `package.yaml` files we can
    # skip that step and just package the .cabal files up as well.
    #
    # This is also important as `plan-to-nix` will look for the .cabal files when generating
    # the relevant `pkgs.nix` file with the local .cabal expressions.
    rsync -a --prune-empty-dirs --chmod=u+w \
          --include '*/' --include '*.cabal' --include 'package.yaml' \
          --exclude '*' \
          $tmp/ $out/

    # Make sure the subDir' exists even if it did not contain any cabal files
    mkdir -p $out${subDir'}

    # make sure the path's in the plan.json are relative to $out instead of $tmp
    # this is necessary so that plan-to-nix relative path logic can work.
    substituteInPlace $tmp${subDir'}/dist-newstyle/cache/plan.json --replace "$tmp" "$out"

    # run `plan-to-nix` in $out.  This should produce files right there with the
    # proper relative paths.
    (cd $out${subDir'} && plan-to-nix --full ${if ignorePackageYaml then "--ignore-package-yaml" else ""} --plan-json $tmp${subDir'}/dist-newstyle/cache/plan.json -o .)

    substituteInPlace $tmp${subDir'}/dist-newstyle/cache/plan.json --replace "$out" "."
    substituteInPlace $tmp${subDir'}/dist-newstyle/cache/plan.json --replace "$CABAL_DIR" ""

    # Replace the /nix/store paths to minimal git repos with indexes (that will work with materialization).
    ${fixedProject.replaceLocations}

    # Remove the non nix files ".project" ".cabal" "package.yaml" files
    # as they should not be in the output hash (they may change slightly
    # without affecting the nix).
    find $out \( -type f -or -type l \) ! -name '*.nix' -delete

    # Make the plan.json file available in case we need to debug plan-to-nix
    cp $tmp${subDir'}/dist-newstyle/cache/plan.json $out

    # Make the revised cabal files available (after the delete step avove)
    echo "Moving cabal files from $tmp${subDir'}/dist-newstyle/cabal-files to $out${subDir'}/cabal-files"
    mv $tmp${subDir'}/dist-newstyle/cabal-files $out${subDir'}/cabal-files

    # Remove empty dirs
    find $out -type d -empty -delete

    # move pkgs.nix to default.nix ensure we can just nix `import` the result.
    mv $out${subDir'}/pkgs.nix $out${subDir'}/default.nix
  '');
in {
  projectNix = plan-json;
  inherit index-state-max src;
  inherit (fixedProject) sourceRepos extra-hackages;
  inherit fixedCabalProjectLocal;
  inherit dotCabalDir;
  # Zero-length string carrying context from rawCabalProject.
  # Used in load-cabal-plan.nix to add context to URLs referencing store paths
  # without using builtins.appendContext (which fails for non-local paths).
  rawCabalProjectContext = builtins.substring 0 0 rawCabalProject;
}
