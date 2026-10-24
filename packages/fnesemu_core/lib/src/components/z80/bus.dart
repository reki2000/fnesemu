/// Memory and I/O accesses needed by the Z80 CPU. Console address maps live
/// in the individual core implementations.
abstract interface class Z80Bus {
  int read(int addr);
  void write(int addr, int data);
  int input(int port);
  void output(int port, int data);
}
