// Dart imports:
import 'dart:io';
import 'dart:typed_data';

// Project imports:
import 'core/nes/component/apu.dart';
import 'core/nes/component/bus.dart';
import 'core/nes/component/cpu.dart';
import 'core/nes/component/cpu_debug.dart';
import 'core/nes/mapper/nrom.dart';
import 'core/nes/rom/nes_file.dart';
import 'util.dart';

void log(String s) {
  stdout.writeln(s);
}

void main() async {
  log("running fnesemu cpu test...");
  final bus = Bus();
  final cpu = Cpu(bus);
  Apu(bus);

  final f = File("assets/rom/nestest.nes");
  log("loading: $f");
  final body = await f.readAsBytes();
  final file = NesFile()..load(body);

  bus.mapper = MapperNROM();
  bus.mapper.setRom(Uint8ListEx.join(file.character),
      Uint8ListEx.join(file.program), Uint8List(0));
  bus.mapper.init();
  cpu.regs.pc = 0xc000;
  cpu.regs.p = 0x24;
  cpu.regs.s = 0xfd;
  cpu.cycle = 7;

  final testLog = File("assets/nestest.log");
  final testLogs = await testLog.readAsLines();

  String prevLine = "";
  for (final l in testLogs) {
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
  log("cpu test completed successfully.");
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
