import 'dart:typed_data';

class Psg {
  Psg();

  Float32List get audioBuffer => Float32List(1000);

  int read8() {
    return 0;
  }

  write8(int value) {}

  void reset() {}

  Float32List render(int clocks) {
    return audioBuffer;
  }
}
