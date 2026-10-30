import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:test/test.dart';

void main() {
  test('TMU aliases, widths, reset and write-zero-clear flags', () {
    final bus = DcBus();
    expect(bus.read32(0xffd8000c), 0xffffffff);
    bus.write32(0x1fd80008, 2);
    bus.write32(0xffd8000c, 0);
    bus.write16(0xffd80010, 0x120);
    expect(bus.read16(0xffd80010), 0x20);
    bus.write8(0xffd80004, 1);
    bus.tmu.tickPeripheralClocks(4);
    expect(bus.read32(0xffd8000c), 2);
    expect(bus.tmu.interruptPending(0), isTrue);
    bus.write16(0xffd80010, 0x120);
    expect(bus.tmu.interruptPending(0), isTrue);
    bus.write16(0xffd80010, 0x20);
    expect(bus.tmu.interruptPending(0), isFalse);
    expect(() => bus.read32(0xdfd8000c), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(0xffd80004, 1), throwsA(isA<DcUnsupported>()));
    bus.resetCpuRegisters();
    expect(bus.read8(0xffd80004), 0);
    expect(bus.read32(0xffd80008), 0xffffffff);
  });

  test('batched timer clocks match individual clocks across all divisors', () {
    for (var prescaler = 0; prescaler < 5; prescaler++) {
      final batch = DcBus(), single = DcBus();
      for (final bus in [batch, single]) {
        for (var channel = 0; channel < 3; channel++) {
          bus.write32(0xffd80008 + channel * 12, channel);
          bus.write32(0xffd8000c + channel * 12, channel + 1);
          bus.write16(0xffd80010 + channel * 12, prescaler | 0x20);
        }
        bus.write8(0xffd80004, 7);
      }
      for (final clocks in [1, 3, 17, 1023, 8193]) {
        batch.tmu.tickPeripheralClocks(clocks);
        for (var i = 0; i < clocks; i++) {
          single.tmu.tickPeripheralClocks(1);
        }
        for (var channel = 0; channel < 3; channel++) {
          expect(batch.read32(0xffd8000c + channel * 12),
              single.read32(0xffd8000c + channel * 12));
          expect(batch.tmu.interruptPending(channel),
              single.tmu.interruptPending(channel));
        }
      }
    }
  });

  test('full 32-bit reload period and unsupported settings are atomic', () {
    final bus = DcBus();
    bus.write8(0xffd80004, 1);
    bus.tmu.tickPeripheralClocks(4 * 0x100000000);
    expect(bus.read32(0xffd8000c), 0xffffffff);
    expect(bus.read16(0xffd80010), 0x100);
    expect(() => bus.write16(0xffd80010, 7), throwsA(isA<DcUnsupported>()));
    expect(bus.read16(0xffd80010), 0x100);
    bus.write8(0xffd80004, 0);
    bus.tmu.tickPeripheralClocks(1024);
    expect(bus.read32(0xffd8000c), 0xffffffff);
  });
}
