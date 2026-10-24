"""Checks out the prebuilt test ROMs of christopherpow/nes-test-roms that e2e.toml uses into .build/."""

import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, git_checkout, require_files, run  # noqa: E402

HERE = Path(__file__).resolve().parent
PREFIX = ".build/nes-test-roms/"


def roms():
    cases = tomllib.loads((HERE.parent / "e2e.toml").read_text())["case"]
    return sorted({f[len(PREFIX):] for c in cases if c.get("dir") == HERE.name for f in c["files"]})


def setup():
    files = roms()
    repo = git_checkout(
        "https://github.com/christopherpow/nes-test-roms.git",
        "95d8f621ae55cee0d09b91519a8989ae0e64753b",
        build_dir(__file__) / "nes-test-roms",
        sparse=[f"/{f}" for f in files],
    )
    require_files(*(repo / f for f in files))


run(setup)
