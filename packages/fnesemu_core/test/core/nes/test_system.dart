// a system and images shared by the nes tests
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/nes/component/apu.dart';
import 'package:fnesemu_core/src/core/nes/component/bus.dart';
import 'package:fnesemu_core/src/core/nes/component/cpu.dart';
import 'package:fnesemu_core/src/core/nes/component/ppu.dart';
import 'package:fnesemu_core/src/core/nes/mapper/mapper.dart';

/// a mapper whose 0x6000-0xffff is RAM, so that a test can place a program
/// and vectors
class RamMapper extends Mapper {
  final mem = Uint8List(0xa000);

  @override
  void init() {}

  @override
  int read(int addr) => mem[addr - 0x6000];

  @override
  void write(int addr, int data) => mem[addr - 0x6000] = data;
}

/// the cpu, ppu and apu on a bus with a [RamMapper]
class TestSystem {
  final bus = Bus();
  late final Cpu cpu;
  late final Ppu ppu;
  late final Apu apu;
  final mapper = RamMapper();

  TestSystem() {
    cpu = Cpu(bus);
    ppu = Ppu(bus);
    apu = Apu(bus);
    bus.mapper = mapper;
  }

  void load(int addr, List<int> code) {
    for (int i = 0; i < code.length; i++) {
      mapper.mem[addr + i - 0x6000] = code[i];
    }
  }

  void vector(int addr, int target) {
    load(addr, [target & 0xff, target >> 8]);
  }

  void reset(int pc) {
    vector(0xfffc, pc);
    bus.onReset();
  }
}

/// an iNES image with 1 x 16k prg and no chr
Uint8List ines({
  int flags6 = 0,
  List<int> header7to15 = const [0, 0, 0, 0, 0, 0, 0, 0, 0],
}) {
  return Uint8List.fromList([
    0x4e, 0x45, 0x53, 0x1a, 1, 0, flags6, ...header7to15, //
    ...List.filled(0x4000, 0),
  ]);
}
