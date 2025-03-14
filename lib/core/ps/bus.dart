import 'dart:typed_data';

import 'package:fnesemu/core/ps/r3000/r3000.dart';
import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import '../../util/debug.dart';
import 'dma.dart';
import 'gpu.dart';

class Bus implements BusR3000 {
  final mem = Uint8List(2 * 1024 * 1024);
  final rom = Uint8List(1024 * 512);

  final scratchPad = Uint8List(1024);
  bool useScratchPad = false;

  int interruptStatus = 0;
  int interruptMask = 0;

  final dma = [0, 0, 0x1f801810, 0, 0, 0, 0, 1]
      .asMap()
      .entries
      .map((entry) => Dma(entry.key, entry.value))
      .toList(growable: false);

  int _dmaControl = 0;
  int get dmaControl => _dmaControl;
  set dmaControl(int value) {
    _dmaControl = value;
    for (var ch = 0; ch < 7; ch++) {
      dma[ch].enabled = (value >> (3 + ch * 4)).bit0;
    }
  }

  int _dmaInterrupt = 0;
  int get dmaInterrupt => _dmaInterrupt;
  set dmaInterrupt(int value) {
    _dmaInterrupt = _dmaInterrupt
        .setBit(
            31,
            _dmaInterrupt.bit15 ||
                (value.bit23 && (value & value >> 16 & 0x1f) != 0))
        .setMasked(0x001f001f, value)
        .setMasked(0x1f000000, ~value & _dmaInterrupt);

    for (var ch = 0; ch < 7; ch++) {
      final modeMask = 0x00001 << ch;
      final useMask = 0x10000 << ch;
      dma[ch].useInterrupt = value & useMask != 0 && value.bit23;
      dma[ch].intterruptOnChunks = value & modeMask != 0;
    }
  }

  final segMask = [32, 32, 32, 32, 31, 29, 32, 32]
      .map((e) => (1 << e) - 1)
      .toList(growable: false);

  late final Gpu gpu;
  late final R3000 cpu;

  Bus();

  @override
  int read8(int addr) => read32(addr & ~0x03) >> (8 * (addr & 0x03)) & 0xff;

  @override
  int read16(int addr) => read32(addr & ~0x03) >> (8 * (addr & 0x02)) & 0xffff;

  @override
  int read32(int addr) {
    final offset = addr & segMask[addr >> 29];
    ex(s) => _unimplemented("read32", s, addr, 0);

    return switch (offset) {
      >= 0x00000000 && < 0x00200000 => mem.getUInt32LE(offset),
      >= 0x1f000000 && < 0x1f000100 => ex("expansion rom header"),
      >= 0x1f000000 && < 0x1f008000 => ex("expansion 1"),
      >= 0x1f800000 && < 0x1f800400 => useScratchPad
          ? scratchPad.getUInt32LE(offset - 0x1f800000)
          : 0xffffffff,
      >= 0x1f801000 && < 0x1f802000 => switch (offset & 0x1fff) {
          0x1070 => interruptStatus,
          0x1074 => interruptMask,
          >= 0x1080 && < 0x10f0 => switch (offset & 0x0c) {
              0x00 => dma[offset >> 8 & 0x07].startAddr,
              0x04 => dma[offset >> 8 & 0x07].blockCtrl,
              0x08 => dma[offset >> 8 & 0x07].channelCtrl,
              _ => ex("DMA")
            },
          0x10f0 => dmaControl,
          0x10f4 => dmaInterrupt,
          0x1810 => gpu.readReg(), // gpu read
          0x1814 => gpu.readStat(), // gpu status
          0x1da8 => 0, // sound ram fifo
          0x1dac => 0x0004, // sound ram ctrl
          >= 0x1c00 && < 0x1c80 => ex("spu voice"),
          >= 0x1d80 && < 0x1dc0 => ex("spu control"),
          >= 0x1dc0 && < 0x1e00 => ex("spu reverb"),
          _ => ex("I/O Ports")
        }, // I/O ports
      >= 0x1f802000 && < 0x1f802100 => ex("expansion 2"),
      >= 0x1fbfff00 && < 0x1fc00000 =>
        0, // before bios rom, to avoid disassembler access error
      >= 0x1fa00000 && < 0x1fc00000 => ex("expansion 3"),
      >= 0x1fc00000 && < 0x1fe00000 => rom.getUInt32LE(offset - 0x1fc00000),
      _ => addr == 0xfffe0130 // cache control
          ? ex("cache control")
          : 0xffffffff,
    };
  }

