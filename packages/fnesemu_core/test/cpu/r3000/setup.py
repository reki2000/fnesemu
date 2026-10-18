"""Checks out the R3000 cases of SingleStepTests/r3000 (MIT) into .build/r3000/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from setuplib import build_dir, git_checkout, require_files, run  # noqa: E402


def setup():
    repo = git_checkout(
        "https://github.com/SingleStepTests/r3000.git",
        "51e227447d0b93882a8f13c87c6cee72819efdd3",
        build_dir(__file__) / "r3000",
        sparse=["/v1/"],
    )
    require_files(repo / "v1" / "ADD.json.bin")


run(setup)
