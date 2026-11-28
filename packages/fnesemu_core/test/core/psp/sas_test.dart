import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/core/psp/sas.dart';
import 'package:test/test.dart';

const _vagAt = 0x08900000;
const _outAt = 0x08a00000;

/// Writes an ADPCM block of one repeated byte of sample nibbles.
void _block(PspMemory mem, int at, int header, int flags, int nibbles) {
  mem.write8(at, header);
  mem.write8(at + 1, flags);
  for (var i = 0; i < 14; i++) {
    mem.write8(at + 2 + i, nibbles);
  }
}

List<int> _left(PspMemory mem, int count) =>
    [for (var i = 0; i < count; i++) mem.read16(_outAt + i * 4).toSigned(16)];

void main() {
  late PspMemory mem;
  late PspSas sas;

  setUp(() {
    mem = PspMemory();
    sas = PspSas(mem);
    sas.init(64, 32, 0);
  });

  test('a voice plays its ADPCM block and then ends', () {
    // Shift 0, filter 0: a nibble of 1 decodes to 0x1000.
    _block(mem, _vagAt, 0x00, 0x01, 0x11);
    sas.setVoice(0, _vagAt, 16, 0);
    expect(sas.endFlags & 1, 1);
    sas.keyOn(0);
    expect(sas.endFlags & 1, 0);
    sas.mix(_outAt);
    final left = _left(mem, 64);
    // The output trails the source by one sample.
    expect(left[0], 0);
    expect(left.sublist(1, 28), everyElement(0x1000));
    expect(left.sublist(29), everyElement(0));
    expect(sas.endFlags & 1, 1);
  });

  test('the filter adds the weighted previous samples', () {
    // Filter 1 adds 60/64 of the previous sample: 0x1000, 0x1f00, ...
    _block(mem, _vagAt, 0x10, 0x00, 0x11);
    sas.setVoice(0, _vagAt, 16, 0);
    sas.keyOn(0);
    sas.mix(_outAt);
    final left = _left(mem, 3);
    expect(left[1], 0x1000);
    expect(left[2], 0x1000 + (0x1000 * 60 + 32 >> 6));
  });

  test('a block with the repeat flag loops to the loop start', () {
    _block(mem, _vagAt, 0x00, 0x04, 0x11);
    _block(mem, _vagAt + 16, 0x00, 0x03, 0x22);
    sas.setVoice(0, _vagAt, 32, 0);
    sas.keyOn(0);
    sas.mix(_outAt);
    sas.mix(_outAt);
    expect(sas.endFlags & 1, 0);
    expect(_left(mem, 64).toSet(), {0x1000, 0x2000});
  });

  test('the volume and the pitch scale the output', () {
    _block(mem, _vagAt, 0x00, 0x00, 0x22);
    sas.setVoice(0, _vagAt, 16, 0);
    sas.setVolume(0, 0x800, -0x1000);
    sas.setPitch(0, 0x800);
    sas.keyOn(0);
    sas.mix(_outAt);
    // At half pitch the first sample arrives on the second output and
    // the next output interpolates halfway to it.
    expect(_left(mem, 4), [0, 0, 0x800, 0x1000]);
    expect(mem.read16(_outAt + 3 * 4 + 2).toSigned(16), -0x2000);
  });

  test('a key off releases the envelope and ends the voice', () {
    _block(mem, _vagAt, 0x00, 0x00, 0x11);
    sas.setVoice(0, _vagAt, 16, 1);
    sas.setAdsr(0, 8, [0, 0, 0, PspSas.envelopeMax ~/ 4]);
    sas.keyOn(0);
    sas.mix(_outAt);
    expect(sas.envelopeHeight(0), PspSas.envelopeMax);
    sas.keyOff(0);
    sas.mix(_outAt);
    expect(sas.envelopeHeight(0), 0);
    expect(sas.endFlags & 1, 1);
  });

  test('a simple ADSR sets the sustain level from its low bits', () {
    _block(mem, _vagAt, 0x00, 0x00, 0x11);
    sas.setVoice(0, _vagAt, 16, 1);
    // Attack rate 0, decay rate 0, sustain level 7 (half), sustain rate
    // 0x7f with a linear increase, which barely moves.
    sas.setSimpleAdsr(0, 0x0007, 0x1fc0);
    sas.keyOn(0);
    sas.mix(_outAt);
    expect(sas.envelopeHeight(0), closeTo(PspSas.envelopeMax ~/ 2, 64));
  });
}
