# These modules are used by `haskell-nix.hackage-project` and the functions
# that use it (like `hackage-package`)
#
let
  # Easier than importing nixpkgs just for this
  mapAttrsToList = f: attrs:
    map (name: f name attrs.${name}) (__attrNames attrs);
in [
  # Avoid pantry 0.9 in versions without https://github.com/commercialhaskell/stack/pull/6187
  # Also avoid optparse-applicative 0.18
  # http-download 0.2.1 https://github.com/commercialhaskell/stack/issues/6210
  ({config, lib, pkgs, ...}:
    { _file = "haskell.nix/overlays/hackage-quirks.nix#stack"; } //
    lib.mkIf (config.name == "stack") {
      cabalProjectLocal =
        if builtins.compareVersions config.version "2.11.1" <= 0 then ''
          constraints: pantry <0.9, optparse-applicative <0.18, http-download <0.2.1
        ''
        else if builtins.compareVersions config.version "2.11.1.1" <= 0 then ''
          constraints: http-download <0.2.1
        ''
        else "";
    }
  )

  # alfred-margaret 2.1.1.0 (released 2026-04-24) uses `foldl'` from Prelude,
  # which was only added to Prelude in base-4.20 (GHC 9.10). It is pulled in
  # transitively when building hoogle (via hackage-revdeps).
  ({config, lib, pkgs, ...}:
    { _file = "haskell.nix/overlays/hackage-quirks.nix#hoogle"; } //
    lib.mkIf (config.name == "hoogle"
        && builtins.compareVersions
             pkgs.buildPackages.haskell-nix.compiler.${config.compiler-nix-name}.version "9.10" < 0) {
      cabalProjectLocal = ''
        constraints: alfred-margaret <2.1.1.0
      '';
    }
  )

  # crypton >=2.1.5 vendors s2n-bignum's x86 assembly, which does not
  # assemble for x86_64-darwin: its `.macro`s use immediates like `$0`, and
  # LLVM's assembler, targeting Darwin, substitutes `$N` inside a macro body
  # with the macro's Nth argument, leaving `adcq , %r8`
  # (cbits/s2n/x86_att/bignum_emontredc_8n.S).  hoogle pulls crypton in via
  # its TLS stack.  The flag falls back to crypton's portable C.
  ({config, lib, pkgs, ...}:
    { _file = "haskell.nix/overlays/hackage-quirks.nix#hoogle-crypton"; } //
    lib.mkIf (config.name == "hoogle"
        && pkgs.stdenv.hostPlatform.isDarwin
        && pkgs.stdenv.hostPlatform.isx86_64) {
      cabalProjectLocal = ''
        package crypton
          flags: -support_s2n_bignum
      '';
    }
  )

  # Map the following into modules that use `mkIf` to check the name of the
  # hackage package in a way that is lazy enought not to cause infinite recursion
  # issues.
  ] ++ mapAttrsToList (n: v: {config, lib, ...}:
    { _file = "haskell.nix/overlays/hackage-quirks.nix#${n}"; } //
    lib.mkIf (n == config.name) v) {

    lsp-test = {
      cabalProject = ''
        packages: .
        package lsp
          flags: +demo
      '';
    };

    pandoc = {
      # Function that returns a sha256 string by looking up the location
      # and tag in a nested attrset
      sha256map =
        { "https://github.com/jgm/pandoc-citeproc"."0.17"
            = "0dxx8cp2xndpw3jwiawch2dkrkp15mil7pyx7dvd810pwc22pm2q"; };
    };

    # See https://github.com/input-output-hk/haskell.nix/issues/948
    postgrest = {
      cabalProject = ''
        packages: .
        package postgresql-libpq
          flags: +use-pkg-config
      '';
      modules = [(
       {pkgs, lib, ...}: lib.mkIf pkgs.stdenv.hostPlatform.isMusl {
         # The order of -lssl and -lcrypto is important here
         packages.postgrest.configureFlags = [
           "--ghc-option=-optl=-lssl"
           "--ghc-option=-optl=-lcrypto"
           "--ghc-option=-optl=-L${pkgs.openssl.out}/lib"
         ];
      })];
    };

    stack = {
      modules = [{
        # Stack has a custom setup that expects both the library and stack executable
        # to be configured at the same time.  Unfortunately this does mean that
        # the library component is rebuilt unecessarily in the exe component derivation.
        packages.stack.components.exes.stack.configureAllComponents = true;
        # But we don't want to configure the tests as they have dependencies that
        # are not included in the `exes` dependencies.
        packages.stack.components.exes.stack.configureFlags = ["--disable-tests"];
      }];
    };
  }

  # Common CLI tools are pulled in via `hackage-tool`/`tool` without a version
  # pin, leaving the choice to the solver.  For a brand-new GHC where no recent
  # release has compatible bounds yet, the solver can silently fall back to a
  # prehistoric version whose (usually unbounded) dependencies happen to solve
  # -- e.g. hoogle-3.1, whose CLI predates `hoogle generate` and so breaks
  # `hoogle-with-packages` (see input-output-hk/haskell.nix#2477).  A
  # conservative lower bound excludes those ancient versions: each floor is low
  # enough to still solve on the oldest GHCs we support (it never rules out a
  # legitimate choice), while on a too-new GHC it turns the silent
  # wrong-version into an honest solve failure until Hackage catches up.  These
  # are lower bounds only -- users are still free to pin any newer version.
  ++ mapAttrsToList (name: bound: {config, lib, ...}:
    { _file = "haskell.nix/overlays/hackage-quirks.nix#lower-bound-${name}"; } //
    lib.mkIf (config.name == name) {
      cabalProjectLocal = "constraints: ${name} >= ${bound}";
    }) {
    hoogle          = "5.0";
    hlint           = "3.0";
    ghcid           = "0.8";
    ormolu          = "0.5";
    fourmolu        = "0.8";
    stylish-haskell = "0.13";
    cabal-fmt       = "0.1.6";
  }
