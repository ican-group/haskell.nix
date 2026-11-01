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
      # See https://github.com/input-output-hk/haskell.nix/pull/1006
    };
  # Some packages (e.g. data-sketches) use this non-standard SPDX identifier.
  LicenseRef-Apache = {
      spdxId = "Apache-2.0";
      shortName = "Apache-2.0";
      fullName = "Apache License 2.0";
      url = "https://spdx.org/licenses/Apache-2.0.html";
      free = true;
    };
  # Cabal's names for the legacy (pre-SPDX) `license: GPL`, `LGPL` and `AGPL`
  # with no version (`licenseToSPDX` in Cabal-syntax).  All are free whichever
  # version is meant; e.g. cpphs and polyparse use `LGPL`.
  LicenseRef-GPL = {
      spdxId = "LicenseRef-GPL";
      shortName = "GPL";
      fullName = "GNU General Public License (unspecified version)";
      url = "https://www.gnu.org/licenses/gpl.html";
      free = true;
    };
  LicenseRef-LGPL = {
      spdxId = "LicenseRef-LGPL";
      shortName = "LGPL";
      fullName = "GNU Lesser General Public License (unspecified version)";
      url = "https://www.gnu.org/licenses/lgpl.html";
      free = true;
    };
  LicenseRef-AGPL = {
      spdxId = "LicenseRef-AGPL";
      shortName = "AGPL";
      fullName = "GNU Affero General Public License (unspecified version)";
      url = "https://www.gnu.org/licenses/agpl.html";
      free = true;
    };
  # No license declared (also what Cabal makes of `AllRightsReserved`).  Like
  # `LicenseRef-OtherLicense` this does not set `free`, so it is whatever the
  # nixpkgs in use makes of a license without one (unfree in a list since the
  # 2026-11 check-meta).  It used to be `null`, which check-meta reported as
  # an unfree license named "unknown".
  NONE = {
      spdxId = "NONE";
      shortName = "NONE";
      fullName = "No license declared";
    };
}
