import 'package:fnesemu_core/src/core/ss/vdp1.dart';
import 'package:test/test.dart';

void main() {
  // a command list: system clipping to 703 x 447, a line from (x, y) to
  // (x, y) in [color], and the end
  Vdp1 drawPoint(int x, int y, int color, {int fbcr = 0, int tvmr = 0}) {
    final vdp1 = Vdp1()..reset();
    void w16(int addr, int v) => vdp1.vramData.setUint16(addr, v);
    w16(0x00, 0x0009); // system clipping
    w16(0x14, 703);
    w16(0x16, 447);
    w16(0x20, 0x0006); // line
    w16(0x24, 0x00c0); // pmod: no end code, no transparent check
    w16(0x26, color);
    w16(0x2c, x);
    w16(0x2e, y);
    w16(0x30, x);
    w16(0x32, y);
    w16(0x40, 0x8000); // end
    vdp1
      ..writeReg(0x00, tvmr)
      ..writeReg(0x02, fbcr)
      ..writeReg(0x04, 1);
    return vdp1;
  }

  test('8-bit pixels take one byte each, the even pixel in the upper byte', () {
    final vdp1 = drawPoint(601, 3, 0x5a, tvmr: 1);
    expect(vdp1.drawFb[3 * Vdp1.fbWidth + 300], 0x005a);
  });

  test('double interlace draws the lines of the field that DIL selects', () {
    final odd = drawPoint(10, 301, 0x8123, fbcr: 0x0c);
    expect(odd.drawFb[150 * Vdp1.fbWidth + 10], 0x8123);
    final even = drawPoint(10, 301, 0x8123, fbcr: 0x08);
    expect(even.drawFb[150 * Vdp1.fbWidth + 10], 0);
  });

  test('a manual erase clears the displayed buffer after its field', () {
    // draws a point, then changes the frame so that the point is displayed
    final vdp1 = drawPoint(10, 5, 0x8123, fbcr: 0x03)
      ..writeReg(0x0a, 127 << 9 | 447) // erase to the bottom right
      ..onVBlankIn();
    expect(vdp1.displayFb[5 * Vdp1.fbWidth + 10], 0x8123);

    vdp1.writeReg(0x02, 0x02);
    vdp1.onVBlankIn();
    expect(vdp1.displayFb[5 * Vdp1.fbWidth + 10], 0x8123);
    vdp1.onVBlankIn();
    expect(vdp1.displayFb[5 * Vdp1.fbWidth + 10], 0);
  });
}
