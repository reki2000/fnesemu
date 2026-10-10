import 'dart:io';
import 'dart:typed_data';

import 'package:cdrom_image/format/chd/flac.dart';
import 'package:test/test.dart';

/// the frames of a .flac file: after "fLaC" and the metadata blocks
Uint8List frames(Uint8List flac) {
  var pos = 4;
  while (true) {
    final last = flac[pos] & 0x80 != 0;
    final length = flac[pos + 1] << 16 | flac[pos + 2] << 8 | flac[pos + 3];
    pos += 4 + length;
    if (last) return Uint8List.sublistView(flac, pos);
  }
}

void main() {
  // pcm: 11025 samples of 16-bit little-endian stereo. the .flac files are
  // made by the flac command with -0 (fixed predictors) and -8 (LPC), with
  // blocks of 2352 samples like CHD
  final pcm = File('test/fixtures/flac_pcm.raw').readAsBytesSync();
  final samples = pcm.length ~/ 4;

  for (final level in [0, 8]) {
    test('frames of flac -$level are decoded to big-endian samples', () {
      final flac = File('test/fixtures/flac_$level.flac').readAsBytesSync();
      final data = frames(flac);
      final (out, used) = FlacDecoder.decodeStereo16(data, samples);
      expect(used, data.length);
      // big-endian: the bytes of each sample are swapped from the pcm
      final expected = Uint8List(pcm.length);
      for (int i = 0; i < pcm.length; i += 2) {
        expected[i] = pcm[i + 1];
        expected[i + 1] = pcm[i];
      }
      expect(out, expected);
    });
  }

  test('decoding stops at the number of samples', () {
    final data = frames(File('test/fixtures/flac_8.flac').readAsBytesSync());
    // the first 2 blocks of 2352 samples
    final (out, used) = FlacDecoder.decodeStereo16(data, 2352 * 2);
    expect(out.length, 2352 * 2 * 4);
    expect(used, lessThan(data.length));
    final (rest, _) =
        FlacDecoder.decodeStereo16(Uint8List.sublistView(data, used), 2352);
    expect(rest.length, 2352 * 4);
  });

  test('truncated frames are an error', () {
    final data = frames(File('test/fixtures/flac_8.flac').readAsBytesSync());
    expect(
        () => FlacDecoder.decodeStereo16(
            Uint8List.sublistView(data, 0, 100), 2352),
        throwsFormatException);
  });
}
