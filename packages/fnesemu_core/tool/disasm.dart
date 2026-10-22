// disassembles one instruction and prints it with its length
//
// usage: dart run tool/disasm.dart <m68k|z80> <hex...>
//   m68k: 16bit words, z80: bytes
import 'dart:io';

import 'package:fnesemu_core/src/components/m68k/disasm.dart';
import 'package:fnesemu_core/src/components/z80/z80_disasm.dart';

import 'logging.dart';

void main(List<String> args) {
  configureLogging();
  if (args.isEmpty || !const {"m68k", "z80"}.contains(args.first)) {
    stderr.writeln("usage: disasm <m68k|z80> <hex...>");
    exit(64);
  }
  final values = args.skip(1).map((v) => int.parse(v, radix: 16)).toList();
  final (instruction, length) = args.first == "m68k"
      ? Disasm().disasm(values, 0)
      : Z80Disasm.disasm(values, 0);
  stdout.writeln(instruction);
  stdout.writeln(length);
}
