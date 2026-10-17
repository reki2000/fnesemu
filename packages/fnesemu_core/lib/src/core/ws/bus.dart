import 'dart:typed_data';

import '../../pad_button.dart';
import '../../sram.dart';
import '../../util/int.dart';
import 'display.dart';
import 'io_masks.dart';
import 'sound.dart';
import 'v30mz/v30mz.dart';

/// the cartridge header at the last 16 bytes of the ROM
class Header {
  final bool color;
  final int saveType;
  final bool vertical;
  final bool rtc;

  Header(Uint8List rom)
      : color = rom[rom.length - 9].bit0,
        saveType = rom[rom.length - 5],
        vertical = rom[rom.length - 4].bit0,
        rtc = rom[rom.length - 3].bit0;

  int get sramSize => switch (saveType) {
        0x01 => 0x2000,
        0x02 => 0x8000,
        0x03 => 0x20000,
        0x04 => 0x40000,
        0x05 => 0x80000,
        _ => 0,
      };

  int get eepromSize => switch (saveType) {
        0x10 => 0x80,
        0x20 => 0x800,
        0x50 => 0x400,
        _ => 0,
      };
}

/// a serial EEPROM accessed through the data, address/command and control
/// ports. only the read and write commands are emulated
class Eeprom {
  final Sram _data;
  final int size;
  int data = 0;
  int address = 0;

  Eeprom(this._data, this.size);

  int readPort(int offset) => switch (offset) {
        0 => data.mask8,
        1 => data.shr8,
        2 => address.mask8,
        3 => address.shr8,
        _ => 0x03, // read and write complete
      };

  void writePort(int offset, int value) {
    switch (offset) {
      case 0:
        data = data & 0xff00 | value;
      case 1:
        data = data & 0xff | value.shl8;
      case 2:
        address = address & 0xff00 | value;
      case 3:
        address = address & 0xff | value.shl8;
      default:
        if (size == 0) return;
        final addr = (address << 1) & (size - 1);
        if (value.bit4) {
          data = _data.read8(addr) | _data.read8(addr + 1).shl8;
        } else if (value.bit5) {
          _data.write8(addr, data.mask8);
          _data.write8(addr + 1, data.shr8);
        }
    }
  }
}

/// the X and Y key groups, start, A and B
class Pad {
  static const x1 = PadButton("X1");
  static const x2 = PadButton("X2");
  static const x3 = PadButton("X3");
  static const x4 = PadButton("X4");
  static const y1 = PadButton("Y1");
  static const y2 = PadButton("Y2");
  static const y3 = PadButton("Y3");
  static const y4 = PadButton("Y4");
  static const start = PadButton("Start");
  static const a = PadButton("A");
  static const b = PadButton("B");

  int _x = 0, _y = 0, _buttons = 0;

  void reset() => _x = _y = _buttons = 0;

  // the X keys are mapped to the directions
  static (int, int) _key(PadButton k) => switch (k.name) {
        "up" || "X1" => (0, 1),
        "right" || "X2" => (0, 2),
        "down" || "X3" => (0, 4),
        "left" || "X4" => (0, 8),
        "Y1" => (1, 1),
        "Y2" => (1, 2),
        "Y3" => (1, 4),
        "Y4" => (1, 8),
        "Start" => (2, 2),
        "A" => (2, 4),
        "B" => (2, 8),
        _ => (-1, 0),
      };

  /// returns true when the key is newly pressed
  bool keyDown(PadButton k) {
    final (group, bit) = _key(k);
    final before = _x | _y << 4 | _buttons << 8;
    switch (group) {
      case 0:
        _x |= bit;
      case 1:
        _y |= bit;
      case 2:
        _buttons |= bit;
    }
    return before != (_x | _y << 4 | _buttons << 8);
  }

  void keyUp(PadButton k) {
    final (group, bit) = _key(k);
    switch (group) {
      case 0:
        _x &= ~bit;
      case 1:
        _y &= ~bit;
      case 2:
        _buttons &= ~bit;
    }
  }

