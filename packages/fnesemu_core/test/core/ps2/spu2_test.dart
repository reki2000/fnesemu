import 'package:fnesemu_core/src/core/ps2/iop/spu2.dart';
import 'package:test/test.dart';

const _core1 = 0x400;

void _w(Spu2 s, int offset, int value) => s.write(Spu2.base + offset, 2, value);
int _r(Spu2 s, int offset) => s.read(Spu2.base + offset, 2);

/// writes an ADPCM block of 28 samples of [nibble] with [flags] at [at]
void _block(Spu2 s, int at, int flags, int nibble) {
  s.ram[at] = flags << 8; // shift 0, filter 0
  for (var i = 1; i < 8; i++) {
    s.ram[at + i] = nibble * 0x1111;
  }
}

void main() {
  test('the transfer port writes sound memory at TSA', () {
    final s = Spu2();
    _w(s, 0x1a8, 0x1);
    _w(s, 0x1aa, 0x2345);
    _w(s, 0x1ac, 0xabcd);
    _w(s, 0x1ac, 0x1234);
    expect(s.ram[0x12345], 0xabcd);
    expect(s.ram[0x12346], 0x1234);
    expect(_r(s, 0x1aa), 0x2347);
  });

  test('a voice plays a block, sets ENDX and stops without repeat', () {
    final s = Spu2();
    _block(s, 0x5000, 1, 3); // end, no repeat
    _w(s, 0x760, 0x3fff); // core 0 MVOLL
    _w(s, 0x762, 0x3fff); // core 0 MVOLR
    _w(s, 0x788, 0x3fff); // core 1 MVOLL: core 0 mixes into core 1
    _w(s, 0x78a, 0x3fff); // core 1 MVOLR
    _w(s, 0x188, 1); // VMIXL voice 0
    _w(s, 0x190, 1); // VMIXR voice 0
    _w(s, 0x000, 0x3fff); // VOLL
    _w(s, 0x002, 0x3fff); // VOLR
    _w(s, 0x004, 0x1000); // pitch 1.0
    _w(s, 0x006, 0x00ff); // attack as fast as possible, sustain level max
    _w(s, 0x008, 0x0000);
    _w(s, 0x1c0, 0); // SSA
    _w(s, 0x1c2, 0x5000);
    _w(s, 0x1a0, 1); // KON voice 0
    s.advance(Spu2.clocksPerSample * 10);
    expect(_r(s, 0x00a), greaterThan(0), reason: 'ENVX');
    expect(s.output[2 * 9], greaterThan(0));
    s.advance(Spu2.clocksPerSample * 40);
    expect(_r(s, 0x340) & 1, 1, reason: 'ENDX');
    expect(s.cores[0].voices[0].phase, Spu2Voice.off);
  });

  test('a voice read at the interrupt address raises the interrupt', () {
    final s = Spu2();
    var raised = 0;
    s.onInterrupt = () => raised++;
    _block(s, 0x6000, 3, 1);
    _w(s, _core1 + 0x19c, 0);
    _w(s, _core1 + 0x19e, 0x6004);
    _w(s, _core1 + 0x19a, 0x8040); // interrupt enable
    _w(s, 0x1c2, 0x6000);
    _w(s, 0x004, 0x1000);
    _w(s, 0x1a0, 1);
    s.advance(Spu2.clocksPerSample);
    expect(raised, 1);
    expect(_r(s, 0x7c2), 8);
    _w(s, _core1 + 0x19a, 0x8000);
    expect(_r(s, 0x7c2), 0);
  });

  test('AutoDMA takes a block for every 256 samples played', () {
    final s = Spu2();
    _w(s, 0x1b0, 1);
    expect(s.autoDma(0), isTrue);
    s.admaBlock(0, List.filled(512, 0x100));
    s.admaBlock(0, List.filled(512, 0x200));
    expect(s.admaWants(0), isFalse);
    s.advance(Spu2.clocksPerSample * 256);
    expect(s.admaWants(0), isTrue);
    expect(s.ram[0x2000], 0x100);
    expect(s.ram[0x2300], 0x200);
  });
}
