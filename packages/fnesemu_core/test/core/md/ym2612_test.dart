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

  test('timer B advances once per sixteen output samples', () {
    final fm = Ym2612();
    _write(fm, 0x26, 0xfe);
    _write(fm, 0x27, 0x0a);
    fm.render(31);
    expect(fm.read8(0) & 2, 0);
    fm.render(1);
    expect(fm.read8(0) & 2, 2);
    _write(fm, 0x27, 0x2a);
    fm.render(31);
    expect(fm.read8(0) & 2, 0);
    fm.render(1);
    expect(fm.read8(0) & 2, 2);
  });

  test('acknowledging an overflow preserves the remaining timer period', () {
    final fm = Ym2612();
    _write(fm, 0x24, 0xff);
    _write(fm, 0x25, 0);
    _write(fm, 0x26, 0xff);
    _write(fm, 0x27, 0x0f);
    fm.render(17);
    expect(fm.read8(0) & 3, 3);
    _write(fm, 0x27, 0x3f);
    expect(fm.read8(0) & 3, 0);
    fm.render(2);
    expect(fm.read8(0) & 3, 0);
    fm.render(1);
    expect(fm.read8(0) & 3, 1);
    _write(fm, 0x27, 0x00);
    fm.render(100);
    expect(fm.read8(0) & 3, 1);
  });
}
