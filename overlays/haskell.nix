{ sources }:
# The haskell.nix infrastructure
#
# for hygienic reasons we'll use haskell-nix as a prefix.
# Using haskell.nix in nix is awkward as I needs to be quoted.
final: prev: {
    haskell-nix = with final.haskell-nix; {

        # Default modules, these will always be included.
        # They are here to be overridden/added to by other
        # overlays.
        defaultModules = prev.haskell-nix.defaultModules or [];

        # Additional user-provided mappings to augment ./../lib/pkgconf-nixpkgs-map.nix
        extraPkgconfigMappings = prev.haskell-nix.extraPkgconfigMappings or {};
        # Nix Flake based source pins.
        # To update all inputs, get unstable Nix and then `nix flake update --recreate-lock-file`
        # Or `nix-shell -p nixVersions.latest --run "nix --experimental-features 'nix-command flakes' flake update --recreate-lock-file"`
        sources = sources;

        # We provide a `callPackage` function to consumers for
        # convenience.  We will however refrain from using it
        # here and be explicit about imports and dependencies.
        callPackage = prev.lib.callPackageWith (final // final.haskell-nix);

        # The systems on which plan-to-nix / IFD ("eval") derivations may
        # run.  A project selects one via its `evalSystem` option; the
        # eval-side artifacts (nixpkgs, dummy-ghc, configured-src, …) are
        # memoised per entry so every project sharing an `evalSystem`
        # reuses one instance instead of re-deriving it per `cabalProject`.
        eval-systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

        # `requiredSystemFeatures` for the checks (`haskellLib.check`) whose
        # test exes cannot run on an emulated builder; see
        # `emulatorNativeBuilderCheck` below for which ones those are.
        #
        # Empty by default: this is build-farm policy, and requiring a
        # feature the user's nix does not advertise would make these
        # derivations unbuildable.  A farm that mixes real hosts with
        # emulated ones opts in with an overlay that names a feature only
        # its real hosts advertise.  haskell.nix's own CI (`ci.nix`) sets
        # `[ "recursive-nix" ]`: not what these builds do, but a marker of
        # convenience -- the zw3rk Hydra withholds it from the darwin
        # hosts' linux `buildMachines` entries (the external derivation
        # builder cannot implement it) while the one real linux host
        # advertises it, so requiring it lands these checks exactly where
        # their exes run.
        #
        # This used to pin much more: Template Haskell slices for hosts
        # whose splices run through an emulator, a deny-list of packages
        # (`base`, `th-orphans`), the native stage-2 GHC library, and
        # Android ARM32 checks.  On 2026-10-24 all of those were built on
        # the `nix-linux-builder` VMs instead and passed (th-dlls,
        # js-template-haskell and with-packages for aarch64 glibc/musl,
        # i686, mingw/ucrt and armv7a, plus the armv7a test exes, which
        # qemu's PER_LINUX32 fallback from #2585 now runs).  What still
        # fails there is a transient deadlock of the x86_64 cross ghc
        # under Rosetta (all threads parked in `futex_lock_pi`); it hits
        # ghc-internal and unix as often as base, so no package pin avoids
        # it, and a retry builds.
        emulatorSystemFeatures = prev.haskell-nix.emulatorSystemFeatures or [];

        # Every check for a host platform matching this predicate is
        # pinned.  32-bit x86 Linux (musl32) is the one that needs it: the
        # test exe itself runs, but under Rosetta in a `nix-linux-builder`
        # VM an i686 ELF that it spawns directly cannot be executed at all
        #   check-datadir-tool: readCreateProcess: posix_spawnp: invalid
        #   argument (Exec format error)
        # (every attempt, on three VMs, in eval 3029), while the same check
        # passes on a real x86_64 host.
        emulatorNativeBuilderCheck =
          prev.haskell-nix.emulatorNativeBuilderCheck
            or (platform: platform.isLinux && platform.isx86_32);

        # nixpkgs used to run `cabal` / `nix-tools`, keyed by eval system
        # and memoised at the fixpoint level.  Non-native systems are
        # imported lazily from the same nixpkgs path and overlays; the
        # native `pkgsBuildBuild` system is always overlaid on top so it
        # reuses the already-instantiated `pkgsBuildBuild` (no second
        # import) AND is present even when it is not in `eval-systems`
        # (future-proofing new host systems).  `genAttrs` is lazy, so the
        # fresh-import thunk for the native key is created but never forced.
        # Replaces the inline construction the `evalPackages` project option
        # used to do (modules/project-common.nix), as a single shared
        # attribute rather than one rebuilt per project.
        evalPackages =
          final.lib.genAttrs eval-systems (evalSystem:
            import final.path { system = evalSystem; overlays = final.overlays; })
          // { ${final.pkgsBuildBuild.stdenv.hostPlatform.system} = final.pkgsBuildBuild; };

        # ghc hackage patches.
        # these are patches that turn hackage packages into the same as the ones
        # ghc ships with the supposedly same version. See GHC Track Issue: 16199
        ghcHackagePatches = import ../patches;

        compat = import ../lib/compat.nix;

        # Utility function for downloading a pinned git repo, that can be
        # overridden with NIX_PATH.
        fetchExternal = import ../lib/fetch-external.nix;

        # Functions for cleaning Haskell source directories.
        inherit (import ../lib/clean-source-haskell.nix { inherit (final) lib; })
          haskellSourceFilter
          cleanSourceHaskell;

        # All packages from Hackage as Nix expressions
        hackageSrc = sources.hackage;
        # The only stack projects need hackage.nix now
        hackageForStack = import sources.hackage-for-stackage;

        # Fetch a specific Hackage package version straight from Hackage using
        # the sha256 recorded in hackage.nix (the `for-stackage` db) and unpack
        # it into a source directory.  Unlike `hackage-package`, this bypasses
        # the cabal solver and the project `index-state`, so it can supply an
        # exact version that is newer than a project's pinned index-state — e.g.
        # a GHC boot library that upstream pins via a direct
        # `https://hackage.haskell.org/package/NAME-VER/NAME-VER.tar.gz` URL in
        # its cabal.project.  Used by the `replace-hackage-tarball-urls` project
        # option (see lib/call-cabal-project-to-nix.nix).  The result is a
        # directory suitable for a cabal.project `packages:` entry.
        hackageTarball = { name, version, evalPackages ? final.buildPackages }:
          let
            versions = hackageForStack.${name}
              or (throw "hackageTarball: package '${name}' is not in hackage.nix");
            entry = versions.${version}
              or (throw "hackageTarball: '${name}-${version}' is not in hackage.nix");
          in evalPackages.runCommand "${name}-${version}-src" { } ''
            mkdir -p "$out"
            tar -xzf ${evalPackages.fetchurl {
              name = "${name}-${version}.tar.gz";
              url = "mirror://hackage/${name}-${version}.tar.gz";
              inherit (entry) sha256;
            }} --strip-components=1 -C "$out"
          '';

        # Contains the hashes of the cabal 01-index.tar.gz for given
        # index states.  Starting from April 1st 2019.
        indexStateHashesPath = hackageSrc + "/index-state-hashes.nix";

        # The set of all Stackage snapshots
        stackageSrc = sources.stackage;
        stackage = import stackageSrc;

        # Utility functions for working with the component builder.
        haskellLib = let hl = import ../lib {
            pkgs = final;
            inherit (final) stdenv lib srcOnly;
            haskellLib = hl;
        }; in hl;

        # Create a Haskell package set based on a cabal build plan (plan-to-nix)
        # and Nix expressions representing cabal packages (cabal-to-nix).
        mkPkgSet =
            { pkg-def  # Base package set. Either from stackage (via stack-to-nix) or from a cabal projects plan file (via plan-to-nix)
            , pkg-def-extras ? [] # Additional packages to augment the Base package set `pkg-def` with.
            , modules ? []
            , extra-hackages ? [] # Extra Hackage repositories to use besides main one.
            , hackage
            }@args:

            let
              hackageAll = builtins.foldl' final.lib.recursiveUpdate hackage extra-hackages;
            in

            import ../package-set.nix {
                inherit (args) pkg-def pkg-def-extras;
                modules = defaultModules ++ modules;
                pkgs = final;
                hackage = hackageAll;
            };

        # Some boot packages (libiserv) are in lts, but not in hackage,
        # so we should not try to get it from hackage based on the stackage
        # info.  Instead we can add ghc-boot-packages to `pkg-def-extras`.
        # The compiler-nix-name allows non default values (like
        # "ghc8102-experimental").
        excludeBootPackages = compiler-nix-name: pkg-def: hackage:
          let original = pkg-def hackage;
              bootPkgNames = final.lib.attrNames
                final.ghc-boot-packages.${
                  if compiler-nix-name != null
                    then compiler-nix-name
                    else (pkg-def hackage).compiler.nix-name};
          in original // {
            packages = final.lib.filterAttrs (n: _: final.lib.all (b: n != b) bootPkgNames)
              original.packages;
          };

        # Create a Haskell package set based on a Stack configuration.
        mkStackPkgSet =
            { stack-pkgs  # Path to the output of stack-to-nix
            , pkg-def-extras ? []
            , modules ? []
            }:
            let
                # The Stackage release referenced in the stack config
                pkg-def = stackage.${stack-pkgs.resolver} or (throw ''
                This version of stackage.nix does not know about the Stackage resolver ${stack-pkgs.resolver}.
                You may need to update haskell.nix to one that includes a newer stackage.nix.
                '');
                # The compiler referenced in the stack config
                compiler = (stack-pkgs.extras hackageForStack).compiler or (pkg-def hackageForStack).compiler;
                patchesModule = ghcHackagePatches.${compiler.nix-name} or {};
                # Remove fake packages generated from stack keywords used in ghc-options
                removeStackSpecial = module: if builtins.typeOf module == "set"
                  then module // { packages = removeSpecialPackages (module.packages or {}); }
                  else module;
                removeSpecialPackages = ps: removeAttrs ps [ "$locals" "$targets" "$everything" ];
            in mkPkgSet {
                pkg-def = excludeBootPackages compiler.nix-name pkg-def;
                pkg-def-extras = [ stack-pkgs.extras
                                   final.ghc-boot-packages.${compiler.nix-name}
                                 ]
                              ++ pkg-def-extras;
                # set doExactConfig = true. The stackage set should be consistent
                # and we should trust stackage here!
                modules = [ { doExactConfig = true; } patchesModule ]
                       ++ modules
                       ++ map removeStackSpecial (stack-pkgs.modules or []);
                hackage = hackageForStack;
            };

        # Create a Haskell package set based on a Cabal configuration.
        mkCabalProjectPkgSet =
            { plan-pkgs  # Path to the output of plan-to-nix
            , pkg-def-extras ? []
            , modules ? []
            , extra-hackages ? []
            , compiler-nix-name ? null
            , compilerSelection ? p: p.haskell-nix.compiler
            }:

            let
                compiler-nix-name' =
                  if compiler-nix-name != null
                    then compiler-nix-name
                    else ((plan-pkgs.extras hackage).compiler or (plan-pkgs.pkgs hackage).compiler).nix-name;
                pkg-def = excludeBootPackages compiler-nix-name plan-pkgs.pkgs;
                patchesModule = ghcHackagePatches.${compiler-nix-name'} or {};
                package.compiler-nix-name.version = (compilerSelection final.buildPackages).${compiler-nix-name'}.version;
                withMsg = final.lib.assertMsg;
            in
              mkPkgSet {
                inherit pkg-def;
                pkg-def-extras = [ plan-pkgs.extras ]
                             ++ pkg-def-extras;
                # set doExactConfig = true, as we trust cabals resolution for
                # the plan.
                modules = [ { doExactConfig = true; } patchesModule ]
                       ++ modules
                       ++ plan-pkgs.modules or [];
                inherit extra-hackages;
                hackage = {};
            };

        # Package sets for all stackage snapshots.
        snapshots = import ../snapshots.nix {
          inherit (final) lib ghc-boot-packages;
          inherit mkPkgSet stackage excludeBootPackages;
          hackage = hackageForStack;
        };
        # Pick the most recent LTS snapshot to be our "default" package set.
        haskellPackages =
          let
            versions = final.lib.mapAttrsToList
              (name: _: final.lib.removePrefix "lts-" name) snapshots;
          in snapshots."lts-${final.lib.head (final.lib.sort final.lib.versionAtLeast versions)}";

        # Creates Cabal local repository from { name, index } set.
        mkLocalHackageRepo = import ../mk-local-hackage-repo final;

        # Dummy version of ghc to work around https://github.com/haskell/cabal/issues/8352
        cabal-issue-8352-workaround = [
          (final.writeTextFile {
            name = "dummy-ghc";
            executable = true;
            destination = "/bin/ghc";
            text = ''
              #!${final.runtimeShell}
              case "$*" in
                --version*)
                  echo 'The Glorious Glasgow Haskell Compilation System, version 8.10.7'
                  ;;
                --numeric-version*)
                  echo '8.10.7'
                  ;;
                --supported-languages*)
                  echo Haskell2010
                  ;;
                --info*)
                  echo '[]'
                  ;;
                *)
                  echo "Unknown argument '$*'" >&2
                  exit 1
                  ;;
              esac
              exit 0
            '';
          })
          (final.writeTextFile {
            name = "dummy-ghc";
            executable = true;
            destination = "/bin/ghc-pkg";
            text = ''
              #!${final.runtimeShell}
              case "$*" in
                --version*)
                  echo 'GHC package manager version 8.10.7'
                  ;;
                *)
                  echo "Unknown argument '$*'" >&2
                  exit 1
                  ;;
              esac
              exit 0
            '';
          })
        ];

        dotCabal = { index-state, sha256, extra-hackage-tarballs ? {}, extra-hackage-repos ? {}, nix-tools, prepopulateHackageIndex ? true, ... }:
            let
              # NOTE: root-keys: aaa is because key-threshold: 0 does not seem to be enough by itself
              bootstrapIndexTarball = name: index: final.runCommand "cabal-bootstrap-index-tarball-${name}" {
                nativeBuildInputs = [ nix-tools.exes.cabal ] ++ cabal-issue-8352-workaround;
              } ''
                HOME=$(mktemp -d)
                mkdir -p $HOME/.cabal/packages/${name}
                cat <<EOF > $HOME/.cabal/config
                repository ${name}
                  url: file:${mkLocalHackageRepo { inherit name index; }}
                  secure: True
                  root-keys: aaa
                  key-threshold: 0
                EOF
                cabal v2-update ${name}
                cp -r $HOME/.cabal/packages/${name} $out
                '';

              # An empty hackage index, for projects that resolve nothing from
              # hackage (`active-repositories: :none` with every package pinned
              # locally, e.g. the stable-haskell GHCs).  cabal parses the
              # prepopulated index at startup regardless of active-repositories,
              # so a full ~1.2 GB index costs seconds — minutes under emulation —
              # for zero benefit; an empty one loads instantly.  Selected by
              # `prepopulateHackageIndex = false`.
              # Produce a fixed output derivation from a moving target (hackage index tarball)
              fullHackageIndexTarball = final.fetchurl {
                  name = "01-index.tar.gz-at-${builtins.replaceStrings [ ":" ] [ "" ] index-state}";
                  url = "https://hackage.haskell.org/01-index.tar.gz";
                  downloadToTemp = true;
                  postFetch = "${nix-tools}/bin/truncate-index -o $out -i $downloadedFile -s ${index-state}";
                  outputHashAlgo = "sha256";
                  outputHash = sha256;
                };

              # A minimal hackage index, for projects that resolve nothing from
              # hackage (every dependency pinned locally, `active-repositories:
              # :none`).  cabal parses the prepopulated index on startup even
              # under :none, so a full index costs seconds (minutes under
              # emulation) for zero benefit.  cabal's index reader rejects a
              # literally empty tar ("short tar trailer"), so we truncate the
              # full index to an early index-state — a tiny but well-formed index
              # (~2 MB vs ~1.2 GB) that cabal loads instantly.  The truncation
              # input is the index FOD, whose store path is fixed by the
              # project's index-state and its (immutable) sha256, so the plan
              # does not recalculate when hackage.nix updates.  Selected by
              # `prepopulateHackageIndex = false`.
              emptyHackageIndexTarball = final.runCommand "minimal-01-index.tar.gz" {
                preferLocalBuild = true;
              } "${nix-tools}/bin/truncate-index -o $out -i ${fullHackageIndexTarball} -s 2008-01-01T00:00:00Z";

              bootstrapped-hackage-tarball =
                bootstrapIndexTarball "hackage.haskell.org"
                (if prepopulateHackageIndex then fullHackageIndexTarball else emptyHackageIndexTarball);

              bootstrapped-extra-hackage-tarballs = final.lib.mapAttrs bootstrapIndexTarball extra-hackage-tarballs;
            in
              # dotCabal creates a suitable CABAL_DIR for cabal to use to make an install plan.
              # This directory will need to include two things:
              #
              # 1) pre-downloaded and pre-bootstrapped repositories
              # 2) a configuration file
              #
              # NOTE: both steps need to be completed exactly as cabal would complete them. We won't
              # be able to alter CABAL_DIR at all after this since it will be stored in the nix store.
              # If these steps are not done properly, few things could go wrong, e.g.:
              #
              # - if cabal.config is missing cabal will try to write a default configuration file and
              #   fail with "Permission denied"
              # - if 01-index.tar.idx is missing cabal will fail to read the index and error out with
              #   "Could not read index. Did you call 'checkForUpdates'?"
              # - cabal will try to recreate 01-index.cache on the nix store and fail with "Permission
              #   denied"
              #
              # Let's examine the steps above one by one.
              #
              # Step 1) is typically the result of calling `cabal update`. Because Haskell.nix supports
              # different ways of including extra repositories, we need to divide this step into two
              # other steps.
              #
              # 1a) Download the index tarball (01-index.tar.gz) and the TUF matadata (mirrors.json,
              #     root.json, snapshot.json, timestamp.json)
              # 1b) Decompress the index tarball and create additional index/cache files (01-index.cache,
              #     01-index.tar, 01-index.tar.idx, 01-index.timestamp)
              #
              # dotCabal supports pre-populating a CABAL_DIR from two kind of repositories:
              #
              # - extra-hackage-repos
              # - extra-hackage-tarballs
              #
              # These repositories are in addititon to hackage, which is always prepopulated.
              #
              # NOTE: this might not be 100% correct since cabal can work without hackage being defined
              # in the global configuration at all. As a workaround, a project that does not want to use
              # hackage can use an explicit `active-repositories:` in the project configuration.
              # Haskell.nix will prepopulate hackage in CABAL_DIR but then cabal will not use it for
              # project planning.
              #
              # Let's examine how we deal with these repositories.
              #
              # - hackage: Hackage index tarball is downloaded and truncated from hackage.haskell.org.
              #   Since this is only the tarball, we need to add the TUF files and we need to bootstrap
              #   it (both part of bootstrapIndexTarball called above). Additionally, cabal will always
              #   include hackage when creating a default global configuration, so we need to add it to
              #   the global cabal config as well.
              #
              # - extra-hackage-repos: The repos are parsed from the project configuration but the user
              #   is responsible for downloading the whole repo (not only the tarball but also the TUF
              #   files). The downloaded repository still needs to be bootstrapped but it's done in
              #   ./lib/cabal-project-parser.nix, before we get here. We don't need to add these
              #   repositories in cabal.config since they are already present in the project configuration.
              #
              # - extra-hackage-tarballs: These are index tarballs the user is asking haskell.nix to
              #   "inject" into the project. They work in a similar way to hackage, since they also need
              #   TUF files, bootstrap and to be added in the cabal configuration.
              #
              #                        |           |                 | needs to be added |
              #                        | needs TUF | needs bootstrap | to cabal.config   |
              # -----------------------+-----------+-----------------+-------------------+
              # hackage                | yes       | yes             | yes               |
              # extra-hackage-repos    | no        | already done    | no                |
              # extra-hackage-tarballs | yes       | yes             | yes               |
              # -----------------------+-----------+-----------------+-------------------+
              #
              # Step 2) is writing the global cabal config. cabal writes a default global configuration
              # file at any invocation if it is missing. This is a simple step but there is one trick
              # we need to be aware and careful about. cabal populates CABAL_DIR with repositories obtained
              # from somewhere (the repository's url). What we are doing here is prepopulating CABAL_DIR
              # for cabal, we do not want to change where cabal thinks a repository is coming from.
              #
              # E.g. after prepopulating CABAL_DIR/packages/hackage.haskell.org from the nix path
              # /nix/store/ff4pn0yva7ndsrg2zshy8qxzlrfsr4cl-cabal-bootstrap-index-tarball-hackage.haskell.org/
              # the configuration we want to write is still
              #
              #   repository hackage.haskell.org
              #     url: http://hackage.haskell.org
              #     secure: True
              #
              # and not
              #
              #   repository hackage.haskell.org
              #     url: file:/nix/store/ff4pn0yva7ndsrg2zshy8qxzlrfsr4cl-cabal-bootstrap-index-tarball-hackage.haskell.org/
              #     secure: True
              #
              # Doing this correctly is important for few reasons:
              #
              # 1. cabal as called by haskell.nix will produce exactly the same install plan as cabal
              #    called outside of haskell.nix (other things equal, of course)
              # 2. The url of the repositories will be visible in the install plan. Having the correct
              #    urls there will allow us to know from where to fetch the packages tarballs at build
              #    time.
              # 3. We don't want to leak the nix path of the index into the derivation of the component
              #    builder since this will cause unnecessary recompilation. In other words, the recipe to
              #    compile a package has to only depend on its content, not on where the recipe is from
              #    or how it is obtained.
              #
              # Using the correct url for the repository is only possible if the url is well-known. Again
              # there is a difference in this regard among the different kind of repositories.
              #
              # - hackage: hackage's url is always well known.
              # - extra-hackage-repos: since the user is responsible for downloading these repositories,
              #   we don't really know where they are from, BUT, we also don't have to include them in
              #   cabal.config because the user has already included them in the project configuration.
              # - extra-hackage-tarballs: this is just a tarball passed to haskell.nix, we have no idea
              #   if the corresponding repository is published anywhere. The best we can do in this case
              #   is to form a url from the key of the extra-hackage-tarball and leave the user to decide.
              #   The user could use a key corresponding to a real reository domain or overwrite the
              #   packages source manually.
              #   E.g. passing
              #
              #     extra-hackage-tarballs = { extra-hackage-demo = ./01-index.tar.gz; };
              #
              #   will produce in cabal.config
              #
              #     repository extra-hackage-demo
              #       url: http://extra-hackage-demo/
              #       secure: True
              #
              #   and any package from that index will have a source url like
              #
              #   http://extra-hackage-demo/package/external-package-demo-0.1.0.0.tar.gz
              #
              #   If "extra-hackage-demo" is not a real domain, the user can correct those source urls
              #   while calling cabalProject
              #
              #   modules = [
              #     { packages.external-package-demo.src = demo-src; }
              #   ];
              #
              # In summary:
              #                        | well know url | what to do |
              # -----------------------+---------------+------------+
              # hackage                | yes           | use it     |
              # extra-hackage-repos    | no            | nothing    |
              # extra-hackage-tarballs | no            | workaround |
              # -----------------------+---------------+------------+
              #
              final.runCommand "dot-cabal" {
                nativeBuildInputs = [ nix-tools.exes.cabal (final.lndir or final.xorg.lndir) ] ++ cabal-issue-8352-workaround;
              } ''
                # prepopulate hackage
                mkdir -p $out/packages/hackage.haskell.org
                lndir ${bootstrapped-hackage-tarball} $out/packages/hackage.haskell.org
                # prepopulate extra-hackage-repos
                ${final.lib.concatStrings (final.lib.mapAttrsToList (name: repo: ''
                  mkdir -p $out/packages/${name}
                  lndir ${repo} $out/packages/${name}
                '') extra-hackage-repos)}
                # prepopulate extra-hackage-tarballs
                ${final.lib.concatStrings (final.lib.mapAttrsToList (name: repo: ''
                  mkdir -p $out/packages/${name}
                  lndir ${repo} $out/packages/${name}
                '') bootstrapped-extra-hackage-tarballs)}
                # Write global cabal config
                cat >$out/config <<EOF
                repository hackage.haskell.org
                  url: http://hackage.haskell.org/
                  secure: True
                ${final.lib.concatStrings (final.lib.mapAttrsToList (name: _repo: ''
                  repository ${name}
                    url: http://${name}/
                    secure: True
                '') bootstrapped-extra-hackage-tarballs)}
                EOF
              '';

        # Some of features of haskell.nix rely on using a hackage index
        # to calculate a build plan.  To maintain stability for caching and
        # to allow the outputs to be materialized we pin this value here.
        # If you want to update this value it important to check the
        # materializations.  Turn `checkMaterialization` on below and
        # check the CI results before turning it off again.
        internalHackageIndexState = builtins.head (builtins.attrNames (
          import (sources.hackage-internal + "/index-state.nix")));
        checkMaterialization = false; # This is the default. Use an overlay to set it to true and test all the materialized files

        # Helps materialize the output of derivations
        materialize = import ../lib/materialize.nix {
          pkgs = final.pkgsBuildBuild;
          inherit (final.pkgsBuildBuild) nix runCommand writeShellScript;
          inherit (final.haskell-nix) checkMaterialization;
        };

        update-index-state-hashes = import ../scripts/update-index-state-hashes.nix {
            inherit (final.haskell-nix) indexStateHashesPath;
            inherit (final) coreutils nix writeShellScriptBin stdenv lib curl;
            # Update scripts use the internal nix-tools (compiled with a fixed GHC version)
            nix-tools = final.haskell-nix.nix-tools-unchecked;
        };

        # Function to call stackToNix
        callStackToNix = import ../lib/call-stack-to-nix.nix;

        # given a source location call `cabal-to-nix` (from nix-tools) on it
        # to produce the nix representation of it.
        callCabalToNix = { name, src, cabal-file ? "${name}.cabal" }:
            final.buildPackages.pkgs.runCommand "${name}.nix" {
                # This function is only used when building stack projects (via mkCacheLine and mkCacheFile)
                # When building stack projects we use the unchecked nix-tools (compiled with a fixed GHC version)
                nativeBuildInputs = [ final.buildPackages.haskell-nix.nix-tools-unchecked ];

                LOCALE_ARCHIVE = final.lib.optionalString (final.stdenv.buildPlatform.libc == "glibc") "${final.buildPackages.glibcLocales}/lib/locale/locale-archive";
                LANG = "en_US.UTF-8";
                LC_ALL = "en_US.UTF-8";
            } ''
            cabal-to-nix "${src}" "${src}/${cabal-file}" > "$out"
            '';


        # Given a single cache entry:
        # { name = ...; url = ...; rev = ...; ref = ...; sha256 = ...; cabal-file = ...; type = ...; is-private = ...; }
        # compute a string that represents this cache entry:
        # "${url} ${rev} ${subdir} ${sha256} ${name} ${nix-expr}"
        #
        # This handles private repositories with the `is-private` argument
        # (with `builtins.fetchGit`), as well as handling stack-based projects
        # with the `type` argument.
        mkCacheLine = { name, url, rev, ref ? null, subdir ? ".", sha256 ? null, cabal-file ? "${name}.cabal", type ? "cabal", is-private ? false, input ? null }:
          let
            # Fetch the entire repo, using either pkgs.fetchgit or
            # builtins.fetchGit depending on whether the repo is private.
            # When the repo was resolved via `inputMap`
            # (see `lib/stack-cache-generator.nix`) use the mapped local
            # path / flake input directly instead of fetching it.
            entireRepo =
              if input != null
              then input
              else if is-private
              then
                # It doesn't make sense to specify sha256 on a private repo
                # because it is not used by buitins.fetchGit.
                assert isNull sha256;
                builtins.fetchGit
                  ({ inherit url rev; } //
                      final.buildPackages.lib.optionalAttrs (ref != null) { inherit ref; }
                  )
              else
                # Non-private repos must have sha256 set.
                assert sha256 != null;
                # pkgs.fetchgit doesn't have any way of fetching from a given
                # ref.
                assert isNull ref;
                final.fetchgit {
                  url = url;
                  rev = rev;
                  sha256 = sha256;
                };

            # This is basically entireRepo, but focused on the subdir if it is specified.
            repoWithSubdir =
              entireRepo + (if subdir == "." then "" else "/" + subdir);

            nix-expr =
              if type == "cabal"
              then
                final.buildPackages.haskell-nix.callCabalToNix {
                  src = repoWithSubdir;
                  inherit name cabal-file;
                }
              else if type == "stack"
              then
                (final.buildPackages.haskell-nix.callStackToNix {
                  src = repoWithSubdir;
                  inherit name subdir;
                }).projectNix
              else
                throw "Unknown type '${type}` for a cache entry";

            sha256String = if isNull sha256 then final.buildPackages.lib.fakeSha256 else sha256;

          in {
            line = "${url} ${rev} ${subdir} ${sha256String} ${name}";
            inherit nix-expr;
          };

        # Given a list of repos:
        # [ { name = ...; url = ...; rev = ...; ref = ...; sha256 = ...; cabal-file = ...; type = ...; is-private = ...; } ]
        # produce a cache file that can be used for
        # stack-to-nix or plan-to-nix to prevent them
        # from needing network access.
        # The cache contains only local paths to nix files so that it can
        # the results of `stack-to-nix` can be imported in restricted eval
        # mode.
        mkCacheFile = repos:
          final.buildPackages.pkgs.runCommand "cache-file" {} ''
              mkdir -p $out
              touch $out/.stack-to-nix.cache
              ${final.lib.concatStrings (
                final.lib.lists.zipListsWith (n: repo:
                  let l = mkCacheLine repo;
                  in ''
                    cp ${l.nix-expr} $out/.stack-to-nix.cache.${toString n}
                    echo ${l.line} .stack-to-nix.cache.${toString n} >> $out/.stack-to-nix.cache
                  '')
                  (final.lib.lists.range 0 ((builtins.length repos) - 1))
                  repos)
              }
          '';

        genStackCache = import ../lib/stack-cache-generator.nix;

        mkCacheModule = cache:
            # for each item in the `cache`, set
            #   packages.$name.src = fetchgit ...
            # and
            #   packages.$name.postUnpack = ...
            # if subdir is given.
            #
            # We need to do this, as cabal-to-nix will generate
            # src = /nix/store/... paths, and when we build the
            # package we won't have access to the /nix/store
            # path.  As such we regenerate the fetchgit command
            # we used in the first place, and thus have a proper
            # src value.
            #
            # TODO: this should be moved into `call-stack-to-nix`
            { packages =
                let
                  repoToAttr = { name, url, rev, ref ? null, sha256 ? null, subdir ? null, is-private ? false, input ? null, ... }:
                    let hasSubdir = subdir != null && subdir != "."; in {
                    ${name} = {
                      src =
                        # When a dependency url was resolved via `inputMap`
                        # (see `lib/stack-cache-generator.nix`) use the mapped
                        # local path / flake input directly instead of
                        # fetching it again.  Select the subdir with
                        # `cleanSourceWith` rather than the `postUnpack` below:
                        # a mapped input may itself be a cleaned source, and
                        # the component source cleaning assumes the package is
                        # at the root of `src`, so it would drop the subdir.
                        if input != null
                        then
                          if hasSubdir
                            then final.haskell-nix.haskellLib.cleanSourceWith {
                              src = input;
                              subDir = subdir;
                              name = "${name}-src";
                            }
                            else input
                        else if is-private
                        then
                          builtins.fetchGit
                            ({ inherit url rev; } //
                              final.buildPackages.lib.optionalAttrs (ref != null) { inherit ref; }
                            )
                        else
                          final.fetchgit { inherit url rev sha256; };
                    } // final.buildPackages.lib.optionalAttrs (input == null && hasSubdir) { postUnpack = "sourceRoot+=/${subdir}; echo source root reset to $sourceRoot"; };
                  };

                  cacheMap = builtins.map repoToAttr cache;
                in
                builtins.foldl' (x: y: x // y) {} cacheMap;

            };

        # Takes a haskell src directory runs cabal new-configure and plan-to-nix.
        # Resulting nix files are added to nix-plan subdirectory.
        callCabalProjectToNix = import ../lib/call-cabal-project-to-nix.nix {
            index-state-hashes =
              (
                if builtins.pathExists (hackageSrc + "/index-state.nix")
                  then import (hackageSrc + "/index-state.nix")
                  else import (hackageSrc + "/index-state-hashes.nix")
              )
              // import (sources.hackage-internal + "/index-state.nix");
            inherit (final.buildPackages.haskell-nix) haskellLib;
            pkgs = final.buildPackages.pkgs;
            inherit (final.buildPackages.pkgs) cacert;
        };

        # Loads a plan and filters the package directories using cleanSourceWith
        importAndFilterProject = import ../lib/import-and-filter-project.nix {
            inherit (final.buildPackages.haskell-nix) haskellLib;
            pkgs = final.buildPackages.pkgs;
        };

        # Loads a plan and filters the package directories using cleanSourceWith
        loadCabalPlan = import ../lib/load-cabal-plan.nix {
            inherit (final.buildPackages.haskell-nix) haskellLib;
            pkgs = final.buildPackages.pkgs;
        };

        # References to the unpacked sources, for caching in a Hydra jobset.
        source-pins = import ../lib/make-source-pins.nix {
            inherit (final) lib writeTextFile;
            sources = [ hackageSrc stackageSrc final.path ];
        };

        # -- IFDs --
        # Build a specific package (name, version) against a given index-stage
        # from hackage.  This is useful if you want to build an executable from
        # a given package.
        # NB: If no explicit index-state is provided the most recent one from
        # the index-state-hashes is used.  This guarantees reproducibility wrt
        # to the haskell.nix revision.  If reproducibility beyond haskell.nix
        # is required, a specific index-state should be provided!
        hackage-package = projectModule:
          let project = hackage-project projectModule;
          in project.getPackage project.args.name;
        hackage-project = projectModule:
          cabalProject' ([
            (import ../modules/hackage-project.nix)
            ] ++ (import ../modules/hackage-quirks.nix)
              ++ (if builtins.isList projectModule then projectModule else [projectModule]));

        # This function is like `cabalProject` but it makes the plan-nix available
        # separately from the hsPkgs.  The advantage is that the you can get the
        # plan-nix without building the project.
        cabalProject' =
          projectModule: haskellLib.evalProjectModule ../modules/cabal-project.nix projectModule (
            { config, options, ... }:
            let
              inherit (config) compiler-nix-name compilerSelection evalPackages evalSystem;
              selectedCompiler = (compilerSelection final.buildPackages).${compiler-nix-name};
              callProjectResults = callCabalProjectToNix config;
              plan-pkgs = if !builtins.pathExists (callProjectResults.projectNix + "/plan.json")
                then
                  # If there is no `plan.json` file assume this is a materialized
                  # `plan-nix` and use the old code path.
                  # TODO remove this once all the materialized files are updated
                  importAndFilterProject {
                    inherit (callProjectResults) projectNix sourceRepos src;
                  }
                else
                  loadCabalPlan {
                    inherit selectedCompiler callProjectResults;
                  };
              buildProject = if final.stdenv.hostPlatform != final.stdenv.buildPlatform
                then final.pkgsBuildBuild.haskell-nix.cabalProject' projectModule
                else project;
              pkg-set = if plan-pkgs ? configurationError
                then {
                  inherit (plan-pkgs) configurationError;
                  config = {
                    compiler.nix-name = compiler-nix-name;
                    hsPkgs = {};
                    inherit evalPackages;
                  };
                }
                else mkCabalProjectPkgSet
                { inherit compiler-nix-name compilerSelection plan-pkgs;
                  pkg-def-extras = config.pkg-def-extras or [];
                  modules = [ { _module.args.buildModules = final.lib.mkForce buildProject.pkg-set; } ]
                    ++ (config.modules or [])
                    ++ [ {
                      ghc.package =
                        let ghc =
                          if config.ghcOverride != null
                            then config.ghcOverride
                          else if config.ghc != null
                            then config.ghc
                          else
                            final.lib.mkDefault selectedCompiler;
                        in if ghc.isHaskellNixCompiler or false then (ghc.evalWith.${evalSystem} or (ghc.override { evalSystem = evalSystem; })) else ghc;
                      compiler.nix-name = final.lib.mkForce config.compiler-nix-name;
                      evalPackages = final.lib.mkDefault evalPackages;
                      inherit (config) prebuilt-depends builderVersion v2LocalPackageSlices v2LocalPackageSliceNames cabalProject withBuildCompiler;
                      # NOT `config.cabalProjectLocal`: the v2 shell writes
                      # this text out as the user's `cabal.project.local`, so
                      # its `source-repository-package` blocks have to be the
                      # `file://` store rewrites plan-to-nix used, not the
                      # original remote URLs (which cabal would clone over the
                      # network).  See `fixedCabalProjectLocal` in
                      # lib/call-cabal-project-to-nix.nix.
                      cabalProjectLocal = callProjectResults.fixedCabalProjectLocal;
                    } ];
                  extra-hackages = config.extra-hackages or [] ++ callProjectResults.extra-hackages;
                };

              project = addProjectAndPackageAttrs rec {
                  inherit (pkg-set.config) hsPkgs;
                  inherit pkg-set;
                  inherit options;
                  args = config;
                  plan-nix = callProjectResults.projectNix;
                  inherit (callProjectResults) index-state-max;
                  # The offline `.cabal` dir (prepopulated hackage index at
                  # the project's `index-state`) that plan-to-nix solved
                  # against.  Exposed so a sandboxed `cabal` -- a v2 shell
                  # test, say -- can solve against the very same index
                  # instead of needing the network.
                  inherit (callProjectResults) dotCabalDir;
                  tool = final.buildPackages.haskell-nix.tool' evalSystem pkg-set.config.compiler.nix-name;
                  tools = final.buildPackages.haskell-nix.tools' evalSystem pkg-set.config.compiler.nix-name;
                  roots = final.haskell-nix.roots { compiler-nix-name = pkg-set.config.compiler.nix-name; inherit evalSystem; };
                  projectFunction = haskell-nix: haskell-nix.cabalProject';
                  inherit projectModule buildProject;
                };
            in project);

        # Take `hsPkgs` from the `rawProject` and update all the packages and
        # components so they have a `.project` attribute and as well as
        # a `.package` attribute on the components.
        addProjectAndPackageAttrs = let
          # helper function similar to nixpkgs 'makeExtensible' but that keep track
          # of extension function so that it can be reused to extend another project:
          makeExtensible = f: rattrs: final.lib.fix (final.lib.extends f (self: rattrs self // {
            __overlay__ = f;
            extend = f: makeExtensible (final.lib.composeExtensions self.__overlay__ f) rattrs;
            appendOverlays = extraOverlays: self.extend (final.lib.composeManyExtensions ([self.__overlay__] ++ extraOverlays));
          }));
         in rawProject:
          makeExtensible (_final: _prev: {}) (project':
            let project = project' // { recurseForDerivations = false; };
            in rawProject // rec {
              # It is often handy to be able to get nix pkgs from the project.
              pkgs = final;
              # Haskell packages
              hsPkgs = final.lib.mapAttrs (packageName: package':
                if package' == null
                  then null
                  else
                    let package = package' // { recurseForDerivations = false; };
                    in package' // rec {
                      components = final.lib.mapAttrs (n: v:
                        if n == "library" || n == "all"
                          then v // { inherit project package; }
                          else final.lib.mapAttrs (_: c: c // { inherit project package; }) v
                      ) package'.components;
                      inherit project;

                      # Look up a component in the package based on ctype:name
                      getComponent = componentName:
                        let m = builtins.match "(lib|flib|exe|test|bench):([^:]*)" componentName;
                        in
                          assert final.lib.asserts.assertMsg (m != null)
                            "Invalid package component name ${componentName}.  Expected it to start with one of lib: flib: exe: test: or bench:";
                          if builtins.elemAt m 0 == "lib" && builtins.elemAt m 1 == packageName
                            then components.library
                            else
                              let ctype = builtins.elemAt m 0;
                                  cname = builtins.elemAt m 1;
                                  # Default to {} so a package with no exes/tests/etc. group
                                  # still reaches the helpful throw below rather than a raw
                                  # "attribute '<group>' missing".
                                  group = components.${haskellLib.prefixComponent.${ctype}} or {};
                              in group.${cname} or (throw ''
                                Package ${packageName} has no component ${componentName}.
                                Available ${ctype} components: ${
                                  if group == {} then "(none)"
                                  else final.lib.concatStringsSep ", " (builtins.attrNames group)}.
                                A missing component is often caused by an automatic Cabal flag being turned off by the solver (for example cabal-plan's `exe` flag, which drops exe:cabal-plan), or by the component not existing for this GHC.
                                If it is a disabled flag, force it back on with cabalProjectLocal, e.g.
                                    cabalProjectLocal = "package ${packageName}\n  flags: +<flag>";
                                For a tool this goes in the tool's module, e.g.
                                    tools.${packageName} = { version = "<version>"; cabalProjectLocal = "package ${packageName}\n  flags: +<flag>"; };
                                Otherwise pin a version of ${packageName} that solves cleanly for this GHC.'');

                      coverageReport = haskellLib.coverageReport ({
                        name = package.identifier.id;
                        # Include the checks for a single package.
                        checks = final.lib.filter (final.lib.isDerivation) (final.lib.attrValues package'.checks);
                        # Checks from that package may provide coverage information for any library in the project.
                        mixLibraries = final.lib.concatMap
                          (pkg: final.lib.optional (pkg.components ? library) pkg.components.library)
                            (final.lib.attrValues (haskellLib.selectProjectPackages project.hsPkgs));
                        ghc = project.pkg-set.config.ghc.package;
                      });
                    }
                ) (builtins.removeAttrs rawProject.hsPkgs
                  # These are functions not packages
                  [ "shellFor" "makeConfigFiles" "ghcWithHoogle" "ghcWithPackages" "buildPackages" ]);

            # The cabal-install the v2 builder (`builderVersion = 2`) builds
            # this project's slices with.  A v2 shell's `cabal` must be this
            # one for `cabal build` to reuse them (see `cabalTool` in
            # builder/shell-for-v2.nix); `shellFor`'s `tools.cabal` picks it
            # by default, and this is the same derivation for shells made
            # some other way, e.g. `nativeBuildInputs = [ p.v2-cabal-install ]`.
            v2-cabal-install =
              let v2ci = final.pkgsBuildBuild.haskell-nix.v2-cabal-install;
              in v2ci.evalWith.${rawProject.args.evalSystem or ""} or v2ci;

            projectCoverageReport = haskellLib.projectCoverageReport project (map (pkg: pkg.coverageReport) (final.lib.attrValues (haskellLib.selectProjectPackages hsPkgs)));

            # `projectCross` is like `pkgsCross`, but for haskell.nix projects.
            # To get a cross platform version of the project use
            # `projectCross.<system>` where system is a member of nixpkgs lib.systems.examples.
            # See https://nixos.wiki/wiki/Cross_Compiling
            projectCross = (final.lib.mapAttrs (_: pkgs:
                (rawProject.projectFunction pkgs.haskell-nix rawProject.projectModule)
                # Re-apply overlay from original project:
                .extend project.__overlay__
              ) final.pkgsCross) // { recurseForDerivations = false; };

            # attribute set of variant (with an extra module applied) for the project,
            # mapped from `flake.variants` config values.
            projectVariants = final.lib.mapAttrs (_: project.appendModule) project.args.flake.variants;

            # re-eval this project with an extra module (or module list).
            appendModule = extraProjectModule: (rawProject.projectFunction final.haskell-nix
              ((if builtins.isList rawProject.projectModule
                then rawProject.projectModule
                else [rawProject.projectModule])
              ++ (if builtins.isList extraProjectModule
                then extraProjectModule
                else [extraProjectModule])))
                # Re-apply overlay from original project:
                .extend project.__overlay__;

            # Add support for passing in `crossPlatforms` argument.
            # crossPlatforms is an easy way to include the inputs for a basic
            # cross platform shell in a native shell.
            #
            # For instance if `default.nix` is a project, then `shell.nix` can be:
            #   (import ./. {}).shellFor {
            #     tools.cabal = {};
            #     crossPlatforms = p: [ p.ghcjs ];
            #   }
            #
            # This adds support for compiling with ghcjs.  To build use the cabal wrapper:
            #   js-unknown-ghcjs-cabal build all
            #
            # ## How it Works
            #
            # The cross compilation shells are made using the `projectCross` attribute
            # to get the selected cross compilation projects (e.g. project.projectCross.ghcjs).
            #
            # The `shellFor` function for those projects is called with arguments based on the
            # ones used for the main shell (the `withHoogle` argument is set to `false`).
            #
            # These shells are added to the main shell using the `inputsFrom` argument.
            #
            # Without `crossPlatforms` the above example would be:
            #   let project = import ./. {};
            #   in project.shellFor {
            #     tools.cabal = {};
            #     inputsFrom = [
            #       (project.platformCross.ghcjs.shellFor { withHoogle = false; })
            #     ];
            #   }
            #
            # `shellFor` uses whatever `builderVersion` the project is
            # configured with.  Under `builderVersion = 2` v1's
            # shellFor path doesn't work anyway (it reaches into
            # v1-only passthru attrs like `executableToolDepends`,
            # `config`, `env`, etc.), so the cross-shell merge below
            # also dispatches on the builder to drop v1-only keys
            # before invoking the v2 shell.
            shellFor = extraArgs: (appendModule { shell = extraArgs; }).shell;
            shell = shellFor' rawProject.args.shell.crossPlatforms;
            shellFor' = crossPlatforms:
              let
                shellArgs = builtins.removeAttrs rawProject.args.shell [ "crossPlatforms" ];
                # Shells for cross compilation
                crossShells = builtins.map (project: project.shellFor {
                    # Prevent recursion
                    crossPlatforms = final.lib.mkForce (_p: []);
                    # The main shell's hoogle will probably be faster to build.
                    withHoogle = final.lib.mkForce false;
                  }) (crossPlatforms projectCross);
                builderV = rawProject.pkg-set.config.builderVersion or 1;
              in rawProject.hsPkgs.shellFor (
                # Under `builderVersion = 2`, drop v1-only keys the
                # v2 shell doesn't accept.  `allToolDeps` IS honoured
                # in v2 (build-tool-depends are surfaced via
                # `executableToolDepends`), so keep it.
                (if builderV == 2
                  then builtins.removeAttrs shellArgs [
                    "exactDeps" "packageSetupDeps"
                    "enableDWARF" "components" "additional"
                  ]
                  else shellArgs)
                // {
                  inputsFrom = shellArgs.inputsFrom or [] ++ crossShells;
                });

            # Like `.hsPkgs.${packageName}` but when compined with `getComponent` any
            # cabal configure errors are defered until the components derivation builds.
            getPackage = packageName:
              if rawProject.pkg-set ? configurationError
                then
                  # A minimal proxy for a package when cabal configure failed
                  let package = {
                    # Including the project so that things like:
                    #  (p.getPackage "hello").project.tool "hlint" "latest"
                    # will still work even if "hello" failed to configure.
                    inherit project;

                    # Defer configure time errors for the library component
                    #  (p.getPackage "hello").components.library
                    components.library = package.getComponent "lib:${packageName}";

                    # This procide a derivation (even though the component may
                    # not exist at all).  The derivation will never build
                    # and simple outputs the result of cabal configure.
                    getComponent = componentName:
                      final.rawProject.config.evalPackages.runCommand "cabal-configure-error" {
                        passthru = {
                          inherit project package;
                        };
                      } ''
                        cat ${rawProject.pkg-set.configurationError}
                        echo Unable to find component ${packageName}:${componentName}  \
                          due to the above cabal configuration error
                        exit 1
                      '';
                  };
                  in package
                else project.hsPkgs.${packageName};

            # Look a component in the project based on `pkg:ctype:name`
            getComponent = componentName:
              let m = builtins.match "([^:]*):(lib|flib|exe|test|bench):([^:]*)" componentName;
              in
                assert final.lib.asserts.assertMsg (m != null)
                  "Invalid package component name ${componentName}.  Expected package:ctype:component (where ctype is one of lib, flib, exe, test, or bench)";
                (getPackage (builtins.elemAt m 0)).getComponent "${builtins.elemAt m 1}:${builtins.elemAt m 2}";

            # Helper function that can be used to make a Nix Flake out of a project
            # by including a flake.nix.  See docs/tutorials/getting-started-flakes.md
            # for an example flake.nix file.
            # This flake function maps the build outputs to the flake `packages`,
            # `checks` and `apps` output attributes.
            flake' =
              let
                combinePrefix = a: b: if a == "default" then b else "${a}-${b}";
                mkFlake = project: haskellLib.mkFlake project rec {
                  selectPackages = project.args.flake.packages;
                  coverage = final.lib.optionalAttrs project.args.flake.doCoverage
                    (haskellLib.projectCoverageCiJobs
                      project selectPackages project.args.flake.coverageProjectModule);
                  inherit (project.args.flake) doHaddock;
                };
                forAllCrossCompilers = prefix: project: (
                    [{ ${prefix} = mkFlake project; }]
                  ++ (map (project: {
                       ${combinePrefix prefix project.pkgs.stdenv.hostPlatform.config} =
                         mkFlake project;
                      })
                     (project.args.flake.crossPlatforms project.projectCross)
                  ));
                forAllVariants =
                    forAllCrossCompilers "default" project
                  ++ final.lib.concatLists (final.lib.mapAttrsToList
                    (name: projectVariant: forAllCrossCompilers name projectVariant)
                     project.projectVariants);
              in haskellLib.combineFlakes ":" (builtins.foldl' (a: b: a // b) {} forAllVariants);
            flake = args: (project.appendModule { flake = args; }).flake';

            inherit (rawProject) args;
            inherit (rawProject.hsPkgs) makeConfigFiles ghcWithHoogle ghcWithPackages;
          });

        cabalProject = args: let p = cabalProject' args;
            in p.hsPkgs // p;

        stackProject' =
          projectModule: haskellLib.evalProjectModule ../modules/stack-project.nix projectModule (
            { config, options, ... }:
            let inherit (config) evalPackages evalSystem;
                callProjectResults = callStackToNix (config
                  // final.lib.optionalAttrs (config.cache == null) { inherit cache; });
                generatedCache = genStackCache config;
                cache = if config.cache != null then config.cache else generatedCache;
            in let
              buildProject = if final.stdenv.hostPlatform != final.stdenv.buildPlatform
                then final.pkgsBuildBuild.haskell-nix.stackProject' projectModule
                else project;
              pkg-set = mkStackPkgSet
                { stack-pkgs = importAndFilterProject callProjectResults;
                  pkg-def-extras = (config.pkg-def-extras or []);
                  modules = [ { _module.args.buildModules = final.lib.mkForce buildProject.pkg-set; }
                      (mkCacheModule cache) ]
                    ++ (config.modules or [])
                    ++ final.lib.optional (config.ghc != null) { ghc.package = config.ghc.evalWith.${evalSystem} or (config.ghc.override { evalSystem = evalSystem; }); }
                    ++ final.lib.optional (config.compiler-nix-name != null)
                        { compiler.nix-name = final.lib.mkForce config.compiler-nix-name; }
                    ++ [ { evalPackages = final.lib.mkDefault evalPackages;
                           inherit (config) builderVersion;
                         } ];
                };

                project = addProjectAndPackageAttrs {
                  inherit (pkg-set.config) hsPkgs;
                  inherit pkg-set;
                  inherit options;
                  args = config;
                  stack-nix = callProjectResults.projectNix;
                  tool = final.buildPackages.haskell-nix.tool' evalSystem pkg-set.config.compiler.nix-name;
                  tools = final.buildPackages.haskell-nix.tools' evalSystem pkg-set.config.compiler.nix-name;
                  roots = final.haskell-nix.roots { compiler-nix-name = pkg-set.config.compiler.nix-name; inherit evalSystem; };
                  projectFunction = haskell-nix: haskell-nix.stackProject';
                  inherit projectModule buildProject;
                };
            in project);

        stackProject = args: let p = stackProject' args;
            in p.hsPkgs // p;

        # `project'` and `project` automatically select between `cabalProject`
        # and `stackProject` (when possible) by looking for `stack.yaml` or
        # `cabal.project` files.  If both exist it uses the `cabal.project` file.
        # To override this pass in:
        #     `projectFileName = "stack.yaml;"`
        # If the selected file ends in a `.yaml` it is assumed to be for `stackProject`.
        # If neither `stack.yaml` nor `cabal.project` exist `cabalProject` is
        # used (as it will use a default `cabal.project`).
        project' = projectModule:
          let
            projectModule' = if builtins.isList projectModule then projectModule else [projectModule];
            inherit ((final.lib.evalModules {
              modules = [
                (import ../modules/project-common.nix)
                (import ../modules/stack-project.nix)
                (import ../modules/cabal-project.nix)
                (import ../modules/project.nix)
                {_module.args.pkgs = final;} # Needed to make `src = config.evalPackages.haskell-nix.haskellLib.cleanGit ...` work
              ] ++ projectModule';
            }).config) src projectFileName;
            dir = __readDir (src.origSrcSubDir or src);
            exists = fileName: builtins.elem (dir.${fileName} or "") ["regular" "symlink"];
            stackYamlExists    = exists "stack.yaml";
            cabalProjectExists = exists "cabal.project";
            selectedFileName =
              if projectFileName != null
                then projectFileName  # Prefer the user selected project file name
                else
                  if stackYamlExists && cabalProjectExists
                    then __trace ("haskell-nix.project : both `stack.yaml` and `cabal.project` files exist.  Using `cabal.project`. "
                      + "set `projectFileName = \"stack.yaml\";` to override this.`") "cabal.project"
                    else
                      if stackYamlExists
                        then "stack.yaml"      # stack needs a stack.yaml
                        else "cabal.project";  # the cabal.project file is optional
          in
            if final.lib.hasSuffix ".yaml" selectedFileName
              then stackProject' ([
                    (import ../modules/project.nix)
                    { stackYaml = selectedFileName; }
                  ] ++ projectModule'
                )
              else cabalProject' ([
                    (import ../modules/project.nix)
                    { cabalProjectFileName = selectedFileName; }
                  ] ++ projectModule');

        # This is the same as the `cabalPackage` and `stackPackage` wrappers
        # for `cabalPackage` and `stackPackage`.
        project = args: let p = project' args;
          in p.hsPkgs // p;

        # Like `cabalProject'`, but for building the GHCJS compiler.
        # This is exposed to allow GHCJS developers to work on the GHCJS
        # code in a nix-shell with `shellFor`.
        ghcjsProject = import ../lib/ghcjs-project.nix { pkgs = final; materialized-dir = ../materialized; };

        # The functions that return a plan-nix often have a lot of dependencies
        # that could be GCed and also will not make it into hydra cache.
        # Use this `withInputs` function to make sure your tests include
        # the dependencies needed explicitly.  For example, if you have:
        #   project = cabalProject' {...};
        # In your tests module add something that is effectively
        #   testProjectPlan = withInputs project.plan-nix;
        withInputs = final.lib.recurseIntoAttrs;

        # The v2 builder's `cabal-install`, built via `haskell-nix.tool`:
        # the stable-haskell cabal fork (3.17, branch stable-haskell/master)
        # pulled via source-repository-package — the same sources
        # make-install-plan links (see nix-tools/cabal.project).  This
        # gives the per-slice `cabal v2-build` the cross-compilation
        # "stage" system (--with-build-compiler / build:/host: constraints)
        # so build-time tool deps resolve in the build scope.
        # Branch `hkm/installed-sublibs` (2 commits on top of
        # stable-haskell/master 01d053ac): lets installed instances satisfy
        # named sub-library deps — required by the ghc-bin slice, whose
        # +threaded/+debug flags depend on the composed installed rts's
        # flavour sublibs (rts:threaded-nodebug etc.).
        #
        # Two pins here:
        #
        #   * `builderVersion = 1` — cabal-install stays a v1 derivation.
        #     Every v2 slice lists the v2 cabal-install as a
        #     nativeBuildInput, so producing it as a v2 slice would cycle
        #     on itself.
        #
        #   * `compilerSelection = p: p.haskell.compiler` — use nixpkgs's
        #     pre-built GHC rather than haskell.nix's own (which would be
        #     built by hadrian, itself a haskell.nix project whose hackage
        #     deps become v2 slices needing the v2 cabal-install).
        #     Pre-built nixpkgs GHC sidesteps the entire hadrian subtree.
        #
        # We go through `tool` (rather than nix-tools' pre-built cabal) so
        # we can apply our own cabal-install patches.
        #
        # Defined here — one memoised definition per eval system (same
        # pattern as `iserv-proxy-exes`) instead of a re-instantiation per
        # project (builder/default.nix), and `roots` links its
        # `.project.plan-nix`.  Always access it via
        # `pkgsBuildBuild.haskell-nix.v2-cabal-install` (it is a build-host
        # tool; going through pkgsBuildBuild shares the instance across
        # cross pkgs).
        v2-cabal-install =
          let
            # Pick the first GHC in this list that nixpkgs ships pre-built
            # (under `haskell.compiler.<name>`).  `ghc9141` is the
            # preference; `ghc9124` / `ghc9123` / `ghc9122` are kept as
            # fallbacks for nixpkgs pins that don't carry 9.14 yet — going
            # back further than 9.12 hasn't been needed in practice.  The
            # exact GHC doesn't show up in any UnitId hash (this just
            # builds the patched cabal-install binary), so any of these
            # produces an equivalent v2 builder.
            compiler-nix-name =
              let candidates  = [ "ghc9141" "ghc9124" "ghc9123" "ghc9122" ];
                  compilerSet = final.pkgsBuildBuild.haskell.compiler or {};
                  picked      = final.lib.findFirst (n: compilerSet ? ${n}) null candidates;
              in if picked == null
                 then throw ("v2-cabal-install: none of [${final.lib.concatStringsSep ", " candidates}] "
                          + "is present in `pkgs.haskell.compiler`; bump the candidates list "
                          + "in `overlays/haskell.nix`.")
                 else picked;
            mkTool = evalSystem: final.pkgsBuildBuild.haskell-nix.tool compiler-nix-name "cabal" {
              version = "3.17.0.1";
              builderVersion = 1;
              # Run the tool project's plan-to-nix on the consumer's eval
              # platform.  Without this it defaults to the pkgsBuildBuild
              # system, forcing IFD on (e.g.) x86_64-linux when the eval
              # host is darwin.
              inherit evalSystem;
              compilerSelection = p: p.haskell.compiler;
              cabalProjectLocal = ''
                source-repository-package
                    type: git
                    location: https://github.com/stable-haskell/Cabal.git
                    tag: f3482d8abc62e93e58574ef1be7cdc51d5d8d146
                    --sha256: sha256-i8eSe3NvUsaHjYmStDhGYa6byZYFJt6xwyFwhlFETfM=
                    subdir: Cabal
                            Cabal-syntax
                            cabal-install
                            cabal-install-solver
                            hooks-exe

                source-repository-package
                    type: git
                    location: https://github.com/stable-haskell/hackage-security.git
                    tag: baaad2e189a8203966f7d3f752a348f02eefd1b2
                    --sha256: sha256-mVWZCWGJKsSjQSqb5iw0Q8fmV+4aFZVL4zOmMaNnEhA=
                    subdir: hackage-security
              '';
              modules = [{
                # (No sublib-pruning patch: a slice's solve needs the deps of
                # every sublib in a package, even unused ones like vector's
                # `benchmarks-O2` -> tasty, and it gets them -- plan-nix comes
                # from an unpruned solve, so they are already in the slice's
                # dep closure, as slices or as metadata-only index entries.)
                packages.cabal-install.patches = [
                  ../builder/cabal-install-patches/skip-installed-revdeps-in-completed.patch
                  ../builder/cabal-install-patches/setup-build-num-jobs-env.patch
                  ../builder/cabal-install-patches/inlibrary-build-stage-exe-platform.patch
                  ../builder/cabal-install-patches/haddock-toolchain-self-reference.patch
                ];
                # The Cabal LIBRARY, not the tool: `v2-build` links it in and
                # uses it as the build system for `build-type: Simple`, so a
                # patch here is what reaches the actual link command.
                packages.Cabal.patches = [
                  ../builder/cabal-install-patches/static-external-only-when-supported.patch
                  ../builder/cabal-install-patches/no-object-for-unemitted-signature.patch
                ];
              }];
            };
            byEvalSystem = final.lib.mapAttrs (evalSystem: _evalPackages:
              mkTool evalSystem) final.haskell-nix.evalPackages;
          in byEvalSystem.${final.pkgsBuildBuild.stdenv.hostPlatform.system}
             // { evalWith = byEvalSystem; };

        iserv-proxy-exes = __mapAttrs (compiler-nix-name: _ghc:
            let
              # `profiled` controls whether the iserv-proxy project's
              # cabal.project enables profiling for the iserv-proxy
              # package.  v1's `.override { enableProfiling = true; }`
              # is read by `comp-builder.nix:71`; v2's
              # `comp-v2-builder` reads configure-args from plan-nix
              # instead, so the toggle has to live in cabal.project
              # to make it through plan-nix into the v2 slice.
              proj = evalSystem: profiled: pkgs: pkgs.haskell-nix.cabalProject' ({config, pkgs, ...}: {
                name = "iserv-proxy";
                inherit compiler-nix-name evalSystem;

                # Patch platform-specific iserv-proxy symbol tables before
                # planning so v2 hashes and source archives describe the same
                # implementation. The ARM32 Bionic patch removes stubs that
                # shadow real static libc routines; the i386 musl patch drops
                # a hidden libc symbol that prevents dynamic linking.
                src = if compiler-nix-name == "ghc914-sh"
                  && pkgs.stdenv.hostPlatform.isLinux
                  && pkgs.stdenv.hostPlatform.isMusl
                  && pkgs.stdenv.hostPlatform.isx86_32
                then config.evalPackages.applyPatches {
                  name = "i386-musl-iserv-proxy-source";
                  src = sources.iserv-proxy;
                  patches = [ ./patches/iserv-proxy-i386-musl-dynamic-libc.patch ];
                } else if compiler-nix-name == "ghc914-sh"
                  && pkgs.stdenv.hostPlatform.isAndroid
                  && pkgs.stdenv.hostPlatform.isAarch32
                then config.evalPackages.applyPatches {
                  name = "android-arm32-iserv-proxy-source";
                  src = sources.iserv-proxy;
                  patches = [
                    ./patches/iserv-proxy-arm32-static-libc.patch
                    ./patches/iserv-proxy-arm32-bionic-symbols.patch
                  ];
                } else sources.iserv-proxy;

                modules = [{
                  config = {
                    # Prevent the iserve-proxy-interpreter from depending on itself
                    # by disabling the `--ghc-option` normally passed to `setupBuildFlags`
                    # when cross compiling.
                    setupBuildFlags = final.lib.mkForce [];
                    # The v2 cross-TH wrapper depends on
                    # iserv-proxy-interpreter; building the
                    # iserv-proxy project itself with that wrapper
                    # applied would recurse on its own inputs.
                    # Opt out so iserv-proxy's slices use the
                    # unwrapped ghc.
                    crossTemplateHaskellSupport = false;
                    # MinGW-w64 14's libmingwex `_assert` member references
                    # `__acrt_iob_func` directly, and base imports
                    # `__p__environ` through an IAT slot not registered by the
                    # GHC RTS. Add both aliases to iserv's Windows symbol table.
                    packages.iserv-proxy.patches = pkgs.lib.optionals (
                         pkgs.stdenv.hostPlatform.isWindows
                      && builtins.compareVersions pkgs.buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6.1" >= 0
                      && builtins.compareVersions pkgs.buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.11" < 0
                    ) [ ./patches/iserv-proxy-windows-crt-symbols.patch ];
                  };
                }];

                cabalProjectLocal =
                  # aarch64 + GHC < 9.8: th-dlls test fails when
                  # iserv-proxy is built with the threaded RTS.
                  final.lib.optionalString (
                       final.stdenv.hostPlatform.isAarch64
                    && builtins.compareVersions final.buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.8" < 0
                  ) ''
                    package iserv-proxy
                      flags: -threaded
                  ''
                  # GHC ≥ 9.14: bake `--optimistic-linking` into
                  # iserv-proxy / iserv-proxy-interpreter at link
                  # time via `-with-rtsopts`.
                  # `GHC/Linker/Executable.hs` emits this into the
                  # generated `main.c` as `__conf.rts_opts`, which
                  # `setupRtsFlags` processes with `RtsOptsAll` —
                  # bypassing the `OPTION_UNSAFE` gate that
                  # `+RTS --optimistic-linking -RTS` on the command
                  # line is subject to.  Makes the runtime linker
                  # tolerate undefined symbols when loading object
                  # files at TH-eval time; splices that don't
                  # actually reference the missing symbol then
                  # resolve fine instead of aborting the load.
                  # `-rtsopts=all` is kept so wrapper scripts /
                  # GHCRTS can still override at invocation.
                  # `--optimistic-linking` is only available in
                  # GHC's RTS from 9.14 onwards; gated on the Nix
                  # side since cabal.project doesn't allow `if`
                  # inside a `package` stanza.
                  + final.lib.optionalString (
                       builtins.compareVersions final.buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.14" >= 0
                  ) ''
                    package iserv-proxy
                      ghc-options: -rtsopts=all -with-rtsopts=--optimistic-linking
                  ''
                  # Windows host: iserv-proxy-interpreter.exe needs
                  # these linker flags to avoid a "32 bit pseudo
                  # relocation … out of range" error when wine
                  # launches it, plus `-debug` for clearer runtime
                  # diagnostics.  The `if os(mingw32)` guard keeps
                  # them from leaking into the build-platform
                  # iserv-proxy build (the same cabalProjectLocal
                  # is shared by both).
                  + final.lib.optionalString final.stdenv.hostPlatform.isWindows ''
                    if os(mingw32)
                      package iserv-proxy
                        ghc-options: -debug -optl-Wl,--disable-dynamicbase,--disable-high-entropy-va,--image-base=0x400000
                  ''
                  # Android host: the cross-compiled
                  # iserv-proxy-interpreter must be statically
                  # linked because qemu-user-mode can't satisfy
                  # Android's dynamic loader (`/system/bin/linker64`
                  # / `/system/bin/linker`) on the build host.
                  # `-optl-static` makes the resulting binary
                  # self-contained; `-optl-ldl` pulls in libdl that
                  # the GHC RTS references even with a static link.
                  #
                  # Guard on the INNER `pkgs.stdenv.hostPlatform` —
                  # the same cabalProjectLocal is reused by both the
                  # build-platform iserv-proxy (`exes
                  # final.pkgsBuildBuild`, linux x86_64) and the
                  # host-platform iserv-proxy-interpreter (`exes
                  # final`, android).  If we keyed off the outer
                  # `final.stdenv.hostPlatform`, the build-platform
                  # iserv-proxy would also pick up `-optl-static`
                  # and the link would fail with a `-fPIC` /
                  # `crtbeginT.o` error trying to statically link
                  # a shared library.
                  #
                  # v1 expressed the same via `setupBuildFlags` in
                  # `overlays/haskell.nix`'s `.override` block; v2
                  # ignores `setupBuildFlags`, so we route the
                  # flags through cabal.project so plan-nix records
                  # them in the slice's UnitId-relevant
                  # configure-args.
                  + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isAndroid ''
                    package iserv-proxy
                      ghc-options: -debug -optl-static -optl-ldl${
                        pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isAarch32 " -optl-no-pie"
                      }
                  ''
                  # stable-haskell musl host: link the interpreter's libc
                  # dynamically.  `executable-static: True` (every musl
                  # host, modules/cabal-project.nix) is `-fully-static` on
                  # the fork since 571f1a2ac, and a fully static musl
                  # interpreter has no dlsym, so the RTS linker could not
                  # resolve a single libc symbol for the archives a splice
                  # loads -- every ghc914-sh aarch64-musl TH build since
                  # then has died with
                  #   iserv-proxy-interpreter: Failed to lookup symbol: strlen
                  # (the mainline GHCs get them by loading libc.a, which
                  # the fork's RTS linker now skips).  The interpreter only
                  # ever runs on the build machine (directly or under
                  # qemu), so nothing needs it static.  Haskell libraries
                  # stay static; only libc &c. are shared.  The C++
                  # runtime is linked in up front for the same reason as
                  # ghc-iserv's (see its stanza in modules/cabal-project.nix):
                  # dlopening nixpkgs' libstdc++.so cannot find its
                  # libgcc_s.so.1.
                  #
                  # i386-musl's symbol table names musl's hidden
                  # `__aio_close`, which only links fully static. The
                  # i386 source patch above removes that table reference so
                  # this interpreter can resolve the public libc symbols it
                  # needs through dlsym like the other musl targets.
                  #
                  # pkgsStatic (`static`) has no libgcc_s, so there only
                  # libc is linked dynamically (musl-static still ships
                  # libc.so); the slice builder also drops the stdenv's
                  # `-static` for this package (`iservDynamicLibc` in
                  # builder/comp-v2-builder.nix).
                  + pkgs.lib.optionalString (
                       pkgs.stdenv.hostPlatform.isMusl
                    && (!pkgs.stdenv.hostPlatform.isx86_32
                      || (compiler-nix-name == "ghc914-sh"
                        && pkgs.stdenv.hostPlatform.isLinux))
                    && (final.buildPackages.haskell-nix.compiler.${compiler-nix-name}.emptyGlobalPackageDb or false)
                  ) ''
                    package iserv-proxy
                      executable-static: False${pkgs.lib.optionalString (!pkgs.stdenv.hostPlatform.isStatic)
                        "\n  ghc-options: -optl-Wl,--no-as-needed -optl-lstdc++ -optl-lgcc_s"}
                  ''
                  # Build the iserv-proxy executables with profiling
                  # for the `-prof` variant.  GHC selects the iserv
                  # to spawn at TH-eval time by appending `-prof` to
                  # `-pgmi`, so we have to produce a prof-linked
                  # binary that has the profiling RTS symbols (e.g.
                  # `registerCcList`) the loaded `.p_o` modules
                  # reference.
                  + pkgs.lib.optionalString profiled ''
                    package iserv-proxy
                      profiling: True
                  '';
              });
              exes = evalSystem: profiled: pkgs:
                (proj evalSystem profiled pkgs).hsPkgs.iserv-proxy.components.exes;
              exesFor = evalSystem: rec {
              # We need the proxy for the build system and the interpreter for the target.
              # `iserv-proxy` is invoked on the build platform — it doesn't
              # need profiling, so use the non-profiled project.
              inherit (exes evalSystem false final.pkgsBuildBuild) iserv-proxy;
              iserv-proxy-interpreter = (exes evalSystem false final).iserv-proxy-interpreter.override
                (final.lib.optionalAttrs final.stdenv.hostPlatform.isAndroid {
                  setupBuildFlags = ["--ghc-option=-optl-static" "--ghc-option=-optl-ldl"] ++ final.lib.optional final.stdenv.hostPlatform.isAarch32 "--ghc-option=-optl-no-pie";
                  enableDebugRTS = true;
                } // final.lib.optionalAttrs final.stdenv.hostPlatform.isWindows {
                  setupBuildFlags = ["--ghc-option=-optl-Wl,--disable-dynamicbase,--disable-high-entropy-va,--image-base=0x400000" ];
                  enableDebugRTS = true;
                });
              # Profiled variant: rebuild the iserv-proxy project
              # with `package iserv-proxy profiling: True` baked into
              # cabal.project so v2's slice picks it up.  Keep the
              # v1-style `enableProfiling = true` override too in
              # case v1's comp-builder is ever in play here.
              iserv-proxy-interpreter-prof = (exes evalSystem true final).iserv-proxy-interpreter.override
                ({ enableProfiling = true; }
                 // final.lib.optionalAttrs final.stdenv.hostPlatform.isAndroid {
                   setupBuildFlags = ["--ghc-option=-optl-static" "--ghc-option=-optl-ldl"] ++ final.lib.optional final.stdenv.hostPlatform.isAarch32 "--ghc-option=-optl-no-pie";
                   enableDebugRTS = true;
                 } // final.lib.optionalAttrs final.stdenv.hostPlatform.isWindows {
                   setupBuildFlags = ["--ghc-option=-optl-Wl,--disable-dynamicbase,--disable-high-entropy-va,--image-base=0x400000" ];
                   enableDebugRTS = true;
                 });
              # The plan-nix derivations behind the three exes above (the
              # build-platform proxy and the host-platform interpreter share
              # a plan only when build == host; the profiled interpreter's
              # cabal.project differs, so its plan is always distinct).
              # `haskell-nix.roots` links them so CI pushes them to the
              # binary cache and later evaluations substitute the plans
              # instead of building them mid-eval.
              plan-nixes = {
                iserv-proxy = (proj evalSystem false final.pkgsBuildBuild).plan-nix;
                iserv-proxy-interpreter = (proj evalSystem false final).plan-nix;
                iserv-proxy-interpreter-prof = (proj evalSystem true final).plan-nix;
              };
              };
              # Memoised per-eval-system variants (same pattern as the
              # compiler's `evalWith`, overlays/stable-haskell.nix): the
              # exe derivations are identical for every eval system, but
              # *computing* them forces the iserv-proxy plan-to-nix IFD on
              # the project's eval platform — so consumers must select the
              # variant matching their `evalSystem` or the IFD runs on the
              # default (pkgsBuildBuild) system, which may not even have a
              # builder on the eval host.
              byEvalSystem = final.lib.mapAttrs (evalSystem: _evalPackages:
                exesFor evalSystem) final.haskell-nix.evalPackages;
            in byEvalSystem.${final.pkgsBuildBuild.stdenv.hostPlatform.system}
               // { evalWith = byEvalSystem; }) final.haskell-nix.compiler;

          ghc-pre-existing = ghc: [
            "Cabal"
            "array"
            "base"
            "binary"
            "bytestring"
            "containers"
            "deepseq"
            "directory"
            "filepath"
            "ghc-boot"
            "ghc-boot-th"
            "ghc-compact"
            "ghc-heap"
            "ghc-prim"
            "ghci"
            "integer-gmp"
            "mtl"
            "parsec"
            "pretty"
            "process"
            "rts"
            "template-haskell"
            "text"
            "time"
            "transformers"
          ] ++ final.lib.optionals (!final.stdenv.targetPlatform.isGhcjs || builtins.compareVersions ghc.version "9.0" > 0) [
            # GHCJS 8.10 does not have these
            "Cabal-syntax"
            "exceptions"
            "file-io"
            "ghc"
            "ghc-bignum"
            "ghc-experimental"
            "ghc-internal"
            "ghc-platform"
            "ghc-toolchain"
            "haskeline"
            "hpc"
            "libiserv"
            "os-string"
            "semaphore-compat"
            "stm"
            "xhtml"
          ] ++ final.lib.optionals (builtins.compareVersions ghc.version "9.4" > 0) [
            "system-cxx-std-lib"
          ] ++ final.lib.optionals (builtins.compareVersions ghc.version "9.12" > 0) [
            "haddock-api"
            "haddock-library"
          ] ++ final.lib.optionals (builtins.compareVersions ghc.version "9.14" >= 0) [
            "rts-headers"
            "rts-fs"
            "template-haskell-lift"
            "template-haskell-quasiquoter"
          ] ++ final.lib.optionals (
                  !final.stdenv.targetPlatform.isGhcjs
               && !final.stdenv.targetPlatform.isWindows
               && ghc.enableTerminfo or true) [
            "terminfo"
          ] ++ (if final.stdenv.targetPlatform.isWindows
            then [ "Win32" ]
            else [ "unix" ]
          );

        # Add this to your tests to make all the dependencies of haskell.nix
        # are tested and cached. Consider using `p.roots` where `p` is a
        # project as it will automatically match the `compiler-nix-name`
        # of the project.
        roots = { compiler-nix-name, ... }@args: final.linkFarm "haskell-nix-roots-${compiler-nix-name}"
          (final.lib.filter (x: x.name != "recurseForDerivations")
            (final.lib.mapAttrsToList (name: path: { inherit name path; })
              (roots' args 2)));

        # Takes `evalSystem` (a system string).  `evalPackages` (a nixpkgs),
        # which it replaced, is still accepted with a deprecation warning.
        roots' = { compiler-nix-name, ... }@rootsArgs: ifdLevel:
          let
            evalSystem =
              if rootsArgs ? evalPackages
              then final.lib.warn
                ("haskell-nix.roots: the `evalPackages` argument is deprecated; "
                 + "pass `evalSystem = \"${rootsArgs.evalPackages.stdenv.hostPlatform.system}\";` instead.")
                rootsArgs.evalPackages.stdenv.hostPlatform.system
              else rootsArgs.evalSystem or final.pkgsBuildBuild.stdenv.hostPlatform.system;
            evalPackages = final.haskell-nix.evalPackages.${evalSystem};
            # The default (build-system) compiler variant and the variant for
            # `evalSystem`.  Their final build derivations are identical; they
            # differ only in where eval-time work (plan-to-nix IFD, dummy
            # ghc/ghc-pkg) runs.
            ghcBuild = final.buildPackages.haskell-nix.compiler.${compiler-nix-name};
            ghc = ghcBuild.evalWith.${evalSystem}
              or (ghcBuild.override { evalSystem = evalSystem; });
            evalDiffers = evalSystem != final.pkgsBuildBuild.stdenv.hostPlatform.system;
            # Link each attr `n` of `defaultAttrs` (the build-system drv —
            # buildable by CI without IFD and substituted by native
            # evaluators later) and, when the eval system differs from the
            # build system, its eval-system twin as `n-eval` (realised
            # during THIS evaluation anyway; linking it gets it pushed to
            # the cache for other eval hosts of the same system).
            withEvalVariants = defaultAttrs: evalAttrs:
              defaultAttrs
              // final.lib.optionalAttrs evalDiffers
                   (final.lib.mapAttrs' (n: _: { name = "${n}-eval"; value = evalAttrs.${n}; }) defaultAttrs);
            planNames = final.lib.mapAttrs' (n: v: { name = "plan-${n}"; value = v; });
            v2ci = final.pkgsBuildBuild.haskell-nix.v2-cabal-install;
          in
            final.lib.recurseIntoAttrs ({
            # Things that require no IFD to build
            source-pin-hackage = hackageSrc;
            source-pin-stackage = stackageSrc;
            source-pin-haskell-nix = final.path;
            inherit (evalPackages) nix gitMinimal nix-prefetch-git;
          } // final.lib.optionalAttrs (final.stdenv.hostPlatform.libc == "glibc") {
            inherit (final) glibcLocales;
          }
            # Cache every plan-nix needed to evaluate the compiler (hadrian
            # for hadrian-built GHCs; stage1/stage2 for the stable-haskell
            # ones).  A plan-nix that is not cached must be BUILT (via IFD)
            # by whoever evaluates a project using the compiler — for
            # hydra's evaluator that is the nix-eval-jobs hang class.
            // withEvalVariants (planNames (ghcBuild.plan-nixes or {}))
                                (planNames (ghc.plan-nixes or {}))
            # (nix-tools needs no root: it is a prebuilt static bundle, with
            # no `project` and so no plan to cache.)
            # The v2 builder's patched cabal-install plan; only
            # stable-haskell compilers use the v2 builder today, so gate on
            # that rather than building the cabal fork for every compiler's
            # roots.
            // final.lib.optionalAttrs (ghcBuild.isStableHaskell or false)
                 (withEvalVariants
                   { plan-v2-cabal-install = v2ci.project.plan-nix; }
                   { plan-v2-cabal-install = (v2ci.evalWith.${evalSystem} or v2ci).project.plan-nix; })
            # The eval-time dummy ghc/ghc-pkg pair (and, through it, the
            # eval-platform source trees it embeds) — realised during every
            # project evaluation for compilers that carry it.
            // final.lib.optionalAttrs (ghcBuild ? dummyGhcPkgs)
                 (withEvalVariants
                   { inherit (ghcBuild.dummyGhcPkgs) dummy-ghc dummy-ghc-pkg; }
                   { inherit (ghc.dummyGhcPkgs) dummy-ghc dummy-ghc-pkg; })
            // final.lib.optionalAttrs (ifdLevel > 0) {
            # Things that require one IFD to build (the inputs should be in level 0)
            inherit ghc;
            ghc-boot-packages-nix = final.ghc-boot-packages-nix.${compiler-nix-name};
          } // final.lib.optionalAttrs (ifdLevel > 0 && ghc ? generated-light) {
            # Cache hadrian's generated sources (primops / deriveConstants /
            # config) built *without* compiling all of GHC.  Consumers pull
            # these at evaluation time (`useLocalGhcLib` / `ghc-lib-reinstallable`
            # and `ghc-boot-packages`); caching the derivation here means those
            # evals substitute it instead of rebuilding it via IFD.
            ghc-generated = ghc.generated-light;
          } // final.lib.optionalAttrs (ifdLevel > 1) {
            # Things that require two levels of IFD to build (inputs should be in level 1)
            nix-tools-unchecked = final.pkgsBuildBuild.haskell-nix.nix-tools-unchecked;
          } // final.lib.optionalAttrs (ifdLevel > 1
            && final.haskell-nix.haskellLib.isCrossHost
            # GHCJS builds its own template haskell runner.
            # These seem to be the only things we use from `ghc-extra-packages`
            # in haskell.nix itself.
            && !final.stdenv.hostPlatform.isGhcjs
            && !final.stdenv.hostPlatform.isWasm
            && final.haskell-nix.iserv-proxy-exes ? ${compiler-nix-name})
              (let
                iservDefault = final.haskell-nix.iserv-proxy-exes.${compiler-nix-name};
                iservEval = iservDefault.evalWith.${evalSystem};
              in builtins.removeAttrs iservEval [ "plan-nixes" ]
                 # The plans behind the exes above, both variants (see
                 # `withEvalVariants`) — cached so evaluating the exes
                 # substitutes the plans instead of building them.
                 // withEvalVariants (planNames iservDefault.plan-nixes)
                                     (planNames iservEval.plan-nixes)));
    };
}
