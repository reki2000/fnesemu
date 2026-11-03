/// A COP2 device attached to an [R3000Core]: the register and control transfers and the command word of the coprocessor instructions.
///
/// A core without a COP2 attached leaves the interface unimplemented, and the core raises the coprocessor-unusable or reserved-instruction exception of its variant instead.
abstract class R3000Cop2 {
  int readReg(int reg);
  int readCtrl(int reg);
  void writeReg(int reg, int value);
  void writeCtrl(int reg, int value);
  void execCmd(int inst32);
}
