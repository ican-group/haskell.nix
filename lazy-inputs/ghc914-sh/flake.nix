{
  description = "Lazy Input for Haskell.nix";

  inputs = {
    ghc914-sh = {
      flake = false;
      # `stable-ghc-9.14-hn` is the latest `stable-ghc-9.14` plus the fixes this
      # repo needs that the stable branch does not have yet (the previous
      # history of this branch is kept as `stable-ghc-9.14-hn-old`):
      #
      #   * JS: the HEAP8/HEAPU8 emscripten exports (GHC #26290).  The
      #     cabalProject-built compilers need them but do not get
      #     overlays/bootstrap.nix's `onGhcjs` patches; without them every
      #     ghcjs executable aborts in h$initEmscriptenHeap.
      #   * GHC.SysTools.Ar: trim Apple ranlib's padding from wasm archive
      #     members (no upstream equivalent).
      #   * The package-library profiling suffix: splitting the rts into
      #     sub-libraries dropped the way suffix from every package's library
      #     name, so `-prof` links picked the vanilla archives and failed on
      #     `pushCostCentre` and friends.
      #   * x86 NCG: keep PIC jump-table shortcuts within the proc; with
      #     -split-sections they could name another proc's section ("can't
      #     resolve .text..L..._info - .L...", e.g. prettyprinter), keeping
      #     the tail-call trampolines those entries then name ("can't
      #     resolve .L... - .L...", with or without -split-sections).
      #   * system-cxx-std-lib names `stdc++` as an extra library on GNU
      #     toolchains, so an external interpreter loading a C++-using
      #     package's archive gets the C++ runtime (th-dlls hung under wine
      #     on an unresolved `__cxa_guard_acquire`).
      #   * RTS linker fixes (aarch64 ELF section pool, PEi386 import symbol
      #     types, ELF visibility macros, ARM PREL31, skip libc.a), MinGW
      #     symbol exports, bare `android` in GHC_CONVERT_OS, AVX flags on
      #     32-bit x86, and `--abi-hash` not claiming an executable link.
      url = "git+https://github.com/stable-haskell/ghc?ref=stable-ghc-9.14-hn";
    };
  };

  outputs = inputs: inputs;
}
