import 'dart:typed_data';

import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/cpu.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/n64/rom.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

Uint8List cartridge(List<int> instructions, {int entry = 0x80000400}) {
  final data = ByteData(0x1000 + instructions.length * 4);
  data.setUint32(0, 0x80371240);
  data.setUint32(8, entry);
  for (var i = 0; i < instructions.length; i++) {
    data.setUint32(0x1000 + i * 4, instructions[i]);
  }
  return data.buffer.asUint8List();
}

Vr4300 processor(List<int> instructions) {
  final bus = N64Bus();
  for (var i = 0; i < instructions.length; i++) {
    // through the unmapped segment: user addresses go through the TLB
    bus.write(0xa0000000 + i * 4, instructions[i], 4);
  }
  return Vr4300(bus)..reset(0x80000000);
}

void main() {
  test('all cartridge byte orders normalize without mutating the input', () {
    final original = cartridge([0x24010001]);
    for (final group in [1, 2, 4]) {
      final input = Uint8List(original.length);
      for (var i = 0; i < input.length; i += group) {
        for (var j = 0; j < group; j++) {
          input[i + j] = original[i + group - j - 1];
        }
      }
      final copy = Uint8List.fromList(input);
      final rom = N64Rom(input);
      expect(rom.bytes, original);
      expect(rom.entryPoint, 0x80000400);
      expect(input, copy);
    }
  });

  test('bad headers, truncated dumps and unsupported entry points fail', () {
    expect(() => N64Rom(Uint8List(4)), throwsFormatException);
    expect(() => N64Rom(Uint8List(0x1004)), throwsFormatException);
    expect(
      () => N64Rom(cartridge([0], entry: 0x80800000)),
      throwsFormatException,
    );
    expect(
      () => N64Rom(cartridge([0], entry: 0x80000401)),
      throwsFormatException,
    );
  });

  test('word arithmetic sign extends; zero stays zero', () {
    final cpu = processor([
      0x3c018000, // lui r1, 0x8000
      0x2422ffff, // addiu r2,r1,-1 -> 0x7fffffff
      0x24430001, // addiu r3,r2,1 -> -2147483648
      0x24000009, // addiu zero,zero,9
    ]);
    for (var i = 0; i < 4; i++) {
      cpu.step();
    }
    expect(cpu.stopReason, isNull);
    expect(cpu.r[1], -2147483648);
    expect(cpu.r[2], 2147483647);
    expect(cpu.r[3], -2147483648);
    expect(cpu.r[0], 0);
  });








  test('direct boot runs a ROM that configures VI and draws a red pixel', () {
    final core = N64();
    addTearDown(core.dispose);
    core.setRom(
      cartridge([
        0x3c08a440, // lui t0, VI
        0x24090002, 0xad090000, // VI mode = 16-bit
        0x24090100, 0xad090004, // origin = 0x100
        0x24090001, 0xad090008, // stride = 1
        0xad090024, // h start/end = 0/1
        0x24090002, 0xad090028, // v start/end = 0/2
        0x24090400, 0xad090030, 0xad090034, // x/y scale
        0x3c0aa000, 0x340bf801, 0xa54b0100, // red pixel
        0x08000110, 0, // loop at 0x80000440
      ]),
    );
    core.reset();
    var lines = 0;
    for (var i = 0; i < core.clocksInScanline * 2; i++) {
      final result = core.exec(true);
      expect(result.stopped, isFalse);
      if (result.scanlineRendered) lines++;
    }
    expect(lines, 2);
    expect(core.imageBuffer().bytes, [255, 0, 0, 255]);
    core.reset();
    expect(core.cpu.clocks, 0);
    expect(core.bus.vi[0], 0);
    expect(core.programCounter(0), 0x80000400);
  });
}
