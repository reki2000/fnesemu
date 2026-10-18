"""Prepares the SMS test ROMs in .build/.

zexdoc.sms and zexall.sms come from the maxim-zhao/zexall-sms v0.21 release (GPL-2.0); FluBBaOfWard/SMSVDPTest has no
release and is assembled with WLA DX.
"""

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from setuplib import build_dir, download, extract_zip, git_checkout, require_files, run, toolchain  # noqa: E402

ZEXALL = "https://github.com/maxim-zhao/zexall-sms/releases/download/v0.21/ZEXALL-SMS-0.21.zip"


def setup():
    out = build_dir(__file__)
    if not (out / "zexdoc.sms").exists():
        archive = download(ZEXALL, out / "ZEXALL-SMS-0.21.zip", "704e39402516fba832b923395c7579b617896e1f00d2f036696342ab4b5fde7c")
        extract_zip(archive, {"zexdoc.sms": out / "zexdoc.sms", "zexall.sms": out / "zexall.sms"})
        archive.unlink()
    if not (out / "SMSVDPTest.sms").exists():
        src = git_checkout("https://github.com/FluBBaOfWard/SMSVDPTest.git", "490c00b38c83012dee5a7a582097f080c210a3e7",
                           out / "SMSVDPTest")
        (src / "linkfile").write_text("[objects]\ntestmain.o\n")
        toolchain(["sh", "-c", "wla-z80 -o testmain.o testmain.asm && wlalink -d -r linkfile SMSVDPTest.sms"], src,
                  ["wla-z80", "wlalink"])
        shutil.copy(src / "SMSVDPTest.sms", out / "SMSVDPTest.sms")
    require_files(*(out / n for n in ("zexdoc.sms", "zexall.sms", "SMSVDPTest.sms")))


run(setup)
