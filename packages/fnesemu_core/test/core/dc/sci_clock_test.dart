import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sci.dart';
import 'package:test/test.dart';

void main() {
  late DcSci sci;
  late List<int> output;
  setUp(() {
    sci = DcSci();
    output = <int>[];
    sci.onTransmit = output.add;
  });
  void send(int value) {
    final status = sci.read(16, 1);
    sci.write(12, 1, value);
    sci.write(16, 1, status & ~0x80);
  }

  for (var divider = 0; divider < 4; divider++) {
    test('synchronous baud divisor $divider ignores asynchronous format bits',
        () {
      sci.write(0, 1, 0xfc | divider);
      sci.write(4, 1, 2);
      sci.write(8, 1, 0x24);
      expect(sci.synchronous, isTrue);
      expect(sci.frameBits, 8);
      final bit = 4 * 3 * (1 << (2 * divider));
      expect(sci.bitClocks, bit);
      send(0xff);
      sci.tickPeripheralClocks(bit * 7 - 1);
      expect(sci.interruptEvent, 0);
      sci.tickPeripheralClocks(1);
      expect(sci.interruptEvent, 0x540);
      expect(output, isEmpty);
      sci.tickPeripheralClocks(bit);
      expect(output, [255]);
    });
  }

  test('synchronous transmitter reloads the buffer at the last data bit', () {
    sci.write(0, 1, 0x80);
    sci.write(4, 1, 0);
    sci.write(8, 1, 0x20);
    send(0x41);
    send(0x42);
    sci.tickPeripheralClocks(27);
    expect(sci.read(16, 1) & 0x80, 0);
    sci.tickPeripheralClocks(1);
    expect(sci.read(16, 1) & 0x84, 0x80);
    send(0x43);
    sci.tickPeripheralClocks(68);
    expect(output, [0x41, 0x42, 0x43]);
    expect(sci.read(16, 1) & 0x84, 0x84);
  });

  test('synchronous receive ignores parity and framing metadata', () {
    sci.write(0, 1, 0xf8);
    sci.write(8, 1, 0x50);
    sci.receiveFrame(255, parityError: true, framingError: true);
    expect(sci.read(20, 1), 255);
    expect(sci.read(16, 1) & 0x78, 0x40);
    expect(sci.interruptEvent, 0x500);
  });

  test(
      'synchronous receive overrun suspends both directions until acknowledged',
      () {
    sci.write(0, 1, 0x80);
    sci.write(4, 1, 0);
    sci.write(8, 1, 0x70);
    send(0x41);
    sci.tickPeripheralClocks(8);
    sci.receiveFrame(0x42);
    sci.receiveFrame(0x43);
    expect(sci.interruptEvent, 0x4e0);
    sci.tickPeripheralClocks(1000);
    expect(output, isEmpty);
    expect(sci.read(20, 1), 0x42);
    sci.read(16, 1);
    sci.write(16, 1, 0x84);
    sci.tickPeripheralClocks(24);
    expect(output, [0x41]);
  });

  test('an endpoint overrun suspends the rest of a synchronous clock batch',
      () {
    sci.write(0, 1, 0x80);
    sci.write(4, 1, 0);
    sci.write(8, 1, 0x30);
    sci.onTransmit = (byte) {
      output.add(byte);
      sci.receiveFrame(byte);
    };
    sci.receiveFrame(0x30);
    send(0x41);
    send(0x42);
    sci.tickPeripheralClocks(1000);
    expect(output, [0x41]);
    expect(sci.read(16, 1) & 0x20, 0x20);
    sci.write(16, 1, 0x84);
    sci.tickPeripheralClocks(32);
    expect(output, [0x41, 0x42]);
    expect(sci.read(20, 1), 0x42);
  });

  for (final synchronous in [false, true]) {
    test(
        'external clock drives ${synchronous ? 'synchronous' : 'asynchronous'} transmission',
        () {
      sci.write(0, 1, synchronous ? 0x80 : 0);
      sci.write(4, 1, 255);
      sci.write(8, 1, 0x22);
      send(0xa5);
      sci.tickPeripheralClocks(1000000);
      expect(output, isEmpty);
      final cycles = synchronous ? 8 : 160;
      sci.tickExternalClocks(cycles - 1);
      expect(output, isEmpty);
      sci.tickExternalClocks(1);
      expect(output, [0xa5]);
    });
  }

  test('external clock injection is ignored in internal mode and module stop',
      () {
    sci.write(0, 1, 0x80);
    sci.write(4, 1, 0);
    sci.write(8, 1, 0x20);
    send(0x41);
    sci.tickExternalClocks(1000);
    expect(output, isEmpty);
    sci.tickPeripheralClocks(32);
    expect(output, [0x41]);
    sci.write(8, 1, 0);
    sci.write(8, 1, 0x22);
    send(0x42);
    sci.clockEnabled = false;
    sci.tickExternalClocks(1000);
    sci.clockEnabled = true;
    sci.tickExternalClocks(1000);
    expect(output, [0x41]);
  });

  test('synchronous bidirectional DMA batches match individual master clocks',
      () {
    final batch = DcBus(), single = DcBus();
    for (final bus in [batch, single]) {
      bus.sci.onTransmit = bus.sci.receiveFrame;
      bus.write8(0xffe00000, 0x80);
      bus.write8(0xffe00004, 0);
      bus.write8(0xffe00008, 0x30);
      for (var i = 0; i < 20; i++) {
        bus.write8(0x8c020000 + i, 0x80 + i);
      }
      for (var channel = 0; channel < 2; channel++) {
        final registers = 0xffa00000 + channel * 16;
        bus.write32(registers, channel == 0 ? 0x8c020000 : 0xffe00014);
        bus.write32(registers + 4, channel == 0 ? 0xffe0000c : 0x8c030000);
        bus.write32(registers + 8, 20);
        bus.write32(registers + 12, channel == 0 ? 0x1811 : 0x4911);
      }
      bus.write32(0xffa00040, 1);
    }
    batch.tickMasterClocks(3000);
    for (var i = 0; i < 3000; i++) {
      single.tickMasterClocks(1);
    }
    for (final bus in [batch, single]) {
      expect([for (var i = 0; i < 20; i++) bus.read8(0x8c030000 + i)],
          [for (var i = 0; i < 20; i++) 0x80 + i]);
      expect(bus.read32(0xffa00008), 0);
      expect(bus.read32(0xffa00018), 0);
      expect(bus.dma.addressError, isFalse);
    }
    expect(batch.read8(0xffe00010), single.read8(0xffe00010));
  });

  test('format changes require disabled transmitter and receiver', () {
    sci.write(8, 1, 0x30);
    expect(() => sci.write(0, 1, 0x80), throwsA(isA<DcUnsupported>()));
    expect(sci.read(0, 1), 0);
    sci.write(8, 1, 0);
    sci.write(0, 1, 0x80);
    expect(sci.synchronous, isTrue);
  });

  test('external-clock batches agree with individual cycles', () {
    final single = DcSci();
    final singleOutput = <int>[];
    single.onTransmit = singleOutput.add;
    for (final device in [sci, single]) {
      device.write(8, 1, 0x22);
      for (final byte in [0x41, 0x42]) {
        device.read(16, 1);
        device.write(12, 1, byte);
        device.write(16, 1, 0);
      }
    }
    sci.tickExternalClocks(1000);
    for (var i = 0; i < 1000; i++) {
      single.tickExternalClocks(1);
    }
    expect(output, [0x41, 0x42]);
    expect(singleOutput, output);
    expect(single.read(16, 1), sci.read(16, 1));
  });
}
