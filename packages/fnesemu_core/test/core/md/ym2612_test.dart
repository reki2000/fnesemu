import 'package:fnesemu_core/src/core/md/ym2612.dart';
import 'package:test/test.dart';

void _write(Ym2612 fm, int reg, int value) {
  fm.writePort8(0, reg);
  fm.writeData8(0, value);
}

void main() {
  test('timer A advances once per 144-clock output sample', () {
    final fm = Ym2612()..setClockHz(7670454);
    _write(fm, 0x24, 0xff);
    _write(fm, 0x25, 0x00); // 1024 - 1020 = four samples.
    _write(fm, 0x27, 0x05);
    fm.render(3);
    expect(fm.read8(0) & 1, 0);
    fm.render(1);
    expect(fm.read8(0) & 1, 1);
    _write(fm, 0x27, 0x15); // Clear the flag while keeping the timer running.
    fm.render(3);
    expect(fm.read8(0) & 1, 0);
    fm.render(1);
    expect(fm.read8(0) & 1, 1);
  });

}
