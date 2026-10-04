import 'dart:typed_data';

import 'package:fnesemu/core/md/32x/sh2/sh2.dart';
import 'package:test/test.dart';

class MemoryBus implements Sh2Bus {
  final ram = Uint8List(0x10000);
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
  test('immediates sign extend and 32-bit arithmetic wraps', () {
    bus.code([0xe1ff, 0x7101, 0xe280, 0x612e]);
    run(1);
    expect(cpu.r[1], 0xffffffff);
    run(1);
    expect(cpu.r[1], 0);
    run(2);
    expect(cpu.r[1], 0xffffff80);
  });
  test('ADD/SUB carry and signed overflow have distinct flags', () {
    cpu.r[1] = 0xffffffff;
    cpu.r[2] = 1;
    bus.code([0x312e, 0x312a, 0x312f, 0x312b]);
    run(1);
    expect(cpu.r[1], 0);
    expect(cpu.t, isTrue);
    run(1);
    expect(cpu.r[1], 0xfffffffe);
    expect(cpu.t, isTrue);
    cpu.r[1] = 0x7fffffff;
    run(1);
    expect(cpu.r[1], 0x80000000);
    expect(cpu.t, isTrue);
    run(1);
    expect(cpu.r[1], 0x7fffffff);
    expect(cpu.t, isTrue);
  });
  test('DIV0U and repeated DIV1 produce an unsigned 16-bit quotient', () {
    bus.code([0x0019, ...List.filled(16, 0x3104), 0x4124, 0x611d]);
    for (final (dividend, divisor) in [
      (100, 7),
      (65535, 255),
      (12345, 37),
      (0, 1),
    ]) {
      cpu.reset();
      cpu.r[0] = divisor << 16;
      cpu.r[1] = dividend;
      run(19);
      expect(cpu.r[1], dividend ~/ divisor,
          reason: '$dividend divided by $divisor');
    }
  });
  test('DIV1 uses Q and M for both add and subtract steps', () {
    bus.code([0x3104]);
    for (final (status, dividend, divisor, remainder, flags) in [
      (0x000, 8, 20, 0xfffffffc, 0x100),
      (0x201, 0x80000000, 5, 6, 0x200),
      (0x100, 0x80000000, 5, 5, 0x100),
      (0x300, 8, 4, 12, 0x301),
    ]) {
      cpu.reset();
      cpu.sr = status;
      cpu.r[0] = divisor;
      cpu.r[1] = dividend;
      run(1);
      expect(cpu.r[1], remainder);
      expect(cpu.sr & 0x301, flags);
    }
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
  test('MAC.L reads consecutive longwords when both operands use one register',
      () {
    bus.code([0x011f]);
    cpu.r[1] = 0x200;
    bus.write32(0x200, 6);
    bus.write32(0x204, 7);
    run(1);
    expect(cpu.r[1], 0x208);
    expect(cpu.macl, 42);
  });
  test('MAC.L saturates at signed 48-bit bounds when S is set', () {
    bus.code([0x012f]);
    cpu.sr = 2;
    cpu.r[1] = 0x200;
    cpu.r[2] = 0x300;
    cpu.mach = 0x7fff;
    cpu.macl = 0xffffffff;
    bus.write32(0x200, 2);
    bus.write32(0x300, 2);
    run(1);
    expect(cpu.mach, 0x7fff);
    expect(cpu.macl, 0xffffffff);
  });
  test('MAC.W accumulates signed words and advances both source registers', () {
    bus.code([0x412f, 0x412f]);
    cpu.r[1] = 0x200;
    cpu.r[2] = 0x300;
    bus.write16(0x200, 0xffff);
    bus.write16(0x202, 0x8000);
    bus.write16(0x300, 3);
    bus.write16(0x302, 2);
    run(2);
    expect(cpu.r[1], 0x204);
    expect(cpu.r[2], 0x304);
    expect(cpu.mach, 0xffffffff);
    expect(cpu.macl, 0xfffefffd);
  });
  test('MAC.W reads consecutive words for one register and saturates MACL', () {
    bus.code([0x411f]);
    cpu.r[1] = 0x200;
    cpu.sr = 2;
    cpu.macl = 0x7fffffff;
    bus.write16(0x200, 6);
    bus.write16(0x202, 7);
    run(1);
    expect(cpu.r[1], 0x204);
    expect(cpu.macl, 0x7fffffff);
  });
  test('loads sign extend and postincrement does not clobber same register',
      () {
    cpu.r[2] = 0x200;
    bus.write8(0x200, 0xff);
    bus.write16(0x202, 0x8000);
    bus.code([0x6124, 0x6205]); // first MOV.B @R2+,R1
    run(1);
    expect(cpu.r[1], 0xffffffff);
    expect(cpu.r[2], 0x201);
    cpu.r[2] = 0x202;
    bus.code([0x6225], address: cpu.pc);
    run(1);
    expect(cpu.r[2], 0xffff8000);
  });
  test('predecrement uses the source value before modifying the destination',
      () {
    cpu.r[1] = 0x204;
    bus.code([0x2116]);
    run(1);
    expect(cpu.r[1], 0x200);
    expect(bus.read32(0x200), 0x204);
  });
  test('literal word and long loads use the instruction PC', () {
    bus.code([0x9102, 0xd202, 9, 9, 0x8000, 9]);
    bus.write32(0x10c, 0x12345678);
    run(2);
    expect(cpu.r[1], 0xffff8000);
    expect(cpu.r[2], 0x12345678);
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
  test('BSR and RTS preserve return address and both delay slots', () {
    bus.code([0xb002, 0xe101, 0xe202, 9, 0x000b, 0xe303]);
    run(1);
    expect(cpu.pr, 0x104);
    run(2);
    expect(cpu.pc, 0x10a);
    run(1);
    expect(cpu.pc, 0x104);
    expect(cpu.r[3], 3);
    run(1);
    expect(cpu.r[2], 2);
  });
  test('a branch in the delay slot stops at the offending instruction', () {
    bus.code([0xa002, 0xa000]);
    run(1);
    expect(cpu.exec(), isFalse);
    expect(cpu.pc, 0x102);
  });
  test('BT and BF select branches using the T bit', () {
    bus.code([0x0018, 0x8900, 0xe101, 0xe102, 0x0008, 0x8b00, 0xe201, 0xe202]);
    run(3);
    expect(cpu.r[1], 2);
    run(3);
    expect(cpu.r[2], 2);
  });
  test('IRQ stacks PC then SR and RTE restores state after its delay slot', () {
    bus.write32((64 + 6) * 4, 0x200);
    bus.code([0x002b, 0xe101], address: 0x200);
    cpu.sr = 1;
    cpu.setInterrupt(12, 70);
    run(1);
    expect(cpu.pc, 0x200);
    expect(cpu.interruptMask, 12);
    expect(bus.read32(0xfef8), 0x100);
    expect(bus.read32(0xfefc), 1);
    cpu.setInterrupt(0, 0);
    run(1);
    expect(cpu.sr, 0xc1);
    run(1);
    expect(cpu.pc, 0x100);
    expect(cpu.sr, 1);
    expect(cpu.r[15], 0xff00);
  });
  test('IRQ waits until a branch delay slot has completed', () {
    bus.code([0xa002, 0xe107]);
    cpu.sr = 0;
    bus.write32(70 * 4, 0x200);
    run(1);
    cpu.setInterrupt(12, 70);
    run(1);
    expect(cpu.r[1], 7);
    expect(cpu.pc, 0x108);
    run(1);
    expect(cpu.pc, 0x200);
    expect(bus.read32(cpu.r[15]), 0x108);
  });
  test('sleep wakes only for an interrupt above the mask', () {
    bus.code([0x001b]);
    bus.write32(70 * 4, 0x200);
    run(1);
    run(1);
    expect(cpu.pc, 0x102);
    cpu.setInterrupt(12, 70);
    run(1);
    expect(cpu.sleeping, isTrue);
    cpu.sr = 0;
    run(1);
    expect(cpu.sleeping, isFalse);
    expect(cpu.pc, 0x200);
  });
  test('TRAPA stacks the next instruction and fetches the vector', () {
    bus.code([0xc320]);
    bus.write32(32 * 4, 0x200);
    run(1);
    expect(cpu.pc, 0x200);
    expect(bus.read32(cpu.r[15]), 0x102);
  });
  test('unknown opcodes stop without advancing or corrupting registers', () {
    bus.code([0xffff]);
    cpu.r[1] = 0x1234;
    expect(cpu.exec(), isFalse);
    expect(cpu.pc, 0x100);
    expect(cpu.r[1], 0x1234);
  });
}
