import 'int.dart';

/// formats register values in rows, without CPU-specific register names
String registerRows(Iterable<(String, int)> registers,
    {int bits = 32, int perLine = 8}) {
  String hex(int value) => bits == 64
      ? '${(value >>> 32).mask32.toRadixString(16).padLeft(8, "0")}${value.mask32.toRadixString(16).padLeft(8, "0")}'
      : (value & ((1 << bits) - 1))
          .toRadixString(16)
          .padLeft((bits + 3) ~/ 4, '0');
  final fields =
      registers.map((entry) => '${entry.$1}:${hex(entry.$2)}').toList();
  return [
    for (var i = 0; i < fields.length; i += perLine)
      fields.sublist(i, (i + perLine).clamp(0, fields.length)).join(' ')
  ].join('\n');
}
