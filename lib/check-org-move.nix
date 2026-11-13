{ lib }:
# Warn projects whose pins (flake.lock, niv, npins) still name the old
# GitHub owner of haskell.nix (or hackage.nix / stackage.nix).
#
# haskell.nix cannot tell how it was itself fetched (`sourceInfo` has no
# owner, and GitHub's redirect serves identical content), but the
# project's own pins are usually inside `src`.  Reading them is a plain
# readFile of a source path, so it is not IFD.  We stay silent whenever
# the pins cannot be read cheaply.
let
  oldOwner = "input-output-hk";
  newOwner = "ican-group";
  repos = [ "haskell.nix" "hackage.nix" "stackage.nix" ];

  # Lower case `haskell.nix` from `{ repo = ...; }` or a GitHub URL.
  repoOf = o: lib.toLower (o.repo or (
    let m = builtins.match ".*github\\.com[/:][^/]+/([^/?#]+).*" (o.url or "");
    in if m == null then "" else lib.removeSuffix ".git" (builtins.head m)));
  isOld = o:
    builtins.elem (repoOf o) repos
    && (lib.toLower (o.owner or "") == oldOwner
        || builtins.match ".*github\\.com[/:]${oldOwner}/.*" (lib.toLower (o.url or "")) != null);
  describe = o: o.url or "github:${o.owner}/${o.repo}";

  # `name: original` pairs the project controls.  A flake.lock also holds
  # the locks of every dependency (eg. another flake with its own older
  # haskell.nix pin), which the project cannot fix, so only look at the
  # root's direct inputs and the overrides set on haskell.nix's inputs.
  flakePins = lock:
    let
      nodes = lock.nodes;
      # string = a node name; list = a `follows` path to a node checked elsewhere
      inputsOf = prefix: n: lib.concatLists (lib.mapAttrsToList (name: k:
        lib.optional (builtins.isString k) { name = prefix + name; node = nodes.${k}; })
        (n.inputs or {}));
      direct = inputsOf "" nodes.${lock.root or "root"};
      overrides = lib.concatMap (i: inputsOf "${i.name}/" i.node)
        (lib.filter (i: repoOf (i.node.original or {}) == "haskell.nix") direct);
    in map (i: {
      inherit (i) name;
      original = i.node.original or {};
      fix = "edit flake.nix, then `nix flake update ${builtins.head (lib.splitString "/" i.name)}`";
    }) (direct ++ overrides);
  nivPins = sources: lib.mapAttrsToList (name: original: {
    inherit name original;
    fix = "`niv modify ${name} -o ${newOwner} && niv update ${name}`";
  }) sources;
  npinsPins = sources: lib.mapAttrsToList (name: p: rec {
    inherit name;
    original = (p.repository or {}) // lib.optionalAttrs (p ? url) { inherit (p) url; };
    fix = "re-add it with `npins add github ${newOwner} ${repoOf original} --name ${name}`";
  }) (sources.pins or {});

in { src, silence ? false }: project:
  let
    root = src.origSrc or src;
    # Never read from a derivation output (that is IFD) and never
    # interpolate a local path (that copies the whole tree to the store).
    readable = builtins.isPath root
      || ((builtins.isString root || root ? outPath)
          && !lib.any (c: c ? outputs) (lib.attrValues (builtins.getContext (toString root))));
    # Only the source root itself: a parent directory (eg. of `src = ./backend;`)
    # may hold pins that do not belong to this project.
    pinFile = p: if builtins.isPath root then root + "/${p}" else "${toString root}/${p}";
    read = p: f:
      lib.optionals (builtins.pathExists (pinFile p))
        (f (builtins.fromJSON (builtins.readFile (pinFile p))));
    stale = lib.optionals (!silence && readable) (lib.filter (p: isOld p.original) (
         read "flake.lock" flakePins
      ++ read "nix/sources.json" nivPins
      ++ read "npins/sources.json" npinsPins));
  in lib.warnIf (stale != []) (''
    haskell.nix has moved from github:${oldOwner} to github:${newOwner}.
    These pins in the project still name the old owner:
  '' + lib.concatMapStrings (p:
    "  ${p.name}: ${describe p.original}\n    fix: ${p.fix}\n") stale + ''
    They work for now only because GitHub redirects the old name.
    Set `silenceOrgMoveWarning = true;` in the project to hide this.'') project
