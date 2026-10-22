"""Extracts the prebuilt test EXEs of the JaCzekanski/ps1-tests build-158 release (MIT) into .build/ps1-tests/.

The release also has the VRAM dumps (vram*.png) and the TTY logs (psx.log) of the real hardware.
"""

import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, download, require_files, run  # noqa: E402

URL = "https://github.com/JaCzekanski/ps1-tests/releases/download/build-158/tests.zip"


def setup():
    out = build_dir(__file__)
    dest = out / "ps1-tests"
    if (dest / "gpu" / "quad" / "quad.exe").exists():
        return
    archive = download(URL, out / "tests.zip", "5de0e82854c1a511697a7ade381c2d778ec4b2fff4a7d7ac79e8098c35eb859b")
    with zipfile.ZipFile(archive) as z:
        z.extractall(dest)
    archive.unlink()
    require_files(dest / "gpu" / "quad" / "quad.exe")


run(setup)
