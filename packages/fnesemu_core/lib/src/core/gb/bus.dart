import 'dart:typed_data';

import '../../util/int.dart';
import 'apu.dart';
import 'cartridge.dart';
import 'cpu.dart';
import 'hdma.dart';
import 'pad.dart';
import 'ppu.dart';
import 'timer.dart';

/// memory map and I/O registers. also drives peripherals by machine cycles.
class Bus {
  static const intVBlank = 0x01;
  static const intStat = 0x02;
  static const intTimer = 0x04;
  static const intSerial = 0x08;
  static const intJoypad = 0x10;

  // approximate CPU stall of a GBC speed switch, in machine cycles at the new speed
  static const _speedSwitchStall = 2050;

  late final Cpu cpu;
  late final Ppu ppu;
  late final Apu apu;
  late final Timer timer;
  late final Pad pad;
  late final Hdma hdma;
  Cartridge cart = Cartridge.empty();

  /// GBC mode: VRAM/WRAM banks, GBC palettes, double speed and VRAM DMA are enabled
  bool gbc = false;
  bool doubleSpeed = false;
  bool _speedArmed = false; // KEY1 bit 0

  // WRAM bank at D000-DFFF in GBC mode. DMG keeps bank 1 there.
  int _wramBank = 1;

  final wram = Uint8List(0x8000);
  final hram = Uint8List(0x7f);

  int ie = 0;
  int _if = 0;

  int get intFlag => _if;
  set intFlag(int v) => _if = v.mask5;

  /// elapsed clocks (4 clocks per machine cycle)
  int clocks = 0;

  /// elapsed system clocks that drive the PPU and APU (4.19MHz in both speeds)
  int dotClocks = 0;

  // serial port
  int _sb = 0;
  int _sc = 0;
  int _serialClocks = 0;

  /// data sent by the serial port, useful for test programs
  final serialOutput = StringBuffer();

  // OAM DMA
  int _dmaReg = 0xff;
  int _dmaSource = 0;
  int _dmaIndex = 160;
  int _dmaDelay = 0;

  Bus() {
    cpu = Cpu(this);
    ppu = Ppu(this);
    apu = Apu();
    timer = Timer(this);
    pad = Pad(this);
    hdma = Hdma(this);
  }

  void reset() {
    wram.fillRange(0, wram.length, 0);
    hram.fillRange(0, hram.length, 0);
    ie = 0;
    _if = 0x01;
    clocks = 0;
    dotClocks = 0;
    doubleSpeed = false;
    _speedArmed = false;
    _wramBank = 1;
    hdma.reset();
    _sb = 0;
    _sc = 0;
    _serialClocks = 0;
    serialOutput.clear();
    _dmaReg = 0xff;
    _dmaIndex = 160;
    _dmaDelay = 0;

    cpu.reset();
    ppu.reset();
    apu.reset();
    timer.reset();
    pad.reset();
  }

  void requestInterrupt(int bit) => _if |= bit;

  /// advances one machine cycle. the timer runs on CPU clocks, while the PPU
  /// and APU run on system clocks, which are half as many in double speed.
  void tick() {
    clocks += 4;
    timer.tick();
    final dots = doubleSpeed ? 2 : 4;
    dotClocks += dots;
    ppu.tick(dots);
    apu.tick(dots);

    if (_dmaIndex < 160) {
      _stepDma();
    }

    if (_serialClocks > 0) {
      _serialClocks -= 4;
      if (_serialClocks <= 0) {
        _sb = 0xff; // no link partner
        _sc &= 0x7f;
        _if |= intSerial;
      }
    }
  }

  /// called by the PPU when a visible line enters HBlank
  void hblank() => hdma.onHBlank();

