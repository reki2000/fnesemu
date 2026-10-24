"""Fetches the dmg-acid2 (MIT) release ROM and its reference image into .build/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, download, run  # noqa: E402

SRC = "https://raw.githubusercontent.com/mattcurrie/dmg-acid2/8a98ce731f96dde032ffb22ec36dc985d78fdb18"


def setup():
    out = build_dir(__file__)
    download("https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb", out / "dmg-acid2.gb",
             "464e14b7d42e7feea0b7ede42be7071dc88913f75b9ffa444299424b63d1dff1")
    download(f"{SRC}/img/reference-dmg.png", out / "reference-dmg.png",
             "ca966d50895c7efef05838590d148c2cbfd7fba57dab986f25b35b4da71abb57")


run(setup)
