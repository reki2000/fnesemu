import 'package:fnesemu_core/src/core/ps2/iop/ohci.dart';
import 'package:test/test.dart';

const _base = 0x1f801600;

void main() {
  test('a host controller reset completes at once', () {
    final ohci = Ohci();
    ohci.write(_base + 0x04, 0x80); // HcControl: operational
    ohci.write(_base + 0x10, 0x8000000f); // HcInterruptEnable
    ohci.write(_base + 0x08, 1); // HcCommandStatus: HostControllerReset
    expect(ohci.read(_base + 0x08) & 1, 0);
    expect(ohci.read(_base + 0x04), 0);
    expect(ohci.read(_base + 0x10), 0);
    expect(ohci.read(_base + 0x00), 0x10);
    expect(ohci.read(_base + 0x34), 0x2edf);
  });
}
