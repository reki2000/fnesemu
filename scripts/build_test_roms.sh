#!/bin/sh
# Builds the homebrew test ROMs of the sms and ws cores from source.
#
# usage: scripts/build_test_roms.sh [out-dir]   (default: assets/testroms)
#
# requires: git, nasm, wla-z80 and wlalink (WLA DX), python3 with Pillow
#
#   WSCpuTest.wsc     V30MZ instructions and flags  (select "Test All")
#   WSHWTest.wsc      interrupts, timers, I/O ports  (select "Test All")
#   WSTimingTest.ws   V30MZ instruction timing
#   zexdoc.sms        Z80 documented flags, also runs in the TMS9918 mode
#   zexall.sms        Z80 with the undocumented flags
#   SMSVDPTest.sms    VDP ports, counters, interrupts and sprites
#
# run them with the core harness, for example:
#   cd packages/fnesemu_core
#   dart run tool/core_harness.dart wsc ../../assets/testroms/WSCpuTest.wsc \
#     -r -f 300000 -e 1000 -p 60:A
#   dart run tool/core_harness.dart sms ../../assets/testroms/zexdoc.sms \
#     -r -f 320000 -e 5000
set -e

OUT=$(realpath -m "${1:-assets/testroms}")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

clone() {
  git clone -q --depth 1 "https://github.com/$1" "$WORK/$2"
}

clone FluBBaOfWard/WSCpuTest WSCpuTest
clone FluBBaOfWard/WSHWTest WSHWTest
clone FluBBaOfWard/WSTimingTest WSTimingTest
clone maxim-zhao/zexall-sms zexall-sms
clone FluBBaOfWard/SMSVDPTest SMSVDPTest

(cd "$WORK/WSCpuTest" && nasm -f bin -o "$OUT/WSCpuTest.wsc" WSCpuTest.asm)
(cd "$WORK/WSHWTest" && nasm -f bin -o "$OUT/WSHWTest.wsc" WSHWTest.asm)
(cd "$WORK/WSTimingTest" && nasm -f bin -o "$OUT/WSTimingTest.ws" timingtest.asm)

# zexall-sms needs its fonts as 1bpp tiles (bmp2tile)
cd "$WORK/zexall-sms/source"
python3 - <<'EOF'
from PIL import Image
for name in ['Envious', 'ZX_Eurostile']:
    im = Image.open(name + '.png')
    px = im.load()
    out = bytearray()
    for ty in range(im.height // 8):
        for tx in range(im.width // 8):
            for y in range(8):
                b = 0
                for x in range(8):
                    b = b << 1 | (1 if px[tx * 8 + x, ty * 8 + y] else 0)
                out.append(b)
    open(name + '.1bpp', 'wb').write(out)
EOF
wla-z80 -o zexdoc.sms.o zexall.sms.asm
wlalink -d -r linkfile-doc "$OUT/zexdoc.sms"
wla-z80 -D UndocumentedFlags -o zexall.sms.o zexall.sms.asm
wlalink -d -r linkfile "$OUT/zexall.sms"

cd "$WORK/SMSVDPTest"
wla-z80 -o testmain.o testmain.asm
printf '[objects]\ntestmain.o\n' > linkfile
wlalink -d -r linkfile "$OUT/SMSVDPTest.sms"

ls -l "$OUT"
