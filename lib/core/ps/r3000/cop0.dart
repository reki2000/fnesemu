part of 'r3000.dart';

extension Cop0 on R3000 {
  int readCop0(int reg) {
    return switch (reg) {
      6 => tar,
      8 => badvaddr,
      12 => sr,
      13 => cause,
      14 => epc,
      15 => 0x00000002,
      _ => 0,
    };
  }

  void writeCop0(int reg, int value) {
    switch (reg) {
      case 6:
        tar = value;
      case 8:
        badvaddr = value;
      case 12:
        // debugLog("sr <- ${value.hex32}");
        sr = value;
      case 13:
        cause = cause.masked(0x30, value);
      case 14:
        epc = value;
    }
  }

  void execCop0(int inst32) {
    switch (inst32 & 0x3f) {
      case 0x10: // rfe
        sr = sr.masked(0x0f, sr >> 2);
        sr &= ~0x30;
      // debugLog(
      //     "cpu: rfe sr:${sr.hex32} cause:${cause.hex32} epc:${epc.hex32}");
      default:
        R3000._unknown(inst32);
    }
  }
}
