import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/util.dart';

import '../bus_z80.dart';
import 'z80.dart';

class BusZ80Test extends BusZ80 {
  @override
  final ram = Uint8List(0x10000);

  late Z80 cpu;

  BusZ80Test();

  @override
  int read(int addr) {
    return ram[addr];
  }

  @override
  void write(int addr, int data) {
    ram[addr] = data;
  }

  final io = [0xc1, 0x71, 0x71, 0xc1];
  int ioIndex = 0;

  @override
  int input(int port) {
    return io[ioIndex++ & 0x03];
  }

  @override
  void output(int port, int data) {}
}

int loadRegs(Z80 cpu, String line1, String line2) {
  final r = cpu.r;

  final regs = line1
      .split(" ")
      .map((e) => e == "" ? 0 : int.parse(e, radix: 16))
      .toList();
  r.af = regs[0];
  r.bc = regs[1];
  r.de = regs[2];
  r.hl = regs[3];
  r.af2 = regs[4];
  r.bc2 = regs[5];
  r.de2 = regs[6];
  r.hl2 = regs[7];
  r.ixiy[0] = regs[8];
  r.ixiy[1] = regs[9];
  r.sp = regs[10];
  r.pc = regs[11];

  final regs2 = line2
      .split(RegExp(r' +'))
      .map((e) => e == "" ? 0 : int.parse(e, radix: 16))
      .toList();
  r.i = regs2[0];
  r.r = regs2[1];
  cpu.iff1 = regs2[2] != 0;
  cpu.iff2 = regs2[3] != 0;
  cpu.im = regs2[4];
  cpu.halted = regs2[5] != 0;

  return int.parse(hex16(regs2[6])); // literally hex to dec
}

String dump(Z80 cpu) {
  final r = cpu.r;
  final res1 =
      "af:${(r.af & 0xffd7).h16} bc:${r.bc.h16} de:${r.de.h16} hl:${r.hl.h16}";
  final res2 =
      "af':${(r.af2 & 0xffd7).h16} bc':${r.bc2.h16} de':${r.de2.h16} hl':${r.hl2.h16}";
  final res3 =
      "ix:${r.ixiy[0].h16} iy:${r.ixiy[1].h16} sp:${r.sp.h16} pc:${r.pc.h16}";
  final regs4 =
      ("r:${r.i.h8} i:01 iff1:${cpu.iff1 ? 1 : 0} iff2:${cpu.iff2 ? 1 : 0} im:${cpu.im} ${cpu.halted ? "halted" : "-"} cy:${cpu.cycles}");
  final flags = List.generate(
      8, (i) => "SZ-H-PNCsz-h-pnc"[(r.f << i) & 0x80 != 0 ? i : 8 + i]).join();
  return "f:$flags $res1 $res2 $res3 $regs4";
}

void main(List<String> args) {
  final bus = BusZ80Test();
  final Z80 cpu = Z80(bus);
  final Z80 cpu2 = Z80(bus);

  final inputs = File(args[0]).readAsLinesSync(); // test.in
  final expects = File(args[1]).readAsLinesSync(); // text.expected

  int inpputLineNo = 0;
  int expectLineNo = 0;

  while (inpputLineNo < inputs.length) {
    final testNo = inputs[inpputLineNo++];

    final cycles =
        loadRegs(cpu, inputs[inpputLineNo++], inputs[inpputLineNo++]);

    bus.ram.fillRange(0, bus.ram.length, 0);

    // set up ram
    while (true) {
      final line = inputs[inpputLineNo++];

      if (line == "-1") {
        inpputLineNo++;
        break;
      }

      final mems = line
          .split(" ")
          .map((e) => (e == "-1" || e == "") ? 0 : int.parse(e, radix: 16))
          .toList();

      int addr = mems[0];
      for (int i = 1; i < mems.length - 1; i++) {
        bus.ram[addr++] = mems[i];
      }
    }

    cpu.cycles = 0;
    while (cpu.cycles < cycles) {
      cpu.exec();
    }

    // assert
    final expectTestNo = expects[expectLineNo++];
    if (expectTestNo != testNo) {
      print("Test loading failed: $expectTestNo != $testNo");
      return;
    }

    // skip memory/port dump
    while (RegExp(r" (MC|MR|MW|PR|PW|PC) ").hasMatch(expects[expectLineNo])) {
      expectLineNo++;
    }

    cpu2.cycles =
        loadRegs(cpu2, expects[expectLineNo++], expects[expectLineNo++]);

    var dump1 = dump(cpu);
    var dump2 = dump(cpu2).padRight(dump1.length, " ");
    dump1.padRight(dump2.length, " ");

    if (dump1 != dump2) {
      print("Test $testNo failed. expected,actual:\n$dump2\n$dump1");
      print(List.generate(dump1.length, (i) => dump1[i] == dump2[i] ? " " : "^")
          .join());
      return;
    }

    // skip memory change log
    while (RegExp(r"-1").hasMatch(expects[expectLineNo])) {
      expectLineNo++;
    }

    expectLineNo++;
  }
}
