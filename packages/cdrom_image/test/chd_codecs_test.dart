import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cdrom_image/format/chd/codecs.dart';
import 'package:test/test.dart';

void main() {
  test('a raw deflate stream is inflated', () {
    final random = Random(1);
    final data = Uint8List.fromList([
      for (int i = 0; i < 20000; i++)
        i % 7 == 0 ? random.nextInt(256) : i & 0x3f
    ]);
    final comp = Uint8List.fromList(ZLibEncoder(raw: true).convert(data));
    expect(inflate(comp, data.length), data);
  });

  test('a raw LZMA stream is decoded', () {
    // made by python lzma.compress(FORMAT_RAW, LZMA1 lc=3 lp=0 pb=2)
    final comp = File('test/fixtures/lzma_raw.bin').readAsBytesSync();
    final plain = File('test/fixtures/lzma_plain.bin').readAsBytesSync();
    expect(lzmaDecode(comp, plain.length), plain);
  });

  test('a short stream is an error', () {
    final comp =
        Uint8List.fromList(ZLibEncoder(raw: true).convert(Uint8List(100)));
    expect(() => inflate(comp, 200), throwsFormatException);
  });
}
