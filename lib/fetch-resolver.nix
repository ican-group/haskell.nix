# Find the resolver in the stack.yaml file and fetch it if a sha256 value is provided
{ pkgs }:
{ src
, stackYaml ? "stack.yaml"
, resolverSha256 ? null
}:
let
    srcDir = src.origSrcSubDir or src;

    # Using origSrcSubDir bypasses any cleanSourceWith so that it will work when
    # access to the store is restricted.  If origSrc was already in the store
    # you can pass the project in as a string.
    rawStackYaml = builtins.readFile (srcDir + "/${stackYaml}");

    # Determine the resolver as it may point to another file we need
    # to look at.  `snapshot` is the modern synonym for `resolver`
    # (stack >= 2.15.1), so accept either key.  The value is either on the
    # same line or, for pantry's object form, a `url:` or `filepath:` key on
    # the indented lines that follow (a `compiler:` object names no file).
    resolver =
      let
        lines = pkgs.lib.splitString "\n" rawStackYaml;
        # Each returns a single-element capture list (the value) or null.
        matchLine = l:
          let r = builtins.match "^resolver: *(.*)" l;
          in if r != null then r else builtins.match "^snapshot: *(.*)" l;
        # The first `url:`/`filepath:` among the indented lines of an object.
        objectValue = ls:
          if ls == [] || builtins.match "^[ \t].*" (builtins.head ls) == null then null
          else let m = builtins.match "^[ \t]+(url|filepath): *(.*)" (builtins.head ls); in
            if m != null then builtins.elemAt m 1 else objectValue (builtins.tail ls);
        go = ls:
          if ls == [] then null
          else let m = matchLine (builtins.head ls); in
            if m == null then go (builtins.tail ls)
            else if builtins.head m != "" then builtins.head m
            else objectValue (builtins.tail ls);
      in
        go lines;

    # If we found a resolver and we have a resolverSha256 then we should download it.
    fetchedResolver =
      if resolver != null && resolverSha256 != null
        then pkgs.fetchurl {
          url = resolver;
          sha256 = resolverSha256;
        }
      else if resolver != null && __pathExists (srcDir + "/${resolver}")
        then pkgs.copyPathToStore (srcDir + "/${resolver}")
      else null;

in { inherit resolver fetchedResolver; }
