/// Memory accesses needed by the 6502 family CPUs. Console address maps and
/// any address translation (such as the HuC6280 MPR paging) live in the
/// individual core implementations.
abstract interface class Cpu6502Bus {
  int read(int addr);
  void write(int addr, int data);
}
