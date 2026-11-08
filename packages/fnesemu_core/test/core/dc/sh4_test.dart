import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const start = 0x8c010000;
  void program(List<int> words) {
    cpu.pc = start;
    for (var i = 0; i < words.length; i++) {
      bus.write16(start + i * 2, words[i]);
    }
  }

  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus);
  });

  test('reset establishes documented PC, SR and VBR', () {
    expect(cpu.pc, 0xa0000000);
    expect(cpu.sr, 0x700000f0);
    expect(cpu.vbr, 0);
    expect(cpu.inDelaySlot, isFalse);
  });

  test('signed immediate arithmetic wraps at 32 bits and preserves T', () {
    program([0x0018, 0xe1ff, 0x7101, 0x71ff]);
    cpu.step();
    cpu.step();
    expect(cpu.r[1], 0xffffffff);
    cpu.step();
    expect(cpu.r[1], 0);
    cpu.step();
    expect(cpu.r[1], 0xffffffff);
    expect(cpu.t, isTrue);
  });













  test('unsupported slot preserves pending branch and reset clears it', () {
    program([0xa002, 0xffff]);
    cpu.step();
    expect(cpu.step, throwsA(isA<DcUnsupported>()));
    bus.write16(start + 2, 0x0009);
    cpu.step();
    expect(cpu.pc, start + 8);
    cpu.reset();
    expect(cpu.inDelaySlot, isFalse);
  });

}
