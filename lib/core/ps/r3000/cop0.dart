part of 'r3000.dart';

extension Cop0 on R3000 {
  int readCop0(int reg) {
    return switch (reg) {
      8 => badvaddr,
      12 => sr,
      13 => cause,
      14 => epc,
      _ => 0,
    };
  }

  void writeCop0(int reg, int value) {
    switch (reg) {
      case 8:
        badvaddr = value;
      case 12:
        sr = value;
      case 13:
        cause = value;
      case 14:
        epc = value;
    }
  }

  void execCop0(int inst32) {
    switch (inst32 & 0x3f) {
      case 0x10: // rfe
        sr = sr.masked(0x0f, sr >> 2);
      default:
        R3000._unknown(inst32);
    }
  }
}
