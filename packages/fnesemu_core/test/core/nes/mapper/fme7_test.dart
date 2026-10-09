import 'dart:typed_data';

import 'package:fnesemu_core/core/nes/mapper/fme7.dart';
import 'package:fnesemu_core/core/nes/mapper/sunsoft5b_apu.dart';
import 'package:test/test.dart';

MapperFme7 _mapper() {
  // 8 prg banks of 8KB and 8 chr banks of 1KB, each filled with its number
  final prg = Uint8List(0x10000);
  for (var b = 0; b < 8; b++) {
    prg.fillRange(b * 0x2000, (b + 1) * 0x2000, b);
  }
  final chr = Uint8List(0x2000);
  for (var b = 0; b < 8; b++) {
    chr.fillRange(b * 0x400, (b + 1) * 0x400, b);
  }
  return MapperFme7()
    ..setRom(chr, prg)
    ..init();
}

void main() {
  test('switches prg and chr banks by command and parameter', () {
    final m = _mapper();
    expect(m.read(0xe000), 7); // the last bank is fixed
    m.write(0x8000, 9);
    m.write(0xa000, 3);
    expect(m.read(0x8000), 3);
    m.write(0x8000, 2);
    m.write(0xa000, 5);
    expect(m.readVram(0x0800), 5);
  });

  test('raises the IRQ when the counter wraps', () {
    final m = _mapper();
    var irq = false;
    m.holdIrq = (on) => irq = on;
    m.write(0x8000, 14);
    m.write(0xa000, 100);
    m.write(0x8000, 15);
    m.write(0xa000, 0);
    m.write(0x8000, 13);
    m.write(0xa000, 0x81);
    m.handleClock(100);
    expect(irq, isFalse);
    m.handleClock(101);
    expect(irq, isTrue);
  });

  test('a tone channel makes a square wave', () {
    final apu = Sunsoft5bApu();
    apu.write(0, 0x20); // channel A period 32
    apu.write(7, 0x3e); // channel A tone on, noise off
    apu.write(8, 0x0f); // full volume
    final out = apu.exec(4096);
    expect(out.reduce((a, b) => a > b ? a : b), greaterThan(0.3));
    expect(out.reduce((a, b) => a < b ? a : b), 0);
  });
}
