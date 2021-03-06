// Dart imports:
import 'dart:io';

// Project imports:
import 'cpu/apu.dart';
import 'cpu/bus.dart';
import 'cpu/cpu.dart';
import 'cpu/cpu_debug.dart';
import 'cpu/ppu.dart';
import 'cpu/rom/nes_file.dart';

void log(String s) {
  stdout.writeln(s);
}

void main() async {
  log("running fnesemu...");
  final cpu = Cpu();
  final bus = Bus(cpu, Ppu(), Apu());
  final file = NesFile();

  final f = File("assets/rom/nestest.nes");
  log("loading: $f");
  final body = await f.readAsBytes();
  await file.load(body);

  bus.mapper.loadProgramRom(file.program);
  cpu.regs.PC = 0xc000;
  cpu.regs.P = 0x24;
  cpu.regs.S = 0xfd;
  cpu.cycle = 7;

  final testLog = File("assets/nestest.log");
  final testLogs = await testLog.readAsLines();
  var prevLine = "";
  for (var l in testLogs) {
    final result = cpu.dumpNesTest();
    if (l.substring(0, 4) + l.substring(48) !=
        result.substring(0, 4) + result.substring(48)) {
      final prevFlag = int.parse(prevLine.substring(65, 67), radix: 16);
      final expectFlag = int.parse(l.substring(65, 67), radix: 16);
      final resultFlag = int.parse(result.substring(65, 67), radix: 16);

      log("previous: $prevLine ${_dumpF(prevFlag)}");
      log("expected: $l ${_dumpF(expectFlag)}");
      log("result  : $result ${_dumpF(resultFlag)}");
      break;
    }
    cpu.exec();
    prevLine = l;
  }
  //print("\$02:${hex8(cpu.read(2))} \$03:${hex8(cpu.read(3))}");
}

String _dumpF(int val) {
  return "N:${_f(val, Flags.N)} "
      "V:${_f(val, Flags.V)} "
      "R:${_f(val, Flags.R)} "
      "B:${_f(val, Flags.B)} "
      "D:${_f(val, Flags.D)} "
      "I:${_f(val, Flags.I)} "
      "Z:${_f(val, Flags.Z)} "
      "C:${_f(val, Flags.C)} ";
}

int _f(int val, int flag) {
  return (val & flag != 0) ? 1 : 0;
}
