import 'dart:typed_data';

import 'package:fnesemu/core/gba/backup.dart';
import 'package:fnesemu/core/gba/bus.dart';
import 'package:fnesemu/core/sram.dart';
import 'package:test/test.dart';

Uint8List romWith(String tag) {
  final rom = Uint8List(0x200);
  final bytes = tag.codeUnits;
  rom.setRange(0x100, 0x100 + bytes.length, bytes);
  return rom;
}

void main() {
  group('Backup.detect', () {
    test('recognises each identifier', () {
      expect(Backup.detect(romWith("SRAM_V123")), BackupType.sram);
      expect(Backup.detect(romWith("FLASH_V100")), BackupType.flash512);
      expect(Backup.detect(romWith("FLASH512_V")), BackupType.flash512);
      expect(Backup.detect(romWith("FLASH1M_V1")), BackupType.flash1m);
      expect(Backup.detect(romWith("EEPROM_V12")), BackupType.eeprom);
      expect(Backup.detect(romWith("nothing")), BackupType.none);
    });
  });

  group('SRAM', () {
    test('reads back bytes through the bus', () {
      final bus = Bus();
      bus.cart.backup.init(BackupType.sram, Sram(), "T");
      bus.write8(0x0e000010, 0xab);
      expect(bus.read8(0x0e000010), 0xab);
    });
  });

  group('Flash', () {
    Bus makeFlash() {
      final bus = Bus();
      bus.cart.backup.init(BackupType.flash512, Sram(), "T");
      return bus;
    }

    void cmd(Bus bus, int value) {
      bus.write8(0x0e005555, 0xaa);
      bus.write8(0x0e002aaa, 0x55);
      bus.write8(0x0e005555, value);
    }

    test('chip id read after entering id mode', () {
      final bus = makeFlash();
      cmd(bus, 0x90); // enter id
      expect(bus.read8(0x0e000000), 0x32); // Panasonic 64K manufacturer
      expect(bus.read8(0x0e000001), 0x1b);
      cmd(bus, 0xf0); // exit
      expect(bus.read8(0x0e000000), 0xff); // erased flash
    });

    test('program a byte then read it back', () {
      final bus = makeFlash();
      cmd(bus, 0xa0); // program
      bus.write8(0x0e000100, 0x42);
      expect(bus.read8(0x0e000100), 0x42);
    });

    test('chip erase resets to 0xff', () {
      final bus = makeFlash();
      cmd(bus, 0xa0);
      bus.write8(0x0e000100, 0x00);
      expect(bus.read8(0x0e000100), 0x00);
      cmd(bus, 0x80); // erase setup
      cmd(bus, 0x10); // chip erase
      expect(bus.read8(0x0e000100), 0xff);
    });
  });

  group('EEPROM', () {
    test('write then read 8 bytes round-trips', () {
      final bus = Bus();
      bus.cart.backup.init(BackupType.eeprom, Sram(), "T");
      final backup = bus.cart.backup;

      final data = [0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0];
      const addr = 5;

      // write command: '10' + 6 addr bits + 64 data bits + stop = 73 bits.
      final wr = <int>[1, 0];
      for (int i = 5; i >= 0; i--) {
        wr.add((addr >> i) & 1);
      }
      for (final b in data) {
        for (int i = 7; i >= 0; i--) {
          wr.add((b >> i) & 1);
        }
      }
      wr.add(0);
      expect(wr.length, 73);

      backup.eepromBeginCommand(73);
      for (final b in wr) {
        bus.write16(0x0d000000, b);
      }

      // read request: '11' + 6 addr bits + stop = 9 bits.
      final rd = <int>[1, 1];
      for (int i = 5; i >= 0; i--) {
        rd.add((addr >> i) & 1);
      }
      rd.add(0);
      expect(rd.length, 9);

      backup.eepromBeginCommand(9);
      for (final b in rd) {
        bus.write16(0x0d000000, b);
      }

      // read 68 bits: 4 dummy + 64 data.
      final outBits = <int>[];
      for (int i = 0; i < 68; i++) {
        outBits.add(bus.read16(0x0d000000) & 1);
      }
      final readBack = <int>[];
      for (int byte = 0; byte < 8; byte++) {
        int v = 0;
        for (int b = 0; b < 8; b++) {
          v = (v << 1) | outBits[4 + byte * 8 + b];
        }
        readBack.add(v);
      }

      expect(readBack, data);
    });
  });
}
