import 'package:fnesemu/util/int.dart';
// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../rom/snes_file.dart';
import 'apu.dart';
import 'cpu.dart';
import 'dma.dart';
import 'pad.dart';
import 'ppu.dart';

/// 24-bit address bus for the SNES.
///
/// WRAM + ROM (LoROM/HiROM) + SRAM are functional. $2100-$213F routes to the
/// PPU's register file (see ppu.dart), $4300-$437F + $420B/$420C route to
/// the DMA/HDMA controller (see dma.dart), and $2140-2143 route to the
/// audio unit (see apu.dart). $4200-$42FF models NMI, the DMA triggers,
/// auto-joypad 1, and the multiply/divide unit; the rest (H/V timer IRQ,
/// programmable I/O, manual joypad) is still a scratch stub.
class Bus {
  late final Cpu cpu;
  late final Ppu ppu;
  late final Dma dma;
  late final Apu apu;

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

  /// true while the current scanline is in its horizontal blanking period
  /// (set up by the owning core, which knows the scanline timing).
  bool Function() inHBlank = () => false;

  void setRom(SnesFile file) {
    rom = file.rom;
    mapping = file.mapping;

    // round rom size to power of two for cheap masking
    var size = 0x8000;
    while (size < rom.length) {
      size <<= 1;
    }
    _romMask = size - 1;

    sram = Uint8List(file.sramSize);
    _sramMask = file.sramSize == 0 ? 0 : file.sramSize - 1;

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
      return wram[bank.mask1.shl16 | page];
    }

    // system banks $00-$3F / $80-$BF
    if (bank.mask7 < 0x40) {
      if (page < 0x2000) return wram[page]; // low 8KB wram mirror
      if (page < 0x6000) return _readMmio(page);
      if (page < 0x8000) {
        final off = _sramOffset(bank, page);
        return off < 0 ? 0 : sramRead(off);
      }
      return _readRom(bank, page); // $8000-$FFFF
    }

    // banks $40-$7D / $C0-$FF: rom (LoROM sram in $70-$7D/$F0-$FF low half)
    final off = _sramOffset(bank, page);
    if (off >= 0) return sramRead(off);
    return _readRom(bank, page);
  }

  int _readRom(int bank, int page) {
    if (mapping == SnesMapping.hiRom) {
      final a = bank.mask6.shl16 | page;
      return rom[a & _romMask];
    }
    // LoROM: 32KB per bank at $8000-$FFFF
    final a = bank.mask7.shl15 | page.mask15;
    return rom[a & _romMask];
  }

  /// sram offset for (bank,page), or -1 if that address isn't sram.
  /// LoROM: banks $70-$7D / $F0-$FF, $0000-$7FFF (32KB per bank).
  /// HiROM: banks $20-$3F / $A0-$BF, $6000-$7FFF (8KB per bank).
  int _sramOffset(int bank, int page) {
    if (sram.isEmpty) return -1;
    final b = bank.mask7;
    if (mapping == SnesMapping.hiRom) {
      if (b < 0x20 || b >= 0x40 || page < 0x6000 || page >= 0x8000) return -1;
      return ((b - 0x20).shl13 | page.mask13) & _sramMask;
    }
    if (b < 0x70 || page >= 0x8000) return -1; // $7E/$7F (wram) never get here
    return (((b - 0x70).shl15) | page) & _sramMask;
  }

  // ----------------------------------------------------------------- write
  void write(int addr, int data) {
    addr &= 0xffffff;
    data &= 0xff;
    final bank = addr.shr16;
    final page = addr.mask16;

    if (bank == 0x7e || bank == 0x7f) {
      wram[bank.mask1.shl16 | page] = data;
      return;
    }

    if (bank.mask7 < 0x40) {
      if (page < 0x2000) {
        wram[page] = data;
        return;
      }
      if (page < 0x6000) {
        _writeMmio(page, data);
        return;
      }
      if (page < 0x8000) {
        final off = _sramOffset(bank, page);
        if (off >= 0) sramWrite(off, data);
        return;
      }
      return; // rom is read-only
    }

    // $40-$7D / $C0-$FF: rom is read-only, except LoROM sram
    final off = _sramOffset(bank, page);
    if (off >= 0) sramWrite(off, data);
  }

  // ------------------------------------------------------------ MMIO
  int _readMmio(int page) {
    if (page >= 0x2100 && page < 0x2140) return ppu.read(page);
    if (page >= 0x2140 && page < 0x2144) return apu.mainCpuRead(page - 0x2140);
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
        return _hvbjoy | (inHBlank() ? 0x40 : 0);
      case 0x4214: // RDDIVL
        return _divResult.mask8;
      case 0x4215: // RDDIVH
        return _divResult.shr8;
      case 0x4216: // RDMPYL (product or remainder)
        return _mulResult.mask8;
      case 0x4217: // RDMPYH
        return _mulResult.shr8;
      case 0x4218: // JOY1L
        return pad.state1.mask8;
      case 0x4219: // JOY1H
        return pad.state1.shr8;
      default:
        return _mmio[page.mask10];
    }
  }

  void _writeMmio(int page, int data) {
    if (page >= 0x2100 && page < 0x2140) {
      ppu.write(page, data);
      return;
    }
    if (page >= 0x2140 && page < 0x2144) {
      apu.mainCpuWrite(page - 0x2140, data);
      return;
    }
    if (page >= 0x4300 && page < 0x4380) {
      dma.write(page, data);
      return;
    }
    if (page == 0x4200) _nmiEnabled = data.bit7; // NMITIMEN
    if (page == 0x4203) {
      // WRMPYB: unsigned 8x8 multiply of WRMPYA * WRMPYB
      _mulResult = _mmio[0x4202 & 0x3ff] * data;
    }
    if (page == 0x4206) {
      // WRDIVB: unsigned 16/8 divide of WRDIVH:WRDIVL by WRDIVB
      final dividend = _mmio[0x4204 & 0x3ff] | _mmio[0x4205 & 0x3ff].shl8;
      if (data == 0) {
        _divResult = 0xffff;
        _mulResult = dividend;
      } else {
        _divResult = dividend ~/ data;
        _mulResult = dividend % data;
      }
    }
    if (page == 0x420b) dma.runDma(data); // MDMAEN: trigger general DMA now
    if (page == 0x420c) dma.hdmaEnableMask = data; // HDMAEN
    _mmio[page.mask10] = data;
  }

  // ------------------------------------------------------------- interrupts
  bool _nmiFlag = false;
  bool _nmiEnabled = false;
  int _hvbjoy = 0;

  int _mulResult = 0; // $4216/4217: product, or division remainder
  int _divResult = 0; // $4214/4215: division quotient

  void enterVBlank() {
    _hvbjoy |= 0x80;
    _nmiFlag = true;
    if (_nmiEnabled) cpu.onNmi();
  }

  void leaveVBlank() {
    _hvbjoy &= ~0x80;
    _nmiFlag = false; // RDNMI is also cleared when vblank ends
  }

  void onReset() {
    cpu.reset();
  }
}