  /// the port 0xb5 with the groups selected by the bits 4-6
  int read(int select) =>
      select & 0x70 |
      (select.bit4 ? _y : 0) |
      (select.bit5 ? _x : 0) |
      (select.bit6 ? _buttons : 0);
}

/// memory map, I/O ports, interrupts, timers and DMA of the ws core
class Bus implements V30Bus {
  final bool color;
  late final V30mz cpu = V30mz(this, colorSoc: color);
  final io = Uint8List(0x100);
  final ram = Uint8List(0x10000);
  late final display = Display(io, ram, color: color);
  late final sound = Sound(io, ram);
  final pad = Pad();

  Bus({required this.color});

  Uint8List rom = Uint8List(0x10000);
  int _romBankMask = 0;
  Header? header;

  Sram _sram = Sram();
  int _sramMask = 0;
  Eeprom cartEeprom = Eeprom(Sram(), 0);
  Eeprom internalEeprom = Eeprom(Sram(), 0);

  int _hblankCounter = 0, _vblankCounter = 0;

  // sound dma
  int _soundDmaClocks = 0;

  static const intSerialTx = 0;
  static const intKey = 1;
  static const intCartridge = 2;
  static const intSerialRx = 3;
  static const intLine = 4;
  static const intVblankTimer = 5;
  static const intVblank = 6;
  static const intHblankTimer = 7;

  void setRom(Uint8List body) {
    // align the ROM to the end of a power of 2 sized bank space
    var size = 0x10000;
    while (size < body.length) {
      size <<= 1;
    }
    rom = Uint8List(size)..fillRange(0, size, 0xff);
    rom.setRange(size - body.length, size, body);
    _romBankMask = (size >> 16) - 1;
    header = Header(rom);
  }

  void attachSaves(Sram? sram, String id) {
    final header = this.header!;
    final sramSize = header.sramSize, eepromSize = header.eepromSize;
    _sramMask = sramSize == 0 ? 0 : sramSize - 1;
    final size = sramSize + eepromSize;
    _sram = (size > 0 ? sram : null) ?? Sram();
    _sram.init(
        id, Uint8List(size)..fillRange(0, size, sramSize > 0 ? 0 : 0xff));
    cartEeprom = Eeprom(_sram, eepromSize);
    internalEeprom = Eeprom(Sram()..init("", Uint8List(color ? 0x800 : 0x80)),
        color ? 0x800 : 0x80);
  }

  void reset() {
    ram.fillRange(0, ram.length, 0);
    io.fillRange(0, io.length, 0);
    io[0xa0] = 0x04; // 16-bit cartridge bus
    // the state left by the boot ROM
    io[0x14] = 0x01; // lcd on
    io.setAll(0x1c, [0x20, 0x64, 0xb9, 0xfd]); // shades
    io[0x16] = 158;
    io[0x17] = 155;
    io[0x91] = 0x80; // headphones connected
    io.setAll(0xc0, [0xff, 0xff, 0xff, 0xff]);
    _hblankCounter = _vblankCounter = 0;
    _soundDmaClocks = 0;
    display.reset();
    sound.reset();
    pad.reset();
    cpu.reset();
    cpu.s[V30mz.ss] = 0;
    cpu.r[V30mz.sp] = 0x2000;
    _updateIrq();
  }

  int get linesInFrame => (color ? io[0x16] : 158) + 1;

  // ----------------------------------------------------------------------
  // memory

  bool get _colorRam => color && io[0x60].bit7;

  @override
  int read8(int addr) {
    switch (addr >> 16) {
      case 0:
        if (addr >= 0x4000 && !_colorRam) return 0x90;
        return ram[addr];
      case 1:
        if (_sramMask == 0) return 0xff;
        return _sram.read8((io[0xc1].shl16 | addr.mask16) & _sramMask);
      case 2:
        return _romRead(io[0xc2], addr);
      case 3:
        return _romRead(io[0xc3], addr);
      default:
        return _romRead(io[0xc0].shl4 | addr >> 16, addr);
    }
  }

