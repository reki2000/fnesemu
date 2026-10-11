import 'package:fnesemu_core/src/cdrom.dart';
import 'package:test/test.dart';

void main() {
  test('LBA uses the two-second origin offset; frame counts do not', () {
    expect(Msf.ofLba(0).frames(), 150);
    expect(Msf.ofLba(0).parts(), (0, 2, 0));
    expect(Msf.ofLba(0).format(), '00:02:00');
    expect(Msf.ofFrames(0).format(), '00:00:00');
    expect(Msf.ofLba(-150).format(), '00:00:00');
    expect(Msf.ofLba(-1).format(), '00:01:74');
  });

  test('second and minute boundaries carry at 75 frames and 60 seconds', () {
    for (final (frames, parts, formatted) in [
      (74, (0, 0, 74), '00:00:74'),
      (75, (0, 1, 0), '00:01:00'),
      (4499, (0, 59, 74), '00:59:74'),
      (4500, (1, 0, 0), '01:00:00'),
      (55574, (12, 20, 74), '12:20:74'),
    ]) {
      final time = Msf.ofFrames(frames);
      expect(time.parts(), parts);
      expect(time.format(), formatted);
    }
  });

  test('numeric and BCD fields round trip without extra origin conversion', () {
    final time = Msf.ofParts(12, 34, 56);
    expect(time.parts(), (12, 34, 56));
    expect(time.bcd(), (0x12, 0x34, 0x56));
    expect(Msf.ofBcd(0x12, 0x34, 0x56).frames(), time.frames());
    expect(Msf.ofLba(time.frames() - Msf.lbaOffset).parts(), time.parts());
  });

  test('relative magnitudes remain explicit and negative times are rejected',
      () {
    const trackStartLba = 1000;
    expect(Msf.ofFrames(1075 - trackStartLba).format(), '00:01:00');
    expect(Msf.ofFrames((925 - trackStartLba).abs()).format(), '00:01:00');
    expect(() => Msf.ofFrames(-1), throwsRangeError);
    expect(() => Msf.ofLba(-151), throwsRangeError);
  });
}
