import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/elf.dart';
import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:test/test.dart';

Uint8List _elf(
    {int entry = 0x100000,
    int address = 0x100000,
    List<int> payload = const [1, 2, 3, 4],
    int memorySize = 8,
    int machine = 8}) {
  final body = ByteData(52 + 32 + payload.length);
  body.setUint8(0, 0x7f);
  body.setUint8(1, 0x45);
  body.setUint8(2, 0x4c);
  body.setUint8(3, 0x46);
  body.setUint8(4, 1);
  body.setUint8(5, 1);
  body.setUint16(16, 2, Endian.little);
  body.setUint16(18, machine, Endian.little);
  body.setUint32(24, entry, Endian.little);
  body.setUint32(28, 52, Endian.little);
  body.setUint16(42, 32, Endian.little);
  body.setUint16(44, 1, Endian.little);
  body.setUint32(52, 1, Endian.little);
  body.setUint32(56, 84, Endian.little);
  body.setUint32(60, address, Endian.little);
  body.setUint32(68, payload.length, Endian.little);
  body.setUint32(72, memorySize, Endian.little);
  final bytes = body.buffer.asUint8List();
  bytes.setAll(84, payload);
  return bytes;
}

void main() {
  test('parses entry and loadable segments', () {
    final elf = Elf.parse(_elf());
    expect(elf.entry, 0x100000);
    expect(elf.segments, hasLength(1));
    expect(elf.segments.single.address, 0x100000);
    expect(elf.segments.single.data, [1, 2, 3, 4]);
    expect(elf.segments.single.memorySize, 8);
  });

  test('rejects other formats', () {
    expect(() => Elf.parse(Uint8List(10)), throwsFormatException);
    expect(() => Elf.parse(_elf(machine: 40)), throwsFormatException);
    final truncated = _elf().sublist(0, 85);
    expect(() => Elf.parse(truncated), throwsFormatException);
  });

  test('Ps2 copies segments to main memory and zero fills the rest', () {
    final ps2 = Ps2();
    ps2.bus.ram.fillRange(0x100000, 0x100008, 0xff);
    ps2.setRom(_elf());
    expect(ps2.entry, 0x100000);
    expect(ps2.bus.ram.sublist(0x100000, 0x100008), [1, 2, 3, 4, 0, 0, 0, 0]);
  });

  test('Ps2 rejects segments outside main memory', () {
    expect(() => Ps2().setRom(_elf(address: Ps2Bus.ramSize - 4)),
        throwsRangeError);
  });

  test('Ps2 runs the loaded ELF from its entry', () {
    final ps2 = Ps2();
    ps2.setRom(_elf(payload: [0x05, 0x00, 0x01, 0x24])); // addiu r1, r0, 5
    final result = ps2.exec(true);
    expect(result.stopped, isFalse);
    expect(ps2.cpu.reg(1), 5);
    expect(ps2.cpu.pc, 0x100004);
  });
}
