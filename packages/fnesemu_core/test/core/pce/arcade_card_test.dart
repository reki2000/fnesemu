import 'dart:typed_data';

import 'package:fnesemu_core/src/core/pce/component/arcade_card.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

const _io = 0xff << 13;
int _bank(int bank, [int offset = 0]) => (bank << 13) | offset;

void main() {
  group('Arcade Card registers', () {
    late ArcadeCard card;

    void setBase(int port, int value) {
      final addr = 0x1a00 + port * 0x10;
      card.write(addr + 2, value);
      card.write(addr + 3, value >> 8);
      card.write(addr + 4, value >> 16);
    }

    setUp(() => card = ArcadeCard());

    test('reports its identifier and leaves unimplemented registers open', () {
      expect(card.read(0x1aff), 0x51);
      expect(card.read(0x1afe), 0x10);
      expect(card.read(0x1aec), 0);
      expect(card.read(0x1aed), 0);
      expect(card.read(0x1a8f), 0xff);
    });

    test('four independent ports share a 2 MiB RAM array', () {
      setBase(0, 0x12345);
      setBase(1, 0x12345);
      setBase(2, 0x12346);
      card.write(0x1a00, 0x9a);
      card.write(0x1a21, 0xb7);
      expect(card.read(0x1a11), 0x9a);
      expect(card.read(0x1a00), 0x9a);
      expect(card.read(0x1a20), 0xb7);
      expect(card.read(0x1a31), 0);
    });

    test('ports mirror at 0x1a40-0x1a7f', () {
      setBase(3, 0x37);
      card.write(0x1a70, 0x83);
      expect(card.read(0x1a30), 0x83);
      expect(card.read(0x1a70), 0x83);
      card.write(0x1a43, 0x04);
      expect(card.read(0x1a03), 4);
    });

    test('RAM address wraps independently of the 24-bit base', () {
      setBase(0, 0x1fffff);
      card.write(0x1a07, 1);
      card.write(0x1a09, 0x11); // data accesses increment the base
      card.writeData(0, 0x12);
      card.writeData(0, 0x34);
      expect(card.read(0x1a04), 0x20); // base advanced to 0x200001
      setBase(0, 0x1fffff);
      card.write(0x1a09, 0);
      expect(card.readData(0), 0x12);
      setBase(0, 0x200000);
      expect(card.readData(0), 0x34);
    });

    test('offset is applied only when enabled, with optional sign extension',
        () {
      setBase(0, 0x100);
      card.write(0x1a05, 0xfe);
      card.write(0x1a06, 0xff);
      card.write(0x1a09, 0x0a); // base + signed offset
      card.writeData(0, 0x77);
      card.write(0x1a09, 0x02); // base + unsigned offset
      card.writeData(0, 0x88);
      expect(card.readData(0), 0x88);
      card.write(0x1a09, 0x0a);
      expect(card.readData(0), 0x77);
      card.write(0x1a09, 0);
      expect(card.readData(0), 0);
    });

    test('data accesses increment offset or base as configured', () {
      setBase(0, 0x100);
      card.write(0x1a05, 1);
      card.write(0x1a07, 3);
      card.write(0x1a09, 0x03); // base + offset, increment offset
      card.writeData(0, 0x11); // 0x101
      card.writeData(0, 0x22); // 0x104
      expect(card.read(0x1a05), 7);
      expect(card.read(0x1a02), 0);
      card.write(0x1a09, 0x02);
      card.write(0x1a05, 1);
      expect(card.readData(0), 0x11);
      card.write(0x1a05, 4);
      expect(card.readData(0), 0x22);

      card.write(0x1a07, 0xff);
      card.write(0x1a08, 0xff);
      card.write(0x1a09, 0x15); // signed -1 increment of base
      card.readData(0);
      expect(card.read(0x1a02), 0xff);
      expect(card.read(0x1a03), 0);
      card.write(0x1a09, 0x11); // unsigned 0xffff
      card.readData(0);
      expect(card.read(0x1a02), 0xfe);
      expect(card.read(0x1a03), 0x00);
      expect(card.read(0x1a04), 0x01);
    });

    test('offset can be added to base on selected register writes', () {
      setBase(0, 0x100);
      card.write(0x1a09, 0x20);
      card.write(0x1a05, 0x10);
      expect(card.read(0x1a02), 0x10);
      expect(card.read(0x1a03), 1);
      card.write(0x1a09, 0x40);
      card.write(0x1a06, 1); // add 0x110 to 0x110
      expect(card.read(0x1a02), 0x20);
      expect(card.read(0x1a03), 2);
      card.write(0x1a09, 0x60);
      card.write(0x1a0a, 0); // add 0x110 to 0x220
      expect(card.read(0x1a02), 0x30);
      expect(card.read(0x1a03), 3);
    });

    test('32-bit shift and rotate support both directions', () {
      for (var i = 0; i < 4; i++) {
        card.write(0x1ae0 + i, [0x12, 0x34, 0x56, 0x78][i]);
      }
      int data() => List.generate(4, (i) => card.read(0x1ae0 + i))
          .reversed
          .fold<int>(0, (value, byte) => (value << 8) | byte);
      expect(data(), 0x78563412);
      card.write(0x1ae4, 0xf1);
      expect(card.read(0x1ae4), 0xf1);
      expect(data(), 0xf0ac6824);
      card.write(0x1ae4, 0x0f); // -1: shift right one
      expect(data(), 0x78563412);
      card.write(0x1ae5, 2);
      expect(data(), 0xe158d049);
      card.write(0x1ae5, 0x0e); // -2: rotate right two
      expect(data(), 0x78563412);
      expect(card.read(0x1ae5), 0x0e);
    });

    test('soft reset resets registers without erasing RAM', () {
      setBase(0, 0x1234);
      card.writeData(0, 0x67);
      card.write(0x1a07, 1);
      card.write(0x1a09, 0x11);
      card.reset();
      expect(card.read(0x1a02), 0);
      expect(card.read(0x1a07), 0);
      expect(card.read(0x1a09), 0);
      setBase(0, 0x1234);
      expect(card.readData(0), 0x67);
      card.powerOn();
      setBase(0, 0x1234);
      expect(card.readData(0), 0);
    });
  });

  group('PCE bus integration', () {
    late Pce pce;

    setUp(() => pce = Pce());

    void mountDisc() {
      pce.setCdromDrive(FakeCdromDrive([Uint8List(2352)]));
    }

    test('the expansion is absent for cartridge-only sessions', () {
      expect(pce.bus.read(_io + 0x1aff), 0xff);
      expect(pce.bus.read(_bank(0x40)), 0xff);
      pce.bus.write(_bank(0x40), 0x45);
      mountDisc();
      expect(pce.bus.read(_io + 0x1aff), 0x51);
      expect(pce.bus.read(_bank(0x40)), 0);
      pce.bus.cdrom.enabled = false; // drive not ready; card stays inserted
      expect(pce.bus.read(_io + 0x1aff), 0x51);
    });

    test('banks 0x40-0x43 are mirrored data ports across each 8 KiB bank', () {
      mountDisc();
      for (var port = 0; port < 4; port++) {
        final reg = _io + 0x1a00 + port * 0x10;
        pce.bus.write(reg + 2, port + 1);
        pce.bus.write(_bank(0x40 + port, 0x1fff), 0x40 + port);
      }
      for (var port = 0; port < 4; port++) {
        final reg = _io + 0x1a00 + port * 0x10;
        expect(pce.bus.read(reg), 0x40 + port);
        expect(pce.bus.read(_bank(0x40 + port, 0x07fe)), 0x40 + port);
      }
    });

    test('the dedicated I/O range does not disturb the CD interface', () {
      mountDisc();
      expect(pce.bus.read(_io + 0x1800), 0);
      expect(pce.bus.read(_io + 0x18c1), 0xaa);
      expect(pce.bus.read(_io + 0x1aff), 0x51);
      pce.bus.write(_io + 0x1a02, 0x36);
      pce.bus.write(_io + 0x1a00, 0x5e);
      expect(pce.bus.read(_bank(0x40)), 0x5e);
      expect(pce.bus.read(_io + 0x18c1), 0xaa);
    });
  });
}
