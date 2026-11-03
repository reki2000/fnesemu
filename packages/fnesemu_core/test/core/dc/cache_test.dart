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







}
