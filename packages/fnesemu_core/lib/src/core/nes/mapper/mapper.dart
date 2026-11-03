import 'dart:typed_data';

import '../../../util/state.dart';
import '../../../util/uint8list.dart';

import 'mirror.dart';

abstract class Mapper {
  // Set ROM data from fixed-size ROM chunks (CHR: 8 KiB, PRG: 16 KiB by
  // default). SRAM is managed separately via `defaultSram()` and
  // `setSramRw(...)`.
  void setRom(Uint8List chrRom, Uint8List prgRom) {
    loadRom(chrRom, chrRomSizeK, prgRom, prgRomSizeK);
  }

  int get chrRomSizeK => 8;
  int get prgRomSizeK => 16;

  void init();

  // what the ppu is fetching, for mappers which map chr differently (MMC5)
  static const fetchBg = 0;
  static const fetchSprite = 1;
  static const fetchCpu = 2; // $2007 access
  int fetchPhase = fetchBg;

  // ppu registers $2000/$2001 written last
  int ppuCtl = 0;
  int ppuMask = 0;

  // true when the mapper has registers in the expansion area (0x4020-0x5fff)
  bool get hasExpansionArea => false;

  int read(int addr) => 0xff;
  void write(int addr, int data) {}

  int readVram(int addr) => 0xff;

  /// Side-effect-free inspection. Stateful mappers override this method.
  int peekVram(int addr, {bool sprite = false}) => readVram(addr);
  void writeVram(int addr, int data) {}

  // the cpu put addr on the ppu address bus through $2006 or $2007
  void ppuAddressBus(int addr) {}

  Uint8List defaultSram() => Uint8List(8 * 1024);

  void setSramRw(int Function(int) read, void Function(int, int) write) {
    readSram = read;
    writeSram = write;
  }

  int Function(int) readSram = (_) => 0xff;
  void Function(int, int) writeSram = (_, __) {};

  void handleClock(int cycles) {}

  Float32List handleApu(int cycles) => Float32List(0);

  /// Saves the mapper type and the shared fetch state, then the concrete mapper state written by [saveMapperState]; the type name lets a reader reject a state of another mapper before any register is applied.
  void saveState(StateWriter w) {
    w.section('nes-mapper');
    w.string(runtimeType.toString());
    w.ints([fetchPhase, ppuCtl, ppuMask]);
    saveMapperState(w);
  }

  /// Restores the state written by [saveState], checking the mapper type first.
  void loadState(StateReader s) {
    s.section('nes-mapper');
    final type = s.string();
    if (type != runtimeType.toString()) {
      throw StateMismatch('state of mapper $type, not $runtimeType');
    }
    final v = s.ints();
    if (v.length != 3) throw const StateMismatch('mapper state layout');
    fetchPhase = v[0];
    ppuCtl = v[1];
    ppuMask = v[2];
    loadMapperState(s);
  }

  /// Saves the concrete mapper registers and RAM; the base mapper has none.
  void saveMapperState(StateWriter w) {}

  /// Restores the state written by [saveMapperState].
  void loadMapperState(StateReader s) {}

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
