extension IntExt on int {
  String get hex8 => toRadixString(16).padLeft(2, "0");
  String get hex16 => toRadixString(16).padLeft(4, "0");
  String get hex32 => toRadixString(16).padLeft(8, "0");

  int get mask8 => this & 0xff;
  int get mask16 => this & 0xffff;
  int get mask32 => this & 0xffffffff;

  int get inc => this + 1;
  int get dec => this - 1;

  int setL8(int val) => this & ~0xff | val & 0xff;
  int setH8(int val) => this & ~0xff00 | val << 8 & 0xff00;
  int setL16(int val) => this & ~0xffff | val & 0xffff;
  int setH16(int val) => this & ~0xffff0000 | val << 16 & 0xffff0000;
}
