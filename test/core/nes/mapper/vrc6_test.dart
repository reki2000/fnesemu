import 'package:fnesemu/core/nes/mapper/vrc6_apu.dart';
import 'package:test/test.dart';

void main() {
  test('vrc6 sawtooth produces output', () {
    final apu = Vrc6Apu();
    apu.write(0xb000, 0x20); // rate
    apu.write(0xb001, 0x10);
    apu.write(0xb002, 0x80); // enable
    final out = apu.exec(2000);
    expect(out.any((v) => v > 0), true);
  });
}
