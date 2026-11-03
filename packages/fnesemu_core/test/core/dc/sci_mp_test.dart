import 'package:fnesemu_core/src/core/dc/sci.dart';
import 'package:test/test.dart';

void send(DcSci chip, int byte) {
  final status = chip.read(16, 1);
  chip.write(12, 1, byte);
  chip.write(16, 1, status & ~0x80);
}

void mpBit(DcSci chip, bool value) => chip.write(16, 1, 0xfc | (value ? 1 : 0));

void main() {

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
