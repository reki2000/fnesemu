import 'package:fnesemu_core/core/pce/component/bus.dart';
import 'package:test/test.dart';

void main() {
  test('writes to CD RAM do not change work RAM', () {
    final bus = Bus();
    bus.write(0xf8 << 13, 0x12);
    bus.write(0x80 << 13, 0x34);
    expect(bus.read(0xf8 << 13), 0x12);
    expect(bus.read(0x80 << 13), 0x34);
  });

  test('all SGX RAM banks retain distinct values at the same offset', () {
    final bus = Bus()..vpc.enabled = true;
    final banks = [
      0xf8,
      0xf9,
      0xfa,
      0xfb,
      ...List.generate(8, (i) => 0x80 + i),
    ];
    for (var i = 0; i < banks.length; i++) {
      bus.write((banks[i] << 13) | 0x1fff, i + 1);
    }
    for (var i = 0; i < banks.length; i++) {
      expect(bus.read((banks[i] << 13) | 0x1fff), i + 1);
    }
  });
}
