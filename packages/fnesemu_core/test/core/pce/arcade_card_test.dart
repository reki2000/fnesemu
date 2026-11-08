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

  });

  group('PCE bus integration', () {
    late Pce pce;

    setUp(() => pce = Pce());

    void mountDisc() {
      pce.setCdromDrive(FakeCdromDrive([Uint8List(2352)]));
    }

  });
}
