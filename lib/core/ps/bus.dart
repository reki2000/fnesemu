import 'dart:typed_data';

import 'package:fnesemu/core/ps/r3000/r3000.dart';
import 'package:fnesemu/core/ps/serial.dart';
import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import '../../util/debug.dart';
import 'cdrom.dart';
import 'dma.dart';
import 'gpu/gpu.dart';
import 'interrupt.dart';
import 'mdec.dart';
import 'spu/spu.dart';
import 'timer.dart';

final debugLogAddr = 0x80135b20;

class Bus implements BusR3000 {
  late final Gpu gpu;
  late final R3000 cpu;
  late final Serial serial;
  late final Spu spu;
  late final TimerController timer;
  late final Cdrom cdrom;
  late final Mdec mdec;
  late final Dma dma;
  late final InterruptController interrupt;

  final mem = Uint8List(2 * 1024 * 1024);
  late final Uint32List mem32 = mem.buffer.asUint32List();
  static const mem32Mask = 0x7ffff;

  final rom = Uint8List(1024 * 512);
  late final Uint32List rom32 = rom.buffer.asUint32List();
  static const rom32Mask = 0x1ffff;

  final scratchPad = Uint8List(1024);
  late final Uint32List scratchPad32 = scratchPad.buffer.asUint32List();
  static const scratchPad32Mask = 0x3ff;
  bool useScratchPad = false;

  final segMask = [32, 32, 32, 32, 31, 29, 32, 32]
      .map((e) => (1 << e) - 1)
      .toList(growable: false);

  void reset() {
    interrupt.reset();
    dma.reset();
    timer.reset();
    gpu.reset();
    serial.reset();
    spu.reset();
    cdrom.reset();
    mdec.reset();
  }

  @override
  int read8(int addr) {
    final offset = addr & 0x1fffffff;
    return switch (offset) {
      < 0x8000000 => mem[offset & 0x1fffff],
      >= 0x1fc00000 && < 0x1fe00000 => rom[(offset - 0x1fc00000) & 0x7ffff],
      >= 0x1f800000 && < 0x1f800400 =>
        useScratchPad ? scratchPad[offset - 0x1f800000] : 0xff,
      _ => _read8Full(addr),
    };
  }

  int _read8Full(int addr) {
    final offset = addr & segMask[addr >> 29];
    const sig = "read8";

    return switch (offset) {
      >= 0x1f000000 && < 0x1f000100 =>
        _unimpl(sig, "expansion rom header", addr),
      >= 0x1f000000 && < 0x1f008000 => _unimpl(sig, "expansion 1", addr),
      >= 0x1f801000 && < 0x1f801020 => [
          0x1f000000, // expansion 1 base address
          0x1f002000, // expansion 2 base address
          0x0013243F, // expansion 1 delay/size
          0x00003022, // expansion 3 delay/size
          0x0013243f, // bios rom delay/size
          0x200931e1, // spu delay/size (0x220931E1 for read)
          0x00020843, // cdrom delay/size (00020843h or 00020943h)
          0x00070777, // expansion 2 delay/size
        ][(offset - 0x1f801000).shr2]
            .byteAt(offset),
      >= 0x1f801040 && < 0x1f801050 => switch (offset & 0x1fff) {
          >= 0x1040 && < 0x1044 => serial.readData(),
          >= 0x1044 && < 0x1048 => serial.readStatus().byteAt(offset),
          >= 0x1048 && < 0x104a => serial.readMode().byteAt(offset),
          >= 0x104a && < 0x104c => serial.readControl().byteAt(offset),
          >= 0x104e && < 0x1050 => serial.readBaudrate().byteAt(offset),
          _ => 0,
        },
      >= 0x1f801060 && < 0x1f801070 =>
        0x00000B88.byteAt(offset), // memory control: joypad ports
      >= 0x1f801070 && < 0x1f801080 => switch (offset & 0x1fff) {
          >= 0x1070 && < 0x1074 => interrupt.status.byteAt(offset),
          >= 0x1074 && < 0x1078 => interrupt.mask.byteAt(offset),
          _ => 0,
        },
      >= 0x1f8010f0 && < 0x1f8010f4 =>
        dma.control.byteAt(offset), // dma control
      >= 0x1f8010f4 && < 0x1f8010f8 =>
        dma.interrupt.byteAt(offset), // dma interrupt
      >= 0x1f801800 && < 0x1f801804 => cdrom.readPort8(offset & 0x03),
      >= 0x1f802000 && < 0x1f802100 => _unimpl(sig, "expansion 2", addr),
      >= 0x1fa00000 && < 0x1fc00000 => _unimpl(sig, "expansion 3", addr),
      _ => _unimpl(sig, "unknown", addr),
    };
  }

