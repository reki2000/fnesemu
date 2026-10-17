import 'dart:typed_data';

import '../../components/sn76489/sn76489.dart';
import '../../components/ym2413/opll.dart';
import '../../components/z80/bus.dart';
import '../../components/z80/z80.dart';
import '../../sram.dart';
import '../../util/int.dart';
import 'pad.dart';
import 'vdp.dart';

enum SmsModel { tms, standard, mk3, gg }

enum Mapper { none, slots, pages }

/// the region code in the ROM header at 0x7ff0, which starts with "TMR ":
/// 3 domestic, 4 export, 5 portable domestic, 6 portable export and 7
/// portable international. null without the header
int? romRegion(Uint8List body) {
  for (final base in [0x7ff0, 0x3ff0, 0x1ff0]) {
    if (body.length >= base + 16 &&
        String.fromCharCodes(body.sublist(base, base + 4)) == 'TMR ') {
      return body[base + 15] >> 4;
    }
  }
  return null;
}

/// the consoles of the sms core
/// - [tms]: the TMS9918 VDP only, 1KB of RAM
/// - [standard]: the mode 4 VDP, 8KB of RAM
/// - [mk3]: the domestic console with the FM sound chip
/// - [portable]: the 160x144 window, 12-bit colors, the start button, the
///   stereo PSG and the link port. cartridges for the mode 4 console run in
///   the compatible mode, which scales the whole picture into the window
///
/// mappers
/// - [Mapper.slots]: registers at 0xfffc-0xffff select the ROM banks of the
///   slots 0-2 and the cartridge RAM
/// - [Mapper.pages]: writes to 0x0000, 0x4000 and 0x8000 select the ROM banks
///
/// memory map and I/O ports of the sms core
class Bus implements Z80Bus {
  final SmsModel model;
  late final Z80 cpu = Z80(this);
  final Vdp vdp;
  final Sn76489 psg;
  final pad = Pad();

  Bus(this.model)
      : vdp = Vdp(tms: model == SmsModel.tms, gg: model == SmsModel.gg),
        psg = Sn76489(lfsr15: model == SmsModel.tms),
        fm = model == SmsModel.mk3 ? Opll(sampleRate: 3579545 ~/ 80) : null;

  /// the FM sound chip of the domestic console, at the ports 0xf0-0xf2
  final Opll? fm;

  // the audio control port 0xf2: bit 0 adds the FM sound to the PSG
  int audioControl = 0;
  bool get fmEnabled => audioControl & 1 != 0;

  Uint8List rom = Uint8List(0x4000);
  Mapper mapper = Mapper.none;

  // the system RAM: 8KB, or 1KB (mirrored) on the TMS9918 console whose
  // cartridges may have 8KB of RAM at 0x2000
  final ram = Uint8List(0x2000);
  int get _ramMask => model == SmsModel.tms ? 0x3ff : 0x1fff;

  // the 32KB battery backed cartridge RAM switched by the slot mapper
  static const cartRamSize = 0x8000;
  Sram _cartRam = Sram()..init("", Uint8List(cartRamSize));

  // the slot mapper: 0xfffc control, 0xfffd-0xffff slot 0-2 banks
  final banks = [0, 1, 2];
  int ramControl = 0;

  // the CPU cycles at the start of the current line
  int lineStartCycles = 0;

  // I/O port control (0x3f)
  int ioControl = 0xff;

  // the portable console: the start button, the region of the cartridge
  // and the link port registers 0x01-0x05
  bool ggStart = false;
  bool ggDomestic = false;
  final linkPort = Uint8List(6);

  /// the portable console runs a cartridge of the mode 4 console
  bool get compatible => vdp.compatible;

  void setRom(Uint8List body) {
    // drop a 512 byte copier header
    if (body.length % 0x4000 == 0x200) {
      body = Uint8List.sublistView(body, 0x200);
    }
    rom = body;
    mapper = _detectMapper(body);
    if (model == SmsModel.gg) {
      final region = romRegion(body);
      vdp.compatible = region == 3 || region == 4;
      ggDomestic = region == 5;
    }
  }

  Mapper _detectMapper(Uint8List body) {
    if (model == SmsModel.tms && body.length <= 0xc000) return Mapper.none;
    if (body.length <= 0x8000 && model != SmsModel.tms) return Mapper.slots;
    if (body.length >= 0x8000) {
      // the page mapper header: a checksum and its complement at 0x7fe6
      final sum = body[0x7fe6] | body[0x7fe7].shl8;
      final inv = body[0x7fe8] | body[0x7fe9].shl8;
      if (sum + inv == 0x10000 && sum != 0) return Mapper.pages;
    }
    return Mapper.slots;
  }

  int get _bankCount => (rom.length + 0x3fff) >> 14;

