import 'dart:typed_data';

import 'package:fnesemu_core/src/components/sh2/jit/jit.dart';
import 'package:fnesemu_core/src/core/md/32x/sh2/sh2.dart';
import 'package:test/test.dart';

class MemoryBus implements Sh2Bus {
  final Uint8List ram;
  MemoryBus([Uint8List? ram]) : ram = ram ?? Uint8List(0x10000);
  late final bytes = ByteData.sublistView(ram);
  @override
  int read8(int address) => ram[address & 0xffff];
  @override
  int read16(int address) => bytes.getUint16(address & 0xffff);
  @override
  int read32(int address) => bytes.getUint32(address & 0xffff);
  @override
  void write8(int address, int value) => ram[address & 0xffff] = value & 255;
  @override
  void write16(int address, int value) =>
      bytes.setUint16(address & 0xffff, value & 0xffff);
  @override
  void write32(int address, int value) =>
      bytes.setUint32(address & 0xffff, value & 0xffffffff);
  void code(List<int> words, {int address = 0x100}) {
    for (final word in words) {
      write16(address, word);
      address += 2;
    }
  }
}

void main() {
  final probe = Sh2Jit.create();
  final nativeSupported = probe != null;
  probe?.dispose();
  for (final native in [false, true]) {
  }
  late MemoryBus bus;
  late Sh2 cpu;
  setUp(() {
    bus = MemoryBus()
      ..write32(0, 0x100)
      ..write32(4, 0xff00);
    cpu = Sh2(bus)..reset();
  });
  void run(int count) {
    for (int i = 0; i < count; i++) {
      expect(cpu.exec(), isTrue);
    }
  }

  test('reset reads big-endian vectors and masks interrupts', () {
    expect(cpu.pc, 0x100);
    expect(cpu.r[15], 0xff00);
    expect(cpu.sr, 0xf0);
  });
  test('MAC.L accumulates signed products and advances both source registers',
      () {
    bus.code([0x012f, 0x012f]);
    cpu.r[1] = 0x200;
    cpu.r[2] = 0x300;
    bus.write32(0x200, 0xffffffff);
    bus.write32(0x204, 0x80000000);
    bus.write32(0x300, 3);
    bus.write32(0x304, 2);
    run(2);
    expect(cpu.r[1], 0x208);
    expect(cpu.r[2], 0x308);
    expect(cpu.mach, 0xfffffffe);
    expect(cpu.macl, 0xfffffffd);
  });
  test('BRA runs exactly one delay slot before changing PC', () {
    bus.code([0xa002, 0xe107, 0xe163, 9, 0xe209]);
    run(1);
    expect(cpu.pc, 0x102);
    run(1);
    expect(cpu.pc, 0x108);
    expect(cpu.r[1], 7);
    run(1);
    expect(cpu.r[2], 9);
  });
}
