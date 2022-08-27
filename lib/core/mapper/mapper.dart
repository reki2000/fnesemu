// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'cnrom.dart';
import 'mirror.dart';
import 'mmc1.dart';
import 'mmc2.dart';
import 'mmc3.dart';
import 'namco163.dart';
import 'nrom.dart';
import 'uxrom.dart';
import 'vrc1.dart';
import 'vrc3.dart';
import 'vrc4.dart';

class Mapper {
  static Mapper of(int iNesMapper) {
    switch (iNesMapper) {
      case 0:
        return MapperNROM();
      case 1:
        return MapperMMC1();
      case 2:
        return MapperUxROM();
      case 3:
        return MapperCNROM();
      case 4:
        return MapperMMC3();
      case 9:
        return MapperMMC2();
      case 75:
        return MapperVrc1();
      case 21:
        return MapperVrc4a4c();
      case 23:
        return MapperVrc4f4e();
      case 25:
        return MapperVrc4b4d();
      case 19:
        return MapperNamco163();
      case 73:
        return MapperVrc3();
      default:
        throw Exception("unimplemented mapper:$iNesMapper!");
    }
  }

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

  void Function(Mirror) mirror = ((_) {});

  String dump() => "rom: ";

  void handleClock(int cycles) {}
}
