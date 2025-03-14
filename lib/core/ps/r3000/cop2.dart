part of 'r3000.dart';

extension Cop2 on R3000 {
  static final regs = List.filled(32, 0);
  static final regsCtrl = List.filled(32, 0);

  int readCop2Ctrl(int reg) {
    return regsCtrl[reg & 0x1f];
  }

  void writeCop2Ctrl(int reg, int value) {
    debugLog("write cop2ctrl: $reg, ${value.hex32}");
    regsCtrl[reg & 0x1f] = value;
  }

  int readCop2(int reg) {
    return regs[reg & 0x1f];
  }

  void writeCop2(int reg, int value) {
    debugLog("write cop2: $reg, ${value.hex32}");
    regs[reg & 0x1f] = value;
  }

  execCop2(int inst32) {
    final funct = inst32 & 0x3f;
    return switch (funct) {
      0x01 => _unimplemented("rtps"),
      0x06 => _unimplemented("nclip"),
      0x0c => _unimplemented("op"),
      0x10 => _unimplemented("dpcs"),
      0x11 => _unimplemented("intpl"),
      0x12 => _unimplemented("mvmva"),
      0x13 => _unimplemented("ncds"),
      0x14 => _unimplemented("cdp"),
      0x16 => _unimplemented("ncdt"),
      0x1b => _unimplemented("nccs"),
      0x1c => _unimplemented("cc"),
      0x1e => _unimplemented("ncs"),
      0x20 => _unimplemented("nct"),
      0x28 => _unimplemented("sqr"),
      0x29 => _unimplemented("dcpl"),
      0x2a => _unimplemented("dpct"),
      0x2d => _unimplemented("avsz3"),
      0x2e => _unimplemented("avsz4"),
      0x30 => _unimplemented("rtpt"),
      0x3d => _unimplemented("gpf"),
      0x3e => _unimplemented("gpl"),
      0x3f => _unimplemented("ncct"),
      _ => R3000._unknown(inst32),
    };
  }

  void _unimplemented(String s) {
    debugLog("unimplemented: $s");
  }
}
