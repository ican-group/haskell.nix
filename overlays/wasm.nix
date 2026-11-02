final: prev: prev.lib.optionalAttrs prev.stdenv.targetPlatform.isWasm {
  # Remove lit's max-time.py self-test. It hangs in the nix build sandbox
  # due to a Python multiprocessing.Pool deadlock (`_help_stuff_finish`
  # acquires `inqueue._rlock` without releasing it) combined with a leaked
  # signal mask that leaves SIGTERM blocked in the worker, so `pool.terminate()`
  # can't kill it. nix-shell builds complete fine; only nix-build hangs.
  llvmPackages_21 =
    let
      f = llvmFinal: llvmPrev: {
        libllvm = llvmPrev.libllvm.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            rm utils/lit/tests/max-time.py
          '';
        });
      };
      # Preserve `.override` after `overrideScope`; see nixpkgs#447012.
      override = args: (prev.llvmPackages_21.override args).overrideScope f;
    in prev.lib.makeOverridable
      (prev.lib.mirrorFunctionArgs prev.llvmPackages_21.override override)
      { };
  # The haskell-wasm LLVM patch, applied to llvm, clang and lld only (the
  # subprojects it touches).  Each of those builds from its own subdirectory
  # of nixpkgs' monorepo source (`sourceRoot = <src>/llvm` etc.), so `-p2`
  # strips `a/<subproject>/`.  This used to be applied to a patched copy of
  # the whole ~150k-file monorepo used as `monorepoSrc`, which every LLVM
  # package then copied its subdirs out of; copying that tree is what ran the
  # Apple builders' Linux VMs out of file descriptors ("Too many open files in
  # system").  With nixpkgs' own `monorepoSrc`, the other LLVM packages'
  # sources are the same as nixpkgs' too.
  llvmPackages =
    let
      withHaskellPatch = p: drv: drv.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          patch -p2 < ${./patches/wasm/llvm + "/haskell-wasm-${p}.patch"}
        '';
      });
      g = _: llvmPrev: {
        libllvm = withHaskellPatch "llvm" llvmPrev.libllvm;
        libclang = withHaskellPatch "clang" llvmPrev.libclang;
        lld = withHaskellPatch "lld" llvmPrev.lld;
      };
      # Preserve `.override` after `overrideScope`, as for llvmPackages_21.
      override = args: (final.llvmPackages_21.override ({
        patchesFn = p: p // { "llvm/gnu-install-dirs.patch" = [{path = ./patches/wasm;}]; };
      } // args)).overrideScope g;
    in prev.lib.makeOverridable
      (prev.lib.mirrorFunctionArgs final.llvmPackages_21.override override)
      { };
  # GHC's wasm backend still requires the haskell-wasm wasi-libc fork — GHC's
  # own toolchain (ghc-wasm-meta) ships a forked wasi-sdk and states plainly
  # that "Upstream wasi-sdk won't work yet"; the fork's patches are NOT
  # upstreamed.  The pinned rev (951e93b) and LLVM (21.1.8, via the
  # haskell-wasm llvm-project patch above) both already match exactly what the
  # current wasi-sdk fork uses, so nothing here is stale.
  #
  # Two things nonetheless break the build under the bumped nixpkgs:
  #  1. nixpkgs re-packaged its own wasilibc around a CMake build (wasi-sdk-32);
  #     `overrideAttrs` inherits cmake/ninja + their setup hooks, so
  #     cmakeConfigurePhase runs against the fork tree (Makefile only, no
  #     CMakeLists.txt) and aborts.  Reuse the base derivation ONLY for its
  #     stdenvNoLibc + cross-toolchain libc-bootstrap wiring, and drive the
  #     fork's own Makefile build explicitly (drop cmake/ninja, disable their
  #     hooks, give explicit configure/build/install phases).
  #  2. ghc-wasm-meta builds wasi-libc with the raw wasi-sdk clang; we build it
  #     through nixpkgs' cc-wrapper, which injects `-rtlib=compiler-rt`.
  #     clang-21 flags that as unused on `-c`-only steps, and the fork
  #     Makefile compiles with `-Werror` (EXTRA_CFLAGS precedes it, so a
  #     suppression there would lose to `-Werror`).  The cc-wrapper appends
  #     NIX_CFLAGS_COMPILE AFTER the Makefile's flags, so demote it there.
  wasilibc = prev.wasilibc.overrideAttrs (old: {
    version = "25";
    # The nixpkgs patches are cut against ITS pinned source (wasi-sdk-32) and
    # target files absent from the fork; the fork needs none of them.
    patches = [];
    src = final.buildPackages.fetchFromGitLab {
      domain = "gitlab.haskell.org";
      owner = "haskell-wasm";
      repo = "wasi-libc";
      rev = "951e93b336cb0ffac3ab2874640b70ed854fdf27";
      hash = "sha256-8thdYhX4bZuU/CbBNdcab3tUnugaEvI6RDw7im4eeec=";
      fetchSubmodules = true;
    };
    nativeBuildInputs =
      builtins.filter
        (x: !(builtins.elem (x.pname or "") [ "cmake" "ninja" ]))
        (old.nativeBuildInputs or [])
      ++ [ final.buildPackages.lld ];
    # Drop nixpkgs' CMake configuration outright, not just its hook.  Every
    # derivation attribute is evaluated even when unused, and nixpkgs'
    # `cmakeFlags` for wasilibc reference the wasi `compiler-rt`, which reaches
    # `compiler-rt-src` -> (the patched `monorepoSrc` this overlay used to
    # build).stdenv -> stdenv and back:
    # infinite recursion while evaluating `libc_bin` of the wasi
    # llvm-binutils-wrapper.  We drive the fork's Makefile directly, so these
    # are dead weight; clearing them cuts the edge that closes the cycle.
    cmakeFlags = [];
    dontUseCmakeConfigure = true;
    dontUseNinjaBuild = true;
    dontUseNinjaInstall = true;
    dontUseNinjaCheck = true;
    NIX_CFLAGS_COMPILE = "-Wno-error=unused-command-line-argument";
    # The fork has no ./configure — its Makefile is driven directly below.
    configurePhase = ''
      runHook preConfigure
      patchShebangs ./scripts
      export BUILTINS_LIB=$($CC --print-libgcc-file-name)
      # The extra shared libraries (libdl.so, libwasi-emulated-*.so, ...) are
      # linked with `--target=wasm32-wasi -resource-dir <the Makefile's own>`
      # so that clang finds compiler-rt there.  But the cc-wrapper appends its
      # `-resource-dir=<wrapper>/resource-root` after the Makefile's flags, so
      # the wrapper's wins, and that only has compiler-rt where clang looks
      # for the wrapper's own target (lib/wasip1/), not for wasm32-wasi
      # (lib/wasm32-unknown-wasi/libclang_rt.builtins.a):
      #   wasm-ld: error: cannot open .../resource-root/lib/wasm32-unknown-wasi/libclang_rt.builtins.a
      # Use a copy of the wrapper's resource dir with the builtins also where
      # wasm32-wasi looks, appended after the wrapper's flag so that it wins.
      wrapperResourceDir=$($CC -print-resource-dir)
      wantedBuiltins=$($CC --target=wasm32-wasi --print-libgcc-file-name)
      resourceDir=$PWD/nix-resource-dir
      cp -rL --no-preserve=mode "$wrapperResourceDir/." "$resourceDir/"
      mkdir -p "$(dirname "$resourceDir/''${wantedBuiltins#$wrapperResourceDir/}")"
      ln -sf "$BUILTINS_LIB" "$resourceDir/''${wantedBuiltins#$wrapperResourceDir/}"
      export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE-} -resource-dir=$resourceDir"
      runHook postConfigure
    '';
    # No CHECK_SYMBOLS=yes: that self-test diffs clang's predefined macros
    # against a set captured with the raw wasi-sdk clang, and clang-21 adds
    # benign extras (e.g. _LIBCPP_HARDENING_MODE) that fail the diff without
    # affecting the built libc.
    buildPhase = ''
      runHook preBuild
      make -j$NIX_BUILD_CORES default libc_so
      runHook postBuild
    '';
    # Use the $out/$dev shell vars (structuredAttrs is on in the base
    # derivation).  nixpkgs' wasilibc no longer has a `share` output, so the
    # sysroot/share metadata (predefined-macros.txt etc.) is not copied — it is
    # build-verification output, not needed by libc consumers.
    #
    # The fork builds for the `wasm32-wasi` triple, but nixpkgs' cc-wrapper
    # looks where nixpkgs' own wasilibc installs (its `passthru.incdir` and
    # `libdir`, now `wasm32-wasip1`): `-idirafter <dev>/include/wasm32-wasip1`
    # and `-B <out>/lib/wasm32-wasip1`.  Headers under include/wasm32-wasi
    # were not found ("'bits/alltypes.h' file not found" building libcxx).
    # Install there, and keep `wasm32-wasi` as a symlink for the haskell.nix
    # code that looks in lib/wasm32-wasi.
    installPhase =
      let incdir = old.passthru.incdir or "/include/wasm32-wasi";
          libdir = old.passthru.libdir or "/lib/wasm32-wasi";
      in ''
      runHook preInstall
      mkdir -p "$out/lib" "$dev/include"
      cp -r sysroot/lib/wasm32-wasi "$out${libdir}"
      cp -r sysroot/include/wasm32-wasi "$dev${incdir}"
      [ -e "$out/lib/wasm32-wasi" ] || ln -s "$(basename "${libdir}")" "$out/lib/wasm32-wasi"
      [ -e "$dev/include/wasm32-wasi" ] || ln -s "$(basename "${incdir}")" "$dev/include/wasm32-wasi"
      runHook postInstall
    '';
  });

  # zlib doesn't cross-compile cleanly to wasm out of the box:
  #  * gzguts.h only `#include <errno.h>` when NO_STRERROR is unset, but
  #    gzread.c / gzwrite.c use errno / EAGAIN / EWOULDBLOCK unconditionally.
  #    zlib's configure probes strerror by compiling *and running* a test,
  #    which can't run when cross-compiling to wasm, so it defines NO_STRERROR
  #    (even though wasi-libc has strerror) and the gz* sources fail to build
  #    with "use of undeclared identifier 'errno'".  -> always include errno.h.
  #  * zlib sets NIX_LDFLAGS = "--undefined-version" whenever the linker is lld
  #    (to counter lld 16+'s --no-undefined-version default for its shared-lib
  #    version script).  wasm-ld is lld-based but rejects that flag, and we
  #    build static anyway, so drop it.
  zlib = prev.zlib.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace gzguts.h \
        --replace-fail '/* get errno and strerror definition */' '/* get errno and strerror definition */
#include <errno.h>'
    '';
    env = (old.env or {}) // { NIX_LDFLAGS = ""; };
  });

  haskell-nix = prev.haskell-nix // ({
    defaultModules = prev.haskell-nix.defaultModules ++ [
      ({ pkgs, ... }: {
        # Grant the wasm guest access to the Nix store so tests can read e.g.
        # their data-files (Paths_*.getDataFileName) under <pkg>-data/share/...;
        # without a --dir preopen WASI gives the module no filesystem access.
        # `--dir .` likewise lets tests read source-relative files (golden
        # files / fixtures) from the directory the check runs in.
        #
        # NB: wasmtime neither forwards host env vars to the guest nor follows
        # absolute symlinks, so data-file tests under the v2 check can't run on
        # wasm and are disabled there (see test/check-datadir/default.nix).
        testWrapper = ["HOME=$(mktemp -d)" (pkgs.pkgsBuildBuild.wasmtime + "/bin/wasmtime") "--dir" "/nix/store" "--dir" "."];
        package-keys = ["clock"];
        packages.clock.ghcOptions = ["-optc-Wno-int-conversion"];
      })
    ];
  });
}
