import 'package:fnesemu_core/src/core/ss/vdp1.dart';
import 'package:fnesemu_core/src/core/ss/vdp2.dart';
import 'package:test/test.dart';

void main() {
  const white = 0x80ffffff;

  // NBG0 as a 512 x 256 RGB 24-bit bitmap in 320-dot mode with the scroll
  // position (scrollX, 0); renders line 0 and returns it
  List<int> renderLine0(
      {int scrollX = 0, void Function(Vdp2 vdp2)? setup, int? fill}) {
    final vdp2 = Vdp2()
      ..vdp1 = (Vdp1()..reset())
      ..reset();
    vdp2
      ..writeReg(0x00, 0x8000) // TVMD: display on, 320 x 224
      ..writeReg(0x20, 0x0101) // BGON: NBG0 on, transparent code off
      ..writeReg(0x28, 0x0042) // CHCTLA: bitmap, 16M colors, 512 x 256
      ..writeReg(0x70, scrollX)
      ..writeReg(0xf8, 0x0001); // PRINA: NBG0 priority 1
    if (fill != null) {
      for (int i = 0; i < 512 * 2; i++) {
        vdp2.vramData.setUint32(i * 4, fill);
      }
    }
    setup?.call(vdp2);
    vdp2.renderLine(0);
    return vdp2.imageBuffer.buffer.sublist(0, 320);
  }

  test('a bitmap line scrolled past the right edge continues in the next row',
      () {
    final reference = renderLine0(setup: (v) {
      v.vramData.setUint32(0, white);
    });
    final scrolled = renderLine0(
        scrollX: 510,
        setup: (v) {
          // the dot at index 512 is the first dot of the second row
          v.vramData.setUint32(512 * 4, white);
        });
    expect(scrolled[2], reference[0]);
    expect(scrolled[1], isNot(reference[0]));
    expect(scrolled[3], isNot(reference[0]));
  });

  test('a window shows a layer only inside of its area', () {
    final line = renderLine0(
        fill: white,
        setup: (v) {
          v
            ..writeReg(0xd0, 0x0003) // NBG0: window 0 on, inside
            ..writeReg(0xc0, 32) // x 16 to 335 in 2-dot units
            ..writeReg(0xc4, 0x27e)
            ..writeReg(0xc6, 0xe0);
        });
    expect(line[10], isNot(line[100]));
    expect(line[15], line[10]);
    expect(line[16], line[100]);
    expect(line[319], line[100]);
  });

  test('a line window takes the range of each line from its table', () {
    final line = renderLine0(
        fill: white,
        setup: (v) {
          v
            ..writeReg(0xd0, 0x0003)
            ..writeReg(0xc6, 0xe0)
            ..writeReg(0xd8, 0x8000) // line window 0 at 0x1000
            ..writeReg(0xda, 0x0800);
          v.vramData
            ..setUint16(0x1000, 40)
            ..setUint16(0x1002, 100);
        });
    expect(line[19], isNot(line[30]));
    expect(line[20], line[30]);
    expect(line[50], line[30]);
    expect(line[51], line[19]);
  });
}
