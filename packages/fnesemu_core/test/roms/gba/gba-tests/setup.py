"""Checks out the prebuilt test ROMs of jsmolka/gba-tests (MIT) that roms.toml uses into .build/."""

import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, git_checkout, require_files, run  # noqa: E402

HERE = Path(__file__).resolve().parent
PREFIX = ".build/gba-tests/"


def roms():
    cases = tomllib.loads((HERE.parent / "roms.toml").read_text())["case"]
    return sorted({f[len(PREFIX):] for c in cases if c.get("dir") == HERE.name for f in c["files"]})


def setup():
    files = roms()
    repo = git_checkout(
        "https://github.com/jsmolka/gba-tests.git",
        "a7113b67e63f83a9b321696ddd7042ccfad6c881",
        build_dir(__file__) / "gba-tests",
        sparse=[f"/{f}" for f in files],
    )
    require_files(*(repo / f for f in files))


run(setup)
