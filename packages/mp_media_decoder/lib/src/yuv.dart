import 'dart:typed_data';

/// Converts a picture of 8-bit planes with 2x2 subsampled chroma (YUV 4:2:0)
/// to RGBA pixels with the BT.601 matrix: video range unless [fullRange].
/// The planes are read through [luma], [cb] and [cr] at rows
/// [lumaStride] and [chromaStride] bytes apart; [chromaStep] is the byte
/// step between chroma samples of a row (2 for interleaved NV12 planes).
Uint32List yuv420ToRgba(int width, int height, Uint8List luma, int lumaStride,
    Uint8List cb, Uint8List cr, int chromaStride,
    {int chromaStep = 1, bool fullRange = false}) {
  final out = Uint32List(width * height);
  // fixed point with 16 fraction bits
  final yScale = fullRange ? 65536 : 76309; // 255 / 219
  final yBase = fullRange ? 0 : 16;
  final crR = fullRange ? 91881 : 104597;
  final cbG = fullRange ? 22554 : 25675;
  final crG = fullRange ? 46802 : 53279;
  final cbB = fullRange ? 116130 : 132201;
  for (var y = 0; y < height; y++) {
    final lumaRow = y * lumaStride;
    final chromaRow = (y >> 1) * chromaStride;
    final outRow = y * width;
    for (var x = 0; x < width; x++) {
      final c = chromaRow + (x >> 1) * chromaStep;
      final l = (luma[lumaRow + x] - yBase) * yScale;
      final u = cb[c] - 128, v = cr[c] - 128;
      final r = _clamp((l + crR * v + 32768) >> 16);
      final g = _clamp((l - cbG * u - crG * v + 32768) >> 16);
      final b = _clamp((l + cbB * u + 32768) >> 16);
      out[outRow + x] = 0xff000000 | b << 16 | g << 8 | r;
    }
  }
  return out;
}

int _clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
