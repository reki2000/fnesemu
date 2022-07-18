// Dart imports:
import 'dart:typed_data';

export 'nrom.dart';
export 'mmc1.dart';
export 'uxrom.dart';
export 'cnrom.dart';
export 'mmc3.dart';

class Mapper {
  int read(int addr) => 0xff;

  void write(int addr, int data) {}

  int readVram(int addr) => 0xff;

  void writeVram(int addr, int data) {}

  late final List<Uint8List> programRoms;
  late final List<Uint8List> charRoms;

  void loadProgramRom(List<Uint8List> roms) {
    programRoms = roms;
  }

  void loadCharRom(List<Uint8List> roms) {
    charRoms = roms;
  }

  void init() {}

  void Function(bool) holdIrq = ((_) {});

  void Function(bool) mirrorVertical = ((_) {});

  String dump() => "rom: ";
}
