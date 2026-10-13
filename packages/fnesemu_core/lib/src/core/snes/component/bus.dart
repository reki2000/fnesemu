import 'dart:typed_data';

import '../../../util/int.dart';

import '../rom/snes_file.dart';
import 'apu.dart';
import 'cpu.dart';
import 'cpu_bus.dart';
import 'cx4.dart';
import 'dma.dart';
import 'dsp1.dart';
import 'pad.dart';
import 'ppu.dart';
import 'sa1.dart';
import 'sdd1.dart';
import 'spc7110.dart';
import 'superfx.dart';

/// 24-bit address bus for the SNES.
///
/// WRAM + ROM (LoROM/HiROM) + SRAM are functional. $2100-$213F routes to the
/// PPU's register file (see ppu.dart), $4300-$437F + $420B/$420C route to
/// the DMA/HDMA controller (see dma.dart), and $2140-2143 route to the
/// audio unit (see apu.dart). $4200-$42FF models NMI, the DMA triggers,
/// auto-joypad 1, H/V timer IRQ, and the multiply/divide unit; programmable
/// I/O and manual joypad are still scratch stubs.
class Bus implements CpuBus {
  @override
  late final Cpu cpu;
  late final Ppu ppu;
  late final Dma dma;
  late final Apu apu;

  final pad = SnesPad();

  /// the S-DD1 chip of the cartridge, if any
  Sdd1? sdd1;

  /// the SA-1 chip of the cartridge, if any
  Sa1? sa1;

  /// the Super FX chip of the cartridge, if any
  SuperFx? superFx;

  /// the DSP-1 chip of the cartridge, if any
  Dsp1? dsp1;

  /// the Cx4 chip of the cartridge, if any
  Cx4? cx4;

  /// the SPC7110 chip of the cartridge, if any
  Spc7110? spc7110;

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
    sdd1 = file.hasSdd1 ? (Sdd1(rom)..reset()) : null;
    sa1 = file.hasSa1 ? Sa1(this, rom, file.sramSize) : null;
    spc7110 = file.hasSpc7110
        ? (Spc7110(rom, (a) => sramRead(a), (a, v) => sramWrite(a, v))..reset())
        : null;
    cx4 = file.hasCx4 ? (Cx4(read, rom)..reset()) : null;
    dsp1 = file.hasDsp1 ? (Dsp1(file.mapping, rom.length)..reset()) : null;
    superFx =
        file.hasSuperFx ? SuperFx(this, rom, _superFxRamSize(file)) : null;

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

  @override
  int readVector(int addr) =>
      sa1?.mainVector(addr) ??
      superFx?.mainVector(addr) ??
      read(addr) | read(addr + 1).shl8;

  // the GSU ram: from the extended header, else the ram size, else 32KB
  static int _superFxRamSize(SnesFile file) => file.expansionRamSize > 0
      ? file.expansionRamSize
      : file.sramSize > 0
          ? file.sramSize
          : 0x8000;

