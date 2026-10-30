import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/flash.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  const base = 0xa0200000;
  setUp(() => bus = DcBus());
  void unlock(int command) {
    bus.write8(base + 0x555, 0xaa);
    bus.write8(base + 0x2aa, 0x55);
    bus.write8(base + 0x555, command);
  }

  void program(int address, int value) {
    unlock(0xa0);
    bus.write8(base + address, value);
  }

  void erase(int address) {
    unlock(0x80);
    bus.write8(base + 0x555, 0xaa);
    bus.write8(base + 0x2aa, 0x55);
    bus.write8(base + address, 0x30);
  }

  test('erased array, direct aliases, wide reads and command access widths',
      () {
    expect(bus.read8(base), 255);
    expect(bus.read16(0x00200000), 0xffff);
    expect(bus.read32(0x80200000), 0xffffffff);
    expect(bus.read8(base + DcFlash.size - 1), 255);
    expect(() => bus.read8(base + DcFlash.size), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read8(0xc0200000), throwsA(isA<DcUnsupported>()));
    bus.write16(base, 0);
    expect(bus.read16(base), 0xffff);
    bus.write32(base, 0);
    expect(bus.read32(base), 0xffffffff);
    expect(() => bus.read16(base + 1), throwsA(isA<DcUnsupported>()));
  });

  test(
      'unlock commands ignore A11-A16 and expose top-boot manufacturer/device IDs',
      () {
    bus.write8(base + 0x15555, 0xaa);
    bus.write8(base + 0x12aaa, 0x55);
    bus.write8(base + 0x15555, 0x90);
    expect(bus.read8(base), 4);
    expect(bus.read8(base + 1), 0xb0);
    expect(bus.read8(base + 0x1a002), 1);
    bus.write8(base, 0xf0);
    expect(bus.read8(base), 255);
  });

  test('incorrect unlock order never programs the array', () {
    bus.write8(base + 0x555, 0xaa);
    bus.write8(base + 0x2ab, 0x55);
    bus.write8(base + 0x555, 0xa0);
    bus.write8(base + 123, 0);
    bus.tickMasterClocks(DcFlash.programClocks);
    expect(bus.read8(base + 123), 255);
  });

  test('byte program is delayed, polls DQ7/DQ6 and ignores debugger peeks', () {
    program(123, 0x5a);
    final first = bus.read8(base + 123);
    final peek = bus.peek8(base + 123);
    expect(peek, first);
    expect(bus.peek8(base + 123), peek);
    expect(bus.read8(base + 123) ^ first, 0x40);
    expect(first & 0x80, 0x80);
    bus.tickMasterClocks(DcFlash.programClocks - 1);
    expect(bus.flash.arrayMode, isFalse);
    bus.tickMasterClocks(1);
    expect(bus.read8(base + 123), 0x5a);
    expect(bus.read8(base + 122), 255);
  });

  test('F0 is valid program data and busy writes do not cancel programming',
      () {
    program(1, 0xf0);
    bus.write8(base, 0xf0);
    bus.tickMasterClocks(DcFlash.programClocks);
    expect(bus.read8(base + 1), 0xf0);
    expect(bus.read8(base), 255);
  });

  test('programming zero bits back to one fails until a read-reset command',
      () {
    program(1, 0x55);
    bus.tickMasterClocks(DcFlash.programClocks);
    program(1, 0xaa);
    bus.tickMasterClocks(DcFlash.programClocks);
    expect(bus.read8(base + 1) & 0x20, 0x20);
    bus.write8(base, 0xf0);
    expect(bus.read8(base + 1), 0);
  });

  for (var sector = 0; sector < 5; sector++) {
    test('sector $sector erase affects exactly its documented top-boot range',
        () {
      bus.flash.loadImage(Uint8List(DcFlash.size));
      final start = DcFlash.sectorStarts[sector];
      final end = DcFlash.sectorStarts[sector + 1];
      erase(end - 1);
      expect(bus.read8(base + start) & 8, 0);
      bus.flash.tickMasterClocks(DcFlash.selectClocks);
      expect(bus.read8(base + start) & 8, 8);
      bus.flash.tickMasterClocks(DcFlash.eraseClocks - 1);
      expect(bus.flash.arrayMode, isFalse);
      bus.flash.tickMasterClocks(1);
      expect(bus.read8(base + start), sector == 3 ? 0 : 255);
      expect(bus.read8(base + end - 1), sector == 3 ? 0 : 255);
      if (start != 0) expect(bus.read8(base + start - 1), 0);
      if (end != DcFlash.size) expect(bus.read8(base + end), 0);
    });
  }

  test(
      'sector selection adds sectors, restarts its timeout and rejects other commands',
      () {
    bus.flash.loadImage(Uint8List(DcFlash.size));
    erase(0);
    bus.flash.tickMasterClocks(DcFlash.selectClocks - 1);
    bus.write8(base + 0x18000, 0x30);
    bus.flash.tickMasterClocks(DcFlash.selectClocks - 1);
    expect(bus.read8(base) & 8, 0);
    bus.flash.tickMasterClocks(1 + DcFlash.eraseClocks);
    expect(bus.read8(base), 255);
    expect(bus.read8(base + 0x18000), 255);
    expect(bus.read8(base + 0x10000), 0);
    erase(0x10000);
    bus.write8(base, 0x90);
    expect(bus.flash.arrayMode, isTrue);
    bus.flash.tickMasterClocks(DcFlash.eraseClocks + DcFlash.selectClocks);
    expect(bus.read8(base + 0x10000), 0);
  });

  test(
      'erase suspension permits other-sector reads/programs and resumes remaining time',
      () {
    final image = Uint8List(DcFlash.size)..fillRange(0, DcFlash.size, 255);
    image[0] = 0;
    bus.flash.loadImage(image);
    erase(0);
    bus.flash.tickMasterClocks(DcFlash.selectClocks + 123);
    bus.write8(base, 0xb0);
    final first = bus.read8(base);
    expect(bus.read8(base) ^ first, 4);
    expect(first & 0xc0, 0xc0);
    expect(bus.read8(base + 0x10000), 255);
    program(0x10000, 0x55);
    bus.flash.tickMasterClocks(DcFlash.programClocks + DcFlash.eraseClocks);
    expect(bus.read8(base + 0x10000), 0x55);
    expect(bus.flash.arrayMode, isFalse);
    bus.write8(base, 0x30);
    bus.flash.tickMasterClocks(DcFlash.eraseClocks - 124);
    expect(bus.flash.arrayMode, isFalse);
    bus.flash.tickMasterClocks(1);
    expect(bus.read8(base), 255);
    expect(bus.read8(base + 0x10000), 0x55);
  });

  test('chip erase retains factory protection and ignores suspend', () {
    bus.flash.loadImage(Uint8List(DcFlash.size));
    unlock(0x80);
    bus.write8(base + 0x555, 0xaa);
    bus.write8(base + 0x2aa, 0x55);
    bus.write8(base + 0x555, 0x10);
    bus.write8(base, 0xb0);
    bus.flash.tickMasterClocks(DcFlash.eraseClocks);
    expect(bus.flash.exportImage(), [
      for (var i = 0; i < DcFlash.size; i++)
        i >= 0x1a000 && i < 0x1c000 ? 0 : 255
    ]);
  });

  test('configured sector protection suppresses erase and programming', () {
    final flash = DcFlash(protectedSectors: {3});
    flash.loadImage(Uint8List(DcFlash.size));
    void command(int command) {
      flash.write(0x555, 0xaa);
      flash.write(0x2aa, 0x55);
      flash.write(0x555, command);
    }

    command(0x90);
    expect(flash.read(0x1a002), 1);
    expect(flash.read(2), 0);
    flash.write(0, 0xf0);
    command(0x80);
    flash.write(0x555, 0xaa);
    flash.write(0x2aa, 0x55);
    flash.write(0x555, 0x10);
    flash.tickMasterClocks(DcFlash.eraseClocks);
    expect(flash.read(0), 255);
    expect(flash.read(0x1a000), 0);
    command(0xa0);
    flash.write(0x1a000, 255);
    expect(flash.arrayMode, isTrue);
    expect(flash.read(0x1a000), 0);
  });

  test(
      'CPU resets retain external flash commands but core reset power-cycles them',
      () {
    final cpu = Sh4(bus);
    unlock(0x90);
    cpu.reset(manual: true);
    expect(bus.read8(base), 4);
    cpu.reset();
    expect(bus.read8(base + 1), 0xb0);
    final core = Dc()..setRom(Uint8List.fromList([9, 0]));
    core.bus.flash.loadImage(Uint8List(DcFlash.size));
    core.reset();
    expect(core.bus.read8(base), 0);
  });

  test('flash persists through Sram, program loading, resets and new instances',
      () {
    final storage = _PersistentSram();
    final first = Dc()..setSram(storage);
    first.bus.flash.loadImage(Uint8List(DcFlash.size));
    first.setRom(Uint8List.fromList([9, 0]));
    first.reset();
    expect(storage.id, 'dc/sram/system_flash');
    final second = Dc()..setSram(storage);
    expect(second.bus.read8(base), 0);
    second.bus.write8(base + 0x555, 0xaa);
    second.bus.write8(base + 0x2aa, 0x55);
    second.bus.write8(base + 0x555, 0xa0);
    second.bus.write8(base, 0);
    second.bus.flash.tickMasterClocks(DcFlash.programClocks);
    expect(storage.read8(0), 0);
    expect(() => second.bus.flash.loadImage(Uint8List(1)), throwsArgumentError);
    expect(second.bus.read8(base), 0);
  });

  test('a guest program writes persistent flash through Core.exec', () {
    final words = [
      0xe0aa,
      0x2100,
      0xe055,
      0x2200,
      0xe0a0,
      0x2100,
      0xe05a,
      0x2300,
      0xaffe,
      9
    ];
    final program = Uint8List(words.length * 2);
    for (var i = 0; i < words.length; i++) {
      program[i * 2] = words[i] & 255;
      program[i * 2 + 1] = words[i] >> 8;
    }
    final storage = _PersistentSram();
    final core = Dc()
      ..setSram(storage)
      ..setRom(program);
    core.cpu.r[1] = base + 0x555;
    core.cpu.r[2] = base + 0x2aa;
    core.cpu.r[3] = base + 123;
    for (var i = 0; i < 1700; i++) {
      expect(core.exec(true).stopped, isFalse);
    }
    expect(core.bus.read8(base + 123), 0x5a);
    expect(storage.read8(123), 0x5a);
    final restored = Dc()..setSram(storage);
    expect(restored.bus.read8(base + 123), 0x5a);
    expect(restored.bus.read8(base + 124), 255);
  });

  test(
      'wide CPU writes become ordered byte cycles without bypassing flash commands',
      () {
    unlock(0xa0);
    bus.write16(base + 0x40, 0xa55a);
    bus.flash.tickMasterClocks(DcFlash.programClocks);
    expect(bus.read16(base + 0x40), 0xff5a);
    unlock(0xa0);
    bus.write32(base + 0x80, 0x12345678);
    bus.flash.tickMasterClocks(DcFlash.programClocks);
    expect(bus.read32(base + 0x80), 0xffffff78);
    unlock(0xa0);
    expect(() => bus.write16(base + 1, 0), throwsA(isA<DcUnsupported>()));
    bus.write8(base + 2, 0x42);
    bus.flash.tickMasterClocks(DcFlash.programClocks);
    expect(bus.read8(base + 2), 0x42);
  });

  test('cached status fill performs device reads, hits and peeks perform none',
      () {
    bus.write32(0xff00001c, 1);
    program(0x10000, 0x5a);
    final cached = bus.read8(0x80210000);
    final status = bus.peek8(base + 0x10000);
    expect(cached & 0x80, 0x80);
    expect(bus.read8(0x80210000), cached);
    expect(bus.peek8(base + 0x10000), status);
    expect(bus.peek8(0x80210000), cached);
    bus.flash.tickMasterClocks(DcFlash.programClocks);
    expect(bus.read8(base + 0x10000), 0x5a);
    expect(bus.read8(0x80210000), cached);
    bus.write32(0xff00001c, 9);
    expect(bus.read8(0x80210000), 0x5a);
  });

  test('autoselect cached fill tolerates unspecified identifier bytes', () {
    unlock(0x90);
    bus.write32(0xff00001c, 1);
    expect(bus.read8(0x80200000), 4);
    expect(bus.read8(0x80200001), 0xb0);
    expect(bus.read8(0x8021a002), 1);
  });

  test('SH4 DMA reads flash status through bus cycles without a CPU cache', () {
    program(123, 0x5a);
    bus.write32(0xffa00000, base + 123);
    bus.write32(0xffa00004, 0x8c020000);
    bus.write32(0xffa00008, 2);
    bus.write32(0xffa0000c, 0x4411);
    bus.write32(0xffa00040, 1);
    bus.tickMasterClocks(4);
    expect(bus.read8(0x8c020000) ^ bus.read8(0x8c020001), 0x40);
    expect(bus.read32(0xffa00008), 0);
  });

  test('factory sector is hardware protected by default', () {
    program(0x1a000, 0);
    bus.flash.tickMasterClocks(DcFlash.programClocks);
    expect(bus.read8(base + 0x1a000), 255);
  });
}

class _PersistentSram extends Sram {
  @override
  void init(String id, Uint8List initialData) {
    if (this.id == id && data.length == initialData.length) return;
    super.init(id, initialData);
  }
}
