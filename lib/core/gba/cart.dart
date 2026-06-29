import 'dart:typed_data';

/// Game Pak: ROM + save memory.
/// Stage 1 supports plain ROM reads and a 64KB SRAM region.
/// Flash / EEPROM auto-detection comes in Stage 6.
class Cart {
  Uint8List rom = Uint8List(0);
  final sram = Uint8List(0x10000); // 64KB max (covers SRAM/Flash 64K)

  String title = "";
  String gameCode = "";

  void load(Uint8List body) {
    rom = body;
    if (body.length >= 0xc0) {
      title = String.fromCharCodes(body.sublist(0xa0, 0xac)).trim();
      gameCode = String.fromCharCodes(body.sublist(0xac, 0xb0));
    }
  }

  int readRom8(int offset) {
    if (offset < rom.length) return rom[offset];
    // open-bus on GBA returns a value derived from the address; 0 is fine here.
    return 0;
  }

  int readSram(int offset) => sram[offset & 0xffff];
  void writeSram(int offset, int data) => sram[offset & 0xffff] = data & 0xff;
}