  int _romRead(int bank, int addr) =>
      rom[(bank & _romBankMask).shl16 | addr.mask16];

  @override
  void write8(int addr, int data) {
    switch (addr >> 16) {
      case 0:
        if (addr >= 0x4000 && !_colorRam) return;
        ram[addr] = data;
      case 1:
        if (_sramMask != 0) {
          _sram.write8((io[0xc1].shl16 | addr.mask16) & _sramMask, data);
        }
    }
  }

  // ----------------------------------------------------------------------
  // I/O

  @override
  int input8(int port) {
    switch (port) {
      case 0x02:
        return _line;
      case 0x92:
        return sound.lfsr.mask8;
      case 0x93:
        return sound.lfsr.shr8;
      case 0xa0: // bits 2-3 are writable
        return 0x81 | (color ? 0x02 : 0) | io[0xa0] & 0x0c;
      case 0xa8:
        return _hblankCounter.mask8;
      case 0xa9:
        return _hblankCounter.shr8;
      case 0xaa:
        return _vblankCounter.mask8;
      case 0xab:
        return _vblankCounter.shr8;
      case 0xb3: // the send buffer is empty while the serial port is enabled
        return io[0xb3] & 0xc0 | (io[0xb3].bit7 ? 0x04 : 0);
      case 0xb5:
        return pad.read(io[0xb5]);
      case >= 0xba && <= 0xbe:
        return internalEeprom.readPort(port - 0xba);
      case >= 0xc4 && <= 0xc8:
        return cartEeprom.readPort(port - 0xc4);
      case 0xca:
      case 0xcb:
        return 0x80; // no RTC
    }
    return io[port];
  }

  @override
  void output8(int port, int data) {
    switch (port) {
      case 0x02:
      case 0xb4:
        return; // read only
      case 0xa0: // bit 2 can not be cleared once set
        io[0xa0] = io[0xa0] & 0x04 | data & 0x0c;
        return;
      case 0xb1: // serial send: the port reads the received data
        return;
      case 0xa4:
      case 0xa5:
        io[port] = data;
        _hblankCounter = io[0xa4] | io[0xa5].shl8;
        return;
      case 0xa6:
      case 0xa7:
        io[port] = data;
        _vblankCounter = io[0xa6] | io[0xa7].shl8;
        return;
      case 0xb2: // latched causes stay when they are disabled
        io[port] = data;
        return;
      case 0xb6: // interrupt acknowledge
        io[0xb4] &= ~data;
        _updateIrq();
        return;
      case 0xb0:
        io[port] = data & 0xf8;
        _updateIrq();
        return;
      case >= 0xba && <= 0xbe:
        internalEeprom.writePort(port - 0xba, data);
        return;
      case >= 0xc4 && <= 0xc8:
        cartEeprom.writePort(port - 0xc4, data);
        return;
    }
    // the color mode registers do not exist on the mono console
    final mask = !color && port >= 0x40 && port <= 0x6f
        ? 0
        : ioMask(port, colorMode: _colorRam);
    io[port] = switch (port) {
      0x91 => io[0x91] & 0x80 | data & 0x0f,
      // other ports of the SoC hold nothing; the cartridge ports pass
      _ => mask == null ? (port < 0xb8 ? 0 : data) : data & mask,
    };
    if (port == 0x48 && data.bit7 && color) _generalDma();
    if (port >= 0x80 && port <= 0x9f) sound.write(port, data);
  }

  // ----------------------------------------------------------------------
  // interrupts

  void interrupt(int no) {
    if (io[0xb2].bit(no)) {
      io[0xb4] |= 1 << no;
      _updateIrq();
    }
  }

  void _updateIrq() {
    // the enable bits only gate the latching of the causes
    final pending = io[0xb4];
    if (pending == 0) {
      cpu.irqVector = -1;
      return;
    }
    var no = 7;
    while (!pending.bit(no)) {
      no--;
    }
    cpu.irqVector = (io[0xb0] & 0xf8) + no;
  }

