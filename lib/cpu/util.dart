const screenWidth = 256;
const screenHeight = 240;

String hex8(int x) {
  return x.toRadixString(16).padLeft(2, "0");
}

String hex16(int x) {
  return x.toRadixString(16).padLeft(4, "0");
}

int flip8(int p0) {
  final p = ((p0 & 0x55) << 1) | ((p0 & 0xaa) >> 1);
  final pp = ((p & 0x33) << 2) | ((p & 0xcc) >> 2);
  return ((pp & 0x0f) << 4) | ((pp & 0xf0) >> 4);
}
