"""Extracts the Z80 test vectors (tests.in, tests.expected) of the Fuse release tarball into .build/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from setuplib import build_dir, download, extract_tar, run  # noqa: E402

URL = "https://downloads.sourceforge.net/project/fuse-emulator/fuse/1.6.0/fuse-1.6.0.tar.gz"


def setup():
    out = build_dir(__file__)
    if (out / "tests.in").exists() and (out / "tests.expected").exists():
        return
    archive = download(URL, out / "fuse-1.6.0.tar.gz", "3a8fedf2ffe947c571561bac55a59adad4c59338f74e449b7e7a67d9ca047096")
    extract_tar(archive, {
        "fuse-1.6.0/z80/tests/tests.in": out / "tests.in",
        "fuse-1.6.0/z80/tests/tests.expected": out / "tests.expected",
    })
    archive.unlink()


run(setup)
