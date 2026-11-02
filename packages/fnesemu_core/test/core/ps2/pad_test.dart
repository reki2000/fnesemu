import 'package:fnesemu_core/src/core/ps2/iop/pad.dart';
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

  test('the configuration commands switch to the analog and pressure modes',
      () {
    final pad = Ps2Pad()..source = (PadState()..press(0, const PadButton('o')));
    List<int> send(List<int> bytes) => pad.transfer(bytes, bytes.length);

    expect(send([1, 0x45, 0, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a]),
        List.filled(9, 0xff),
        reason: 'only 0x42 and 0x43 work outside the configuration mode');
    expect(send([1, 0x43, 0, 1, 0]), [0xff, 0x41, 0x5a, 0xff, 0xdf]);
    expect(send([1, 0x44, 0, 1, 3, 0, 0, 0, 0]),
        [0xff, 0xf3, 0x5a, 0, 0, 0, 0, 0, 0]);
    expect(send([1, 0x45, 0, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a]),
        [0xff, 0xf3, 0x5a, 3, 2, 1, 2, 1, 0]);
    expect(send([1, 0x4f, 0, 0xff, 0xff, 3, 0, 0, 0]),
        [0xff, 0xf3, 0x5a, 0, 0, 0, 0, 0, 0x5a]);
    expect(send([1, 0x43, 0, 0, 0, 0, 0, 0, 0]),
        [0xff, 0xf3, 0x5a, 0, 0, 0, 0, 0, 0]);

    final poll = pad.transfer([1, 0x42, 0], 21);
    expect(poll.sublist(0, 9),
        [0xff, 0x79, 0x5a, 0xff, 0xdf, 0x80, 0x80, 0x80, 0x80]);
    // the pressure of circle is the sixth pressure byte
    expect(poll.sublist(9), [0, 0, 0, 0, 0, 0xff, 0, 0, 0, 0, 0, 0]);
  });

  test('the receive DMA waits for the replies of the transfer', () {
    final sio2 = Sio2()..pad.source = PadState();
    expect(sio2.replyReady, isFalse);
    sio2.write(Sio2.base, 4, (5 << 18) | (5 << 8));
    for (final byte in [0x01, 0x42, 0, 0, 0]) {
      sio2.send(byte);
    }
    sio2.write(Sio2.base + 0x68, 4, 0x3bd);
    expect(sio2.replyReady, isTrue);
    expect(sio2.read(Sio2.base + 0x6c, 4), 0x1100);
    expect(List.generate(5, (_) => sio2.receive()),
        [0xff, 0x41, 0x5a, 0xff, 0xff]);
    expect(sio2.replyReady, isFalse);
  });
}
