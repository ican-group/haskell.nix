# haskell.nix's flake-parts module (`flakeModules.default`, ../../flake-module.nix)
# on the `cabal-simple` test's source, with two projects:
#
#  * `default`, from two definitions (they merge like project modules), whose
#    outputs keep their names;
#  * `other`, whose outputs get `other:` in front (and no `other:default`).
#
# It checks the output names at evaluation time (as the flake would have them
# for this system), that reading the option gives the project, that
# `addFlakeOutputs = false` and `addHydraJobs = false` leave the flake alone,
# and builds and runs the
# `default` project's executable from the flake's `packages`.
{ stdenv, lib, pkgs, haskell-nix, runCommand, testSrc, compiler-nix-name, evalSystem, testCabalProjectLocal, testInputMap, ... }:

let
  inherit (stdenv.hostPlatform) system;

  flake-parts = haskell-nix.sources.flake-parts;

  module = lib.setDefaultModuleLocation ../../flake-module.nix
    (import ../../flake-module.nix { pkgsFor = _: pkgs; });

  projectArgs = {
    src = testSrc "cabal-simple";
    inherit compiler-nix-name evalSystem;
    inputMap = testInputMap;
    cabalProjectLocal = testCabalProjectLocal;
    # Package has no exposed modules which causes
    #   haddock: No input file(s)
    modules = [{ packages.cabal-simple.doHaddock = false; }];
  };

  evalFlake = extraPerSystem: extraTop: flake-parts.lib.evalFlakeModule
    { inputs.self = { outPath = ./.; }; }
    {
      imports = [ module extraTop ];
      systems = [ system ];
      perSystem = {
        imports = [ extraPerSystem ];
        haskellNix.projects.default = projectArgs;
        haskellNix.projects.other = projectArgs;
      };
    };

  extraJob = runCommand "flake-parts-extra-job" { } "touch $out";

  eval = evalFlake ({ config, ... }: {
    # A second definition of the same project.
    haskellNix.projects.default = { name = "flake-parts-default"; };
    # A job added to the projects' `packages` jobs, and one that clashes
    # with a project job.
    haskellNix.hydraJobs.packages.extra = extraJob;
    haskellNix.hydraJobs.packages.${exe} = extraJob;
  }) { };
  flake = eval.config.flake;
  perSystem = eval.config.allSystems.${system};

  disabledEval = evalFlake { haskellNix.addFlakeOutputs = false; } { };
  noJobsEval = evalFlake { } { haskellNix.addHydraJobs = false; };

  exe = "cabal-simple:exe:cabal-simple";

  expect = what: cond: lib.assertMsg cond "flake-parts test: ${what}";
  hasAll = names: attrs: lib.all (n: attrs ? ${n}) names;

  checked =
    assert expect "packages has both projects' executables, and the default project's default"
      (hasAll [ exe "other:${exe}" "default" ] flake.packages.${system}
        && !(flake.packages.${system} ? "other:default")
        && !(flake.apps.${system} ? "other:default"));
    assert expect "apps has both projects' executables"
      (hasAll [ exe "other:${exe}" ] flake.apps.${system}
        && flake.apps.${system}.${exe}.type == "app");
    assert expect "devShells has `default` and `other`"
      (hasAll [ "default" "other" ] flake.devShells.${system});
    # The `default` project's jobs are not under a name of their own.
    assert expect "ciJobs is laid out `ciJobs.<system>.<job>`"
      (hasAll [ "packages" "other" ] flake.ciJobs.${system});
    assert expect "hydraJobs is laid out `hydraJobs.<job>.<system>`"
      (flake.hydraJobs.packages ? ${system} && flake.hydraJobs.other ? ${system});
    assert expect "`haskellNix.hydraJobs` definitions add to the projects' jobs"
      (hasAll [ "extra" "cabal-simple:lib:cabal-simple" ] flake.hydraJobs.packages.${system}
        && hasAll [ "extra" "cabal-simple:lib:cabal-simple" ] flake.ciJobs.${system}.packages);
    assert expect "a job defined twice is an error when it is used"
      (!(builtins.tryEval (builtins.seq flake.hydraJobs.packages.${system}.${exe} null)).success);
    assert expect "the option's value is the project, with both definitions merged"
      (perSystem.haskellNix.projects.default.args.name == "flake-parts-default"
        && perSystem.haskellNix.projects.default ? hsPkgs);
    assert expect "`addFlakeOutputs = false` adds nothing to the flake"
      (disabledEval.config.flake.packages.${system} == { }
        && disabledEval.config.flake.hydraJobs == { }
        && disabledEval.config.allSystems.${system}.haskellNix.outputs.packages ? ${exe});
    assert expect "`addHydraJobs = false` leaves `hydraJobs` and `ciJobs` unset"
      (!(noJobsEval.config.flake ? hydraJobs) && !(noJobsEval.config.flake ? ciJobs)
        && noJobsEval.config.flake.packages.${system} ? ${exe});
    true;

in lib.recurseIntoAttrs {
  ifdInputs = {
    inherit (perSystem.haskellNix.projects.default) plan-nix;
  };

  run = assert checked; runCommand "flake-parts-test" { } ''
    ${flake.packages.${system}.${exe}}/bin/cabal-simple
    touch $out
  '';

  # The module only adds names around what `project.flake` makes, so one
  # native platform covers it.
  meta.disabled = stdenv.hostPlatform != stdenv.buildPlatform;
}
