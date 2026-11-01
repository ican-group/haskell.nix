{
  description = "Lazy Input for Haskell.nix";

  inputs = {
    ghc914-sh = {
      flake = false;
      # `stable-ghc-9.14-hn` is the latest `stable-ghc-9.14` plus the fixes this
      # repo needs that the stable branch does not have yet (the previous
      # history of this branch is kept as `stable-ghc-9.14-hn-old`).
      # stable-ghc-9.14 has since taken several of them in its own form (#196,
      # #197: the JS HEAP8/HEAPU8 exports, Apple ranlib wasm padding in
      # GHC.SysTools.Ar, the profiling library suffix, x86 PIC jump-table
      # shortcuts, PEi386 import symbol types, AVX for the vector Cmm).  What
      # -hn still adds:
      #
      #   * system-cxx-std-lib names `stdc++` as an extra library on GNU
      #     toolchains, so an external interpreter loading a C++-using
      #     package's archive gets the C++ runtime (th-dlls hung under wine
      #     on an unresolved `__cxa_guard_acquire`).
      #   * TimerManager: registering threads publish only evaluated timeout
      #     queues (GHC #9809, ghc!16863), so many threads registering
      #     timeouts at once no longer build thunk chains and blow up the heap.
      #     `modifyTimeouts` is OPAQUE so the optimiser cannot rewrite the
      #     pointer its CAS expects, which would livelock it
      #     (stable-haskell/ghc#201).
      #   * TimerManager: on x86_64 Linux cap each backend wait at one second
      #     so a GHC running under Rosetta cannot sit in an indefinite poll
      #     after consuming a suspension request (haskell.nix #2609).
      #   * RTS linker: the aarch64 ELF section/GOT pool, skipping libc.a, and
      #     the MinGW symbol exports time and unix need.
      #   * `--abi-hash` does not claim an executable link (it stripped
      #     -dynamic on wasm and then rejected the dyn interfaces).
      #   * The dyn way defines DYNAMIC (as the prof way defines PROFILING), so
      #     the boot libraries' shared rts loads (`__fini_array_start`) while
      #     the vanilla rts that ghc links stays non-dynamic.
      #   * ghc-bin and the ghc-toolchain packages declare BSD-3-Clause.  With
      #     no license nixpkgs' check-meta counts them as unfree and refuses
      #     to evaluate the ghc executable.
      url = "git+https://github.com/stable-haskell/ghc?ref=stable-ghc-9.14-hn";
    };
  };

  outputs = inputs: inputs;
}
