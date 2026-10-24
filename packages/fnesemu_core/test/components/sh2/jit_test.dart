import 'dart:typed_data';

import 'package:fnesemu_core/src/components/sh2/jit/jit.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

const _base = 0x06000000;

final class _ProfileFixture {
  final Sh2Jit jit;
  late final Uint8List ram = jit.rt.alloc(4096);
  late final ByteData data = ByteData.sublistView(ram);

  _ProfileFixture(bool native, int threshold)
      : jit = Sh2Jit.create(
            native: native,
            compileThreshold: threshold,
            profileMemory: true,
            maxInstructions: 1,
            stopOnNoStore: false)! {
    jit.map(_base, ram.length, ram);
    jit.attach((pc) => data.getUint16(pc - _base));
    data.setUint16(0, 0x6142);
    data.setUint16(2, 0xffff);
    data.setUint32(0x100, 42);
    data.setUint32(0x200, 99);
    jit.regs[4] = _base + 0x100;
  }
}

void main() {
  for (final native in [false, true]) {
    group(native ? 'compiled entry profiles' : 'reference entry profiles', () {
      test('cold code changes discard observations before specialization', () {
        final fixture = _ProfileFixture(native, 3);
        final jit = fixture.jit;
        addTearDown(jit.dispose);
        expect(jit.run(_base, 1), isNull);
        expect(jit.run(_base, 1), isNull);
        fixture.data.setUint16(0, 0x6242);
        expect(jit.run(_base, 1), (_base + 2, 1));
        expect(jit.regs[2], 42);
        jit.regs[4] = _base + 0x200;
        // Only one sample belongs to the changed entry, so it stays generic.
        expect(jit.run(_base, 1), (_base + 2, 1));
        expect(jit.regs[2], 99);
      });

      test('profile misses keep generic code and reset allows fresh candidates',
          () {
        final fixture = _ProfileFixture(native, 2);
        final jit = fixture.jit;
        addTearDown(jit.dispose);
        expect(jit.run(_base, 1), isNull);
        expect(jit.run(_base, 1), (_base + 2, 1));
        expect(jit.regs[1], 42);
        jit.regs[4] = _base + 0x200;
        expect(jit.run(_base, 1), isNull);
        expect(jit.rt.ctx[JitCtx.budget], 1);
        expect(jit.regs[1], 42);
        expect(jit.run(_base, 1), (_base + 2, 1));
        expect(jit.regs[1], 99);
        jit.regs[4] = _base + 0x100;
        expect(jit.run(_base, 1), (_base + 2, 1));
        expect(jit.regs[1], 42);
        jit.reset();
        expect(jit.run(_base, 1), isNull);
        expect(jit.run(_base, 1), (_base + 2, 1));
        jit.regs[4] = _base + 0x200;
        expect(jit.run(_base, 1), isNull);
        expect(jit.regs[1], 42);
      });
    }, skip: native && !JitRuntime.nativeSupported);
  }
}
