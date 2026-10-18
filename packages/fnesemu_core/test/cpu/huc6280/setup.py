"""Checks out the HuC6280 cases of SingleStepTests/huc6280 (MIT) into .build/huc6280/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from setuplib import build_dir, git_checkout, require_files, run  # noqa: E402


def setup():
    repo = git_checkout(
        "https://github.com/SingleStepTests/huc6280.git",
        "4ce378e04e243437e6f74dfe76c3cb7c70e45bf1",
        build_dir(__file__) / "huc6280",
        sparse=["/v1/"],
    )
    require_files(repo / "v1" / "00.json.bin")


run(setup)
