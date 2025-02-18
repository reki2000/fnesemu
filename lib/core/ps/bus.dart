import 'dart:typed_data';

import 'package:fnesemu/core/ps/r3000/r3000.dart';
import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import 'gpu.dart';

class Bus implements BusR3000 {
  final mem = Uint8List(2 * 1024 * 1024);
  final rom = Uint8List(1024 * 512);

  final scratchPad = Uint8List(1024);
  bool useScratchPad = false;

  int interruptStatus = 0;
  int interruptMask = 0;

  final segMask =
      [32, 32, 32, 32, 31, 29, 32, 32].map((e) => (1 << e) - 1).toList();

  late final Gpu gpu;
  late final R3000 cpu;

  Bus();

  @override
  int read8(int addr) => read32(addr & ~0x03) >> (8 * (addr & 0x03)) & 0xff;

  @override
  int read16(int addr) => read32(addr & ~0x03) >> (16 * (addr & 0x01)) & 0xffff;

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
          0x1814 => gpu.read(), // gpu status
          0x1dac => 0, // too many unknowns
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
      _ => ex("-"),
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
          >= 0x1080 && < 0x1090 => ex("dma channel 0 - MDEC in"),
          >= 0x1090 && < 0x10a0 => ex("dma channel 1 - MDEC out"),
          >= 0x10a0 && < 0x10b0 => ex("dma channel 2 - GPU"),
          >= 0x10b0 && < 0x10c0 => ex("dma channel 3 - CDROM"),
          >= 0x10c0 && < 0x10d0 => ex("dma channel 4 - SPU"),
          >= 0x10d0 && < 0x10e0 => ex("dma channel 5 - PIO"),
          >= 0x10e0 && < 0x10f0 => ex("dma channel 6 - OTC"),
          0x10f0 => ex("dma control"),
          0x10f4 => ex("dma interrupt"),
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

  int _unimplemented(String op, String device, int addr, int value) {
    print('$op: ${addr.hex32} ${value.hex32} pc:${cpu.pc.hex32} $device');
    return 0xdeadbeef;
  }
}
