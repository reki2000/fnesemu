"""Checks out the prebuilt test ROMs of PeterLemon/N64 (Unlicense) that e2e.toml uses into .build/."""

import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, git_checkout, require_files, run  # noqa: E402

HERE = Path(__file__).resolve().parent
PREFIX = ".build/N64/"


def roms():
    cases = tomllib.loads((HERE.parent / "e2e.toml").read_text())["case"]
    return sorted({f[len(PREFIX):] for c in cases if c.get("dir") == HERE.name for f in c["files"]})


def setup():
    files = roms()
    repo = git_checkout(
        "https://github.com/PeterLemon/N64.git",
        "7085543e4a19d8c539fc9e0a4d2869e788b4ed4b",
        build_dir(__file__) / "N64",
        sparse=[f"/{f}" for f in files],
    )
    require_files(*(repo / f for f in files))


run(setup)
