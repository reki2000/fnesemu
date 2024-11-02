class Psg {
  Psg();

  int read8(int addr) {
    return 0;
  }

  write8(int addr, int data) {
    switch (addr) {
      case 0x7f11: // psg
        break;
    }
  }
}
