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
  }
}
