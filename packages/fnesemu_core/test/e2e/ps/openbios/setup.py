"""Builds OpenBIOS of pcsx-redux/nugget (MIT) into .build/openbios.bin, a replacement BIOS for the PS1 test EXEs."""

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, git_checkout, require_files, run, toolchain  # noqa: E402

PREFIX = "mipsel-linux-gnu"


def setup():
    out = build_dir(__file__)
    bios = out / "openbios.bin"
    if bios.exists():
        return
    src = git_checkout("https://github.com/pcsx-redux/nugget.git", "08f1b3e1b3289b27fda955f6105fc9e6afd9ffe6", out / "nugget")
    toolchain(["make", "-C", "openbios", f"PREFIX={PREFIX}", "FORMAT=elf32-tradlittlemips", "-j4"], src,
              [f"{PREFIX}-gcc", f"{PREFIX}-g++", "make"])
    require_files(src / "openbios" / "openbios.bin")
    shutil.copy(src / "openbios" / "openbios.bin", bios)


run(setup)
