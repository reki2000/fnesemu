extension IntExt on int {
  String get format3 {
    int column = 0;
    final r = List<String>.empty(growable: true);
    for (int val = abs(); column == 0 || val != 0; val ~/= 10) {
      if (column > 0 && column % 3 == 0) {
        r.add(',');
      }
      column++;

      r.add('0123456789'[val % 10]);
    }

    return "${this < 0 ? "-" : ""}${r.reversed.join()}";
  }

  String get hex8 => mask8.toRadixString(16).padLeft(2, "0");
  String get hex16 => mask16.toRadixString(16).padLeft(4, "0");
  String get hex24 => mask24.toRadixString(16).padLeft(6, "0");
  String get hex32 => mask32.toRadixString(16).padLeft(8, "0");
  String get hex => toRadixString(16);

  int get mask8 => this & 0xff;
  int get mask16 => this & 0xffff;
  int get mask24 => this & 0xffffff;
  int get mask32 => this & 0xffffffff;

  int mask(int size) => size == 1
      ? mask8
      : size == 2
          ? mask16
          : size == 4
              ? mask32
              : throw ("unreachable");

  int smask(int size) => size == 1
      ? mask8.rel8.mask32
      : size == 2
          ? mask16.rel16.mask32
          : size == 4
              ? mask32
              : throw ("unreachable");

  bool msb(int size) => size == 1
      ? bit7
      : size == 2
          ? bit15
          : size == 4
              ? bit31
              : throw ("unreachable");

  int scale(int size) => size == 1
      ? this
      : size == 2
          ? this << 1
          : size == 4
              ? this << 2
              : throw ("unreachable");

  int get bits => this == 1
      ? 8
      : this == 2
          ? 16
          : this == 4
              ? 32
              : throw ("unreachable");

  int get inc => this + 1;
  int get inc2 => this + 2;
  int get inc3 => this + 3;
  int get inc4 => this + 4;
  int get dec => this - 1;
  int get dec2 => this - 2;
  int get dec4 => this - 4;

  int get rel8 => bit7 ? this - 0x100 : this;
  int get rel16 => bit15 ? this - 0x10000 : this;
  int get rel24 => bit23 ? this - 0x1000000 : this;
  int get rel32 => bit31 ? this - 0x100000000 : this;

  int rel(int size) => size == 1
      ? rel8
      : size == 2
          ? rel16
          : size == 4
              ? rel32
              : throw ("unreachable");

  int setL8(int val) => this & ~0xff | val & 0xff;
  int setH8(int val) => this & ~0xff00 | val << 8 & 0xff00;
  int setL16(int val) => this & ~0xffff | val & 0xffff;
  int setH16(int val) => this & ~0xffff0000 | val << 16 & 0xffff0000;
  int setL(int val, int size) => size == 1
      ? setL8(val)
      : size == 2
          ? setL16(val)
          : size == 4
              ? val
              : throw ("unreachable");

  bool get bit0 => this & 0x01 != 0;
  bool get bit1 => this & 0x02 != 0;
  bool get bit2 => this & 0x04 != 0;
  bool get bit3 => this & 0x08 != 0;
  bool get bit4 => this & 0x10 != 0;
  bool get bit5 => this & 0x20 != 0;
  bool get bit6 => this & 0x40 != 0;
  bool get bit7 => this & 0x80 != 0;
  bool get bit8 => this & 0x100 != 0;
  bool get bit9 => this & 0x200 != 0;
  bool get bit10 => this & 0x400 != 0;
  bool get bit11 => this & 0x800 != 0;
  bool get bit12 => this & 0x1000 != 0;
  bool get bit13 => this & 0x2000 != 0;
  bool get bit14 => this & 0x4000 != 0;
  bool get bit15 => this & 0x8000 != 0;
  bool get bit16 => this & 0x10000 != 0;
  bool get bit17 => this & 0x20000 != 0;
  bool get bit18 => this & 0x40000 != 0;
  bool get bit19 => this & 0x80000 != 0;
  bool get bit20 => this & 0x100000 != 0;
  bool get bit21 => this & 0x200000 != 0;
  bool get bit22 => this & 0x400000 != 0;
  bool get bit23 => this & 0x800000 != 0;
  bool get bit24 => this & 0x1000000 != 0;
  bool get bit25 => this & 0x2000000 != 0;
  bool get bit26 => this & 0x4000000 != 0;
  bool get bit27 => this & 0x8000000 != 0;
  bool get bit28 => this & 0x10000000 != 0;
  bool get bit29 => this & 0x20000000 != 0;
  bool get bit30 => this & 0x40000000 != 0;
  bool get bit31 => this & 0x80000000 != 0;
}

extension IntClip on int {
  int clip(int min, int max) => this < min
      ? min
      : this > max
          ? max
          : this;
}
