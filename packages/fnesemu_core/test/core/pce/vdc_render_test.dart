import 'dart:math';

import 'package:fnesemu_core/src/core/pce/component/vdc.dart';
import 'package:fnesemu_core/src/core/pce/component/vdc_render.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:test/test.dart';

// sets up a vdc with random vram, sprites and registers from [seed]
Pce _machine(int seed, {required bool collision, required int mode}) {
  final pce = Pce()..reset();
  final vdc = pce.vdc;
  final r = Random(seed);
  for (int i = 0; i < vdc.vram.length; i++) {
    vdc.vram[i] = r.nextInt(0x10000);
  }

  void reg(int no, int lsb, int msb) {
    vdc.writeReg(no);
    vdc.writeLsb(lsb);
    vdc.writeMsb(msb);
  }

  // control: bg + sprites, optional collision irq
  reg(0x05, 0xc0 | (collision ? 0x01 : 0) | 0x02, 0);
  reg(0x07, r.nextInt(256), r.nextInt(4)); // scroll x
  reg(0x08, r.nextInt(256), r.nextInt(2)); // scroll y
  reg(0x09, mode, 0); // bg size, dot width
  reg(0x0b, r.nextInt(64), 0); // horizontal display

  // sprites around the visible area, sprite 0 included
  for (int i = 0; i < 64; i++) {
    vdc.sat[i * 4 + 0] = 64 + r.nextInt(260) - 30;
    vdc.sat[i * 4 + 1] = r.nextInt(vdc.hSize + 64);
    vdc.sat[i * 4 + 2] = r.nextInt(0x800);
    vdc.sat[i * 4 + 3] = r.nextInt(0x10000);
  }
  vdc.fetchSatb();
  return pce;
}

void main() {
  for (final collision in [false, true]) {
    for (final mode in [0x00, 0x13, 0x50, 0x83, 0x33]) {
    }
  }

  test('a change of HDR in a frame keeps the lines rendered so far', () {
    final vdc = (Pce()..reset()).vdc;
    void reg(int no, int lsb) {
      vdc.writeReg(no);
      vdc.writeLsb(lsb);
      vdc.writeMsb(0);
    }

    final buffer = vdc.indexBuffer;
    reg(0x0b, 0x25); // 304 dots
    expect(vdc.indexBuffer, same(buffer));
    expect(vdc.hSize, 256);
    reg(0x0b, 0x1f); // 256 dots
    expect(vdc.pendingHSize, 304, reason: 'the widest of the frame');
  });
}