  // to be used in switch expression, explicitly shows its type is void
  void writeMem8(addr, value) {
    mem[addr] = value;
  }

  @override
  void write8(int addr, int v) {
    final offset = addr & segMask[addr >> 29];
    ex(s) => _unimplemented("write8", s, addr, v);

    return switch (offset) {
      >= 0x00000000 && < 0x00200000 => writeMem8(offset, v),
      >= 0x1f801000 && < 0x1f802000 => switch (offset & 0x1fff) {
          _ => ex("expansion 1")
        },
      >= 0x1f802000 && < 0x1f802100 => switch (offset & 0xffff) {
          0x2041 => ex("PSX POST"),
          _ => ex("expansion 2")
        },
      >= 0x1fc00000 && < 0x1fe00000 => 0, // bios rom
      _ => 0, //ex("-"),
    };
  }

  @override
  void write16(int addr, int v) {
    final offset = addr & segMask[addr >> 29];
    ex(s) => _unimplemented("write16", s, addr, v);

    return switch (offset) {
      >= 0x00000000 && < 0x00200000 => mem.setUInt16LE(offset, v),
      >= 0x1f801000 && < 0x1f802000 => switch (offset & 0x1fff) {
          0x1070 => interruptStatus &= v.mask16,
          0x1074 => interruptMask = v.mask16,
          0x1100 => ex("Timer 0 Current Counter Value"),
          0x1104 => ex("Timer 0 Counter Mode"),
          0x1108 => ex("Timer 0 Counter Target Value"),
          0x1110 => ex("Timer 1 Current Counter Value"),
          0x1114 => ex("Timer 1 Counter Mode"),
          0x1118 => ex("Timer 1 Counter Target Value"),
          0x1120 => ex("Timer 2 Current Counter Value"),
          0x1124 => ex("Timer 2 Counter Mode"),
          0x1128 => ex("Timer 2 Counter Target Value"),
          >= 0x1c00 && < 0x1d80 => ex("spu voice"),
          0x1da8 => 0, // sound ram
          0x1daa => 0, // sound ctrl?
          >= 0x1d80 && < 0x1dc0 => ex("spu control"),
          >= 0x1dc0 && < 0x1e00 => ex("spu reverb"),
          _ => ex("expansion 1")
        },
      >= 0x1fc00000 && < 0x1fe00000 => 0, // bios rom
      _ => ex("-"),
    };
  }

