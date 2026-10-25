{ system ? "x86_64-linux"
, pkgs ? (import ../default.nix { inherit system; }).pkgs
, check ? false
}:

assert pkgs.stdenv.hostPlatform.isLinux;
pkgs.runCommandCC "rosetta-signals-${pkgs.stdenv.hostPlatform.system}" {
  nativeBuildInputs = [ pkgs.coreutils ];
  allowSubstitutes = false;
  preferLocalBuild = true;
} ''
  timeout -k 2 30 "$CC" -std=c11 -Werror=vla -pedantic -Wall -Wextra \
    ${./rosetta-signals.c} -o rosetta-signals
  timeout -k 2 90 bash ${./rosetta-signals.sh} \
    "$PWD/rosetta-signals" "$out" ${if check then "check" else "probe"}
  cp rosetta-signals "$out/"
''
