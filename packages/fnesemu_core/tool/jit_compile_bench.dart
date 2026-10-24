// Separates IR construction and native installation for fixed N64 code blocks.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/n64/jit/vr4300_translator.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

void main(List<String> args) {
  const count = 1000, start = 0x80010000, stride = 128;
  final source = Uint8List(0x80000), data = ByteData.sublistView(source);
  final random = Random(84);
  int immediate(int op, int s, int t, int imm) =>
      op << 26 | s << 21 | t << 16 | (imm & 0xffff);
  for (var block = 0; block < count; block++) {
    for (var i = 0; i < 20; i++) {
      final s = 3 + random.nextInt(24), t = 3 + random.nextInt(24);
      final d = 3 + random.nextInt(24), imm = random.nextInt(65536);
      final op = switch (i % 8) {
        0 => immediate(35, 28, t, (i % 16) * 4),
        1 => immediate(43, 28, t, (i % 16) * 4),
        2 => immediate(9, s, t, imm),
        3 => immediate(12, s, t, imm),
        4 => s << 21 | t << 16 | d << 11 | 45,
        5 => t << 16 | d << 11 | 13 << 6 | 62,
        6 => immediate(11, s, t, imm),
        _ => s << 21 | t << 16 | d << 11 | 38,
      };
      data.setUint32((start & 0x1fffffff) + block * stride + i * 4, op);
    }
    data.setUint32(
        (start & 0x1fffffff) + block * stride + 80, immediate(5, 1, 2, -21));
  }
  for (var round = 0; round < 3; round++) {
    {
      final rt = JitRuntime.native(
          ctxWords: Vr4300Translator.ctxFpuControl + 1,
          addrMask: 0x1fffffff,
          read: (_, __) => 0,
          write: (_, __, ___) {});
      if (rt == null) throw StateError('Compiled backend unavailable');
      try {
        final ram = rt.alloc(source.length)..setAll(0, source);
        rt.mapPages(0, ram.length, ram);
        final words = ByteData.sublistView(ram);
        int? fetch(int pc) => words.getUint32(pc & 0x1fffffff);
        final frontend = Vr4300Translator(fetch: fetch, protect: (_) {});
        final lower = Stopwatch(), install = Stopwatch();
        var instructions = 0, exits = 0, snapshotWords = 0;
        for (var block = 0; block < count; block++) {
          lower.start();
          final ir = frontend.translate(start + block * stride)!;
          lower.stop();
          instructions += ir.insts.length;
          exits += ir.exits.length;
          for (final exit in ir.exits) snapshotWords += exit.stores.length;
          install.start();
          rt.install(ir);
          install.stop();
        }
        print(jsonEncode({
          'round': round,
          'blocks': count,
          'lowerUs': lower.elapsedMicroseconds,
          'installUs': install.elapsedMicroseconds,
          'irInstructions': instructions,
          'exits': exits,
          'snapshotValues': snapshotWords
        }));
      } finally {
        rt.dispose();
      }
    }
  }
}
