/// A simple bus interface for MIPS memory accesses, shared by the cores that embed an R3000.
abstract class R3000Bus {
  int read8(int addr);
  int read16(int addr);
  int read32(int addr);
  void write8(int addr, int value);
  void write16(int addr, int value);
  void write32(int addr, int value);
}
