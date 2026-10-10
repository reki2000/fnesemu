// the general purpose decompressors used by the CHD codecs
import 'dart:typed_data';

import 'package:archive/archive.dart' show Inflate, InputStream;
// not exported by archive, which is pinned to a minor version in pubspec.yaml
// ignore: implementation_imports
import 'package:archive/src/lzma/lzma_decoder.dart';

/// decompresses a raw deflate stream (without a zlib header) into [length]
/// bytes
Uint8List inflate(Uint8List src, int length) {
  final out = Inflate(src, length).getBytes();
  return _exact(out, length);
}

/// decompresses a raw LZMA stream (without a header) into [length] bytes,
/// with the properties CHD uses: lc=3, lp=0, pb=2
Uint8List lzmaDecode(Uint8List src, int length) =>
    _exact(LzmaDecoder().decode(InputStream(src), length), length);

Uint8List _exact(List<int> out, int length) {
  if (out.length < length) {
    throw FormatException('chd: ${out.length} bytes decompressed, '
        'expected $length');
  }
  final bytes = out is Uint8List ? out : Uint8List.fromList(out);
  return bytes.length == length
      ? bytes
      : Uint8List.sublistView(bytes, 0, length);
}
