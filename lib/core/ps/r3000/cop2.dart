part of 'r3000.dart';

extension Cop2 on R3000 {
  int readCop2Ctrl(int reg) {
    return 0;
  }

  void writeCop2Ctrl(int reg, int value) {}

  int readCop2(int reg) {
    return 0;
  }

  void writeCop2(int reg, int value) {}

  execCop2(int inst32) {
    final funct = inst32 & 0x3f;
    return switch (funct) {
      0x01 => "rtps",
      0x06 => "nclip",
      0x0c => "op",
      0x10 => "dpcs",
      0x11 => "intpl",
      0x12 => "mvmva",
      0x13 => "ncds",
      0x14 => "cdp",
      0x16 => "ncdt",
      0x1b => "nccs",
      0x1c => "cc",
      0x1e => "ncs",
      0x20 => "nct",
      0x28 => "sqr",
      0x29 => "dcpl",
      0x2a => "dpct",
      0x2d => "avsz3",
      0x2e => "avsz4",
      0x30 => "rtpt",
      0x3d => "gpf",
      0x3e => "gpl",
      0x3f => "ncct",
      _ => R3000._unknown(inst32),
    };
  }
}
