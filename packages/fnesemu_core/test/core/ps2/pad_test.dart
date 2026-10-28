import 'package:fnesemu_core/src/core/ps2/iop/sio2.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:test/test.dart';

void main() {
  test('a poll of port 0 returns the pad buttons', () {
    final pad = PadState()
      ..press(0, PadButton.up)
      ..press(0, const PadButton('x'));
    final sio2 = Sio2()..pad.source = pad;
    sio2.write(Sio2.base, 4, (5 << 18) | (5 << 8));
    for (final byte in [0x01, 0x42, 0, 0, 0]) {
      sio2.send(byte);
    }
    sio2.write(Sio2.base + 0x68, 4, 1);
    final reply = List.generate(5, (_) => sio2.receive());
    expect(reply, [0xff, 0x41, 0x5a, 0xef, 0xbf]);
  });

  test('other ports and devices read as 0xff', () {
    final sio2 = Sio2();
    sio2.write(Sio2.base, 4, (3 << 18) | (3 << 8) | 1);
    for (final byte in [0x01, 0x42, 0]) {
      sio2.send(byte);
    }
    sio2.write(Sio2.base + 0x68, 4, 1);
    expect(List.generate(3, (_) => sio2.receive()), [0xff, 0xff, 0xff]);
  });
}
