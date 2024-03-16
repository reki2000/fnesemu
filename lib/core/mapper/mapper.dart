// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../../util.dart';
import 'cnrom.dart';
import 'mapper088.dart';
import 'namco118.dart';
import 'mirror.dart';
import 'mmc1.dart';
import 'mmc2.dart';
import 'mmc3.dart';
import 'mmc4.dart';
import 'namco163.dart';
import 'nrom.dart';
import 'uxrom.dart';
import 'vrc1.dart';
import 'vrc3.dart';
import 'vrc4.dart';

abstract class Mapper {
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
      case 10:
        return MapperMMC4();
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
      case 88:
        return Mapper088();
      case 206:
        return MapperNamco118();
      default:
        throw Exception("unimplemented mapper:$iNesMapper!");
    }
  }

  // banked rom data
  final List<Uint8List> chrRoms = [];
  final List<Uint8List> prgRoms = [];

  // utility to load bank data to chrRoms and prgRoms from original sized rom data
  void loadRom(List<Uint8List> chrRoms8k, int chrBankSizeK,
      List<Uint8List> prgRoms16k, int prgBankSizeK) {
    chrRoms
      ..clear()
      ..addAll(Uint8ListEx.join(chrRoms8k).split(chrBankSizeK * 1024));
    prgRoms
      ..clear()
      ..addAll(Uint8ListEx.join(prgRoms16k).split(prgBankSizeK * 1024));
  }

  // set rom data from fix-sized chunks of rom data (chr: 8k, prg: 16k)
  // sramLoaded: SRAM data, if empty, mapper should prepare a new one with proper size
  void setRom(List<Uint8List> chrRom8k, List<Uint8List> prgRom16k,
      Uint8List sramLoaded) {
    loadRom(chrRom8k, 8, prgRom16k, 16);
  }

  void Function(List<Uint8List>) saveSram = ((_) {});

  int read(int addr) => 0xff;

  void write(int addr, int data) {}

  int readVram(int addr) => 0xff;

  void writeVram(int addr, int data) {}

  void init();

  Uint8List exportSram() {
    return Uint8List(0);
  }

  void Function(bool) holdIrq = ((_) {});

  void Function(Mirror) mirror = ((_) {});

  String dump() => "rom: ";

  void handleClock(int cycles) {}
}
