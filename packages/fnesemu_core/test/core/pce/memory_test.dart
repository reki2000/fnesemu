import 'dart:typed_data';

import 'package:fnesemu_core/src/core/pce/component/bus.dart';
import 'package:fnesemu_core/src/core/pce/mapper/rom.dart';
import 'package:test/test.dart';

void main() {
  test('writes to CD RAM do not change work RAM', () {
    final bus = Bus();
    bus.write(0xf8 << 13, 0x12);
    bus.write(0x80 << 13, 0x34);
    expect(bus.read(0xf8 << 13), 0x12);
    expect(bus.read(0x80 << 13), 0x34);
  });

}
