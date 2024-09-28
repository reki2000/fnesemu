// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../../../util.dart';
import 'cnrom.dart';
import 'mapper088.dart';
import 'mirror.dart';
import 'mmc1.dart';
import 'mmc2.dart';
import 'mmc3.dart';
import 'mmc4.dart';
import 'namco118.dart';
import 'namco163.dart';
import 'nrom.dart';
import 'uxrom.dart';
import 'vrc1.dart';
import 'vrc3.dart';
import 'vrc4.dart';
import 'vrc6.dart';

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
      case 24:
        return MapperVrc6a();
      case 26:
        return MapperVrc6b();
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

  // set rom data from fix-sized chunks of rom data (chr: 8k, prg: 16k)
  // sramLoaded: SRAM data, if empty, mapper should prepare a new one with proper size
  void setRom(Uint8List chrRom, Uint8List prgRom, Uint8List sram) {
    loadRom(chrRom, chrRomSizeK, prgRom, prgRomSizeK);
  }

  int get chrRomSizeK => 8;
  int get prgRomSizeK => 16;

  void init();

  int read(int addr) => 0xff;
  void write(int addr, int data) {}

  int readVram(int addr) => 0xff;
  void writeVram(int addr, int data) {}

  Uint8List exportSram() => Uint8List(0);

  void handleClock(int cycles) {}

  void handleApu() {}
  Float32List apuBuffer() => Float32List(0);

  String dump() => "rom: ";

  void Function(List<Uint8List>) saveSram = ((_) {});

  void Function(bool) holdIrq = ((_) {});

  void Function(Mirror) mirror = ((_) {});

  // banked rom data
  final List<Uint8List> chrRoms = [];
  final List<Uint8List> prgRoms = [];

  // utility to load bank data to chrRoms and prgRoms from original sized rom data
  void loadRom(
      Uint8List chrRom, int chrBankSizeK, Uint8List prgRom, int prgBankSizeK) {
    chrRoms
      ..clear()
      ..addAll(chrRom.split(chrBankSizeK * 1024));
    prgRoms
      ..clear()
      ..addAll(prgRom.split(prgBankSizeK * 1024));
  }
}
