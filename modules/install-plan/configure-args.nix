# Extract program options from plan.json configure-args and apply them
# to the corresponding packages.  This allows options set in a
# cabal.project file (via `package` or `program-options` stanzas)
# to be picked up automatically by haskell.nix.
#
# --ghc-option / --ghcjs-option  →  ghcOptions  (dedicated option)
# --configure-option=            →  configureOptions (cabal-project round-trip)
# --<prog>-option=               →  configureFlags  (passed through, v1)
#                                 + programOptions (per-program list keyed by
#                                   PROG, emitted back as a `<prog>-options:`
#                                   line in v2's slice cabal.project so cabal
#                                   threads it to the program's ProgramDb).
#                                   `configure-options:` is only honoured for
#                                   `build-type: Configure` packages, so v2
#                                   can't round-trip the v1 `--<prog>-option=`
#                                   form via `--configure-option=` wrapping —
#                                   we use the native field instead.
{config, lib, ...}: {
  packages = lib.listToAttrs (lib.concatMap (p:
    let
      configureArgs = p.configure-args or [];
      # The first element is the command name ("configure"), skip it.
      args = if configureArgs != [] then builtins.tail configureArgs else [];

      # Extract --ghc-option=VALUE and --ghcjs-option=VALUE entries
      # into the dedicated ghcOptions option.
      #
      # Filter `-hide-all-packages`: cabal injects it on every Setup
      # configure call (it explicitly hides all packages and re-adds
      # them via --dependency=).  Round-tripping it through the v2
      # builder's `package <n>\n  ghc-options:` block would cause a
      # duplicate `--ghc-option=-hide-all-packages` to appear in the
      # slice's `pkgHashProgramArgs` while a downstream cabal-build
      # only sees it once — forking the UnitId hash and defeating
      # cache reuse.
      ghcOptions = lib.concatMap (arg:
        let
          m = builtins.match "--(ghc|ghcjs)-option=(.*)" arg;
          opt = if m != null then builtins.elemAt m 1 else null;
        in lib.optional (m != null && (config.builderVersion == 1 || opt != "-hide-all-packages")) opt
      ) args;

      # Extract other --PROG-option=VALUE entries (gcc, ld, hsc2hs,
      # alex, happy, c2hs, cpphs, ghc-pkg, …) that aren't already
      # handled by `--ghc-option` / `--configure-option`.
      otherFlags = builtins.filter (arg:
        let
          isProgOption = builtins.match "--[a-z][a-z0-9-]*-option=.*" arg != null;
          isGhcOption = builtins.match "--(ghc|ghcjs)-option=.*" arg != null;
          isCfgOption = builtins.match "--configure-option=.*" arg != null;
        in isProgOption && !isGhcOption && !isCfgOption
      ) args;

      # Extract --configure-option=VALUE entries into the dedicated
      # configureOptions option.  These come from cabal.project's
      # `configure-options:` stanza and the v2 builder emits them
      # back into its own cabal.project so UnitIds stay consistent
      # between a slice build and downstream consumers.
      #
      # Per-program `--<prog>-option=` entries (`otherFlags`) must NOT
      # be added here: cabal hashes `configure-options:` into
      # `pkgHashConfigureScriptArgs` and passes them as
      # `--configure-option=` (to ./configure only), so re-emitting
      # them would fork the slice's UnitId from plan-nix's.  v2
      # round-trips them via `programOptions` below instead.
      configureOptions =
        lib.concatMap (arg:
          let m = builtins.match "--configure-option=(.*)" arg;
          in lib.optional (m != null) (builtins.elemAt m 0)
        ) args;

      # Translate `--enable-X` toggles cabal-install records in
      # plan.json's `configure-args` back into haskell.nix module
      # options.  v1's comp-builder reads these straight off each
      # component config — picking them up here lets a project set
      # e.g. `package <pkg>\n  profiling: True` /
      # `debug-info: 2` in cabal.project and have v1 honour it
      # without also needing module-level toggles.  v2 reads from
      # plan.json directly via `projectConfigPragmas`, so the
      # picked-up values are merely consistent there.
      hasEnableFlag = name: lib.elem ("--enable-${name}") args;
      enableFlags =
        lib.optionalAttrs (hasEnableFlag "profiling")         { enableProfiling        = true; }
        // lib.optionalAttrs (hasEnableFlag "library-profiling") { enableLibraryProfiling = true; }
        // lib.optionalAttrs (hasEnableFlag "coverage")        { doCoverage             = true; }
        // lib.optionalAttrs (hasEnableFlag "debug-info")      { enableDWARF            = true; };

      # Group `--<prog>-option=VAL` entries by PROG so the v2 builder
      # can emit `<prog>-options:` lines per program in the slice's
      # cabal.project — `configure-options:` isn't honoured for
      # `build-type: Simple` packages, but `<prog>-options:` is.
      progOptionPairs = lib.concatMap (arg:
        let m = builtins.match "--([a-z][a-z0-9-]*)-option=(.*)" arg;
        in lib.optional (m != null) {
          prog = builtins.elemAt m 0;
          option = builtins.elemAt m 1;
        }
      ) otherFlags;
      progNames = lib.unique (map (e: e.prog) progOptionPairs);
      programOptions = lib.listToAttrs (map (prog: {
        name = prog;
        value = map (e: e.option) (lib.filter (e: e.prog == prog) progOptionPairs);
      }) progNames);

      # Extract `--extra-lib-dirs=PATH` and `--extra-include-dirs=PATH`
      # entries.  These come from cabal.project's `package <pkg>`
      # `extra-lib-dirs:` / `extra-include-dirs:` stanzas; v2 re-emits
      # the same lines in the slice's cabal.project so the slice's
      # cabal-computed unit-id includes the same `pkgHashExtraLibDirs`
      # / `pkgHashExtraIncludeDirs` inputs plan-nix did.
      extractValuedFlag = flagName: lib.concatMap (arg:
        let m = builtins.match "--${flagName}=(.*)" arg;
        in lib.optional (m != null) (builtins.elemAt m 0)
      ) args;
      extraLibDirs     = extractValuedFlag "extra-lib-dirs";
      extraIncludeDirs = extractValuedFlag "extra-include-dirs";

      value =
        lib.optionalAttrs (ghcOptions != []) { inherit ghcOptions; }
        // lib.optionalAttrs (configureOptions != []) { inherit configureOptions; }
        // lib.optionalAttrs (otherFlags != []) { configureFlags = otherFlags; }
        // lib.optionalAttrs (programOptions != {}) { inherit programOptions; }
        // lib.optionalAttrs (extraLibDirs != []) { inherit extraLibDirs; }
        // lib.optionalAttrs (extraIncludeDirs != []) { inherit extraIncludeDirs; }
        // enableFlags;
    in lib.optional (value != {}) {
      name = p.id;
      inherit value;
    }
  ) config.plan-json.install-plan);
}
