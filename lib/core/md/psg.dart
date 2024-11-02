import 'dart:typed_data';

class Psg {
  Psg();

  Float32List get audioBuffer => Float32List(1000);

  int read8(int addr) {
    return 0;
  }

  write8(int addr, int data) {
    switch (addr) {
      case 0x7f11: // psg
        break;
    }
  }

  void reset() {}

  Float32List render(int clocks) {
    return audioBuffer;
  }
}
