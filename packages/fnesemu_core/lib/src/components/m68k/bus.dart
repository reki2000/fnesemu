/// Memory accesses needed by the 68000 CPU. Console address maps live in
/// the individual core implementations.
abstract interface class M68Bus {
  int read8(int address);
  int read16(int address);
  void write8(int address, int value);
  void write16(int address, int value);
}
