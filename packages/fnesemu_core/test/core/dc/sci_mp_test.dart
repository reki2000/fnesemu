import 'package:fnesemu_core/src/core/dc/sci.dart';
import 'package:test/test.dart';

void send(DcSci chip, int byte) {
  final status = chip.read(16, 1);
  chip.write(12, 1, byte);
  chip.write(16, 1, status & ~0x80);
}

void mpBit(DcSci chip, bool value) => chip.write(16, 1, 0xfc | (value ? 1 : 0));

void main() {
  for (final external in [false, true]) {
    for (final seven in [false, true]) {
      for (final twoStops in [false, true]) {
        for (final parity in [false, true]) {
          test(
              'MP transmit external=$external seven=$seven stops=$twoStops PE=$parity',
              () {
            final chip = DcSci();
            final bytes = <int>[];
            final frames = <(int, bool?)>[];
            chip.onTransmit = bytes.add;
            chip.onTransmitFrame = (byte, mp) => frames.add((byte, mp));
            chip.write(
                0,
                1,
                4 |
                    (seven ? 0x40 : 0) |
                    (twoStops ? 8 : 0) |
                    (parity ? 0x20 : 0));
            chip.write(4, 1, 0);
            chip.write(8, 1, 0x24 | (external ? 2 : 0));
            final bit = external ? 16 : 32;
            final dataBits = seven ? 7 : 8;
            final stops = twoStops ? 2 : 1;
            expect(chip.frameBits, 1 + dataBits + 1 + stops);
            void tick(int clocks) => external
                ? chip.tickExternalClocks(clocks)
                : chip.tickPeripheralClocks(clocks);
            mpBit(chip, false);
            send(chip, 0xff);
            // MPBT must not have been buffered when the data was loaded.
            tick((1 + dataBits) * bit - 1);
            mpBit(chip, true);
            tick(1); // The MP bit starts here.
            mpBit(
                chip, false); // A change after sampling affects the next frame.
            tick(bit - 1);
            expect(chip.interruptEvent, 0);
            tick(1); // Stop bit starts: TEND/TEI precede frame completion.
            expect(chip.interruptEvent, 0x540);
            expect(frames, isEmpty);
            tick(stops * bit - 1);
            expect(bytes, isEmpty);
            tick(1);
            expect(frames, [(seven ? 127 : 255, true)]);
            expect(bytes, [seven ? 127 : 255]);
            send(chip, 0x12);
            tick(chip.frameBits * bit);
            expect(frames.last, (0x12, false));
          });
        }
      }
    }
  }

  test(
      'MP frames loop back through the decoded receiver with address filtering',
      () {
    final transmitter = DcSci(), receiver = DcSci();
    transmitter.write(0, 1, 4);
    transmitter.write(4, 1, 0);
    transmitter.write(8, 1, 0x20);
    receiver.write(0, 1, 4);
    receiver.write(8, 1, 0x58);
    transmitter.onTransmitFrame =
        (byte, mp) => receiver.receiveFrame(byte, multiprocessorBit: mp!);
    send(transmitter, 0x21);
    transmitter.tickPeripheralClocks(352);
    expect(receiver.receiveRequest, isFalse);
    mpBit(transmitter, true);
    send(transmitter, 0x42);
    transmitter.tickPeripheralClocks(320); // TEND at the beginning of stop.
    mpBit(transmitter, false);
    send(transmitter, 0x63);
    transmitter.tickPeripheralClocks(32);
    expect(receiver.dmaRead(), 0x42);
    transmitter.tickPeripheralClocks(352);
    expect(receiver.dmaRead(), 0x63);
  });

  test('MP double buffering samples each frame independently and batches agree',
      () {
    final chips = [DcSci(), DcSci()];
    final outputs = [<(int, bool?)>[], <(int, bool?)>[]];
    for (var i = 0; i < 2; i++) {
      final chip = chips[i];
      chip.onTransmitFrame = (byte, mp) => outputs[i].add((byte, mp));
      chip.write(0, 1, 4);
      chip.write(4, 1, 0);
      chip.write(8, 1, 0x20);
      mpBit(chip, true);
      chip.dmaWrite(0x81);
      chip.dmaWrite(0x82);
      chip.tickPeripheralClocks(320); // Second data byte preloaded.
      mpBit(chip, false);
    }
    chips[0].tickPeripheralClocks(384);
    for (var i = 0; i < 384; i++) {
      chips[1].tickPeripheralClocks(1);
    }
    expect(outputs[0], [(0x81, true), (0x82, false)]);
    expect(outputs[1], outputs[0]);
  });

  for (final mode in [0, 0x84]) {
    test('ordinary and synchronous transmit frame metadata is null: $mode', () {
      final chip = DcSci();
      final frames = <(int, bool?)>[];
      chip.onTransmitFrame = (byte, mp) => frames.add((byte, mp));
      chip.write(0, 1, mode);
      chip.write(4, 1, 0);
      chip.write(8, 1, 0x20);
      mpBit(chip, true);
      send(chip, 0x55);
      chip.tickPeripheralClocks(chip.frameBits * chip.bitClocks);
      expect(frames, [(0x55, null)]);
    });
  }

  test('aborted MP frame does not emit and reset clears its sampled bit', () {
    final chip = DcSci();
    final frames = <(int, bool?)>[];
    chip.onTransmitFrame = (byte, mp) => frames.add((byte, mp));
    for (final reset in [false, true]) {
      chip.write(0, 1, 4);
      chip.write(4, 1, 0);
      chip.write(8, 1, 0x20);
      mpBit(chip, true);
      send(chip, 0xaa);
      chip.tickPeripheralClocks(288);
      if (reset) {
        chip.reset();
      } else {
        chip.write(8, 1, 0);
      }
      chip.tickPeripheralClocks(1000);
    }
    expect(frames, isEmpty);
    chip.write(0, 1, 4);
    chip.write(4, 1, 0);
    chip.write(8, 1, 0x20);
    send(chip, 0x11);
    chip.tickPeripheralClocks(352);
    expect(frames, [(0x11, false)]);
  });
}
