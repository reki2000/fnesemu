"""Fetches public PCE card test ROMs into .build/: display tests of Chris Covell, the card build of 240p Test Suite
1.10 (GPL-2.0, SourceForge) and the prebuilt test ROMs of rgalland."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, download, extract_zip, git_checkout, require_files, run  # noqa: E402

# file in .build/ -> (zip URL, sha256, member)
ZIPS = {
    "screen-dimension.pce": ("https://www.chrismcovell.com/data/Screen_Dimension_Test.zip",
                             "cc47cc7003fb84c88e00f6eda363aaf817e294f5ee72ab30e50d39a3e24ad93d", "Screen_Dimension_Test.pce"),
    "greyscale.pce": ("https://www.chrismcovell.com/data/Greyscale_Test.zip",
                      "db74b79ba953ee07cc78954026fbd9dd23df2b77c3533fb3fae6c2459337a5cb", "Greyscale_Test.pce"),
    "512-colours.pce": ("https://www.chrismcovell.com/data/512cols.zip",
                        "613c6c19bc9b22957b9eea282870393bc0eac2bbdc34a7379b5258d84a12f70b", "512_Colours.pce"),
    "split-res.pce": ("https://www.chrismcovell.com/data/SplitRes.zip",
                      "452b6603da59263bac1e087758aa50672a222ccaefe66f347ddbdf4524d3f12f", "SplitRes.pce"),
    "240p-suite.pce": ("https://downloads.sourceforge.net/project/testsuite240p/OldFiles/PCE-TG16-SCD/240pSuite_1.10_HuCard.zip",
                       "3edcb149858fbe344582775659edeedd21c5f62a8cce0b452923201476629ff1", "240pSuite.pce"),
}
RGALLAND = ["BG_128x64/bg_128x64.pce", "BG_64x32/bg_64x32.pce", "LATCHING_TEST/cr_byr_bxr_latching_test.pce",
            "LOADING_SCREEN/loading_screen.pce", "SPRITE/sprite.pce"]


def setup():
    out = build_dir(__file__)
    for name, (url, digest, member) in ZIPS.items():
        if not (out / name).exists():
            archive = download(url, out / f"{name}.zip", digest)
            extract_zip(archive, {member: out / name})
            archive.unlink()
    repo = git_checkout("https://github.com/rgalland/PCEngine_TestRoms.git", "1b2d56c2d59d927df781ae41dd3a4c3ada053052",
                        out / "rgalland", sparse=[f"/{r}" for r in RGALLAND])
    require_files(*(repo / r for r in RGALLAND))


run(setup)
