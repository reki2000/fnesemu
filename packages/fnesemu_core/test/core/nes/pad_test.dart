import 'package:fnesemu_core/src/core/nes/component/pad.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:test/test.dart';

void main() {
  test('reads the buttons after the strobe and 1 after the 8 buttons', () {
    final pad = Joypad()..keyDown(0, PadButton.right);
    pad
      ..write(0x4016, 1)
      ..write(0x4016, 0);
    final bits = [for (var i = 0; i < 10; i++) pad.read(0x4016) & 1];
    expect(bits, [0, 0, 0, 0, 0, 0, 0, 1, 1, 1]);
  });

  test('the strobe holds the register at A', () {
    final pad = Joypad()..keyDown(0, const PadButton("A"));
    pad.write(0x4016, 1);
    expect([pad.read(0x4016) & 1, pad.read(0x4016) & 1], [1, 1]);
  });
}
