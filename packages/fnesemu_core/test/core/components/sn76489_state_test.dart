import 'dart:typed_data';

import 'package:fnesemu_core/src/components/sn76489/sn76489.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

void main() {
  Uint8List save(Sn76489 psg) {
    final writer = StateWriter('component', 1, 0);
    psg.saveState(writer);
    return writer.take();
  }

  void load(Sn76489 psg, Uint8List bytes) {
    final reader = StateReader(bytes, 'component', 1, 0);
    psg.loadState(reader);
    reader.end();
  }

  test('fresh instance continues identical stereo PCM and pending latch', () {
    final source = Sn76489(lfsr15: true)..setClockHz(4000000);
    source.stereo = 0x99;
    source.write8(0x85); // Tone 0 frequency latch, low nibble 5.
    source.write8(0x12); // Tone 0 frequency becomes 0x125.
    source.write8(0x92); // Tone 0 volume.
    source.write8(0xc7); // Tone 2 frequency latch, low nibble 7.
    source.write8(0x10); // Tone 2 frequency becomes 0x107.
    source.write8(0xe7); // Periodic noise, using tone 2 frequency.
    source.write8(0xf3); // Noise volume.

    final warmup = Float32List(39 * 2);
    source.renderStereoTo(warmup, 0, 39);
    source
        .write8(0x8b); // Leave a tone 0 frequency write latched but incomplete.
    final state = save(source);

    final restored = Sn76489();
    final tones = restored.tones;
    final tone0 = restored.tones[0];
    final noise = restored.noise;
    load(restored, state);

    expect(identical(restored.tones, tones), isTrue);
    expect(identical(restored.tones[0], tone0), isTrue);
    expect(identical(restored.noise, noise), isTrue);
    expect(save(restored), state);

    // Data bytes use the restored latch; both tone and noise remain active.
    source.write8(0x15);
    restored.write8(0x15);
    final expected = Float32List(512 * 2);
    final actual = Float32List(512 * 2);
    source.renderStereoTo(expected, 0, 512);
    restored.renderStereoTo(actual, 0, 512);

    expect(actual, expected);
    expect(actual.any((sample) => sample != 0), isTrue);
    expect(restored.elapsedSamples, source.elapsedSamples);
    expect(save(restored), save(source));
  }, testOn: 'vm');

  test('state rejects an unexpected section before changing PSG state', () {
    final psg = Sn76489()..write8(0x85);
    final before = save(psg);
    final writer = StateWriter('component', 1, 0)..section('other');

    expect(() => load(psg, writer.take()), throwsA(isA<StateMismatch>()));
    expect(save(psg), before);
  }, testOn: 'vm');
}
