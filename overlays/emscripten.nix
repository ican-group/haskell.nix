final: prev: {
    emsdk = final.linkFarm "emsdk" [
      { name = "upstream/bin"; path = final.clang + "/bin"; }
      { name = "upstream/emscripten"; path = final.emscripten + "/bin"; }
      { name = "share"; path = final.emscripten + "/share"; }
    ];
} //
# Use the plain build-platform nodejs in package sets that only differ from it
# in their target platform (e.g. a cross set's `buildPackages`, where
# emscripten and the ghcjs/wasm GHCs come from).  nodejs does not depend on
# the target, but on darwin such a set does not reuse the bootstrap stage's
# openssl/zstd the way the top-level set does, so its nodejs is a different
# derivation that cache.nixos.org does not have (and whose test suite then
# runs on our builders).  `buildPackages` here is that top-level-equivalent
# set (build = host = target).  On linux the two are already identical, so
# this changes nothing there.
prev.lib.optionalAttrs (
  prev.stdenv.buildPlatform.config == prev.stdenv.hostPlatform.config
  && prev.stdenv.targetPlatform.config != prev.stdenv.hostPlatform.config
) (prev.lib.genAttrs
  (builtins.filter (n: prev ? ${n}) [
    "nodejs" "nodejs-slim"
    "nodejs_22" "nodejs-slim_22"
    "nodejs_24" "nodejs-slim_24"
    "nodejs_26" "nodejs-slim_26"
    "nodejs_latest" "nodejs-slim_latest"
  ])
  (n: final.buildPackages.${n}))
