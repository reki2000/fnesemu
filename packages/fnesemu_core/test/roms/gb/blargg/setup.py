"""Checks out the prebuilt blargg GB test ROMs of retrio/gb-test-roms into .build/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, git_checkout, require_files, run  # noqa: E402

ROMS = ["cpu_instrs/cpu_instrs.gb", "instr_timing/instr_timing.gb", "mem_timing/mem_timing.gb",
        "halt_bug.gb", "dmg_sound/dmg_sound.gb"]


def setup():
    repo = git_checkout(
        "https://github.com/retrio/gb-test-roms.git",
        "c240dd7d700e5c0b00a7bbba52b53e4ee67b5f15",
        build_dir(__file__) / "gb-test-roms",
        sparse=[f"/{r}" for r in ROMS],
    )
    require_files(*(repo / r for r in ROMS))


run(setup)
