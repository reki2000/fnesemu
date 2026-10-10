// the P and Q parity (ECC) of a mode 1 CD-ROM sector, from the definition in
// ECMA-130: Reed-Solomon codes over GF(2^8) with the polynomial
// x^8 + x^4 + x^3 + x^2 + 1, on the 2340 bytes from the header.
import 'dart:typed_data';

/// x * alpha
final _mulAlpha = Uint8List(256);

/// y where y * (alpha + 1) == x
final _divAlpha1 = Uint8List(256);

bool _ready = false;

void _init() {
  for (int i = 0; i < 256; i++) {
    final j = ((i << 1) ^ (i & 0x80 != 0 ? 0x11d : 0)) & 0xff;
    _mulAlpha[i] = j;
    _divAlpha1[i ^ j] = i;
  }
  _ready = true;
}

/// computes the parity bytes of the [majors] vectors of [minors] bytes. the
/// vector [major] starts at byte (major / 2) * [majorStep] + major % 2 from the
/// header and goes by [minorStep] bytes (wrapping around), and has the weights
/// alpha^(minors + 1 - i) in the second check equation. the two parity bytes
/// p0, p1 of each vector make sum(v) + p0 + p1 = 0 and
/// sum(alpha^(minors + 1 - i) v[i]) + alpha p0 + p1 = 0.
void _parity(Uint8List sector, int majors, int minors, int majorStep,
    int minorStep, int dest) {
  final size = majors * minors;
  for (int major = 0; major < majors; major++) {
    var index = (major >> 1) * majorStep + (major & 1);
    var weighted = 0; // sum(alpha^(minors - i) v[i]) by Horner's method
    var sum = 0;
    for (int minor = 0; minor < minors; minor++) {
      final v = sector[12 + index];
      index += minorStep;
      if (index >= size) index -= size;
      sum ^= v;
      weighted = _mulAlpha[weighted ^ v];
    }
    // p0 (alpha + 1) = sum + alpha * weighted, p1 = p0 + sum
    final p0 = _divAlpha1[_mulAlpha[weighted] ^ sum];
    sector[dest + major] = p0;
    sector[dest + majors + major] = p0 ^ sum;
  }
}

/// fills the P parity (0x81c..0x8c7) and the Q parity (0x8c8..0x92f) of a
/// mode 1 or mode 2 form 1 [sector] of 2352 bytes. the parity of mode 2 is
/// computed with the header (the address and the mode) as zero.
void generateEcc(Uint8List sector) {
  if (!_ready) _init();
  final mode2 = sector[15] == 2;
  final header = mode2 ? sector.sublist(12, 16) : null;
  if (mode2) sector.fillRange(12, 16, 0);
  _parity(sector, 86, 24, 2, 86, 0x81c);
  _parity(sector, 52, 43, 86, 88, 0x8c8);
  if (header != null) sector.setAll(12, header);
}
