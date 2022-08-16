// Dart imports:
import 'dart:typed_data';

export 'nrom.dart';
export 'mmc1.dart';
export 'uxrom.dart';
export 'cnrom.dart';
export 'mmc3.dart';
export 'vrc1.dart';
export 'vrc4.dart';

class Mapper {
  // banked rom data
  final List<Uint8List> chrRoms = [];
  final List<Uint8List> prgRoms = [];

  // load bank data from original sized rom data
  void loadRom({required int chrBankSizeK, required int prgBankSizeK}) {
    // resize chr roms from 8k to 4k
    chrRoms.clear();
    for (final char8k in _chrRoms8k) {
      for (int i = 0; i < 8 * 1024; i += chrBankSizeK * 1024) {
        chrRoms.add(char8k.sublist(i, i + chrBankSizeK * 1024));
      }
    }

    // resize prg roms from 16k to 8k
    prgRoms.clear();
    for (final prog16k in _prgRoms16k) {
      for (int i = 0; i < 16 * 1024; i += prgBankSizeK * 1024) {
        prgRoms.add(prog16k.sublist(i, i + prgBankSizeK * 1024));
      }
    }
  }

  // will be deprecated
  late final List<Uint8List> _prgRoms16k;
  // will be deprecated
  late final List<Uint8List> _chrRoms8k;

  void setRom(List<Uint8List> chrRom8k, List<Uint8List> prgRom16k) {
    _chrRoms8k = chrRom8k;
    _prgRoms16k = prgRom16k;
    loadRom(chrBankSizeK: 8, prgBankSizeK: 16);
  }

  int read(int addr) => 0xff;

  void write(int addr, int data) {}

  int readVram(int addr) => 0xff;

  void writeVram(int addr, int data) {}

  void init() {}

  void Function(bool) holdIrq = ((_) {});

  void Function(bool) mirrorVertical = ((_) {});

  String dump() => "rom: ";

  void handleClock(int cycles) {}
}