  // ------------------------------------------------------------------ read
  @override
  int read(int addr) {
    addr &= 0xffffff;
    final bank = addr.shr16;
    final page = addr.mask16;

    // $7E-$7F: full WRAM
    if (bank == 0x7e || bank == 0x7f) {
      return wram[bank.mask1.shl16 | page];
    }

    final sa1 = this.sa1;
    if (sa1 != null) {
      final v = sa1.mainRead(addr);
      if (v >= 0) return v;
    }
    final superFx = this.superFx;
    if (superFx != null) {
      final v = superFx.mainRead(addr);
      if (v >= 0) return v;
    }
    final spc7110 = this.spc7110;
    if (spc7110 != null) {
      final v = spc7110.mainRead(addr);
      if (v >= 0) return v;
    }
    final dsp1 = this.dsp1;
    if (dsp1 != null) {
      final port = dsp1.port(addr);
      if (port == 1) return dsp1.readData();
      if (port == 2) return dsp1.readStatus();
    }

    // system banks $00-$3F / $80-$BF
    if (bank.mask7 < 0x40) {
      if (page < 0x2000) return wram[page]; // low 8KB wram mirror
      if (sdd1 != null && Sdd1.isRegister(bank, page)) {
        return sdd1!.readRegister(page);
      }
      if (page < 0x6000) return _readMmio(page);
      if (page < 0x8000) {
        if (cx4 != null) return cx4!.read(page);
        final off = _sramOffset(bank, page);
        return off < 0 ? 0 : sramRead(off);
      }
      return _readRom(bank, page); // $8000-$FFFF
    }

    // banks $40-$7D / $C0-$FF: rom (LoROM sram in $70-$7D/$F0-$FF low half)
    final off = _sramOffset(bank, page);
    if (off >= 0) return sramRead(off);
    if (sdd1 != null && bank >= 0xc0) return sdd1!.mmcRead(addr);
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
  /// S-DD1: banks $C0-$FF are rom only (1MB blocks via $4804-$4807).
  int _sramOffset(int bank, int page) {
    if (sram.isEmpty) return -1;
    if (sdd1 != null && bank >= 0xc0) return -1;
    final b = bank.mask7;
    if (mapping == SnesMapping.hiRom) {
      if (b < 0x20 || b >= 0x40 || page < 0x6000 || page >= 0x8000) return -1;
      return ((b - 0x20).shl13 | page.mask13) & _sramMask;
    }
    if (b < 0x70 || page >= 0x8000) return -1; // $7E/$7F (wram) never get here
    return (((b - 0x70).shl15) | page) & _sramMask;
  }

  // ----------------------------------------------------------------- write
  @override
  void write(int addr, int data) {
    addr &= 0xffffff;
    data &= 0xff;
    final bank = addr.shr16;
    final page = addr.mask16;

    if (bank == 0x7e || bank == 0x7f) {
      wram[bank.mask1.shl16 | page] = data;
      return;
    }

    if (sa1?.mainWrite(addr, data) ?? false) return;
    if (superFx?.mainWrite(addr, data) ?? false) return;
    if (spc7110?.mainWrite(addr, data) ?? false) return;
    final dsp1 = this.dsp1;
    if (dsp1 != null) {
      final port = dsp1.port(addr);
      if (port == 1) dsp1.writeData(data);
      if (port != 0) return;
    }

    if (bank.mask7 < 0x40) {
      if (page < 0x2000) {
        wram[page] = data;
        return;
      }
      if (sdd1 != null && Sdd1.isRegister(bank, page)) {
        sdd1!.writeRegister(page, data);
        return;
      }
      if (page < 0x6000) {
        _writeMmio(page, data);
        return;
      }
      if (page < 0x8000) {
        if (cx4 != null) {
          cx4!.write(page, data);
          return;
        }
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
      case 0x2180: // WMDATA
        final v = wram[_wramAddr];
        _wramAddr = (_wramAddr + 1) & 0x1ffff;
        return v;
      case 0x4210: // RDNMI: bit7 = vblank nmi flag (read-clears)
        {
          final v = _nmiFlag ? 0x82 : 0x02;
          _nmiFlag = false;
          return v;
        }
      case 0x4211: // TIMEUP: reading acknowledges the timer IRQ
        final v = _irqFlag ? 0x80 : 0;
        _irqFlag = false;
        cpu.releaseIrq();
        return v;
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
    switch (page) {
      case 0x2180: // WMDATA: a wram write at WMADD, which increments
        wram[_wramAddr] = data;
        _wramAddr = (_wramAddr + 1) & 0x1ffff;
        return;
      case 0x2181: // WMADDL/M/H
        _wramAddr = (_wramAddr & 0x1ff00) | data;
        return;
      case 0x2182:
        _wramAddr = (_wramAddr & 0x100ff) | data.shl8;
        return;
      case 0x2183:
        _wramAddr = _wramAddr.mask16 | data.mask1.shl16;
        return;
    }
    if (page == 0x4200) {
      _nmiEnabled = data.bit7;
      _irqMode = data.shr4.mask2;
      if (_irqMode == 0) {
        _irqFlag = false;
        cpu.releaseIrq();
      }
    }
    if (page == 0x4207) _hTime = (_hTime & 0x100) | data;
    if (page == 0x4208) _hTime = _hTime.mask8 | data.mask1.shl8;
    if (page == 0x4209) _vTime = (_vTime & 0x100) | data;
    if (page == 0x420a) _vTime = _vTime.mask8 | data.mask1.shl8;
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
  bool _irqFlag = false;
  int _irqMode = 0;
  int _hTime = 0x1ff;
  int _vTime = 0x1ff;
  int _hvbjoy = 0;

  int _wramAddr = 0; // $2181-$2183: the wram address of WMDATA

  int _mulResult = 0; // $4216/4217: product, or division remainder
  int _divResult = 0; // $4214/4215: division quotient

  /// Check the timer for the current scanline. The dot is scaled to the
  /// core's approximate CPU-cycle clock. The caller keeps a per-line guard.
  bool timerReached(
      int scanline, int lineStartCycle, int cpuCycle, int cyclesInScanline) {
    if (_irqMode == 0 || (_irqMode.bit1 && scanline != _vTime)) {
      return false;
    }
    final h = _irqMode.bit0 ? _hTime : 0;
    if (h >= 340) return false;
    final target = lineStartCycle + h * cyclesInScanline ~/ 341;
    if (cpuCycle < target) return false;
    _irqFlag = true;
    cpu.holdIrq();
    return true;
  }

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
    sdd1?.reset();
    sa1?.reset();
    superFx?.reset();
    dsp1?.reset();
    cx4?.reset();
    spc7110?.reset();
    _nmiEnabled = false;
    _nmiFlag = false;
    _irqFlag = false;
    _irqMode = 0;
    _hTime = 0x1ff;
    _vTime = 0x1ff;
    cpu.releaseIrq();
    cpu.reset();
  }
}
