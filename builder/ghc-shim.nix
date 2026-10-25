# Build a ghc "shim" directory that mirrors `${ghc}/bin/*` but
# applies the small set of tweaks v2 needs from ghc:
#
#   * Cross GHCs ship only `<prefix>ghc-pkg`; cabal v2-build's
#     "near-compiler" lookup expects `ghc-pkg` in the same dir.
#     Add unprefixed aliases for every prefixed binary so cabal
#     finds `ghc-pkg`, `hsc2hs`, `runghc`, etc.
#
#   * ghcjs: lndir real ghc's TOPDIR into the shim, materialise a
#     writable `settings` file, sed-swap the `ar command` entry to
#     `ghcjsArWrapper` (drops missing `.o`s — backpack-on-ghcjs
#     workaround), and wrap `ghc` / `ghc-<v>` with `-B<topdir>` so
#     ghc uses the patched settings.
#
#   * native-musl ghc ≥ 9.10: lndir topdir into the shim, wrap ghc
#     binaries with `-B<topdir>`, and add unprefixed aliases for
#     `unlit` and `ghc-iserv[-dyn|-prof]`.  Mirrors v1's
#     `ghc-for-component-wrapper.nix:136-140`.
#
# Used by:
#   * `build-cabal-slice.nix` — slice's `--with-compiler=` target.
#   * `shell-for-v2.nix` — base of the user-facing shell's ghc;
#     the `ghc-pkg` exposure mode layers env-var wrappers on top.
#
# Topdir vs libdir matters on the stable-haskell multi-target GHCs:
# `--print-libdir` answers with the target-resolved `targets/<triple>/lib`,
# while `-B` expects the level above it.  See `mirrorTopdir` below.
{ stdenv, lib, pkgsBuildBuild, haskellLib }:

{ ghc
, # if non-null AND ghcjs, sed the `ar command` entry of the
  # patched settings file to point at this wrapper.  Pass `null`
  # to skip the patch (still does the lib lndir, settings copy,
  # and `-B` wrap — useful when the caller doesn't have an ar
  # wrapper handy).
  ghcjsArWrapper ? null
, # extra paths to prefix into `LD_LIBRARY_PATH` when the wrapped
  # ghc binaries run.  Used on native-musl to give iserv-dyn (which
  # ghc spawns for TH eval) the musl-gcc libs dir — its transitive
  # `libstdc++.so` → `libgcc_s.so.1` lookup would otherwise miss.
  # Scoping the env to the ghc wrapper (rather than the whole
  # derivation) keeps glibc subprocesses cabal spawns directly —
  # notably `git` for `source-repository-package` — from loading
  # musl libs and crashing.
  extraLibraryPaths ? []
}:

