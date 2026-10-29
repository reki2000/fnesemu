import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/ipu/ipu.dart';
import 'package:test/test.dart';

const _cmd = 0x10002000, _ctrl = 0x10002010, _top = 0x10002030;

/// writes [bits] (a string of '0' and '1') to the input FIFO, padded with
/// zeros to whole quadwords
void _feed(Ipu ipu, String bits) {
  final padded = bits.padRight(((bits.length + 127) ~/ 128) * 128, '0');
  final bytes = [
    for (var i = 0; i < padded.length; i += 8)
      int.parse(padded.substring(i, i + 8), radix: 2),
  ];
  for (var q = 0; q < bytes.length; q += 16) {
    for (var half = 0; half < 2; half++) {
      var v = 0;
      for (var k = 7; k >= 0; k--) {
        v = v << 8 | bytes[q + half * 8 + k];
      }
      ipu.writeFifo(0x10007010 + half * 8, 8, v);
    }
  }
}

List<int> _drain(Ipu ipu) {
  final out = <int>[];
  final quad = Int64List(2);
  while (ipu.fromIpu.hasData) {
    ipu.fromIpu.get(quad);
    out
      ..add(quad[0])
      ..add(quad[1]);
  }
  return out;
}

void main() {
  test('FDEC shows the next 32 bits after the skipped ones', () {
    final ipu = Ipu();
    _feed(ipu, '0000000000000000000000011011001111111111');
    ipu.write(_cmd, 4, 0x40000000 | 8);
    expect(ipu.read(_cmd, 8), 0x0001b3ff);
    expect(ipu.read(_top, 4), 0x0001b3ff);
    expect(ipu.read(0x10002020, 4) & 0x7f, 8);
  });

  test('VDEC returns the code length and the value', () {
    final ipu = Ipu();
    _feed(ipu, '011' '00000001000' '00011' '11');
    ipu.write(_cmd, 4, 0x30000000); // macroblock address increment
    expect(ipu.read(_cmd, 4), 3 << 16 | 2);
    ipu.write(_cmd, 4, 0x30000000); // escape
    expect(ipu.read(_cmd, 4), 11 << 16 | 0x23);
    ipu.write(_cmd, 4, 0x38000000); // motion code -3
    expect(ipu.read(_cmd, 4), 5 << 16 | 0xfffd);
    ipu.write(_cmd, 4, 0x3c000000); // dmvector -1
    expect(ipu.read(_cmd, 4), 2 << 16 | 0xffff);
  });

  test('VDEC decodes macroblock_type with the table of the picture type', () {
    final ipu = Ipu();
    _feed(ipu, '001' '01');
    ipu.write(_ctrl, 4, 2 << 24); // P picture
    ipu.write(_cmd, 4, 0x34000000);
    expect(ipu.read(_cmd, 4), 3 << 16 | 8); // forward only
    ipu.write(_ctrl, 4, 1 << 24); // I picture
    ipu.write(_cmd, 4, 0x34000000);
    expect(ipu.read(_cmd, 4), 2 << 16 | 17); // intra with quantiser
  });

  test('a command without enough data waits for it', () {
    final ipu = Ipu();
    ipu.write(_cmd, 4, 0x40000000);
    expect(ipu.read(_ctrl, 4) >>> 31, 1);
    _feed(ipu, '1');
    expect(ipu.read(_ctrl, 4) >>> 31, 0);
    expect(ipu.read(_cmd, 4), 0x80000000);
  });

  test('BDEC of an intra macroblock with only DC coefficients', () {
    final ipu = Ipu();
    // luminance: DC size 0, end of block; chrominance: the same
    _feed(ipu, '10010' * 4 + '0010' * 2);
    // intra, DC reset, quantiser scale 1
    ipu.write(_cmd, 4, 0x20000000 | 1 << 27 | 1 << 26 | 1 << 16);
    expect(ipu.read(_ctrl, 4) >>> 31, 0);
    final out = _drain(ipu);
    expect(out.length, 96);
    final halves = [
      for (final w in out)
        for (var i = 0; i < 4; i++) (w >> (16 * i)) & 0xffff
    ];
    expect(halves, List.filled(384, 128));
  });

  test('CSC converts the black and the white of the studio range', () {
    final ipu = Ipu();
    final y = List.filled(256, 16)..fillRange(128, 256, 235);
    final bits = [...y, ...List.filled(128, 128)]
        .map((v) => v.toRadixString(2).padLeft(8, '0'))
        .join();
    _feed(ipu, bits);
    ipu.write(_cmd, 4, 0x70000000 | 1);
    final out = _drain(ipu);
    expect(out.length, 128);
    expect(out.first & 0xffffffff, 0x80000000);
    expect(out.last >>> 32, 0x80ffffff);
  });
}
