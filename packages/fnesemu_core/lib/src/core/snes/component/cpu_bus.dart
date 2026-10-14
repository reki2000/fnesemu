import 'cpu.dart';

/// the memory a 65816 core runs on: the main bus, or the SA-1's own bus
abstract class CpuBus {
  set cpu(Cpu cpu);

  int read(int addr);
  void write(int addr, int data);

  /// the 16-bit interrupt or reset vector at [addr] in bank 0
  int readVector(int addr);
}
