import 'dart:typed_data';

import 'mapper.dart';

mixin Sram on Mapper {
  late final Uint8List ram;

  int get chrRomSizeK;
  int get prgRomSizeK;
  int get sramSizeK => 8;

  @override
  void setRom(Uint8List chrRom, prgRom, Uint8List sram) {
    loadRom(chrRom, chrRomSizeK, prgRom, prgRomSizeK);

    ram = sram.isEmpty ? Uint8List(sramSizeK * 1024) : sram;
  }

  @override
  Uint8List exportSram() {
    return ram;
  }
}
