// the general purpose decompressors used by the CHD codecs, from archive
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show Inflate, InputMemoryStream, LzmaDecoder, ZstdDecoder;

/// decompresses a raw deflate stream (without a zlib header) into [length]
/// bytes
Uint8List inflate(Uint8List src, int length) =>
    _exact(Inflate(src, uncompressedSize: length).getBytes(), length);

/// decompresses a raw LZMA stream (without a header) into [length] bytes,
/// with the properties CHD uses: lc=3, lp=0, pb=2 (the decoder's defaults)
Uint8List lzmaDecode(Uint8List src, int length) =>
    _exact(LzmaDecoder().decode(InputMemoryStream(src), length), length);

/// decompresses a zstd frame into [length] bytes
Uint8List zstdDecode(Uint8List src, int length) =>
    _exact(ZstdDecoder().decodeBytes(src, throwOnError: true), length);

Uint8List _exact(Uint8List out, int length) {
  if (out.length < length) {
    throw FormatException('chd: ${out.length} bytes decompressed, '
        'expected $length');
  }
  return out.length == length ? out : Uint8List.sublistView(out, 0, length);
}
