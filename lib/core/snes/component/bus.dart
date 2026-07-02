import 'package:fnesemu/util/int.dart';
// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../rom/snes_file.dart';
import 'cpu.dart';
import 'dma.dart';
import 'pad.dart';
import 'ppu.dart';

/// 24-bit address bus for the SNES.
///
/// WRAM + ROM (LoROM/HiROM) + SRAM are functional. $2100-$213F routes to the
/// PPU's register file (see ppu.dart) and $4300-$437F + $420B/$420C route to
/// the DMA/HDMA controller (see dma.dart). The SPC700 audio link
/// ($2140-2143) and most of $4200-$42FF besides NMI/DMA triggers are still
/// a scratch stub.
class Bus {
  late final Cpu cpu;
  late final Ppu ppu;
  late final Dma dma;

  final pad = SnesPad();

  // 128KB work ram ($7E0000-$7FFFFF, mirrored low 8KB in system area)
  final wram = Uint8List(0x20000);

  Uint8List rom = Uint8List(0x8000);
  int _romMask = 0x7fff;
  SnesMapping mapping = SnesMapping.loRom;

  Uint8List sram = Uint8List(0);
  int _sramMask = 0;

  // open-bus scratch for unimplemented MMIO
  final _mmio = Uint8List(0x400);

  int Function(int) sramRead = (_) => 0;
  void Function(int, int) sramWrite = (_, __) {};

  void setRom(SnesFile file) {
    rom = file.rom;
    mapping = file.mapping;

    // round rom size to power of two for cheap masking
    var size = 0x8000;
    while (size < rom.length) {
      size <<= 1;
    }
    _romMask = size - 1;

    final s = file.sramSize == 0 ? 0x8000 : file.sramSize;
    sram = Uint8List(s);
    _sramMask = s - 1;

    // default volatile backing (battery-backed games overwrite these via
    // sramRead/sramWrite once the Sram wrapper is initialized)
    sramRead = (addr) => sram[addr & _sramMask];
    sramWrite = (addr, v) => sram[addr & _sramMask] = v.mask8;
  }

  // ------------------------------------------------------------------ read
  int read(int addr) {
    addr &= 0xffffff;
    final bank = addr.shr16;
    final page = addr.mask16;

    // $7E-$7F: full WRAM
    if (bank == 0x7e || bank == 0x7f) {
      return wram[(bank & 1).shl16 | page];
    }

    // system banks $00-$3F / $80-$BF
    if ((bank & 0x7f) < 0x40) {
      if (page < 0x2000) return wram[page]; // low 8KB wram mirror
      if (page < 0x6000) return _readMmio(page);
      if (page < 0x8000) return _readSram(bank, page);
      return _readRom(bank, page); // $8000-$FFFF
    }

    // banks $40-$7D / $C0-$FF: rom (and sram for hi banks)
    return _readRom(bank, page);
  }

  int _readRom(int bank, int page) {
    if (mapping == SnesMapping.hiRom) {
      final a = ((bank & 0x3f).shl16) | page;
      return rom[a & _romMask];
    }
    // LoROM: 32KB per bank at $8000-$FFFF
    final a = ((bank & 0x7f).shl15) | (page & 0x7fff);
    return rom[a & _romMask];
  }

  int _readSram(int bank, int page) {
    if (sram.isEmpty) return 0;
    // LoROM sram in banks $70-$7D / $F0-$FF, $0000-$7FFF.
    // TODO(milestone 3): HiROM sram is a flat region in banks $20-$3F /
    // $A0-$BF and needs its own mapping; not modeled yet.
    final off = (((bank & 0x7f) - 0x70).max(0).shl15) | (page & 0x7fff);
    return sramRead(off);
  }

  // ----------------------------------------------------------------- write
  void write(int addr, int data) {
    addr &= 0xffffff;
    data &= 0xff;
    final bank = addr.shr16;
    final page = addr.mask16;

    if (bank == 0x7e || bank == 0x7f) {
      wram[(bank & 1).shl16 | page] = data;
      return;
    }

    if ((bank & 0x7f) < 0x40) {
      if (page < 0x2000) {
        wram[page] = data;
        return;
      }
      if (page < 0x6000) {
        _writeMmio(page, data);
        return;
      }
      if (page < 0x8000) {
        _writeSram(bank, page, data);
        return;
      }
      return; // rom is read-only
    }
    // $40-$7D / $C0-$FF rom: read-only
  }

  void _writeSram(int bank, int page, int data) {
    if (sram.isEmpty) return;
    final off = (((bank & 0x7f) - 0x70).max(0).shl15) | (page & 0x7fff);
    sramWrite(off, data);
  }

  // ------------------------------------------------------------ MMIO
  int _readMmio(int page) {
    if (page >= 0x2100 && page < 0x2140) return ppu.read(page);
    if (page >= 0x4300 && page < 0x4380) return dma.read(page);
    switch (page) {
      case 0x4210: // RDNMI: bit7 = vblank nmi flag (read-clears)
        {
          final v = _nmiFlag ? 0x82 : 0x02;
          _nmiFlag = false;
          return v;
        }
      case 0x4211: // TIMEUP irq flag
        return 0;
      case 0x4212: // HVBJOY: vblank/hblank/auto-joy status
        return _hvbjoy;
      case 0x4218: // JOY1L
        return pad.state1.mask8;
      case 0x4219: // JOY1H
        return pad.state1.shr8;
      default:
        return _mmio[page & 0x3ff];
    }
  }

  void _writeMmio(int page, int data) {
    if (page >= 0x2100 && page < 0x2140) {
      ppu.write(page, data);
      return;
    }
    if (page >= 0x4300 && page < 0x4380) {
      dma.write(page, data);
      return;
    }
    if (page == 0x4200) _nmiEnabled = data.bit7; // NMITIMEN
    if (page == 0x420b) dma.runDma(data); // MDMAEN: trigger general DMA now
    if (page == 0x420c) dma.hdmaEnableMask = data; // HDMAEN
    _mmio[page & 0x3ff] = data;
  }

  // ------------------------------------------------------------- interrupts
  bool _nmiFlag = false;
  bool _nmiEnabled = false;
  int _hvbjoy = 0;

  void enterVBlank() {
    _hvbjoy |= 0x80;
    _nmiFlag = true;
    if (_nmiEnabled) cpu.onNmi();
  }

  void leaveVBlank() {
    _hvbjoy &= ~0x80;
  }

  void onReset() {
    cpu.reset();
  }
}