  @override
  int read16(int addr) {
    final offset = addr & segMask[addr >> 29];

    return switch (offset) {
      >= 0x1f801100 && < 0x1f801130 => switch (offset & 0x0e) {
          0x00 => timer.counter(offset >> 4 & 3),
          0x04 => timer.mode(offset >> 4 & 3),
          0x08 => timer.target(offset >> 4 & 3),
          _ => 0
        },
      >= 0x1f801c00 && < 0x1f801ec0 => switch (offset & 0x1fff) {
          >= 0x1c00 && < 0x1d80 =>
            spu.readVoice(offset & 0x0e, offset >> 4 & 0x1f),
          0x1d9c => spu.endx, // spu endx
          0x1da4 => spu.irqAddr, // spu irq address
          0x1da6 => spu.fifoAddr, // spu dma start address
          0x1daa => spu.control, // spu control
          0x1dac => spu.fifoType, // spu ram ctrl
          0x1dae => spu.status, // spu status
          >= 0x1e00 && < 0x1ec0 =>
            spu.readVoice(offset & 0x03, offset >> 2 & 0x1f),
          _ => 0,
        },
      _ => read8(addr) | read8(addr.inc).shl8,
    };
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('vm:no-bounds-check')
  int read32(int addr) {
    final offset = addr & 0x1fffffff;
    return (offset < 0x8000000)
        ? mem32[offset >> 2 & mem32Mask]
        : (offset >= 0x1fc00000 && offset < 0x1fe00000)
            ? rom32[(offset - 0x1fc00000) >> 2 & rom32Mask]
            : _read32Full(addr);
  }

  int _read32Full(int addr) {
    final offset = addr & segMask[addr >> 29];
    const sig = "read32";

    return switch (offset) {
      >= 0x1f800000 && < 0x1f800400 => useScratchPad
          ? scratchPad32[(offset - 0x1f800000) >> 2 & scratchPad32Mask]
          : 0xffffffff,
      >= 0x1f801000 && < 0x1f802000 => switch (offset & 0x1fff) {
          >= 0x1080 && < 0x10f0 => switch (offset & 0x0c) {
              0x00 => dma.channels[offset >> 4 & 0x07].startAddr,
              0x04 => dma.channels[offset >> 4 & 0x07].blockCtrl,
              0x08 => dma.channels[offset >> 4 & 0x07].channelCtrl,
              _ => _unimpl(sig, "DMA", addr)
            },
          0x1810 => gpu.readReg(), // gpu read
          0x1814 => gpu.readStat(), // gpu status
          0x1820 => mdec.readData(), // mdec data
          0x1824 => mdec.readStatus(), // mdec status
          _ => read16(addr) | read16(addr.inc2).shl16,
        }, // I/O ports
      >= 0x1fbfff00 && < 0x1fc00000 =>
        0, // before bios rom, to avoid disassembler access error
      _ => addr == 0xfffe0130 // cache control
          ? _unimpl(sig, "cache control", addr)
          : _unimpl(sig, "-", addr),
    };
  }

  @override
  void write8(int addr, int v) {
    // if (addr == debugLogAddr) {
    //   debugLog("bus: write8 to ${debugLogAddr.hex32}: ${v.hex8}");
    // }

    final offset = addr & segMask[addr >> 29];
    const sig = "write8";

    return switch (offset) {
      >= 0x00000000 && < 0x00800000 => mem[addr & 0x1fffff] = v,
      >= 0x1f800000 && < 0x1f800400 =>
        useScratchPad ? scratchPad[offset - 0x1f800000] = v : 0,
      >= 0x1f801000 && < 0x1f802000 => switch (offset & 0x1fff) {
          0x1040 => serial.writeData(v),
          >= 0x1800 && < 0x1804 => cdrom.writePort8(offset & 0x03, v),
          0x10f4 => dma.interrupt = dma.interrupt.masked(0xff, v),
          0x10f6 => dma.interrupt = dma.interrupt.masked(0xff0000, v << 16),
          _ => _unimpl(sig, "** unknwown ** expansion 1", addr, value: v)
        },
      >= 0x1f802000 && < 0x1f802100 => switch (offset & 0xffff) {
          0x2041 => debugLog("post: $v"),
          _ => _unimpl(sig, "expansion 2", addr, value: v)
        },
      >= 0x1fc00000 && < 0x1fe00000 => 0, // bios rom
      _ => _unimpl(sig, "-", addr, value: v),
    };
  }

  @override
  void write16(int addr, int v) {
    // if (addr == debugLogAddr) {
    //   debugLog("bus: write16 to ${debugLogAddr.hex32}: ${v.hex16}");
    // }

    final offset = addr & segMask[addr >> 29];
    const sig = "write16";

    return switch (offset) {
      >= 0x00000000 && < 0x00800000 => mem.setUint16LE(offset & 0x1fffff, v),
      >= 0x1f800000 && < 0x1f800400 =>
        useScratchPad ? scratchPad.setUint16LE(offset - 0x1f800000, v) : 0,
      >= 0x1f801000 && < 0x1f802000 => switch (offset & 0x1fff) {
          0x1070 => interrupt.ackIrq(v),
          0x1074 => interrupt.mask = v.mask16,
          0x1048 => serial.writeMode(v),
          0x104a => serial.writeControl(v),
          0x104e => serial.writeBaudrate(v),
          0x10f4 => dma.interrupt = dma.interrupt.setL16(v),
          0x10f6 => dma.interrupt = dma.interrupt.setH16(v),
          >= 0x1100 && < 0x1130 => switch (offset & 0x0e) {
              0x00 => timer.setCounter(offset >> 4 & 3, v),
              0x04 => timer.setMode(offset >> 4 & 3, v),
              0x08 => timer.setTarget(offset >> 4 & 3, v),
              _ => _unimpl(sig, "Timer", addr, value: v)
            },
          >= 0x1c00 && < 0x1d80 =>
            spu.writeVoice(offset & 0x0e, offset >> 4 & 0x1f, v),
          0x1d80 => spu.mainVolumeLeft = v,
          0x1d82 => spu.mainVolumeRight = v,
          0x1d84 => spu.reverb.setOutputVolume(0, v),
          0x1d86 => spu.reverb.setOutputVolume(1, v),
          0x1d88 => spu.keyOn(v),
          0x1d8a => spu.keyOn(v << 16),
          0x1d8c => spu.keyOff(v),
          0x1d8e => spu.keyOff(v << 16),
          0x1d90 => spu.setPitchModulation(v),
          0x1d92 => spu.setPitchModulation(v << 16),
          0x1d94 => spu.setNoiseFlags(v),
          0x1d96 => spu.setNoiseFlags(v << 16),
          0x1d98 => spu.reverb.setReverbEnabled(v),
          0x1d9a => spu.reverb.setReverbEnabled(v << 16),
          0x1d9c => 0,
          0x1d9e => 0,
          0x1da2 => spu.reverb.setBaseAddr(v << 3), // work address
          0x1da4 => spu.setIrqAddr(v), // irq address
          0x1da6 => spu.setFifoAddr(v), // dma start address
          0x1da8 => spu.writeFifo16(v), // sound ram
          0x1daa => spu.writeCtrl(v), // spu ctrl
          0x1dac => spu.fifoType = v, // spu ram ctrl
          0x1db0 => spu.cdAudioInputLeft = v,
          0x1db2 => spu.cdAudioInputRight = v,
          0x1db4 => spu.externalInputLeft = v,
          0x1db6 => spu.externalInputRight = v,
          0x1db8 => spu.mainVolumeLeft = v, // read only by design
          0x1dba => spu.mainVolumeRight = v, // read only by design
          >= 0x1d80 && < 0x1dc0 => _unimpl(sig, "spu control", addr, value: v),
          >= 0x1dc0 && < 0x1e00 => spu.reverb.write16(offset, v),
          _ => _unimpl(sig, "expansion 1", addr, value: v)
        },
      >= 0x1fc00000 && < 0x1fe00000 => 0, // bios rom
      _ => _unimpl(sig, "-", addr, value: v),
    };
  }

  @override
  void write32(int addr, int v) {
    final offset = addr & 0x1fffffff;
    if (offset < 0x8000000) {
      mem32[offset >> 2 & mem32Mask] = v;
      return;
    }
    _write32Full(addr, v);
  }

  void _write32Full(int addr, int v) {
    // if (addr == debugLogAddr) {
    //   debugLog("bus: write32 to ${debugLogAddr.hex32}: ${v.hex32}");
    // }

    final offset = addr & segMask[addr >> 29];
    const sig = "write32";

    return switch (offset) {
      >= 0x1f000000 && < 0x1f008000 =>
        _unimpl(sig, "expansion 1", addr, value: v),
      >= 0x1f800000 && < 0x1f800400 =>
        useScratchPad ? scratchPad.setUint32LE(offset - 0x1f800000, v) : 0,
      >= 0x1f801000 && < 0x1f802000 => switch (offset & 0x1fff) {
          0x1000 => 0, //ex("memory control 1: Expansion 1 Base Address"),
          0x1004 => 0, //ex("memory control 1: Expansion 2 Base Address"),
          0x1008 => 0, //ex("memory control 1: Expansion 1 Delay/Size"),
          0x100c => 0, //ex("memory control 1: Expansion 3 Delay/Size"),
          0x1010 => 0, //ex("memory control 1: BIOS ROM"),
          0x1014 => 0, //ex("memory control 1: SPU Delay/Size"),
          0x1018 => 0, //ex("memory control 1: CDROM Delay/Size"),
          0x101c => 0, //ex("memory control 1: Expansion 2 Delay/Size"),
          0x1020 => 0, //ex("memory control 1: COMMON_DELAY"),
          0x1040 => serial.writeData(v),
          0x1050 => 0, //ex("memory control 2: RAM base address"),
          0x1060 => 0, //ex("memory control 2: RAM size"),
          0x1070 => interrupt.ackIrq(v),
          0x1074 => interrupt.mask = v.mask16,
          >= 0x1080 && < 0x10f0 => switch (offset & 0x0c) {
              0x00 => dma.channels[offset >> 4 & 0x07].startAddr = v,
              0x04 => dma.channels[offset >> 4 & 0x07].blockCtrl = v,
              0x08 => dma.channels[offset >> 4 & 0x07].channelCtrl = v,
              _ => _unimpl(sig, "DMA", addr, value: v)
            },
          0x10f0 => dma.control = v,
          0x10f4 => dma.interrupt = v,
          >= 0x1100 && < 0x1130 => switch (offset & 0x0e) {
              0x00 => timer.setCounter(offset >> 4 & 3, v),
              0x04 => timer.setMode(offset >> 4 & 3, v),
              0x08 => timer.setTarget(offset >> 4 & 3, v),
              _ => _unimpl(sig, "Timer", addr, value: v)
            },
          0x1810 => gpu.writeGp0(v), // gp0
          0x1814 => gpu.writeGp1(v), // gp1
          0x1820 => mdec.writeCommand(v), // mdec command
          0x1824 => mdec.writeControl(v), // mdec control
          >= 0x1c00 && < 0x1ec0 => () {
              write16(addr, v & 0xffff);
              write16(addr + 2, v >> 16 & 0xffff);
            }(),
          _ => _unimpl(sig, "I/O Ports", addr, value: v)
        }, // I/O ports
      >= 0x1f802000 && < 0x1f802100 =>
        _unimpl(sig, "expansion 2", addr, value: v), // expansion 2
      >= 0x1fa00000 && < 0x1fc00000 => 0, // expansion 3
      >= 0x1fc00000 && < 0x1fe00000 => 0, // bios rom
      _ => addr == 0xfffe0130 // cache control
          ? useScratchPad = v.bit3 && v.bit7
          : 0xffffffff,
    };
  }

  void setIrq(int irqNo) {
    interrupt.setIrq(irqNo);
  }

  int _unimpl(String op, String device, int addr, {int value = 0}) {
    debugLog('====================================================');
    debugLog('$op: unknown ${addr.hex32} <= ${value.hex32} $device');
    debugLog('====================================================');
    return 0;
  }
}

extension _IntExt on int {
  int byteAt(int n) => (this >> ((n & 3) << 3)) & 0xff;
}
