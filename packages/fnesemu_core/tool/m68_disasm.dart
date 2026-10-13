import 'dart:io';

import 'package:fnesemu_core/src/components/m68k/disasm.dart';

import 'logging.dart';

void main(List<String> args) {
  configureLogging();
  final words = args.map((word) => int.parse(word, radix: 16)).toList();
  final (instruction, length) = Disasm().disasm(words, 0);
  stdout.writeln(instruction);
  stdout.writeln(length);
}
