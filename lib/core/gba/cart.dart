import 'dart:typed_data';

import '../sram.dart';
import 'backup.dart';

/// Game Pak: ROM + backup memory (SRAM / Flash / EEPROM, auto-detected).
class Cart {
  Uint8List rom = Uint8List(0);
  final backup = Backup();

  String title = "";
  String gameCode = "";

  void load(Uint8List body) {
    rom = body;
    if (body.length >= 0xc0) {
      title = String.fromCharCodes(body.sublist(0xa0, 0xac)).trim();
      gameCode = String.fromCharCodes(body.sublist(0xac, 0xb0));
    }
  }

  /// detect the backup type from the ROM and bind it to persistent storage.
  void initBackup(Sram storage) {
    final id = gameCode.isNotEmpty ? gameCode : "gba";
    backup.init(Backup.detect(rom), storage, id);
  }

  bool get hasEeprom => backup.isEeprom;

  int readRom8(int offset) {
    if (offset < rom.length) return rom[offset];
    // open-bus on GBA returns a value derived from the address; 0 is fine here.
    return 0;
  }

  int readSram(int offset) => backup.read8(offset);
  void writeSram(int offset, int data) => backup.write8(offset, data);
}
