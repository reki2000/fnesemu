import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0x0c010000, vector = 0x8c020000;

  void program(List<int> words, [int address = code]) {
    for (var i = 0; i < words.length; i++) {
      bus.write16(address + i * 2, words[i]);
    }
  }

  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = code;
    cpu.vbr = vector;
  });

  test('SR banks R0-R7 using MD and RB, leaving R8-R15 shared', () {
    cpu.r[0] = 10;
    cpu.bank[0] = 20;
    cpu.r[8] = 30;
    cpu.sr = 0x60000000;
    expect(cpu.r[0], 20);
    expect(cpu.bank[0], 10);
    cpu.sr = 0x20000000; // User mode always selects bank 0.
    expect(cpu.r[0], 10);
    expect(cpu.bank[0], 20);
    expect(cpu.r[8], 30);
    cpu.sr = 0x60000000;
    expect(cpu.r[0], 20);
  });

  test('LDC SR masks reserved bits and STC reads the active SR', () {
    program([0x480e, 0x0902]);
    cpu.r[8] = 0xffffffff;
    cpu.step();
    expect(cpu.sr, 0x700083f3);
    cpu.step();
    expect(cpu.r[9], 0x700083f3);
  });

  test('bank register transfers address the opposite bank', () {
    program([0x418e, 0x0282, 0x480e, 0x0382]);
    cpu.r[0] = 0x1111;
    cpu.r[1] = 0x2222;
    cpu.r[8] = 0x60000000;
    cpu.step();
    cpu.step();
    expect(cpu.r[2], 0x2222);
    cpu.step();
    expect(cpu.r[0], 0x2222);
    cpu.step();
    expect(cpu.r[3], 0x1111);
  });











  test('general exception with BL set performs a manual reset retaining RAM',
      () {
    program([0xc300]);
    cpu.sr = 0x50000000;
    cpu.step();
    expect(cpu.pc, 0xa0000000);
    expect(cpu.sr, 0x700000f0);
    expect(cpu.vbr, 0);
    expect(bus.expevt, 0x20);
    expect(bus.read16(code), 0xc300);
  });




}
