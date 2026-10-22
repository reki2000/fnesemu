// runs the instruction tests of a cpu (the data is fetched by make test-cpu-setup)
//
// usage: dart run tool/cpu_test.dart <cpu> <test data...>
//   nestest  <nestest.nes> <nestest.log>           6502 (NES), the log of nestest
//   z80      <tests.in> <tests.expected>           Z80, the FUSE tests
//   v30      <metadata.json> <XX.json.gz...>       V30MZ, the 8088 tests of SingleStepTests
//   m68k     <68000/v1 dir>                        68000, SingleStepTests/680x0
//   r3000    <r3000/v1 dir>                        R3000 (PS1), SingleStepTests/r3000
//   gte      <tests.c>                             PS1 GTE, gte/test-all of ps1-tests
//   huc6280  <huc6280/v1 dir>                      HuC6280 (PCE), SingleStepTests/huc6280
import 'dart:io';

import 'cpu_test/gte.dart' as gte;
import 'cpu_test/huc6280.dart' as huc6280;
import 'cpu_test/m68k.dart' as m68k;
import 'cpu_test/nestest.dart' as nestest;
import 'cpu_test/r3000.dart' as r3000;
import 'cpu_test/v30.dart' as v30;
import 'cpu_test/z80.dart' as z80;

final _tests = <String, dynamic Function(List<String>)>{
  "nestest": nestest.main,
  "z80": z80.main,
  "v30": v30.main,
  "m68k": m68k.main,
  "r3000": r3000.main,
  "gte": gte.main,
  "huc6280": huc6280.main,
};

Future<void> main(List<String> args) async {
  final test = args.isEmpty ? null : _tests[args.first];
  if (test == null) {
    stderr.writeln("usage: cpu_test <${_tests.keys.join("|")}> <test data...>");
    exit(64);
  }
  await test(args.sublist(1));
}
