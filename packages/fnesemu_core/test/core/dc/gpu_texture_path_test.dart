import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const mode0 = 0xa05f6884, mode1 = 0xa05f6888;
  late DcBus bus;
  setUp(() {
    bus = DcBus();
    bus.write32(0xa05f8008, 0);
  });
  void send(int address, {int first = 0x11223344}) {
    for (var i = 0; i < 32; i += 4) {
      bus.write32(0xe0000000 + (address & 32) + i, first + i);
    }
    bus.write32(
        (address & 32) == 0 ? 0xff000038 : 0xff00003c, (address >> 24) & 0x1c);
    bus.transferStoreQueue(0xe0000000 | (address & 0x03ffffff));
  }

  test('default direct path interleaves longwords across the two VRAM banks',
      () {
    send(0x11000000);
    expect(bus.read32(0xa4000000), 0x11223344);
    expect(bus.read32(0xa4000004), 0x11223348);
    expect(bus.read32(0xa5000000), 0x11223344);
    expect(bus.read32(0xa5400000), 0x11223348);
    expect(bus.read32(0xa5000004), 0x1122334c);
    expect(bus.read32(0xa05f6880), 8);
    expect(bus.systemBus.normalStatus, 0);
  });





  test(
      'FIFO reads, partial bursts and reset-held writes fail without VRAM changes',
      () {
    for (final operation in [
      () => bus.read32(0xb1000000),
      () => bus.read32(0xb3000000),
      () => bus.write32(0xb1000000, 1),
      () => bus.write16(0xb1000000, 1),
      () => bus.gpu.writeTexture(0x11000004, Uint8List(32)),
    ]) {
      expect(operation, throwsA(isA<DcUnsupported>()));
    }
    bus.write32(0xa05f8008, 4);
    expect(() => send(0x11000000), throwsA(isA<DcUnsupported>()));
    expect(bus.gpu.vram.getUint32LE(0), 0);
    expect(bus.systemBus.normalStatus, 0);
    bus.write32(0xa05f8008, 0);
    send(0x11000000);
    expect(bus.read32(0xa4000000), 0x11223344);
  });

  test(
      'engine soft resets retain board mode settings while full reset restores defaults',
      () {
    bus.write32(mode0, 1);
    bus.write32(mode1, 1);
    bus.write32(0xa05f8008, 3);
    expect(bus.read32(mode0), 1);
    expect(bus.read32(mode1), 1);
    bus.gpu.reset();
    expect(bus.read32(mode0), 0);
    expect(bus.read32(mode1), 0);
  });
}
