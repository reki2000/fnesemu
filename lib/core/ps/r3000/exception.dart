/// Exception constants for the emulator
class Exception {
  static const interrupt = 0x00;
  static const readalign = 0x04;
  static const writeAlign = 0x05;
  static const syscall = 0x08;
  static const break_ = 0x09;
  static const illegalInstruction = 0x0a;
  static const overflow = 0x0c;
}

class ReadMisalignException implements Exception {
  final int addr;

  ReadMisalignException(this.addr);
}

class WriteMisalignException implements Exception {
  final int addr;

  WriteMisalignException(this.addr);
}

class UnknownOpcodeException implements Exception {}
