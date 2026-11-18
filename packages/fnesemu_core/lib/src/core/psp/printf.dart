import 'dart:typed_data';

import 'allegrex.dart';

final _conversion = RegExp(
    r"%([-+ #0]*)(\*|\d+)?(?:\.(\*|\d*))?(hh|ll|[hljztL])?([diuoxXcspfeEgG%])");

/// Formats a guest kernel debug message using the Allegrex argument slots.
String formatKernelPrintf(Allegrex cpu) {
  final mem = cpu.mem;
  final pointer = cpu.r[4];
  if (pointer == 0) return '';
  final format = mem.readString(pointer, 4096);
  var slot = 1;
  int nextWord() {
    final index = slot++;
    return index < 8
        ? cpu.r[4 + index] & 0xffffffff
        : mem.read32(cpu.r[29] + (index - 8) * 4);
  }

  int nextPair() {
    slot = (slot + 1) & ~1;
    final low = nextWord();
    return low | nextWord() << 32;
  }

  return format.replaceAllMapped(_conversion, (match) {
    final conversion = match[5]!;
    if (conversion == '%') return '%';
    final flags = match[1]!;
    final widthSpec = match[2];
    final precisionSpec = match[3];
    final width = widthSpec == '*'
        ? nextWord().toSigned(32)
        : int.tryParse(widthSpec ?? '') ?? 0;
    final precision = precisionSpec == '*'
        ? nextWord().toSigned(32)
        : precisionSpec == null
            ? -1
            : int.tryParse(precisionSpec) ?? 0;
    final left = width < 0 || flags.contains('-');
    final columns = width.abs().clamp(0, 4096);
    String pad(String text) =>
        left ? text.padRight(columns) : text.padLeft(columns);

    if (conversion == 's') {
      final at = nextWord();
      final text = at == 0 ? '(null)' : mem.readString(at, 4096);
      return pad(precision >= 0 && precision < text.length
          ? text.substring(0, precision)
          : text);
    }
    if (conversion == 'c') {
      return pad(String.fromCharCode(nextWord() & 0xff));
    }

    final length = match[4];
    final floating = 'feEgG'.contains(conversion);
    final bits = switch (length) {
      'hh' => 8,
      'h' => 16,
      'll' || 'j' => 64,
      _ => 32,
    };
    final raw = floating || bits == 64 ? nextPair() : nextWord();
    var prefix = '';
    String text;
    final signed = floating || conversion == 'd' || conversion == 'i';
    if (floating) {
      final value = (ByteData(8)..setInt64(0, raw)).getFloat64(0);
      final places = (precision < 0 ? 6 : precision).clamp(0, 20);
      prefix = value.isNegative ? '-' : '';
      final magnitude = value.abs();
      text = switch (conversion.toLowerCase()) {
        'f' => magnitude.toStringAsFixed(places),
        'e' => magnitude.toStringAsExponential(places),
        _ => magnitude.toStringAsPrecision(places == 0 ? 1 : places),
      };
    } else {
      final radix = switch (conversion.toLowerCase()) {
        'o' => 8,
        'x' || 'p' => 16,
        _ => 10,
      };
      final value = signed
          ? BigInt.from(raw).toSigned(bits)
          : BigInt.from(raw).toUnsigned(bits);
      prefix = value.isNegative ? '-' : '';
      text = value == BigInt.zero && precision == 0
          ? ''
          : value.abs().toRadixString(radix);
      if (precision >= 0) text = text.padLeft(precision.clamp(0, 4096), '0');
      if (conversion == 'p' ||
          (radix == 16 && flags.contains('#') && value != BigInt.zero)) {
        prefix = conversion == 'X' ? '0X' : '0x';
      }
      if (radix == 8 && flags.contains('#') && !text.startsWith('0')) {
        text = '0$text';
      }
    }
    if ('XEG'.contains(conversion)) text = text.toUpperCase();
    if (signed && prefix.isEmpty) {
      if (flags.contains('+')) {
        prefix = '+';
      } else if (flags.contains(' ')) {
        prefix = ' ';
      }
    }
    if (!left && flags.contains('0') && (precision < 0 || floating)) {
      return prefix + text.padLeft(columns - prefix.length, '0');
    }
    return pad(prefix + text);
  });
}