  // ----------------------------------------------------------------------
  // lines and timers

  int _line = 0;

  /// processes the line events and renders the active lines.
  /// returns true at the end of a frame
  bool runLine() {
    final line = _line;
    if (line == io[0x03]) interrupt(intLine);

    if (line < Display.height) display.renderLine(line);

    var frameEnd = false;
    if (line == Display.height) {
      display.swap();
      interrupt(intVblank);
      if (_vblankCounter > 0 && (io[0xa2].bit2 || _vblankCounter == 1)) {
        _vblankCounter--;
        if (_vblankCounter == 0) {
          interrupt(intVblankTimer);
          if (io[0xa2].bit3) _vblankCounter = io[0xa6] | io[0xa7].shl8;
        }
      }
      frameEnd = true;
    }
    if (line == Display.height - 2) display.latchSprites();

    // a counter at 1 fires even when the timer is stopped
    if (_hblankCounter > 0 && (io[0xa2].bit0 || _hblankCounter == 1)) {
      _hblankCounter--;
      if (_hblankCounter == 0) {
        interrupt(intHblankTimer);
        if (io[0xa2].bit1) _hblankCounter = io[0xa4] | io[0xa5].shl8;
      }
    }

    _line = line + 1 >= linesInFrame ? 0 : line + 1;
    return frameEnd;
  }

  int get line => _line;

  // ----------------------------------------------------------------------
  // DMA

  void _generalDma() {
    var src = io[0x40] | io[0x41].shl8 | io[0x42].mask4.shl16;
    var dst = io[0x44] | io[0x45].shl8;
    var length = io[0x46] | io[0x47].shl8;
    final step = io[0x48].bit6 ? -2 : 2;
    while (length > 0) {
      write8(dst, read8(src));
      write8((dst + 1).mask16, read8((src + 1) & 0xfffff));
      src = (src + step) & 0xfffff;
      dst = (dst + step).mask16;
      length -= 2;
      cpu.cycles += 2;
    }
    cpu.cycles += 5;
    io[0x40] = src.mask8;
    io[0x41] = src.shr8.mask8;
    io[0x42] = src.shr16;
    io[0x44] = dst.mask8;
    io[0x45] = dst.shr8;
    io[0x46] = io[0x47] = 0;
    io[0x48] &= 0x7f;
  }

  static const _soundDmaPeriods = [768, 512, 256, 128]; // 4/6/12/24kHz

  /// advances the sound DMA by [clocks] CPU clocks
  void runSoundDma(int clocks) {
    final ctrl = io[0x52];
    if (!color || !ctrl.bit7) return;
    _soundDmaClocks += clocks;
    final period = _soundDmaPeriods[ctrl.mask2];
    while (_soundDmaClocks >= period) {
      _soundDmaClocks -= period;
      var src = io[0x4a] | io[0x4b].shl8 | io[0x4c].mask4.shl16;
      var length = io[0x4e] | io[0x4f].shl8 | io[0x50].mask4.shl16;
      if (length == 0) {
        io[0x52] &= 0x7f;
        return;
      }
      sound.dmaWrite(read8(src));
      src = (ctrl.bit6 ? src - 1 : src + 1) & 0xfffff;
      length--;
      io[0x4a] = src.mask8;
      io[0x4b] = src.shr8.mask8;
      io[0x4c] = src.shr16;
      io[0x4e] = length.mask8;
      io[0x4f] = length.shr8.mask8;
      io[0x50] = length.shr16;
    }
  }

  String dump() =>
      "line:${_line.x2} int:en${io[0xb2].x2} st${io[0xb4].x2} base${io[0xb0].x2} "
      "banks:${io[0xc0].x2} ${io[0xc1].x2} ${io[0xc2].x2} ${io[0xc3].x2} "
      "disp:${io[0x00].x2} mode:${io[0x60].x2} tmr:${io[0xa2].x2} "
      "h${_hblankCounter.x4} v${_vblankCounter.x4}";
}
