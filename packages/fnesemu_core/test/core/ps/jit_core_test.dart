import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

int _r(int rs, int rt, int rd, int funct) =>
    rs << 21 | rt << 16 | rd << 11 | funct;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

const _k0 = 26, _t0 = 8, _t1 = 9, _t2 = 10, _s0 = 16, _s7 = 23;

/// an interrupt handler which acknowledges every interrupt and counts them
/// in s7
final _handler = [
  _i(0x0f, 0, _k0, 0x1f80), // lui k0, 0x1f80
  _i(0x29, _k0, 0, 0x1070), // sh r0, 0x1070(k0): acknowledge
  _i(0x09, _s7, _s7, 1), // addiu s7, s7, 1
  0x40000000 | _k0 << 16 | 14 << 11, // mfc0 k0, epc
  0,
  _r(_k0, 0, 0, 0x08), // jr k0
  0x42000010, // rfe
];

/// a bios which installs [_handler], enables the vblank interrupt and counts
/// in s0 in a loop that loads and stores ram
List<int> _bios() => [
      _i(0x0f, 0, _t0, 0x8000), // lui t0, 0x8000
      for (final (n, w) in _handler.indexed) ...[
        _i(0x0f, 0, _t2, w >> 16),
        _i(0x0d, _t2, _t2, w),
        _i(0x2b, _t0, _t2, 0x80 + 4 * n), // sw t2, vector(t0)
      ],
      _i(0x0f, 0, _t0, 0x1f80),
      _i(0x09, 0, _t1, 1),
      _i(0x29, _t0, _t1, 0x1074), // sh t1, I_MASK: vblank
      _i(0x09, 0, _t1, 0x0401),
      0x40800000 | _t1 << 16 | 12 << 11, // mtc0 t1, sr: IM2 and IEc
      _i(0x0f, 0, _t0, 0x8010), // lui t0, 0x8010
      // loop:
      _i(0x23, _t0, _t1, 0), // lw t1, 0(t0)
      _i(0x09, _s0, _s0, 1), // addiu s0, s0, 1
      _r(_t1, _s0, _t1, 0x21), // addu t1, t1, s0
      _i(0x2b, _t0, _t1, 0), // sw t1, 0(t0)
      _i(0x04, 0, 0, -5), // beq r0, r0, loop
      0,
    ];

void main() {
  test('the default backend follows build flags and explicit overrides', () {
    const enabled = bool.fromEnvironment('JIT', defaultValue: true);
    const trace = bool.fromEnvironment('PS_TRACE');
    final ps = Ps();
    addTearDown(ps.dispose);
    expect(ps.jit != null, enabled && !trace && JitRuntime.nativeSupported);
    expect(ps.jitEnabled, ps.jit != null);
    final interpreted = Ps(jit: false);
    addTearDown(interpreted.dispose);
    expect(interpreted.jit, isNull);
    expect(interpreted.jitEnabled, isFalse);
  });

  test('the recompiler takes the interrupts of the interpreter', () {
    if (!JitRuntime.nativeSupported) {
      markTestSkipped('no native recompiler on this host');
      return;
    }
    final rom = Uint8List(512 * 1024);
    final words = rom.buffer.asUint32List();
    // past the addresses of the bios hooks, which the interpreter runs
    words[0] = 0x08000000 | (0xbfc00100 >> 2) & 0x3ffffff; // j 0xbfc00100
    words.setAll(0x40, _bios());

    final results = <List<int>>[];
    for (final jit in [false, true]) {
      final ps = Ps(jit: jit);
      addTearDown(ps.dispose);
      expect(ps.jit != null, jit);
      ps.setSram(Sram());
      ps.setBiosFiles([rom]);
      ps.reset();
      for (int frame = 0; frame < 30; frame++) {
        ps.runFrame(ps.scanlinesInFrame);
      }
      final r = ps.cpu.r;
      results.add([r[_s7], r[_s0], ps.bus.mem32[0x100000 >> 2]]);
    }
    final [interpreted, recompiled] = results;
    expect(interpreted[0], greaterThanOrEqualTo(29));
    expect(recompiled[0], interpreted[0]);
    // the loop runs as many times, within the clocks of a block
    expect((recompiled[1] - interpreted[1]).abs(), lessThan(1000));
    expect(recompiled[1], greaterThan(1000000));
  });
}