  void reset() {
    ram.fillRange(0, ram.length, 0);
    banks.setAll(0, [0, 1, 2]);
    ramControl = 0;
    ioControl = 0xff;
    lineStartCycles = 0;
    vdp.reset();
    psg.reset();
    fm?.reset();
    audioControl = 0;
    linkPort.setAll(0, [0, 0x7f, 0xff, 0, 0xff, 0]);
    cpu.reset();
    // the boot ROM leaves the stack pointer at the top of the RAM
    if (model != SmsModel.tms) cpu.r.sp = 0xdff0;
  }

  /// attaches the persistent storage of the cartridge RAM
  void attachCartRam(Sram? sram, String id) {
    _cartRam = (sram ?? Sram())..init(id, Uint8List(cartRamSize));
  }

  int _romByte(int bank, int offset) {
    final count = _bankCount;
    final b = bank < count ? bank : bank % count;
    final addr = b.shl14 | offset;
    return addr < rom.length ? rom[addr] : 0xff;
  }

  @override
  int read(int addr) {
    if (addr >= 0xc000) return ram[addr & _ramMask];

    switch (mapper) {
      case Mapper.none:
        if (addr < rom.length) return rom[addr];
        if (model == SmsModel.tms && addr >= 0x2000 && addr < 0x4000) {
          return ram[addr & 0x1fff];
        }
        return 0xff;
      case Mapper.slots:
        if (addr < 0x400) return rom.length > addr ? rom[addr] : 0xff;
        final slot = addr.shr14;
        if (slot == 2 && ramControl.bit3) {
          return _cartRam.read8((ramControl.bit2 ? 0x4000 : 0) | addr.mask14);
        }
        return _romByte(banks[slot], addr.mask14);
      case Mapper.pages:
        return _romByte(banks[addr.shr14], addr.mask14);
    }
  }

  @override
  void write(int addr, int data) {
    if (addr >= 0xc000) {
      ram[addr & _ramMask] = data;
      if (mapper == Mapper.slots && addr >= 0xfffc) {
        switch (addr) {
          case 0xfffc:
            ramControl = data;
          case 0xfffd:
            banks[0] = data;
          case 0xfffe:
            banks[1] = data;
          case 0xffff:
            banks[2] = data;
        }
      }
      return;
    }

    switch (mapper) {
      case Mapper.none:
        if (model == SmsModel.tms &&
            addr >= 0x2000 &&
            addr < 0x4000 &&
            rom.length <= 0x2000) {
          ram[addr & 0x1fff] = data;
        }
      case Mapper.slots:
        if (addr >= 0x8000 && ramControl.bit3) {
          _cartRam.write8((ramControl.bit2 ? 0x4000 : 0) | addr.mask14, data);
        }
      case Mapper.pages:
        if (addr.mask14 == 0) banks[addr.shr14] = data;
    }
  }

  @override
  int input(int port) {
    port = port.mask8;
    if (model == SmsModel.gg && !compatible && port < 7) {
      return switch (port) {
        // start (active low), export region, NTSC
        0 => (ggStart ? 0 : 0x80) | (ggDomestic ? 0 : 0x40),
        // the link port: nothing is connected
        4 => 0xff,
        5 => linkPort[5] & 0xf8 | 0x02, // the send buffer is empty
        6 => psg.stereo,
        _ => linkPort[port],
      };
    }

    if (fm != null && port == 0xf2) return audioControl;

    switch (port & 0xc1) {
      case 0x40:
        return vdp.vCounter;
      case 0x41:
        return vdp.hLatch;
      case 0x80:
        return vdp.readData();
      case 0x81:
        return vdp.readStatus();
      case 0xc0:
        return pad.portA();
      case 0xc1:
        return pad.portB(ioControl, domestic: model == SmsModel.mk3);
    }
    return 0xff;
  }

  @override
  void output(int port, int data) {
    port = port.mask8;
    if (model == SmsModel.gg && !compatible && port < 7) {
      if (port == 6) {
        psg.stereo = data;
      } else if (port != 0 && port != 4) {
        linkPort[port] = data;
      }
      return;
    }

    final fm = this.fm;
    if (fm != null && port >= 0xf0 && port <= 0xf2) {
      switch (port) {
        case 0xf0:
          fm.writeAddress(data);
        case 0xf1:
          fm.writeData(data);
        default:
          audioControl = data & 0x03;
      }
      return;
    }

    switch (port & 0xc1) {
      case 0x01:
        // a rising edge of a TH pin latches the horizontal counter. the pins
        // set as inputs are pulled up
        int th(int v) => (v | v >> 4) & 0x0a;
        if (th(data) & ~th(ioControl) != 0) {
          vdp.hLatch = Vdp.hCounter(cpu.cycles - lineStartCycles);
        }
        ioControl = data;
      case 0x40:
      case 0x41:
        psg.write8(data);
      case 0x80:
        vdp.writeData(data);
      case 0x81:
        vdp.writeControl(data);
    }
  }

  String dump() =>
      "mapper:${mapper.name} banks:${banks.map((b) => b.x2).join(" ")} "
      "ramctl:${ramControl.x2} io:${ioControl.x2}";
}
