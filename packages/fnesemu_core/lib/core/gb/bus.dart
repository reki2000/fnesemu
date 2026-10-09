import 'dart:typed_data';

import 'apu.dart';
import 'cartridge.dart';
import 'cpu.dart';
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

  late final Cpu cpu;
  late final Ppu ppu;
  late final Apu apu;
  late final Timer timer;
  late final Pad pad;
  Cartridge cart = Cartridge.empty();

  final wram = Uint8List(0x2000);
  final hram = Uint8List(0x7f);

  int ie = 0;
  int _if = 0;

  int get intFlag => _if;
  set intFlag(int v) => _if = v & 0x1f;

  /// elapsed clocks (4 clocks per machine cycle)
  int clocks = 0;

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
  }

  void reset() {
    wram.fillRange(0, wram.length, 0);
    hram.fillRange(0, hram.length, 0);
    ie = 0;
    _if = 0x01;
    clocks = 0;
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

  /// advances one machine cycle
  void tick() {
    clocks += 4;
    timer.tick();
    ppu.tick();
    apu.tick();

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

  int read(int addr) {
    switch (addr >> 12) {
      case 0x0 || 0x1 || 0x2 || 0x3 || 0x4 || 0x5 || 0x6 || 0x7:
        return cart.read(addr);
      case 0x8 || 0x9:
        return ppu.vram[addr & 0x1fff];
      case 0xa || 0xb:
        return cart.readRam(addr);
      case 0xc || 0xd:
        return wram[addr & 0x1fff];
      case 0xe:
        return wram[addr & 0x1fff];
      default:
        if (addr < 0xfe00) {
          return wram[addr & 0x1fff];
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
    switch (addr >> 12) {
      case 0x0 || 0x1 || 0x2 || 0x3 || 0x4 || 0x5 || 0x6 || 0x7:
        cart.write(addr, data);
      case 0x8 || 0x9:
        ppu.vram[addr & 0x1fff] = data;
      case 0xa || 0xb:
        cart.writeRam(addr, data);
      case 0xc || 0xd || 0xe:
        wram[addr & 0x1fff] = data;
      default:
        if (addr < 0xfe00) {
          wram[addr & 0x1fff] = data;
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
      default:
        if (addr >= 0xff10 && addr < 0xff40) {
          return apu.read(addr);
        }
        if (addr >= 0xff40 && addr < 0xff4c) {
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
        _dmaSource = data << 8;
        _dmaIndex = 0;
        _dmaDelay = 1;
      default:
        if (addr >= 0xff10 && addr < 0xff40) {
          apu.write(addr, data);
        } else if (addr >= 0xff40 && addr < 0xff4c) {
          ppu.write(addr, data);
        }
    }
  }
}
