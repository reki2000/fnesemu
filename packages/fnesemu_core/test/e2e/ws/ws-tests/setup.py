"""Prepares the WS test ROMs of FluBBaOfWard in .build/.

WSCpuTest and WSTimingTest come from their release zips; WSHWTest has no release and is assembled with nasm.
"""

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, download, extract_zip, git_checkout, require_files, run, toolchain  # noqa: E402

RELEASES = [
    ("https://github.com/FluBBaOfWard/WSCpuTest/releases/download/v0.7.1/WSCpuTest.zip",
     "d15b36ac5a36c8a44c458e5e262a41585751494f67b3c42c223fb81effeb06a4", "WSCpuTest.wsc", "WSCpuTest.wsc"),
    ("https://github.com/FluBBaOfWard/WSTimingTest/releases/download/v0.2.0/WSTimingTest.zip",
     "0c5cd61c0b475f9c84c1de14d4631e1ada46f053804032eb71a755fec7e76144", "timingtest.ws", "WSTimingTest.ws"),
]


def setup():
    out = build_dir(__file__)
    for url, digest, member, name in RELEASES:
        if not (out / name).exists():
            archive = download(url, out / Path(url).name, digest)
            extract_zip(archive, {member: out / name})
            archive.unlink()
    if not (out / "WSHWTest.wsc").exists():
        src = git_checkout("https://github.com/FluBBaOfWard/WSHWTest.git", "34e33d5bfaaabb8b09fa5a557e409efe9fbfd979",
                           out / "WSHWTest")
        toolchain(["nasm", "-f", "bin", "-o", "WSHWTest.wsc", "WSHWTest.asm"], src, ["nasm"])
        shutil.copy(src / "WSHWTest.wsc", out / "WSHWTest.wsc")
    require_files(*(out / n for n in ("WSCpuTest.wsc", "WSTimingTest.ws", "WSHWTest.wsc")))


run(setup)
