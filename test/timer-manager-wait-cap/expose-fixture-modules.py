"""Expose three internal modules in a test-only copy of one registration."""

import re
import sys
from pathlib import Path

MODULES = (
    "GHC.Internal.Event.Control",
    "GHC.Internal.Event.Internal",
    "GHC.Internal.Event.TimerManager",
)


def expose(text):
    headers = list(re.finditer(r"(?m)^([a-zA-Z][a-zA-Z0-9-]*):", text))
    if not headers or text[:headers[0].start()].strip() or "${pkgroot}" in text:
        raise ValueError("expected one clean registration with expanded pkgroot")
    chunks = {}
    for index, header in enumerate(headers):
        key = header.group(1)
        if key in chunks:
            raise ValueError("duplicate registration field: " + key)
        end = headers[index + 1].start() if index + 1 < len(headers) else len(text)
        chunks[key] = text[header.start():end]
    value = lambda key: chunks[key].split(":", 1)[1].strip()
    if value("name") != "ghc-internal" or value("version") != "9.1400.0":
        raise ValueError("expected the matching GHC 9.14 ghc-internal registration")
    hidden = value("hidden-modules").split()
    if any(module not in hidden for module in MODULES):
        raise ValueError("required fixture modules are not all hidden")
    chunks["exposed-modules"] = chunks["exposed-modules"].rstrip() + "\n    " + " ".join(MODULES) + "\n"
    chunks["hidden-modules"] = "hidden-modules: " + " ".join(module for module in hidden if module not in MODULES) + "\n"
    return "".join(chunks.values())


def self_test():
    original = (
        "name: ghc-internal\nversion: 9.1400.0\nid: retained-unit\n"
        "exposed-modules: Keep.Exposed\nhidden-modules: Keep.Hidden\n    "
        + " ".join(MODULES)
        + "\nlibrary-dirs: /retained/library\ndepends: retained-dependency\n"
    )
    expected = original.replace(
        "exposed-modules: Keep.Exposed\n", "exposed-modules: Keep.Exposed\n    " + " ".join(MODULES) + "\n"
    ).replace("hidden-modules: Keep.Hidden\n    " + " ".join(MODULES), "hidden-modules: Keep.Hidden")
    assert expose(original) == expected
    for invalid in (original + "name: another\n", original.replace(MODULES[0], "Missing.Module"), original.replace("/retained/library", "${pkgroot}/lib")):
        try:
            expose(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted an invalid registration")
    print("PASS: private exposure preserves other registration fields and rejects unsupported input")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 3:
        Path(sys.argv[2]).write_text(expose(Path(sys.argv[1]).read_text()))
    else:
        raise SystemExit("usage: expose-fixture-modules.py INPUT OUTPUT | --self-test")