let
  targetPrefix = ghc.targetPrefix or "";
  ghcBin = "${targetPrefix}ghc";
  # Every native-musl GHC needs the LD_LIBRARY_PATH prefix shim
  # (see `extraLibraryPaths` above for the iserv libgcc lookup).
  # The unprefixed alias creation (unlit, ghc-iserv…) is a separate
  # concern that only applies from 9.10 onwards — before that, ghc
  # ships those tools at unprefixed paths already.
  nativeMuslNeedsAliases =
    haskellLib.isNativeMusl
    && builtins.compareVersions ghc.version "9.10" >= 0;
  needsLibShim =
    stdenv.hostPlatform.isGhcjs
    || haskellLib.isNativeMusl;

  # Mirror the real ghc's libdir tree into the shim and leave three shell
  # variables behind for the branch that uses it:
  #
  #   libRel       the mirrored TOPDIR, relative to $out -- this is what `-B`
  #                must be given.
  #   settingsRel  the TARGET libdir, relative to $out -- this is where
  #                `settings` actually lives.
  #   ghcTop       the source topdir that was mirrored.
  #
  # Why topdir and not just `--print-libdir`: on a stable-haskell
  # multi-target GHC that flag answers with the TARGET-resolved directory
  # (`$topdir/targets/<triple>/lib`), whereas `-B` wants the level above it --
  # GHC appends `targets/<triple>/lib` to whatever `-B` is given.  Handing the
  # resolved path back doubles the suffix and every invocation dies with
  #
  #   ghc: Couldn't find specific target `<triple>' in
  #     `…/targets/<triple>/lib/targets/<triple>/lib'
  #
  # `ghc --numeric-version` included, which then exits 1 having printed
  # nothing -- and cabal's compiler probe reports that empty string back as
  # [Cabal-1008] "the version of … could not be determined" (seen on
  # `ghcjs.tests.cabal-sublib-shell`).  Single-target GHCs have no
  # `targets/<triple>/lib` suffix to strip, so `ghcTop == ghcLib` and they are
  # unaffected -- which is why native-musl never showed this.
  mirrorTopdir = ''
    mkdir -p $out/bin
    ghcLib=$(${ghc}/bin/${ghcBin} --print-libdir)
    ghcTop="$ghcLib"
    case "$ghcLib" in
      */targets/*/lib) ghcTop=''${ghcLib%/targets/*/lib} ;;
    esac
    libRel=''${ghcTop#${ghc}/}
    settingsRel=''${ghcLib#${ghc}/}
    mkdir -p "$out/$libRel"
    lndir -silent "$ghcTop" "$out/$libRel"
  '';
in

pkgsBuildBuild.runCommand "${ghc.name}-shim" {
  preferLocalBuild = true;
  nativeBuildInputs = lib.optionals needsLibShim [
    (pkgsBuildBuild.lndir or pkgsBuildBuild.xorg.lndir)
    pkgsBuildBuild.makeWrapper
  ];
  passthru = {
    inherit (ghc) version meta;
    inherit targetPrefix;
  };
} (
  (if stdenv.hostPlatform.isGhcjs then ''
    ${mirrorTopdir}
    settingsFile="$out/$settingsRel/settings"
    if [ -L "$settingsFile" ]; then
      cp --remove-destination "$(readlink -f "$settingsFile")" "$settingsFile"
    fi
    ${lib.optionalString (ghcjsArWrapper != null) ''
      # NB no space after the comma in the generated settings file —
      # `("ar command","…")` — so match optional whitespace.  With the old
      # `", "` pattern the sed silently never matched and both GHC and
      # cabal (which takes its `ar` hint from ghc's settings — the
      # "Using ar found on system at" line) kept the RAW emar.
      sed -i 's|("ar command", *"[^"]*")|("ar command","${ghcjsArWrapper}")|' "$settingsFile"
      grep -qF '${ghcjsArWrapper}' "$settingsFile" || {
        echo "ghc-shim: ar command swap did not match settings" >&2
        exit 1
      }
    ''}
    for f in ${ghc}/bin/*; do
      base=$(basename "$f")
      case "$base" in
        ${ghcBin}|${ghcBin}-${ghc.version})
          makeWrapper "$f" "$out/bin/$base" --add-flags "-B$out/$libRel"
          ;;
        *)
          ln -s "$f" "$out/bin/$base"
          ;;
      esac
    done
  ''
  else if haskellLib.isNativeMusl then ''
    ${mirrorTopdir}
    for f in ${ghc}/bin/*; do
      base=$(basename "$f")
      case "$base" in
        ${ghcBin}|${ghcBin}-${ghc.version})
          makeWrapper "$f" "$out/bin/$base" --add-flags "-B$out/$libRel" ${
            lib.concatMapStringsSep " "
              (p: "--prefix LD_LIBRARY_PATH : ${p}")
              extraLibraryPaths
          }
          ;;
        *)
          ln -s "$f" "$out/bin/$base"
          ;;
      esac
    done
    ${lib.optionalString nativeMuslNeedsAliases (
      # Literate pre-processor + iserv lookups.  GHC ≥ 9.10
      # only — earlier versions ship those tools at unprefixed
      # paths already.  Guarded on existence so a ghc that lacks
      # `<prefix>ghc-iserv-dyn` (etc.) just skips that one alias
      # instead of dangling.
      lib.concatMapStrings (a: ''
        if [ -e "${ghc}/bin/${targetPrefix}${a}" ] && [ ! -e "$out/bin/${a}" ]; then
          ln -s "${targetPrefix}${a}" "$out/bin/${a}"
        fi
      '') [ "unlit" "ghc-iserv" "ghc-iserv-dyn" "ghc-iserv-prof" ]
    )}
  '' else ''
    mkdir -p $out/bin
    for f in ${ghc}/bin/*; do
      base=$(basename "$f")
      ln -s "$f" "$out/bin/$base"
    done
  '')
  + lib.optionalString (targetPrefix != "") ''
    for f in ${ghc}/bin/${targetPrefix}*; do
      base=$(basename "$f")
      unprefixed=''${base#${targetPrefix}}
      [ -e "$out/bin/$unprefixed" ] || ln -s "$base" "$out/bin/$unprefixed"
    done
  ''
)
