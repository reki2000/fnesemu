/// The addresses and tables a compiled block refers to.
abstract interface class NativeEnv {
  bool get win64;
  int get blockEntryFn;

  /// the mask applied to guest addresses before the page lookup
  int get addrMask;
  int get pageShift;

  /// the shared exit address published by the native trampoline
  int get exitStub;

  /// native addresses of the read and write functions for unmapped pages
  int get readFn;
  int get writeFn;

  int helperFn(int id);

  /// the host address of a guest word mapped at compile time, or null
  int? guardAddr(int guestAddr);

  /// a link slot which will hold the entry of the block (pc, tag)
  int slotFor(int pc, int tag);
}
