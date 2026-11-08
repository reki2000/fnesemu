import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0x0c010000, vector = 0x8c020000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = code;
    cpu.vbr = vector;
    bus.write16(code, 0xe12a);
    bus.write16(code + 2, 0x0009);
  });

  test('encoded IRL input validates all pin values before replacing the level',
      () {
    cpu.irlPins = 7;
    expect(() => cpu.irlPins = -1, throwsRangeError);
    expect(() => cpu.irlPins = 16, throwsRangeError);
    expect(cpu.irlPins, 7);
  });







  test('CPU reset preserves external pin levels and clears internal state', () {
    cpu.irlPins = 4;
    cpu.reset();
    expect(cpu.irlPins, 4);
    expect(cpu.sr, 0x700000f0);
    expect(cpu.instructionExecuted, isFalse);
    expect(bus.intevt, 0);
  });
}
