{ lib, config, pkgs, ... }:
with lib;
let
  cfg = config.replace-hackage-tarball-urls;

  # Direct Hackage tarball URLs (`{ url; name; version; }`) in a cabal.project
  # `packages:` stanza; parsing shared with the stable-haskell overlay.
  urlsIn = pkgs.haskell-nix.haskellLib.hackageTarballUrls;

  # Plan side (EVAL platform): rewrite each URL to a hackage.nix tarball built
  # with `evalPackages`, so plan-to-nix resolves the exact pinned version
  # offline — no network access, and no need for the version to be present at
  # the project's `index-state`.  `replaceStrings` keeps the substituted store
  # paths' string context.
  rewrite = text:
    let found = urlsIn text;
    in builtins.replaceStrings
         (map (p: p.url) found)
         (map (p: toString (pkgs.haskell-nix.hackageTarball
                { inherit (p) name version; inherit (config) evalPackages; })) found)
         text;

  # Build side (BUILD platform): the packages found in the user's project text.
  # cabal treats a rewritten URL as a LOCAL package, so plan-to-nix records its
  # `src` as the eval-platform store path from `rewrite` above.  We override
  # that `src` to the content-identical BUILD-platform tarball
  # (`hackageTarball`'s default `evalPackages = buildPackages`), so the built
  # derivation does not depend on the eval platform — a darwin dev-eval and a
  # linux CI eval must produce the same derivation.
  #
  # Unlike `rewrite` (which substitutes over the whole text, harmlessly turning
  # any commented URL into a store path in the comment), these overrides drive
  # real `packages.<name>.src` definitions, so we skip commented-out URLs — a
  # commented URL is not a `packages:` entry and has no package in the plan.
  # Scan the same text `rewrite` is applied to — the assembled cabal.project
  # (`cabalProject` + `cabalProjectLocal`, see `rawCabalProject` in
  # lib/call-cabal-project-to-nix.nix).  A URL that only appears in
  # `cabalProjectLocal` would otherwise get the eval-platform rewrite in the
  # plan but no build-platform `src` override, leaking the eval platform
  # into the built derivation.
  found = lib.concatMap
    (line: lib.optionals (builtins.match "[[:space:]]*--.*" line == null) (urlsIn line))
    (lib.splitString "\n"
      ((if config.cabalProject == null then "" else config.cabalProject)
       + "\n"
       + (if config.cabalProjectLocal == null then "" else config.cabalProjectLocal)));
in {
  _file = "haskell.nix/modules/replace-hackage-tarball-urls.nix";
  options = {
    replace-hackage-tarball-urls = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When enabled, rewrite direct Hackage tarball URLs in the cabal.project
        `packages:` stanza — of the form
        `https://hackage.haskell.org/package/NAME-VER/NAME-VER.tar.gz` — into
        local nix store paths fetched via hackage.nix (haskell-nix.hackageTarball).

        This lets cabal use the exact pinned versions without network access
        during plan-to-nix, and without the version needing to be present at the
        project's `index-state` (hackage.nix carries the sha256 for the exact
        version).  Off by default; enable for projects (such as the stable
        Haskell GHC build) that pin dependencies via direct Hackage URLs.

        The plan-to-nix rewrite uses `evalPackages` (the tarballs are only read
        at eval time), while each found package's build `src` is overridden to
        the content-identical `buildPackages` tarball, so the built derivation
        stays independent of the eval platform.
      '';
    };
    # `text -> text` hook applied to the assembled cabal.project before
    # plan-to-nix (consumed by lib/call-cabal-project-to-nix.nix).  Kept as an
    # option so it travels in the project `config` passed to
    # callCabalProjectToNix.
    cabalProjectRewrite = mkOption {
      internal = true;
      type = types.unspecified;
      default = p: p;
    };
  };
  config = mkIf cfg {
    cabalProjectRewrite = rewrite;
    modules = [ {
      packages = builtins.listToAttrs (map (p: {
        inherit (p) name;
        value.src = lib.mkForce (pkgs.haskell-nix.hackageTarball { inherit (p) name version; });
      }) found);
    } ];
  };
}
