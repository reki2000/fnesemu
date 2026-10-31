import 'r5900.dart';

/// COP2: the interface to VU0. The 128-bit transfers and control register
/// moves are handled here; macro instructions are executed by the VU.
extension R5900Cop2 on R5900 {
  bool executeCop2(int ir) {
    final v = vu0;
    if (v == null) return false;
    final rs = (ir >> 21) & 31, rt = (ir >> 16) & 31, rd = (ir >> 11) & 31;
    switch (rs) {
      case 1: // QMFC2
        if (rt != 0) {
          gpr[rt * 2] = v.vf[rd * 4] | (v.vf[rd * 4 + 1] << 32);
          gpr[rt * 2 + 1] = v.vf[rd * 4 + 2] | (v.vf[rd * 4 + 3] << 32);
        }
      case 2: // CFC2
        setReg(rt, v.readControl(rd).toSigned(32));
      case 5: // QMTC2
        if (rd != 0) {
          v.vf[rd * 4] = gpr[rt * 2];
          v.vf[rd * 4 + 1] = gpr[rt * 2] >>> 32;
          v.vf[rd * 4 + 2] = gpr[rt * 2 + 1];
          v.vf[rd * 4 + 3] = gpr[rt * 2 + 1] >>> 32;
        }
      case 6: // CTC2
        v.writeControl(rd, reg(rt));
      default:
        if (rs < 16) return false;
        v.macro(ir);
    }
    return true;
  }

  void loadQuadToVf(int vfReg, int address) {
    final v = vu0;
    if (v == null || vfReg == 0) return;
    for (var c = 0; c < 4; c++) {
      v.vf[vfReg * 4 + c] = bus.read32(address + c * 4);
    }
  }

  void storeQuadFromVf(int vfReg, int address) {
    final v = vu0;
    if (v == null) return;
    for (var c = 0; c < 4; c++) {
      bus.write32(address + c * 4, v.vf[vfReg * 4 + c]);
    }
  }
}