  /// STOP with KEY1 armed toggles the CPU speed. returns false when the STOP
  /// does not switch the speed.
  bool switchSpeed() {
    if (!gbc || !_speedArmed) {
      return false;
    }
    _speedArmed = false;
    doubleSpeed = !doubleSpeed;
    for (int i = 0; i < _speedSwitchStall; i++) {
      tick();
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  int readTick(int addr) {
    tick();
    return read(addr);
  }

  @pragma('vm:prefer-inline')
  void writeTick(int addr, int data) {
    tick();
    write(addr, data);
  }

  void _stepDma() {
    if (_dmaDelay > 0) {
      _dmaDelay--;
      return;
    }
    ppu.oam[_dmaIndex] = read(_dmaSource + _dmaIndex);
    _dmaIndex++;
  }

  // index into wram for C000-FDFF. C000-CFFF is bank 0; D000-DFFF is the
  // switchable bank, which stays bank 1 outside GBC mode.
  @pragma('vm:prefer-inline')
  int _wramIndex(int addr) {
    final offset = addr.mask13;
    return offset < 0x1000 ? offset : (_wramBank << 12) | (offset & 0xfff);
  }

  int read(int addr) {
    switch (addr.shr12) {
      case 0x0 || 0x1 || 0x2 || 0x3 || 0x4 || 0x5 || 0x6 || 0x7:
        return cart.read(addr);
      case 0x8 || 0x9:
        return ppu.vram[ppu.vramBank.shl13 | addr.mask13];
      case 0xa || 0xb:
        return cart.readRam(addr);
      case 0xc || 0xd || 0xe:
        return wram[_wramIndex(addr)];
      default:
        if (addr < 0xfe00) {
          return wram[_wramIndex(addr)];
        }
        if (addr < 0xfea0) {
          return ppu.oam[addr - 0xfe00];
        }
        if (addr < 0xff00) {
          return 0xff;
        }
        if (addr >= 0xff80 && addr < 0xffff) {
          return hram[addr - 0xff80];
        }
        if (addr == 0xffff) {
          return ie;
        }
        return _readIo(addr);
    }
  }

  void write(int addr, int data) {
    switch (addr.shr12) {
      case 0x0 || 0x1 || 0x2 || 0x3 || 0x4 || 0x5 || 0x6 || 0x7:
        cart.write(addr, data);
      case 0x8 || 0x9:
        ppu.vram[ppu.vramBank.shl13 | addr.mask13] = data;
      case 0xa || 0xb:
        cart.writeRam(addr, data);
      case 0xc || 0xd || 0xe:
        wram[_wramIndex(addr)] = data;
      default:
        if (addr < 0xfe00) {
          wram[_wramIndex(addr)] = data;
        } else if (addr < 0xfea0) {
          ppu.oam[addr - 0xfe00] = data;
        } else if (addr < 0xff00) {
          // unusable area
        } else if (addr >= 0xff80 && addr < 0xffff) {
          hram[addr - 0xff80] = data;
        } else if (addr == 0xffff) {
          ie = data;
        } else {
          _writeIo(addr, data);
        }
    }
  }

  int _readIo(int addr) {
    switch (addr) {
      case 0xff00:
        return pad.read();
      case 0xff01:
        return _sb;
      case 0xff02:
        return _sc | 0x7e;
      case 0xff04 || 0xff05 || 0xff06 || 0xff07:
        return timer.read(addr);
      case 0xff0f:
        return _if | 0xe0;
      case 0xff46:
        return _dmaReg;
      case 0xff4d:
        if (!gbc) {
          return 0xff;
        }
        return (doubleSpeed ? 0x80 : 0) | (_speedArmed ? 1 : 0) | 0x7e;
      case 0xff55:
        return gbc ? hdma.read() : 0xff;
      case 0xff70:
        return gbc ? 0xf8 | _wramBank : 0xff;
      default:
        if (addr >= 0xff10 && addr < 0xff40) {
          return apu.read(addr);
        }
        if (addr >= 0xff40 && addr < 0xff4c) {
          return ppu.read(addr);
        }
        if (addr == 0xff4f || (addr >= 0xff68 && addr < 0xff6d)) {
          return ppu.read(addr);
        }
        return 0xff;
    }
  }

  void _writeIo(int addr, int data) {
    switch (addr) {
      case 0xff00:
        pad.write(data);
      case 0xff01:
        _sb = data;
      case 0xff02:
        _sc = data & 0x81;
        if (_sc == 0x81) {
          serialOutput.writeCharCode(_sb);
          _serialClocks = 8 * 512; // 8192Hz internal clock
        }
      case 0xff04 || 0xff05 || 0xff06 || 0xff07:
        timer.write(addr, data);
      case 0xff0f:
        intFlag = data;
      case 0xff46:
        _dmaReg = data;
        _dmaSource = data.shl8;
        _dmaIndex = 0;
        _dmaDelay = 1;
      case 0xff4d:
        if (gbc) {
          _speedArmed = data.bit0;
        }
      case 0xff51 || 0xff52 || 0xff53 || 0xff54 || 0xff55:
        if (gbc) {
          hdma.write(addr, data);
        }
      case 0xff70:
        if (gbc) {
          _wramBank = data.mask3 == 0 ? 1 : data.mask3;
        }
      default:
        if (addr >= 0xff10 && addr < 0xff40) {
          apu.write(addr, data);
        } else if (addr >= 0xff40 && addr < 0xff4c) {
          ppu.write(addr, data);
        } else if (addr == 0xff4f || (addr >= 0xff68 && addr < 0xff6d)) {
          ppu.write(addr, data);
        }
    }
  }
}
