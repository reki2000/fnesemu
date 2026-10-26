import 'package:fnesemu_core/src/core/md/pad.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:test/test.dart';

void main() {
  // writes TH high then low four times, 100 clocks apart, and returns the
  // reads after each write
  List<int> readCycle(Pad pad, int start) {
    final reads = <int>[];
    var clocks = start;
    for (var i = 0; i < 4; i++) {
      for (final th in [0x40, 0x00]) {
        pad.writeData(0, th, clocks);
        reads.add(pad.readData(0, clocks) & 0x3f);
        clocks += 100;
      }
    }
    return reads;
  }

  test('reads the 6 button pad in the order of the TH edges', () {
    final state = PadState()
      ..press(0, const PadButton('Start'))
      ..press(0, const PadButton('Y'))
      ..press(0, PadButton.up);
    final pad = Pad()
      ..source = state
      ..writeCtrl(0, 0x40);

    expect(readCycle(pad, 0), [
      0x3e, // C B R L D U
      0x12, // S A 0 0 D U
      0x3e,
      0x12,
      0x3e,
      0x10, // S A 0 0 0 0
      0x3d, // C B M X Y Z
      0x1f, // S A 1 1 1 1
    ]);
  });

  test('returns to the first state when TH does not change for 1.5 ms', () {
    final pad = Pad()..writeCtrl(0, 0x40);

    // one TH pulse per frame, without writing the ctrl register
    for (var frame = 0; frame < 8; frame++) {
      final clocks = frame * 128000;
      pad.writeData(0, 0x00, clocks);
      expect(pad.readData(0, clocks) & 0x0f, 0x03, reason: 'frame $frame');
      pad.writeData(0, 0x40, clocks + 100);
    }
  });
}
