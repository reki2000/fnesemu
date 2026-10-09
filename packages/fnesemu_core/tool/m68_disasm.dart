import 'dart:io';
import 'package:fnesemu_core/core/components/m68k/disasm.dart';

void main(List<String> args) {
  final words = args.map((word) => int.parse(word, radix: 16)).toList();
  final (instruction, length) = Disasm().disasm(words, 0);
  stdout.writeln(instruction);
  stdout.writeln(length);
}
