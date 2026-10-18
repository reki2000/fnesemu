import 'dart:io';

import 'package:fnesemu_core/src/components/z80/z80_disasm.dart';

import 'logging.dart';

void main(List<String> args) {
  configureLogging();
  final bytes = args.map((byte) => int.parse(byte, radix: 16)).toList();
  final (instruction, length) = Z80Disasm.disasm(bytes, 0);
  stdout.writeln(instruction);
  stdout.writeln(length);
}
