import 'dart:typed_data';

import 'package:fnesemu_core/src/components/sh2/jit/jit.dart';
import 'package:fnesemu_core/src/components/sh2/jit/translator.dart';
import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/core/ss/sh2/sh2.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

import '../tool/headless/jit_metrics.dart';

void main() {
  test('cores without a compiler expose no diagnostic runtimes', () {
    for (final core in [
      Core(),
      Ps(jit: false),
      N64(jit: false),
      Ss(jit: false),
      Md(sh2Jit: false)
    ]) {
      addTearDown(core.dispose);
      expect(core.jitDiagnostics, isEmpty);
      expect(jitRuntimes(core), isEmpty);
    }
  });

  test('each core supplies runtime metadata in CPU order', () {
    final ps = Ps(), n64 = N64(), ss = Ss(jit: true);
    final md = Md(expansionBoot: true, sh2Jit: true);
    for (final core in [ps, n64, ss, md]) {
      addTearDown(core.dispose);
    }
    expect(jitRuntimes(ps).toList(), [ps.jit!.rt]);
    expect(jitRuntimes(n64).toList(), [n64.jit!.rt]);
    expect(jitRuntimes(ss).toList(),
        [(ss.master as Sh2).jit!.rt, (ss.slave as Sh2).jit!.rt]);
    expect(jitRuntimes(md).toList(),
        md.expansion!.cpus.map((cpu) => cpu.jit!.rt).toList());
    expect(ps.jitDiagnostics.single.byteOrder, Endian.little);
    expect(n64.jitDiagnostics.single.byteOrder, Endian.big);
    expect(ss.jitDiagnostics.first.instructionBytes, 2);
    expect(md.jitDiagnostics.first.instructionBytes, 2);
  }, skip: JitRuntime.nativeSupported ? false : 'No compiled backend');

  for (final enabled in [false, true]) {
    test('SH-2 diagnostic decoding honors MAC options: $enabled', () {
      final jit =
          Sh2Jit.create(native: false, macLong: enabled, macWord: enabled)!;
      addTearDown(jit.dispose);
      final ram = jit.rt.alloc(0x1000);
      jit.map(0, ram.length, ram);
      final data = ByteData.sublistView(ram);
      data.setUint16(0, 0x412f); // MAC.W
      data.setUint16(2, 0x012f); // MAC.L
      for (final pc in [0, 2]) {
        expect(jit.diagnostics.classify(pc, Sh2Translator.interpret, 0, null),
            enabled ? 'guestExit' : 'unsupportedInstructionOrSlot');
      }
      expect(jit.diagnostics.classify(0, Sh2Translator.profileMiss, 0, null),
          'profileGuard');
      expect(jit.diagnostics.classify(0, Sh2Translator.idleDetected, 1, null),
          'idleSkip');
      expect(jit.diagnostics.classify(0x1000, Sh2Translator.interpret, 0, null),
          'guestExit');
    });
  }
}
