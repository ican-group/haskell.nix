# Predicates used in conditional
# cabal expressions.
{
  compiler = {
    # Haskell compilers
    isGhc = false;
    isGhcjs = false;
    isNhc = false;
    isYhc = false;
    isHugs = false;
    isHbc = false;
    isHelium = false;
    isJhc = false;
    isLhc = false;
    isUhc = false;
    isEta = false;
    isMhs = false;
  };
  os = {
    # OSs
    isLinux     = false;
    isWindows   = false;
    isOsx       = false;
    isIos       = false;
    isFreebsd   = false;
    isOpenbsd   = false;
    isNetbsd    = false;
    isDragonFly = false;
    isSolaris   = false;
    isAix       = false;
    isHPUX      = false;
    isIRIX      = false;
    isHalvm     = false;
    isHurd      = false;
    isIOS       = false;
    isAndroid   = false;
    isGhcjs     = false;
    isWasi      = false;
  };
  arch = {
    # Archs
    isI386   = false;
    isX86_64 = false;
    isPPC    = false;
    isPPC64  = false;
    # plan-to-nix (via capitalize) generates isPpc/isPpc64; keep aliases so
    # generated plan.nix files evaluate correctly until nix-tools is rebuilt
    # with the fixSystem entries below.
    isPpc    = false;
    isPpc64  = false;
    isSparc  = false;
    isArm    = false;
    isAarch64= false;
    isMips   = false;
    isSH     = false;
    isIA64   = false;
    isS390   = false;
    isS390x  = false;
    isAlpha  = false;
    isHppa   = false;
    isRs6000 = false;
    isM68k   = false;
    isVax    = false;
    isJavaScript = false;
    isWasm32 = false;
    # Newer architectures in GHC 9.14's rts.cabal not yet in older cabal-os-arch-comp
    isRiscv64    = false;   # nixpkgs: isRiscV64
    isRiscV64    = false;
    isLoongarch64 = false;  # nixpkgs: isLoongArch64 (if/when added)
    isLoongArch64 = false;
  };
}
