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

  test('settings blocks take the clock date and keep a valid CRC', () {
    // CRC-16 with polynomial 0x1021, initial 0xffff and inverted output;
    // its standard check value for "123456789" is 0xd64e.
    int crc(List<int> bytes) {
      var value = 0xffff;
      for (final byte in bytes) {
        value ^= byte << 8;
        for (var bit = 0; bit < 8; bit++) {
          value = (value & 0x8000 != 0 ? (value << 1) ^ 0x1021 : value << 1) &
              0xffff;
        }
      }
      return value ^ 0xffff;
    }

    expect(crc('123456789'.codeUnits), 0xd64e);
    final image = Uint8List(DcFlash.size)..fillRange(0, DcFlash.size, 255);
    void block(int index, List<int> data, {bool valid = true}) {
      final at = DcFlash.settingsStart + index * 64;
      image.setAll(at, data);
      final value = crc(image.sublist(at, at + 62)) ^ (valid ? 0 : 1);
      image[at + 62] = value & 255;
      image[at + 63] = value >> 8;
    }

    block(1, [5, 0, 1, 2, 3, 4, 9, 9]);
    block(2, [5, 0, 1, 2, 3, 4, 8, 8], valid: false);
    block(3, [6, 0, 1, 2, 3, 4]);
    final flash = DcFlash()..loadImage(image);
    flash.dateSettings(0x908dc467);
    final after = flash.exportImage();
    int at(int index) => DcFlash.settingsStart + index * 64;
    expect(after.sublist(at(1), at(1) + 8), [5, 0, 0x67, 0xc4, 0x8d, 0x90, 9, 9]);
    expect(after[at(1) + 62] | after[at(1) + 63] << 8,
        crc(after.sublist(at(1), at(1) + 62)));
    // Blocks with a bad CRC or another id stay as they are.
    expect(after.sublist(at(2), at(4)), image.sublist(at(2), at(4)));
  });

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
    addTearDown(core.dispose);
    core.bus.flash.loadImage(Uint8List(DcFlash.size));
    core.reset();
    expect(core.bus.read8(base), 0);
  });

  test('flash persists through Sram, program loading, resets and new instances',
      () {
    final storage = _PersistentSram();
    final first = Dc()..setSram(storage);
    addTearDown(first.dispose);
    first.bus.flash.loadImage(Uint8List(DcFlash.size));
    first.setRom(Uint8List.fromList([9, 0]));
    first.reset();
    expect(storage.id, 'dc/sram/system_flash');
    final second = Dc()..setSram(storage);
    addTearDown(second.dispose);
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






}

class _PersistentSram extends Sram {
  @override
  void init(String id, Uint8List initialData) {
    if (this.id == id && data.length == initialData.length) return;
    super.init(id, initialData);
  }
}
