import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0x0c010000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000001;
    cpu.pc = code;
    cpu.vbr = 0x0c020000;
    bus.write16(code, 0x0183); // PREF @R1.
    bus.write32(0xff000038, 0x0c);
    bus.write32(0xff00003c, 0x0c);
  });

  test('queue selection and mirrored writes preserve all eight words', () {
    for (var word = 0; word < 16; word++) {
      bus.write32(0xe3fff000 + word * 4, 0x87650000 + word);
    }
    for (final (queueAddress, destination, firstWord) in [
      (0xe0001000, 0x0c001000, 0),
      (0xe000202c, 0x0c002020, 8),
    ]) {
      cpu.r[1] = queueAddress;
      cpu.step();
      for (var i = 0; i < 8; i++) {
        expect(bus.read32(destination + i * 4), 0x87650000 + firstWord + i);
      }
      expect(cpu.t, isTrue);
      expect(cpu.r[1], queueAddress);
      cpu.pc = code;
    }
    // A transfer retains queue contents for another destination.
    cpu.r[1] = 0xe0003000;
    cpu.step();
    expect(bus.read32(0x0c003000), 0x87650000);
  });

  test('quadword stores retain SH-4 high-word-first ordering', () {
    bus.writePair(0xe0000000, 0x11223344, 0x55667788);
    bus.writePair(0xe0000020, 0xaabbccdd, 0xeeff0011);
    bus.transferStoreQueue(0xe0000100);
    bus.transferStoreQueue(0xe0000120);
    expect(bus.read32(0x0c000100), 0x11223344);
    expect(bus.read32(0x0c000104), 0x55667788);
    expect(bus.read32(0x0c000120), 0xaabbccdd);
    expect(bus.read32(0x0c000124), 0xeeff0011);
  });






  test('MMUCR TI self-clears, AT enables translation, and reset clears queues',
      () {
    bus.write32(0xff000010, 0xfffffffe);
    expect(bus.read32(0x1f000010), 0xfcfcff00);
    bus.write32(0xff000010, 1);
    expect(bus.read32(0xff000010), 1);
    bus.write32(0xe0000000, 42);
    cpu.reset();
    expect(bus.read32(0xff000010), 0);
    expect(bus.read32(0xff000038), 0);
    bus.write32(0xff000038, 0x0c);
    bus.transferStoreQueue(0xe0000000);
    expect(bus.read32(0x0c000000), 0);
  });

}
