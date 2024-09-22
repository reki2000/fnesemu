// Dart imports:
import 'dart:io';

import 'core_pce/component/bus.dart';
import 'core_pce/component/cpu.dart';
import 'core_pce/component/cpu_debug.dart';
// Project imports:
import 'core_pce/component/psg.dart';
import 'core_pce/mapper/rom.dart';
import 'core_pce/rom/pce_file.dart';

void log(String s) {
  stdout.writeln(s);
}

void main() async {
  log("running fnesemu cpu test...");
  final bus = Bus();
  final cpu = Cpu2(bus);
  Psg(bus);

  final f = File("assets/roms/pcetest.pce");
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
