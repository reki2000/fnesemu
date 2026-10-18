"""Extracts the prebuilt ROMs of the gilyon/snes-tests v1.4 release (MIT) into .build/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, download, extract_zip, run  # noqa: E402

URL = "https://github.com/gilyon/snes-tests/releases/download/v1.4/snes-tests.zip"
ROMS = ["cputest/cputest-basic.sfc", "cputest/cputest-full.sfc", "spctest/spctest.sfc"]


def setup():
    out = build_dir(__file__)
    if all((out / Path(r).name).exists() for r in ROMS):
        return
    archive = download(URL, out / "snes-tests.zip", "c3a39e15a9f3789fe143e54dfa035c988204576eafacf97df8ff3546a917c5e9")
    extract_zip(archive, {r: out / Path(r).name for r in ROMS})
    archive.unlink()


run(setup)
