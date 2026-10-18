"""Fetches nestest.nes and its reference log into .build/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from setuplib import build_dir, download, run  # noqa: E402

BASE = "https://raw.githubusercontent.com/christopherpow/nes-test-roms/95d8f621ae55cee0d09b91519a8989ae0e64753b/other"


def setup():
    out = build_dir(__file__)
    download(f"{BASE}/nestest.nes", out / "nestest.nes", "f67d55fd6b3cf0bad1cc85f1df0d739c65b53e79cecb7fea8f77ec0eadab0004")
    download(f"{BASE}/nestest.log", out / "nestest.log", "442c4dd5539c7e88b3fd73c7b732a7eadbd22b47c2cd9e58397ef147f64f6f8f")


run(setup)