  @override
  void write32(int addr, int v) {
    final offset = addr & segMask[addr >> 29];
    ex(s) => _unimplemented("write32", s, addr, v);

    return switch (offset) {
      >= 0x00000000 && < 0x00200000 => mem.setUInt32LE(offset, v),
      >= 0x1f000000 && < 0x1f008000 => ex("expansion 1"),
      >= 0x1f800000 && < 0x1f800400 =>
        useScratchPad ? scratchPad.setUInt32LE(offset - 0x1f800000, v) : 0,
      >= 0x1f801000 && < 0x1f802000 => switch (offset & 0x1fff) {
          0x1000 => ex("memory control 1: Expansion 1 Base Address"),
          0x1004 => ex("memory control 1: Expansion 2 Base Address"),
          0x1008 => ex("memory control 1: Expansion 1 Delay/Size"),
          0x100c => ex("memory control 1: Expansion 3 Delay/Size"),
          0x1010 => ex("memory control 1: BIOS ROM"),
          0x1014 => ex("memory control 1: SPU Delay/Size"),
          0x1018 => ex("memory control 1: CDROM Delay/Size"),
          0x101c => ex("memory control 1: Expansion 2 Delay/Size"),
          0x1020 => ex("memory control 1: COMMON_DELAY"),
          0x1040 => ex("joy_data Data"),
          0x1050 => ex("memory control 2: RAM base address"),
          0x1060 => ex("memory control 2: RAM size"),
          0x1070 => interruptStatus &= v,
          0x1074 => interruptMask = v,
          >= 0x1080 && < 0x10f0 => switch (offset & 0x0c) {
              0x00 => dma[offset >> 4 & 0x07].startAddr = v,
              0x04 => dma[offset >> 4 & 0x07].blockCtrl = v,
              0x08 => dma[offset >> 4 & 0x07].channelCtrl = v,
              _ => ex("DMA")
            },
          0x10f0 => dmaControl = v,
          0x10f4 => dmaInterrupt = v,
          0x1810 => gpu.writeGp0(v), // gp0
          0x1814 => gpu.writeGp1(v), // gp1
          0x1820 => ex("mdec command"),
          0x1824 => ex("mdec control"),
          >= 0x1c00 && < 0x1c80 => ex("spu voice"),
          >= 0x1d80 && < 0x1dc0 => ex("spu control"),
          >= 0x1dc0 && < 0x1e00 => ex("spu reverb"),
          _ => ex("I/O Ports")
        }, // I/O ports
      >= 0x1f802000 && < 0x1f802100 => ex("expansion 2"), // expansion 2
      >= 0x1fa00000 && < 0x1fc00000 => 0, // expansion 3
      >= 0x1fc00000 && < 0x1fe00000 => 0, // bios rom
      _ => addr == 0xfffe0130 // cache control
          ? useScratchPad = v.bit3 && v.bit7
          : 0xffffffff,
    };
  }

  void execDma(int count) {
    for (int ch = 0; ch < 7; ch++) {
      final d = dma[ch];

      if (d.ioAddr == 0) {
        continue;
      }

      if (!d.enabled || !d.running) {
        continue;
      }

      debugLog("DMA$ch start: ${d.dump()}");

      // otc fills memory with 0xff
      if (ch == 6) {
        if (d.syncMode != 0 || !d.toRam) {
          continue;
        }

        if (d.size == 0) d.size = 0x10000;
        while (d.size > 1) {
          write32(d.addr, d.addr & 0x1fffff);
          d.addr += d.incr;
          d.size--;
        }
        debugLog("dma ch6 done");
        d.addr += d.incr;
        write32(d.addr, 0xffffff);
        completeDma(ch);
        continue;
      }

      switch (d.syncMode) {
        case 0:
          if (d.size == 0) d.size = 0x10000;
          while (d.size > 0) {
            d.toRam
                ? write32(d.addr, read32(d.ioAddr))
                : write32(d.ioAddr, read32(d.addr));
            d.addr += d.incr;
            d.size--;
          }

          completeDma(ch);

        case 1:
          while (d.amount-- > 0) {
            for (int i = 0; i < d.size; i++) {
              d.toRam
                  ? write32(d.addr, read32(d.ioAddr))
                  : write32(d.ioAddr, read32(d.addr));
              d.addr += d.incr;
            }

            completeDma(ch, partial: true);
          }

          completeDma(ch);

        case 2:
          while (d.addr != 0xffffff) {
            final node = read32(d.addr);

            for (int i = 0; i < node >> 24; i++) {
              d.addr += d.incr;
              write32(d.ioAddr, read32(d.addr));
            }

            d.addr = node.mask24;

            completeDma(ch, partial: true);
          }

          completeDma(ch);
      }
    }
  }

  void completeDma(int ch, {bool partial = false}) {
    final d = dma[ch];

    if (!partial) {
      d.running = false;
    }

    if (d.useInterrupt && (!partial || d.intterruptOnChunks)) {
      _dmaInterrupt |= (1 << ch) << 24;
    }
  }

  int _unimplemented(String op, String device, int addr, int value) {
    debugLog('$op: ${addr.hex32} ${value.hex32} pc:${cpu.pc.hex32} $device');
    return 0xffffffff;
  }
}
