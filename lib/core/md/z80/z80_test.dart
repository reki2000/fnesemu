import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/util/util.dart';

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

  final wrLog = <List<String>>[];

  @override
  void write(int addr, int data) {
    final element = wrLog.firstWhere(
      (e) => e[0] == (addr - e[1].length ~/ 3).hex16,
      orElse: () => [],
    );

    if (element.isNotEmpty) {
      element[1] += "${data.hex8} ";
    } else {
      final element = wrLog.firstWhere(
        (e) => e[0] == (addr + 1).hex16,
        orElse: () => [],
      );
      if (element.isNotEmpty) {
        element[0] = addr.hex16;
        element[1] = "${data.hex8} ${element[1]}";
      } else {
        wrLog.add([addr.hex16, "${data.hex8} "]);
      }
    }

    ram[addr] = data;
  }

  final io = [
    0xc1, 0x71, 0x71, 0xc1, 0x29, 0x7d, 0xbb, 0x40, //
    0x0d, 0x62, 0xf7, 0xf2, 0x9a, 0x02, 0x56, 0xab, //
    0xd7, 0x01, 0x56, 0xab, //
    ...List.generate(10, (i) => 10 - i), 0x0a, //
    ...List.generate(6, (i) => 6 - i), 0x06, //
    ...List.filled(1000, 0xff)
  ];
  int ioIndex = 0;

  @override
  int input(int port) {
    return io[ioIndex++];
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

  return int.parse(regs2[6].hex16); // literally hex to dec
}

String dump(Z80 cpu) {
  final r = cpu.r;
  final res1 =
      "af:${(r.af & 0xffd7).hex16} bc:${r.bc.hex16} de:${r.de.hex16} hl:${r.hl.hex16}";
  final res2 =
      "af':${(r.af2 & 0xffd7).hex16} bc':${r.bc2.hex16} de':${r.de2.hex16} hl':${r.hl2.hex16}";
  final res3 =
      "ix:${r.ixiy[0].hex16} iy:${r.ixiy[1].hex16} sp:${r.sp.hex16} pc:${r.pc.hex16}";
  final regs4 =
      ("i:${r.i.hex8} r:${r.r.hex8} iff1:${cpu.iff1 ? 1 : 0} iff2:${cpu.iff2 ? 1 : 0} im:${cpu.im} ${cpu.halted ? "halted" : "-"} cy:${cpu.cycles}");
  const f = "SZ-H-PNC";
  final flags = List.generate(
      f.length,
      (i) => "$f${f.toLowerCase()}"[
          (r.f << i & (1 << f.length - 1)) != 0 ? i : f.length + i]).join();
  return "f:$flags $res1 $res2 $res3 $regs4";
}

void main(List<String> args) {
  final bus = BusZ80Test();
  final Z80 cpu = Z80(bus);
  final Z80 cpu2 = Z80(bus);
  bus.cpu = cpu;

  final inputs = File(args[0]).readAsLinesSync(); // test.in
  final expects = File(args[1]).readAsLinesSync(); // text.expected

  int inpputLineNo = 0;
  int expectLineNo = 0;

  while (inpputLineNo < inputs.length) {
    cpu.cycles = 0;
    cpu.im = 0;
    cpu.iff1 = false;
    cpu.iff2 = false;
    cpu.halted = false;
    bus.wrLog.clear();

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
      print("Test $testNo failed. expected, actual:\n$dump2\n$dump1");
      print(List.generate(dump1.length, (i) => dump1[i] == dump2[i] ? " " : "^")
          .join());
      print(bus.wrLog);
      return;
    }

    // skip memory change log
    int i = 0;
    while (expects[expectLineNo].endsWith("-1")) {
      final wr = expects[expectLineNo];
      final log = "${bus.wrLog[i][0]} ${bus.wrLog[i][1]}-1";
      if (wr != log) {
        print("Test $testNo failed. expected, actual:\n$wr, $log");
        print(bus.wrLog);
        return;
      }
      i++;
      expectLineNo++;
    }

    expectLineNo++;
  }

  print("All tests passed.");
}
