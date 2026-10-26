import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps/pad.dart';
import 'package:test/test.dart';

/// Sends one transfer [tx] (address, command, then parameters) and returns the
/// bytes answered by the pad.
List<int> transfer(Pad pad, List<int> tx) =>
    [for (final b in tx) pad.notify(b).rxData];

void main() {
  test('digital pad answers a 2 byte poll', () {
    final pad = Pad();
    expect(
        transfer(pad, [0x01, 0x42, 0, 0, 0]), [0xff, 0x41, 0x5a, 0xff, 0xff]);
    expect(pad.padStep, Pad.waitAddr);
  });

  test('configuration selects the analog mode and polls the sticks', () {
    final state = PadState()
      ..setAxis(0, PadAxis.leftX, -1)
      ..setAxis(0, PadAxis.leftY, 1)
      ..setAxis(0, PadAxis.rightX, 1)
      ..setAxis(0, PadAxis.rightY, 0);
    final pad = Pad()..source = state;
    transfer(pad, [0x01, 0x43, 0, 1, 0]);
    expect(pad.configMode, isTrue);
    expect(transfer(pad, [0x01, 0x44, 0, 1, 3, 0, 0, 0, 0]),
        [0xff, 0xf3, 0x5a, 0, 0, 0, 0, 0, 0]);
    expect(pad.analogMode, isTrue);
    transfer(pad, [0x01, 0x43, 0, 0, 0, 0, 0, 0, 0]);
    expect(pad.configMode, isFalse);
    expect(transfer(pad, [0x01, 0x42, 0, 0, 0, 0, 0, 0, 0]),
        [0xff, 0x73, 0x5a, 0xff, 0xff, 255, 0x80, 1, 255]);
  });

  test('reset returns to the digital mode', () {
    final pad = Pad()..analogMode = true;
    pad.reset();
    expect(transfer(pad, [0x01, 0x42, 0, 0, 0])[1], 0x41);
  });
}
