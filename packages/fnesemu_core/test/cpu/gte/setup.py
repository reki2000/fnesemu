"""Fetches the GTE test source of ps1-tests (its cases are parsed from tests.c) into .build/."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from setuplib import build_dir, download, run  # noqa: E402

URL = "https://raw.githubusercontent.com/JaCzekanski/ps1-tests/f727802fead11f1daa7549285548392ef87749cb/gte/test-all/tests.c"


def setup():
    download(URL, build_dir(__file__) / "tests.c", "10136d1335069b8f8e4d5e3f1c1f197a7c4ec1e7606ece1aa658a8c0d1706240")


run(setup)
