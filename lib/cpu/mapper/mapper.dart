// Dart imports:
import 'dart:typed_data';

export 'mapper0.dart';
export 'mapper1.dart';
export 'mapper2.dart';
export 'mapper3.dart';
export 'mapper4.dart';

class Mapper {
  int read(int addr) {
    return 0xff;
  }

  void write(int addr, int data) {}

  int readVram(int addr) {
    return 0xff;
  }

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

  void onScanLine(void Function() irqCallback) {}
  void onVblank() {}
}
