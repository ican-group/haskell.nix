{ pkgs }:
let
  args = '' --arg userDefaults "$HOME/.config/hix/hix.conf" --arg src ./.'';
  # Use HIX_ROOT to override the version of hix used when developing new hix features.
  # See docs/dev/hix.md for details.
  hixProject = "\${HIX_ROOT:-${./..}}/hix/project";
  hixInit = "\${HIX_ROOT:-${./..}}/hix/init";
  hix-shell = pkgs.writeScriptBin "hix-shell" ''
    nix-shell ${hixProject} ${args} -A shell "$@"
  '';
  hix-build = pkgs.writeScriptBin "hix-build" ''
    nix-build ${hixProject} ${args} "$@"
  '';
  hix-instantiate = pkgs.writeScriptBin "hix-instantiate" ''
    nix-instantiate ${hixProject} ${args} "$@"
  '';
  hix-env = pkgs.writeScriptBin "hix-env" ''
    nix-env -f ${hixProject} ${args} "$@"
  '';
  hix = pkgs.writeScriptBin "hix" ''
      #! /usr/bin/env bash
      cmd=$1
      shift
      case $cmd in
      init|init-hix)
        if [ "$cmd" == "init" ]; then
          FLAKE_NIX="$(mktemp -d)/flake.nix"
          sed 's|EVAL_SYSTEM|${pkgs.stdenv.hostPlatform.system}|' < ${hixInit}/flake.nix > $FLAKE_NIX
          if [ -e flake.nix ]; then
            if ! diff -u flake.nix $FLAKE_NIX; then
              echo 'ERROR: Not replacing existing `flake.nix`.'
              exit 1
            fi
          else
            cp $FLAKE_NIX flake.nix
            echo '`flake.nix` file created.'
          fi
        fi
        HIX_NIX="$(mktemp -d)/hix.nix"
        sed 's|EVAL_SYSTEM|${pkgs.stdenv.hostPlatform.system}|' < ${hixInit}/nix/hix.nix > $HIX_NIX
        if [ -e nix/hix.nix ]; then
          echo '`nix/hix.nix` project configuration already exists:'
        else
          mkdir -p nix
          cp $HIX_NIX nix/hix.nix
          echo '`nix/hix.nix` project configuation:'
        fi
        ${pkgs.bat}/bin/bat nix/hix.nix
        ;;
      help)
        cat <<EOF
      Usage: hix <command> [args...]

      hix is a wrapper around for the nix command that allows you
      to work on haskell projects using nix without the need to add
      nix files to the project.

      Any nix <command> that takes 'installables' as an argument should
      work and behave as if the project had a 'flake.nix' file that
      was set up to work with haskell.nix.

      You can add a 'nix/hix.nix' file to your project and 'hix' will
      include that file as nix module containing project arguments.

      Other commands:
        init             Add flake.nix and nix/hix.nix file to allow
                         nix commands to work (without hix).
        help             This message

      Advanced options:
        --projectArgs <nix>       Haskell.nix arguments as Nix expression
        --supportedSystems <nix>  Supported systems as Nix expression
        --overlays <nix>          Overlay definitions
        --config <nix>            Custom nix configuration

      Examples:
        hix flake show .
        hix build '.#hello:exe:hello'
        hix run '.#hello:exe:hello'
        hix flake check --projectArgs '{ compiler-nix-name = "ghc9122"; }'

      EOF
        ;;
      *)
        # Put the flake files for remote URLs in $HOME/.hix by default
        HIX_DIR="''${HIX_DIR:-$HOME/.hix}"
        HIX_TMPDIR="$(mktemp -d)"
        args=("--option" "allow-import-from-derivation" "true")
        while(($#)); do
          arg=$1
          case $arg in
            --projectArgs)
              printf %s "$2" > "$HIX_TMPDIR/projectArgs.nix"
              shift
              ;;
            --supportedSystems)
              printf %s "$2" > "$HIX_TMPDIR/supportedSystems.nix"
              shift
              ;;
            --overlays)
              printf %s "$2" > "$HIX_TMPDIR/overlays.nix"
              shift
              ;;
            --config)
              printf %s "$2" > "$HIX_TMPDIR/config.nix"
              shift
              ;;
            --out-link|-o|--eval-store|--include|-I|--inputs-from|--expr|--file|-f|--keep|-k|--phase|--profile|--unset|-u)
              args+=("$arg" "$2")
              shift
              ;;
            --arg|--argstr|--override-flake|--override-input)
              args+=("$arg" "$2" "$3")
              shift
              shift
              ;;
            -*)
              args+=("$arg")
              ;;
            github:*#*)
              SRC="''${arg%%#*}"
              FLAKE=$HIX_DIR/$SRC
              args+=("path:$FLAKE#''${arg#*#}" --override-input src "$SRC")
              has_input_src=true
              ;;
            github:*)
              SRC="$arg"
              FLAKE=$HIX_DIR/$SRC
              args+=("path:$FLAKE" --override-input src "$SRC")
              has_input_src=true
              ;;
            *#*)
              SRC="''${arg%%#*}"
              FLAKE=$SRC/.hix-flake
              args+=("path:$FLAKE#''${arg#*#}" --override-input src "$SRC")
              has_input_src=true
              ;;
            .*)
              SRC="$arg"
              FLAKE=$SRC/.hix-flake
              args+=("path:$FLAKE" --override-input src "$SRC")
              has_input_src=true
              ;;
            *)
              args+=("$arg")
              ;;
          esac
          shift
        done
        # Any of --projectArgs, --supportedSystems, --overlays or --config
        # wrote a file to $HIX_TMPDIR; pass it to the flake once.
        if [ -n "$(ls -A "$HIX_TMPDIR")" ]; then
          args+=(--override-input projectArgs "$(realpath "$HIX_TMPDIR")")
        fi
        if [ "$has_input_src" != true ]; then
          SRC=.
          FLAKE=$SRC/.hix-flake
          args+=("path:$FLAKE" --override-input src "$SRC")
        fi
        # Make a temporary flake if we have not already
        mkdir -p $FLAKE
        HIX_FLAKE="$HIX_TMPDIR/flake.nix"
        sed 's|EVAL_SYSTEM|${pkgs.stdenv.hostPlatform.system}|' < ${hixProject}/flake.nix > $HIX_FLAKE
        if ! cmp $HIX_FLAKE $FLAKE/flake.nix &>/dev/null; then
          if [ -e $FLAKE/flake.lock ]; then
            >&2 echo "Updating $FLAKE/flake.nix and deleting old $FLAKE/flake.lock"
            rm $FLAKE/flake.lock
          else
            >&2 echo "Updating $FLAKE/flake.nix"
          fi
          cp $HIX_FLAKE $FLAKE/flake.nix
          chmod +w $FLAKE/flake.nix
        fi
        nix $cmd "''${args[@]}"
        ;;
      esac
    '';
in (pkgs.symlinkJoin {
  name = "hix";
  paths = [ hix-build hix-shell hix-instantiate hix-env hix ];
}) // {
  apps = { inherit hix-build hix-shell hix-instantiate hix-env hix; };
}
