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

}
