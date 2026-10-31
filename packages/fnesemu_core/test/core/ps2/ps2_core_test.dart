import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:test/test.dart';

/// an ELF whose program is `b .` followed by a nop
Uint8List _loopElf() {
  const entry = 0x100000;
  final body = ByteData(52 + 32 + 8);
  body.setUint8(0, 0x7f);
  body.setUint8(1, 0x45);
  body.setUint8(2, 0x4c);
  body.setUint8(3, 0x46);
  body.setUint8(4, 1);
  body.setUint8(5, 1);
  body.setUint16(16, 2, Endian.little);
  body.setUint16(18, 8, Endian.little);
  body.setUint32(24, entry, Endian.little);
  body.setUint32(28, 52, Endian.little);
  body.setUint16(42, 32, Endian.little);
  body.setUint16(44, 1, Endian.little);
  body.setUint32(52, 1, Endian.little);
  body.setUint32(56, 84, Endian.little);
  body.setUint32(60, entry, Endian.little);
  body.setUint32(68, 8, Endian.little);
  body.setUint32(72, 8, Endian.little);
  body.setUint32(84, 0x1000ffff, Endian.little);
  return body.buffer.asUint8List();
}

void main() {
  test('an ELF program draws a sprite that shows up in the image buffer', () {
    final ps2 = Ps2()..setRom(_loopElf());
    final bus = ps2.bus;
    expect(ps2.imageBuffer().width, 0);

    // display circuit 1: 64x32 pixels from frame buffer 0, PSMCT32
    bus.write64(0x12000000, 1); // PMODE: EN1
    bus.write64(0x12000070, 1 << 9); // DISPFB1: FBW 1
    bus.write64(0x12000080, 63 << 32 | 31 << 44); // DISPLAY1

    bus.write32(0x1000e000, 1); // D_CTRL: DMAE
    var a = 0x2000;
    void qw(int lo, int hi) {
      bus.write64(a, lo);
      bus.write64(a + 8, hi);
      a += 16;
    }

    qw(7 | (7 << 28), 0); // end tag, 7 quadwords
    qw(2 | (1 << 15) | (1 << 60), 0xe); // GIF: A+D, 2 registers
    qw(1 << 16, 0x4c); // FRAME_1: FBW 1
    qw((63 << 16) | (31 << 48), 0x40); // SCISSOR_1
    // PRIM sprite, then RGBAQ and two XYZ2 (12.4 fixed point)
    qw(1 | (1 << 15) | (1 << 46) | (6 << 47) | (3 << 60), 0x551);
    qw(0xff, 0xff | (0x80 << 32));
    qw(0, 0);
    qw((16 * 16) | ((16 * 16) << 32), 0);
    bus.write32(0x1000a030, 0x2000);
    bus.write32(0x1000a000, 0x104);
    final image = ps2.imageBuffer();
    expect(image.width, 64);
    expect(image.height, 32);
    expect(image.buffer[0], 0xffff00ff);
    expect(image.buffer[32 * 0 + 5], 0xffff00ff);
    expect(image.buffer[63], 0xff000000);
  });
}
