import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/cache.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const ccr = 0xff00001c, address = 0x8c000100, raw = 0xac000100;
  const tag = 0xf4000100, data = 0xf5000100, code = 0xac010000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000001;
    cpu.pc = code;
    cpu.vbr = 0x8c020000;
    for (var i = 0; i < 8; i++) {
      bus.write32(raw + i * 4, 0x11220000 + i);
    }
  });

  test('operand read allocates a line and uncached writes do not snoop it', () {
    bus.write32(ccr, 5);
    expect(bus.read32(address + 12), 0x11220003);
    expect(bus.read32(tag), 0x0c000001);
    for (var i = 0; i < 8; i++) {
      expect(bus.read32(data + i * 4), 0x11220000 + i);
    }
    bus.write32(raw, 42);
    expect(bus.read32(address), 0x11220000);
    expect(bus.read32(raw), 42);
  });

  test('copy-back byte/word/quadword stores allocate and retain external bytes',
      () {
    bus.write32(ccr, 5);
    bus.write8(address, 0x78);
    bus.write16(address + 2, 0x3456);
    bus.writePair(address + 8, 0x89abcdef, 0x01234567);
    expect(bus.read32(address), 0x34560078);
    expect(bus.readPair(address + 8), (0x89abcdef, 0x01234567));
    expect(bus.read32(tag) & 3, 3);
    expect(bus.read32(raw), 0x11220000);
    expect(bus.read32(raw + 8), 0x11220002);
  });

  test('write-through misses bypass allocation and hits update cache and RAM',
      () {
    bus.write32(ccr, 1);
    bus.write32(address, 42);
    expect(bus.read32(tag) & 1, 0);
    expect(bus.read32(raw), 42);
    expect(bus.read32(address), 42);
    bus.write32(address, 43);
    expect(bus.read32(raw), 43);
    expect(bus.read32(data), 43);
    expect(bus.read32(tag) & 3, 1);
    bus.write32(raw, 44);
    expect(bus.read32(address), 43);
  });

  test('P0 write policy uses WT independently of the P1 CB bit', () {
    bus.write32(ccr, 1);
    bus.write32(0x0c000100, 42);
    expect(bus.read32(raw), 0x11220000);
    expect(bus.read32(tag) & 3, 3);
    bus.write32(ccr, 0x0b); // Invalidate and select P0 write-through.
    bus.write32(0x0c000100, 43);
    expect(bus.read32(raw), 43);
    expect(bus.read32(tag) & 1, 0);
  });

  test(
      'a conflicting read writes back all dirty bytes before replacing the line',
      () {
    bus.write32(ccr, 5);
    bus.write32(address + 28, 0xfeedface);
    bus.write32(raw + 0x4000, 99);
    expect(bus.read32(address + 0x4000), 99);
    expect(bus.read32(raw + 28), 0xfeedface);
    expect(bus.read32(tag), 0x0c004001);
  });

  for (final (opcode, writesBack, invalidates) in [
    (0x0193, false, true),
    (0x01a3, true, true),
    (0x01b3, true, false),
  ]) {
    test('cache instruction ${opcode.toRadixString(16)} has documented effects',
        () {
      bus.write32(ccr, 5);
      bus.write32(address, 42);
      bus.write16(code, opcode);
      cpu.r[1] = address + 3; // Cache operations ignore the byte position.
      cpu.step();
      expect(cpu.pc, code + 2);
      expect(cpu.t, isTrue);
      expect(bus.read32(raw), writesBack ? 42 : 0x11220000);
      expect(bus.read32(tag) & 1, invalidates ? 0 : 1);
      if (writesBack) expect(bus.read32(tag) & 2, 0);
    });
  }

  test(
      'instruction cache stays stale until ICI and is separate from operand data',
      () {
    final cachedCode = code - 0x20000000;
    bus.write16(code, 0xe901);
    bus.write32(ccr, 0x105);
    cpu.pc = cachedCode;
    cpu.step();
    expect(cpu.r[9], 1);
    bus.write16(code, 0xe902);
    expect(bus.read16(cachedCode), 0xe902);
    cpu.pc = cachedCode;
    cpu.step();
    expect(cpu.r[9], 1);
    bus.write32(ccr, 0x905);
    expect(bus.read32(ccr), 0x105);
    cpu.pc = cachedCode;
    cpu.step();
    expect(cpu.r[9], 2);
  });

  test(
      'cache arrays mirror their storage and associative invalidation compares tags',
      () {
    bus.write32(ccr, 5);
    bus.write32(address, 42);
    expect(bus.read32(tag + 0x8000), bus.read32(tag));
    bus.write32(tag + 8, 0x0d000000); // Mismatched tag.
    expect(bus.read32(tag) & 3, 3);
    bus.write32(tag + 8, 0x8c000001); // Clear dirty while retaining validity.
    expect(bus.read32(raw), 42);
    expect(bus.read32(tag), 0x0c000001);
    bus.write32(data + 0x4000, 43);
    expect(bus.read32(address), 43);
    expect(bus.read32(tag) & 2, 0); // Data-array writes do not mark dirty.
    bus.write32(0xf0000000, 0xffffffff);
    expect(bus.read32(0xf0000000), 0x1ffffc01);
    bus.write32(0xf1000000, 0xe90a0009);
    expect(bus.read32(0xf1002000), 0xe90a0009);
    expect(() => bus.read16(data), throwsA(isA<DcUnsupported>()));
    expect(() => bus.readPair(data), throwsA(isA<DcUnsupported>()));
  });

  test(
      'RAM mode maps two 4 KiB banks into the operand array without external writes',
      () {
    bus.write32(ccr, 0x25);
    bus.write32(0x7c001000, 42);
    bus.writePair(0x7c002000, 43, 44);
    expect(bus.read32(0x7c000000), 42);
    expect(bus.read32(0x7fff0000), 42);
    expect(bus.readPair(0x7c003000), (43, 44));
    expect(bus.read32(0xf5001000), 42);
    expect(bus.read32(0xf5003000), 43);
    bus.write32(address + 0x1000, 45);
    expect(bus.read32(0x7c001000), 42); // Cache allocations skip RAM entries.
    expect(bus.read32(0xf4001100) & 1, 0);
    expect(bus.read32(0xf4000100) & 1, 1);
    expect(() => bus.fetch16(0x7c000000), throwsA(isA<DcUnsupported>()));
  });

  test('OC and IC index modes use effective address bit 25 to select halves',
      () {
    bus.write32(ccr, 0x8185);
    bus.write32(0x8c000000, 42);
    bus.write32(0x8e000000, 43);
    expect(bus.read32(0xf4000000), 0x0c000003);
    expect(bus.read32(0xf4002000), 0x0e000003);
    expect(bus.read32(0x8c000000), 42);
    expect(bus.read32(0x8e000000), 43);
    bus.fetch16(0x8c000000);
    bus.fetch16(0x8e000000);
    expect(bus.read32(0xf0000000), 0x0c000001);
    expect(bus.read32(0xf0001000), 0x0e000001);
    bus.write32(ccr, 0xa1);
    bus.write32(0x7c000000, 44);
    bus.write32(0x7e000000, 45);
    expect(bus.read32(0x7dfff000), 44);
    expect(bus.read32(0x7ffff000), 45);
  });

  test(
      'manual reset retains cache validity and dirty data; power reset invalidates',
      () {
    bus.write32(ccr, 5);
    bus.write32(address, 42);
    cpu.reset(manual: true);
    expect(bus.read32(ccr), 0);
    expect(bus.read32(tag) & 3, 3);
    expect(bus.read32(address), 0x11220000);
    bus.write32(ccr, 5);
    expect(bus.read32(address), 42);
    cpu.reset();
    expect(bus.read32(tag) & 3, 0);
  });

  test('MOVCA allocation skips the incoming block read', () {
    var reads = 0;
    final memory = Uint8List(256);
    final cache = DcCache((address, size, write) {
      if (!write) reads++;
      return (memory, address & 255);
    })
      ..ccr = 5;
    cache.write(0x80000000, Uint8List.fromList([42, 0, 0, 0]), allocate: true);
    expect(reads, 0);
    cache.operate(0x80000000, 1);
    expect(memory[0], 42);
    bus.write32(ccr, 5);
    bus.write16(code, 0x01c3);
    cpu.r[0] = 42;
    cpu.r[1] = address;
    cpu.step();
    expect(bus.read32(address), 42);
    expect(bus.read32(raw), 0x11220000);
  });

  test('ordinary PREF fills an operand line without changing registers or T',
      () {
    bus.write32(ccr, 5);
    bus.write16(code, 0x0183);
    cpu.r[1] = address + 3;
    cpu.step();
    expect(bus.read32(tag) & 1, 1);
    expect(cpu.t, isTrue);
    expect(cpu.r[1], address + 3);
    bus.write32(raw, 42);
    expect(bus.read32(address), 0x11220000);
  });

  test('failed write-back preserves the old line and development-stop PC', () {
    bus.write32(data, 42);
    bus.write32(tag, 3); // Dirty line pointing at read-only boot ROM.
    bus.write32(ccr, 5);
    bus.write16(code, 0x01b3);
    cpu.r[1] = 0x80000100;
    expect(() => cpu.step(), throwsA(isA<DcUnsupported>()));
    expect(cpu.pc, code);
    expect(bus.read32(tag), 3);
    expect(bus.read32(data), 42);
    expect(bus.bios[0x100], 0);
  });

  test('user-mode data accesses can use operand RAM without exposing area 7',
      () {
    bus.write32(ccr, 0x25);
    bus.write16(code, 0x2122);
    bus.write16(code + 2, 0x6312);
    cpu.pc = code & 0x1fffffff;
    cpu.sr = 0;
    cpu.r[1] = 0x7c001000;
    cpu.r[2] = 42;
    cpu.step();
    cpu.step();
    expect(cpu.r[3], 42);
    expect(bus.read32(0xf5001000), 42);
    expect(bus.expevt, 0);
  });

  test('user PREF suppresses protected-address errors without allocating', () {
    bus.write32(ccr, 5);
    bus.write16(code, 0x0183);
    cpu.pc = code & 0x1fffffff;
    cpu.sr = 0;
    cpu.r[1] = address;
    cpu.step();
    expect(bus.read32(tag) & 1, 0);
    expect(bus.expevt, 0);
  });

  test('cache maintenance checks write access even when the cache is disabled',
      () {
    bus.write16(code, 0x0193);
    cpu.pc = code & 0x1fffffff;
    cpu.sr = 0;
    cpu.r[1] = address;
    cpu.step();
    expect(bus.expevt, 0x100);
    expect(bus.tea, address);
  });

  test('CCR invalidation discards dirty data and command bits self-clear', () {
    bus.write32(ccr, 5);
    bus.write32(address, 42);
    bus.write32(ccr, 0xffffffff);
    expect(bus.read32(ccr), 0x81a7);
    expect(bus.read32(tag) & 3, 0);
    expect(bus.read32(raw), 0x11220000);
    expect(() => bus.read16(ccr), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write8(ccr, 1), throwsA(isA<DcUnsupported>()));
  });
}
