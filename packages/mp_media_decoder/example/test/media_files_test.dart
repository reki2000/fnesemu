import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp_media_decoder_example/media_files.dart';

void main() {
  test('splits access units before a parameter set or a new picture', () {
    final stream = Uint8List.fromList([
      0, 0, 0, 1, 0x67, 1, // SPS
      0, 0, 0, 1, 0x68, 2, // PPS
      0, 0, 1, 0x65, 0x88, 3, // IDR slice, first_mb 0
      0, 0, 1, 0x65, 0x40, 4, // IDR slice of the same picture
      0, 0, 1, 0x41, 0x9a, 5, // slice of a new picture
    ]);
    final units = h264AccessUnits(stream);
    expect(units.map((u) => u.length), [24, 6]);
  });

  test('reads the video of a PSMF movie', () {
    final file = Uint8List(0x1000);
    file.setAll(0, 'PSMF0014'.codeUnits);
    file.setAll(8, [0, 0, 0x08, 0]);
    // a pack with a video PES packet of 3 payload bytes
    file.setAll(0x800, [0, 0, 1, 0xba, ...List.filled(9, 0), 0xf8]);
    file.setAll(0x80e, [0, 0, 1, 0xe0, 0, 6, 0x81, 0, 0, 7, 8, 9]);
    expect(psmfVideo(file), [7, 8, 9]);
  });
}
