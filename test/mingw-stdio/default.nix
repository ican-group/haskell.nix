{ pkgs }:
assert pkgs.stdenv.hostPlatform.isWindows && pkgs.stdenv.hostPlatform.isx86_64;
assert pkgs.pkgsBuildBuild.stdenv.hostPlatform.isLinux
  && pkgs.pkgsBuildBuild.stdenv.hostPlatform.isx86_64;
assert pkgs.stdenv.cc.libc.drvPath == pkgs.windows.mingw_w64.drvPath;
assert pkgs.stdenv.hostPlatform.libc != "ucrt"
  || (pkgs.windows.mingw_w64_pthreads.CPPFLAGS or "") == "-D_UCRT";
let
  buildPkgs = pkgs.pkgsBuildBuild;
  wine = buildPkgs.wine64Packages.minimal;
  payload = pkgs.stdenv.mkDerivation {
    name = "mingw-stdio-exact-fit-probe";
    dontUnpack = true;
    dontConfigure = true;
    strictDeps = true;
    buildInputs = [ pkgs.windows.mingw_w64_pthreads ];
    buildPhase = ''
      $CC -std=c11 -Werror=vla -pedantic -Wall -Wextra -O1 -static \
        -Wl,-Map,probe.map ${./Probe.c} -o probe.exe
      # A UCRT default can pass without calling the patched ISO formatter.
      grep -F '__mingw_vswprintf' probe.map >/dev/null
    '';
    installPhase = ''
      mkdir -p "$out/bin" "$out/share"
      cp probe.exe "$out/bin/"
      cp probe.map "$out/share/"
    '';
  };
in buildPkgs.runCommand "mingw-stdio-exact-fit" {
  nativeBuildInputs = [ buildPkgs.coreutils ];
} ''
  set -euo pipefail
  mkdir -p "$out"
  export WINEPREFIX="$TMPDIR/mingw-stdio-prefix"
  export WINEDEBUG=-all
  cleanup() {
    timeout --kill-after=1s 5s ${wine}/bin/wineserver -k >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  timeout --kill-after=2s 90s ${wine}/bin/wine ${payload}/bin/probe.exe \
    2>&1 | tee "$out/result.log"
  cp ${payload}/share/probe.map "$out/"
''
