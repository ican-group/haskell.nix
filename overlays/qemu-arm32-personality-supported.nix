# Keep emulator selection and its native-builder scheduling exception aligned.
{ lib, buildPlatform, hostPlatform, qemuVersion, qemuSuffix ? "arm" }:
buildPlatform.isLinux
  && (hostPlatform.isAndroid or false)
  && (hostPlatform.isAarch32 or false)
  && qemuSuffix == "arm"
  && lib.versionAtLeast qemuVersion "9.1"
  && lib.versionOlder qemuVersion "12"
