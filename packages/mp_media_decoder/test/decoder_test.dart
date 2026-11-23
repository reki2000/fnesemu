import 'dart:typed_data';

import 'package:mp_media_decoder/mp_media_decoder.dart';
import 'package:test/test.dart';

import 'stream_data.dart';

/// Splits an Annex B stream into access units: a unit ends before the next
/// parameter set, SEI or slice that follows a slice.
List<Uint8List> _units(List<int> stream) {
  final starts = <int>[];
  for (var i = 0; i + 3 < stream.length; i++) {
    if (stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1) {
      starts.add(i > 0 && stream[i - 1] == 0 ? i - 1 : i);
      i += 2;
    }
  }
  final units = <Uint8List>[];
  var unitStart = 0;
  var sawSlice = false;
  for (final start in starts) {
    final header = stream[stream.indexOf(1, start) + 1];
    final type = header & 0x1f;
    final isSlice = type == 1 || type == 5;
    if (sawSlice && start > unitStart) {
      units.add(Uint8List.fromList(stream.sublist(unitStart, start)));
      unitStart = start;
      sawSlice = false;
    }
    if (isSlice) sawSlice = true;
  }
  units.add(Uint8List.fromList(stream.sublist(unitStart)));
  return units;
}

void main() {
  final decoders = MediaDecoders.open();

  test('decodes H.264 to RGBA pictures', () {
    final decoder = decoders.openH264()!;
    final units = _units(testStream);
    expect(units, hasLength(2));
    final picture = decoder.decode(units[0]);
    expect(picture, isNotNull);
    expect(picture!.width, 64);
    expect(picture.height, 48);
    for (final (x, y, r, g, b) in testPixels) {
      final pixel = picture.pixels[y * 64 + x];
      expect(pixel & 0xff, closeTo(r, 6), reason: 'red at $x,$y');
      expect(pixel >> 8 & 0xff, closeTo(g, 6), reason: 'green at $x,$y');
      expect(pixel >> 16 & 0xff, closeTo(b, 6), reason: 'blue at $x,$y');
      expect(pixel >>> 24, 0xff);
    }
    expect(decoder.decode(units[1]), isNotNull);
    decoder.close();
  }, skip: decoders.supportsH264 ? false : 'no H.264 decoder here');

  test('opens an ATRAC3plus stream', () {
    final decoder = decoders.openAtrac3plus(blockAlign: 0x230);
    expect(decoder, isNotNull);
    decoder!.close();
  },
      skip: decoders.supportsAtrac3plus
          ? false
          : 'no libavcodec with ATRAC3plus here');

  test('opens an ATRAC3 stream with the format extension of its file', () {
    // a stereo stream of 384-byte frames, as a WAVE file describes it
    final decoder = decoders.openAtrac3(
        blockAlign: 384,
        codecData:
            Uint8List.fromList([1, 0, 0, 16, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]));
    expect(decoder, isNotNull);
    decoder!.close();
  }, skip: decoders.supportsAtrac3 ? false : 'no mmd_libav with ATRAC3 here');
}
