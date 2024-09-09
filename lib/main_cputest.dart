// Dart imports:
import 'dart:io';

// Project imports:
import 'core/component/apu.dart';
import 'core/component/bus.dart';
import 'core/component/cpu.dart';
import 'core/component/cpu_debug.dart';
import 'core/mapper/rom.dart';
import 'core/rom/pce_file.dart';

void log(String s) {
  stdout.writeln(s);
}

void main() async {
  log("running fnesemu cpu test...");
  final bus = Bus();
  final cpu = Cpu2(bus);
  Apu(bus);

  final f = File("assets/rom/pcetest.pce");
  log("loading: $f");
  final body = await f.readAsBytes();
  log("loaded: ${body.length} bytes");
  final file = PceFile()..load(body);
  log("loaded: ${file.banks.length} banks, crc:${file.crc}");

  bus.rom = Rom(file.banks);
  cpu.reset();

  // dump rom
  // for (int i = 0x0000; i < 0x2000; i += 16) {
  //   String line = "${hex16(i)}: ";
  //   for (int j = 0; j < 16; j++) {
  //     line += "${hex8(file.banks[0][i + j])} ";
  //   }
  //   log(line);
  // }

  // disasm vector
  // log(cpu.dumpDisasm(0xe073, toAddrOffset: 150));

  for (int i = 0; i < 1000; i++) {
    log(cpu.dumpNesTest());
    cpu.exec();
  }
  //print("\$02:${hex8(cpu.read(2))} \$03:${hex8(cpu.read(3))}");
  log("cpu test completed successfully.");
}

String _dumpF(int val) {
  return "N:${_f(val, Flags.N)} "
      "V:${_f(val, Flags.V)} "
      "T:${_f(val, Flags.T)} "
      "B:${_f(val, Flags.B)} "
      "D:${_f(val, Flags.D)} "
      "I:${_f(val, Flags.I)} "
      "Z:${_f(val, Flags.Z)} "
      "C:${_f(val, Flags.C)} ";
}

int _f(int val, int flag) {
  return (val & flag != 0) ? 1 : 0;
}
