// Dart imports:
import 'dart:typed_data';

import 'package:fnesemu/util/uint8list.dart';

// Project imports:
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
    return switch (iNesMapper) {
      0 => MapperNROM(),
      1 => MapperMMC1(),
      2 => MapperUxROM(),
      3 => MapperCNROM(),
      4 => MapperMMC3(),
      9 => MapperMMC2(),
      10 => MapperMMC4(),
      75 => MapperVrc1(),
      21 => MapperVrc4a4c(),
      23 => MapperVrc4f4e(),
      25 => MapperVrc4b4d(),
      24 => MapperVrc6a(),
      26 => MapperVrc6b(),
      19 => MapperNamco163(),
      73 => MapperVrc3(),
      88 => Mapper088(),
      206 => MapperNamco118(),
      _ => throw Exception("unimplemented mapper:$iNesMapper!")
    };
  }

  // Set ROM data from fixed-size ROM chunks (CHR: 8 KiB, PRG: 16 KiB by
  // default). SRAM is managed separately via `defaultSram()` and
  // `setSramRw(...)`.
  void setRom(Uint8List chrRom, Uint8List prgRom) {
    loadRom(chrRom, chrRomSizeK, prgRom, prgRomSizeK);
  }

  int get chrRomSizeK => 8;
  int get prgRomSizeK => 16;

  void init();

  int read(int addr) => 0xff;
  void write(int addr, int data) {}

  int readVram(int addr) => 0xff;
  void writeVram(int addr, int data) {}

  Uint8List defaultSram() => Uint8List(8 * 1024);

  void setSramRw(int Function(int) read, void Function(int, int) write) {
    readSram = read;
    writeSram = write;
  }

  int Function(int) readSram = (_) => 0xff;
  void Function(int, int) writeSram = (_, __) {};

  void handleClock(int cycles) {}

  Float32List handleApu(int cycles) => Float32List(0);

  String dump() => "rom: ";

  void Function(bool) holdIrq = (_) {};

  void Function(Mirror) mirror = (_) {};

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
