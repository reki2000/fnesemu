import 'dart:typed_data';

import 'package:fnesemu_core/src/core/pce/component/bus.dart';
import 'package:fnesemu_core/src/core/pce/mapper/rom.dart';
import 'package:test/test.dart';

void main() {
  test('writes to CD RAM do not change work RAM', () {
    final bus = Bus();
    bus.write(0xf8 << 13, 0x12);
    bus.write(0x80 << 13, 0x34);
    expect(bus.read(0xf8 << 13), 0x12);
    expect(bus.read(0x80 << 13), 0x34);
  });

  test('all SGX RAM banks retain distinct values at the same offset', () {
    final bus = Bus()..vpc.enabled = true;
    final banks = [
      0xf8,
      0xf9,
      0xfa,
      0xfb,
      ...List.generate(8, (i) => 0x80 + i),
    ];
    for (var i = 0; i < banks.length; i++) {
      bus.write((banks[i] << 13) | 0x1fff, i + 1);
    }
    for (var i = 0; i < banks.length; i++) {
      expect(bus.read((banks[i] << 13) | 0x1fff), i + 1);
    }
  });

  test('the cartridge RAM at banks 0x40-0x43 keeps what is written', () {
    List<Uint8List> banks() => List.generate(0x40, (_) => Uint8List(0x2000));
    final bus = Bus()..rom = Rom(banks(), cartridgeRam: true);
    for (var bank = 0x40; bank <= 0x43; bank++) {
      bus.write((bank << 13) | 0x123, bank);
    }
    for (var bank = 0x40; bank <= 0x43; bank++) {
      expect(bus.read((bank << 13) | 0x123), bank);
    }

    // without the RAM, the banks after a 512kB ROM read as open bus
    final plain = Bus()..rom = Rom(banks());
    plain.write((0x40 << 13) | 0x123, 0x55);
    expect(plain.read((0x40 << 13) | 0x123), 0xff);
  });
}
