/// Memory bus seen from an SH-2 CPU (big-endian), shared by the cores that
/// plug the shared SH-2 interpreter and on-chip peripherals into their own
/// address maps.
abstract class Sh2Bus {
  int read8(int address);
  int read16(int address);
  int read32(int address);
  void write8(int address, int value);
  void write16(int address, int value);
  void write32(int address, int value);
}
