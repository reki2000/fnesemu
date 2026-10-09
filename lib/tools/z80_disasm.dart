import 'dart:io';
import '../core/md/z80/z80_disasm.dart';

void main(List<String> args) {
  final bytes = args.map((byte) => int.parse(byte, radix: 16)).toList();
  final (instruction, length) = Z80Disasm.disasm(bytes, 0);
  stdout.writeln(instruction);
  stdout.writeln(length);
}
