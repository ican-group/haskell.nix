pkgs:
let licenses = import spdx/licenses.nix pkgs;
in licenses // {
  # Generic
  LicenseRef-PublicDomain = {
      spdxId = "LicenseRef-PublicDomain";
      shortName = "Public Domain";
      fullName = "This work is dedicated to the Public Domain";
      url = "https://wikipedia.org/wiki/Public_domain";
      free = true;
    };
  LicenseRef-OtherLicense = {
      spdxId = "LicenseRef-OtherLicense";
      shortName = "Other License";
      fullName = "Unidentified Other License";
      url = "https://spdx.github.io/spdx-spec/appendix-IV-SPDX-license-expressions/";
      # Not setting `free` here. The license may or may not be `free`.
      # See https://github.com/ican-group/haskell.nix/pull/1006
    };
  # Some packages (e.g. data-sketches) use this non-standard SPDX identifier.
  LicenseRef-Apache = {
      spdxId = "Apache-2.0";
      shortName = "Apache-2.0";
      fullName = "Apache License 2.0";
      url = "https://spdx.org/licenses/Apache-2.0.html";
      free = true;
    };
  NONE = null;
}
