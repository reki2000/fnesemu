"""Checks out the 68000 cases of SingleStepTests/680x0 into .build/680x0/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from setuplib import build_dir, git_checkout, require_files, run  # noqa: E402


def setup():
    repo = git_checkout(
        "https://github.com/SingleStepTests/680x0.git",
        "e0d5ece9670205cc84a0101081837deb446f86a3",
        build_dir(__file__) / "680x0",
        sparse=["/68000/v1/"],
    )
    require_files(repo / "68000" / "v1")


run(setup)
