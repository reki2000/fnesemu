"""Fetches the replacement BIOS of Cult-of-GBA/BIOS (MIT, a prebuilt bios.bin in the repository) into .build/.

The GBA test ROMs call BIOS functions, which the core runs only with a BIOS image.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, download, run  # noqa: E402

URL = "https://raw.githubusercontent.com/Cult-of-GBA/BIOS/a30e9a96df083628b650724b7d4d7112b4070b98/bios.bin"


def setup():
    download(URL, build_dir(__file__) / "bios.bin", "61af6e8c2db6cf24aa6924e8133f6a50833158fca33ff08ea5e11e1a06e132f2")


run(setup)
