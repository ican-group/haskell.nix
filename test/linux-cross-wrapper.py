#!/usr/bin/env python3
"""Run the generated Linux cross-TH wrappers against a recording proxy."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class LinuxCrossWrapperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="linux-cross-wrapper-")
        cls.root = Path(cls.temp.name)
        proxy = cls.root / "proxy" / "bin" / "iserv-proxy"
        proxy.parent.mkdir(parents=True)
        proxy.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "with open(os.environ['PROXY_RECORD'], 'w') as record:\n"
            " json.dump({'pid': os.getpid(), 'args': sys.argv[1:]}, record)\n"
            "sys.exit(int(os.environ.get('PROXY_EXIT', '0')))\n"
        )
        proxy.chmod(0o755)
        overlay = Path(__file__).resolve().parents[1] / "overlays/linux-cross.nix"
        expression = r'''
          let
            root = ROOT;
            cross = import (builtins.toPath OVERLAY) {
              stdenv.shell = "/bin/bash";
              lib = {
                optionalString = c: s: if c then s else "";
                optional = c: v: if c then [ v ] else [];
                optionals = c: v: if c then v else [];
              };
              haskellLib = {};
              runCommand = null;
              makeWrapper = null;
              writeShellScriptBin = name: script: { inherit name script; };
              symlinkJoin = attrs: builtins.toJSON attrs.paths;
              qemu = root + "/qemu";
              qemuSuffix = "aarch64";
              iserv-proxy = root + "/proxy";
              iserv-proxy-interpreter = {
                outPath = root + "/ordinary";
                exeName = "iserv-proxy-interpreter";
              };
              iserv-proxy-interpreter-prof = {
                outPath = root + "/profiled";
                exeName = "iserv-proxy-interpreter";
              };
              gmp = root + "/gmp";
              buildPlatform = {};
              hostPlatform = {
                isAarch32 = false;
                isAarch64 = true;
                isAndroid = true;
              };
            };
            captured = builtins.replaceStrings [ "/bin/iserv-wrapper" ] [ "" ]
              (builtins.elemAt cross.ghcOptions 2);
          in builtins.fromJSON captured
        '''.replace("ROOT", json.dumps(str(cls.root))).replace(
            "OVERLAY", json.dumps(str(overlay))
        )
        result = subprocess.run(
            ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression],
            check=True, capture_output=True, text=True, timeout=30,
        )
        cls.wrappers = []
        for wrapper in json.loads(result.stdout):
            path = cls.root / wrapper["name"]
            path.write_text(wrapper["script"])
            cls.wrappers.append(path)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_wrapper(self, wrapper, arguments, exit_code=0):
        record = self.root / "record.json"
        environment = dict(os.environ, PROXY_RECORD=str(record),
                           PROXY_EXIT=str(exit_code), ISERV_ARGS="-v")
        process = subprocess.Popen(
            ["/bin/bash", str(wrapper), *arguments], env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        process.communicate(timeout=10)
        return process, json.loads(record.read_text())

    def test_protocol_arguments_and_interpreter_selection(self):
        for wrapper, way in zip(self.wrappers, ("ordinary", "profiled")):
            with self.subTest(way=way):
                process, record = self.run_wrapper(wrapper, ["4", "5", "argument with spaces"])
                self.assertEqual(process.returncode, 0)
                self.assertEqual(record["args"], [
                    "4", "5", "argument with spaces", "--pipe",
                    str(self.root / "qemu/bin/qemu-aarch64"),
                    str(self.root / way / "bin/iserv-proxy-interpreter"),
                    "tmp", "--stdio", "-v",
                ])

    def test_ghc_tracks_the_proxy_process(self):
        for wrapper in self.wrappers:
            with self.subTest(wrapper=wrapper.name):
                process, record = self.run_wrapper(wrapper, ["4", "5"])
                self.assertEqual(record["pid"], process.pid)

    def test_proxy_failure_reaches_ghc(self):
        for wrapper in self.wrappers:
            with self.subTest(wrapper=wrapper.name):
                process, _ = self.run_wrapper(wrapper, ["4", "5"], exit_code=23)
                self.assertEqual(process.returncode, 23)


if __name__ == "__main__":
    unittest.main()
