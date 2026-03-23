import 'dart:typed_data';

class Sram {
  List<int> data = [];
  String id = "";

  void init(String id, Uint8List initialData) {
    this.id = id;
    data = List.from(initialData);
  }

  void write8(int addr, int value) {
    if (addr < data.length) {
      data[addr] = value;
    }
  }

  int read8(int addr) => (addr < data.length) ? data[addr] : 0;
}
