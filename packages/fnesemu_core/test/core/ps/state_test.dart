import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/memory_card.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

int _r(int rs, int rt, int rd, int funct) =>
    rs << 21 | rt << 16 | rd << 11 | funct;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

const _k0 = 26, _t0 = 8, _t1 = 9, _t2 = 10, _s0 = 16, _s7 = 23;

/// an interrupt handler which acknowledges every interrupt and counts them in s7
final _handler = [
  _i(0x0f, 0, _k0, 0x1f80), // lui k0, 0x1f80
  _i(0x29, _k0, 0, 0x1070), // sh r0, 0x1070(k0): acknowledge
  _i(0x09, _s7, _s7, 1), // addiu s7, s7, 1
  0x40000000 | _k0 << 16 | 14 << 11, // mfc0 k0, epc
  0,
  _r(_k0, 0, 0, 0x08), // jr k0
  0x42000010, // rfe
];

/// a bios which installs [_handler], enables the vblank interrupt and counts in s0 in a loop that loads and stores ram
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

Uint8List _biosRom({int extra = 0}) {
  final rom = Uint8List(512 * 1024);
  final words = rom.buffer.asUint32List();
  words[0] = 0x08000000 | (0xbfc00100 >> 2) & 0x3ffffff; // j 0xbfc00100
  words.setAll(0x40, _bios());
  words[0x100] = extra;
  return rom;
}

Ps _ps(bool jit, {Uint8List? card2}) {
  final ps = Ps(jit: jit, memoryCard2Image: card2);
  addTearDown(ps.dispose);
  ps.setSram(Sram());
  ps.setBiosFiles([_biosRom()]);
  ps.reset();
  return ps;
}

void _frames(Ps ps, int n) {
  for (var i = 0; i < n; i++) {
    ps.runFrame(ps.scanlinesInFrame);
  }
}

void main() {
  for (final jit in [false, true]) {
    test('a restored ${jit ? 'JIT' : 'CPU'} PS continues like the original',
        () {
      if (jit && !JitRuntime.nativeSupported) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      final card2 = Uint8List.fromList(MemoryCard.blankImage)..[500] = 0x42;
      final original = _ps(jit, card2: card2);
      _frames(original, 3);
      original.gpu.frameBuffer[12345] = 0x77;
      original.spu.ram[300] = 0x5a;
      original.spu.voices[3].pitch = 0x1234;
      original.cpu.cop2.writeReg(0, 0x11223344);
      original.cpu.cop2.writeCtrl(31, 0x00010002);
      original.cdrom.mode = 0x55;
      original.cdrom.atv[1] = 0x33;
      original.timer.timers[2].target = 0x777;
      original.mdec.decoder.qtY[5] = 99;
      final state = original.saveState();
      _frames(original, 3);

      final restoredCard2 = Uint8List.fromList(MemoryCard.blankImage);
      final restored = _ps(jit, card2: restoredCard2);
      _frames(restored, 1);
      restored.bus.mem[0x2345] = 0x99;
      restored.loadState(state);
      expect(restoredCard2[500], 0x42);
      expect(restored.saveState(), state);
      _frames(restored, 3);
      expect(restored.cpu.r, original.cpu.r);
      expect([restored.cpu.pc, restored.cpu.clocks],
          [original.cpu.pc, original.cpu.clocks]);
      expect(restored.bus.mem32[0x100000 >> 2],
          original.bus.mem32[0x100000 >> 2]);
      expect(restored.gpu.frameBuffer[12345], 0x77);
      expect(restored.spu.ram[300], 0x5a);
      expect(restored.spu.voices[3].pitch, 0x1234);
      expect(restored.cpu.cop2.readReg(0), original.cpu.cop2.readReg(0));
      expect(restored.cpu.cop2.readCtrl(31), original.cpu.cop2.readCtrl(31));
      expect(restored.cdrom.mode, 0x55);
      expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
      expect(restored.dump(), original.dump());
      if (!jit) expect(restored.saveState(), original.saveState());
    });
  }

  test('a state of another BIOS or a truncated state is rejected without changing the core', () {
    final original = _ps(false);
    _frames(original, 2);
    final state = original.saveState();

    final other = Ps(jit: false);
    addTearDown(other.dispose);
    other.setSram(Sram());
    other.setBiosFiles([_biosRom(extra: 1)]);
    other.reset();
    _frames(other, 1);
    final otherBefore = other.saveState();
    expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
    expect(other.saveState(), otherBefore);

    final same = _ps(false);
    _frames(same, 1);
    final sameBefore = same.saveState();
    expect(
        () => same.loadState(Uint8List.sublistView(state, 0, state.length - 1)),
        throwsA(isA<StateMismatch>()));
    expect(same.saveState(), sameBefore);
    expect(() => same.loadState(Uint8List.fromList([...state, 0])),
        throwsA(isA<StateMismatch>()));
    expect(same.saveState(), sameBefore);
  });
}
