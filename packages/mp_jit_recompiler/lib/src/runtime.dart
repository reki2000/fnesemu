import 'dart:typed_data';

import 'interp_runtime.dart';
import 'ir.dart';
import 'native_stub.dart'
    if (dart.library.io) 'native_ffi.dart'
    if (dart.library.js_interop) 'wasm_runtime.dart' as host;

/// A host function called from a block; arguments are unsigned 32-bit
/// values and the result is truncated to 32 bits.
typedef JitHelper = int Function(int a, int b, int c);

/// Reads 1, 2 or 4 raw bytes at an unmapped guest address, packed with the
/// lowest-address byte in the low bits. IR byte order is applied afterwards.
typedef JitRead = int Function(int addr, int size);

/// Writes 1, 2 or 4 raw bytes, lowest-address byte in the low bits. The IR
/// runtime applies the access byte order before calling this function.
typedef JitWrite = void Function(int addr, int size, int value);

/// Runs [IrBlock]s on guest state shared with the host.
///
/// The host owns the guest state through views returned by [ctx] and
/// [alloc], so nothing is copied when a run starts or returns. Guest
/// addresses are masked with `addrMask` and mapped in 4KiB pages; an
/// access to an unmapped page calls the read or write function given to
/// the constructor. Blocks are found by (pc, tag); a run continues from
/// block to block until one exits, and returns its reason.
abstract class JitRuntime {
  static const pageBits = 12;
  static const pageSize = 1 << pageBits;

  /// The compiled runtime of this host: x86-64 on supported native hosts,
  /// Wasm on the Web, or null when compilation is unavailable or blocked.
  static JitRuntime? native(
          {required int ctxWords,
          required int addrMask,
          required JitRead read,
          required JitWrite write}) =>
      host.create(ctxWords, addrMask, read, write);

  /// a runtime that interprets the IR, available on every platform
  static JitRuntime interpreter(
          {required int ctxWords,
          required int addrMask,
          required JitRead read,
          required JitWrite write}) =>
      IrInterpreterRuntime(ctxWords, addrMask, read, write);

  /// Whether [native] can compile blocks on this host.
  static bool get nativeSupported => host.supported;

  final int addrMask;
  final JitRead read;
  final JitWrite write;

  JitRuntime(this.addrMask, this.read, this.write);

  /// the context words; the first [JitCtx.user] words are reserved
  Uint32List get ctx;

  /// How often a host should see a block run before installing it. Below
  /// it, running the guest code in the host interpreter costs less than
  /// compiling; an estimate from the compile time of this executor.
  int get compileThreshold => 1;

  /// Width and byte-order capabilities of the executor, not of its host.
  /// Compiled i64/big-endian emission can be added without changing i32 IR.
  bool get supportsI64 => false;
  bool get supportsBigEndian => false;

  bool supportsBlock(IrBlock block) =>
      (supportsI64 || !block.usesI64) &&
      (supportsBigEndian || !block.usesBigEndian);

  /// Validate before compiling or publishing links to a block. Unsupported
  /// widths must never be silently truncated by a narrower backend.
  void checkBlock(IrBlock block) {
    block.verify(ctxWords: ctx.length);
    if (!supportsBlock(block)) {
      throw UnsupportedError(
          'executor does not support this IR width or byte order');
    }
  }

  /// zeroed memory which can be mapped with [mapPages]
  Uint8List alloc(int size);

  int get exitPc => ctx[JitCtx.exitPc];
  int get exitTag => ctx[JitCtx.exitTag];

  /// the read and write pages: a host buffer and its offset for each page
  late final readPages =
      List<(Uint8List, int)?>.filled((addrMask >>> pageBits) + 1, null);
  late final writePages =
      List<(Uint8List, int)?>.filled((addrMask >>> pageBits) + 1, null);

  /// maps [size] bytes of guest memory at [guestAddr] to [host] from
  /// [offset]; [host] must be returned by [alloc]
  void mapPages(int guestAddr, int size, Uint8List host,
      {int offset = 0, bool read = true, bool write = true}) {
    if ((guestAddr | size | offset) & (pageSize - 1) != 0) {
      throw ArgumentError('unaligned page mapping');
    }
    if (offset + size > host.length) {
      throw ArgumentError('page mapping beyond the host buffer');
    }
    for (int p = 0; p < size; p += pageSize) {
      final page = ((guestAddr + p) & addrMask) >>> pageBits;
      if (read) setPage(false, page, (host, offset + p));
      if (write) setPage(true, page, (host, offset + p));
    }
  }

  void unmapPages(int guestAddr, int size,
      {bool read = true, bool write = true}) {
    for (int p = 0; p < size; p += pageSize) {
      final page = ((guestAddr + p) & addrMask) >>> pageBits;
      if (read) setPage(false, page, null);
      if (write) setPage(true, page, null);
    }
  }

  void setPage(bool write, int page, (Uint8List, int)? host) =>
      (write ? writePages : readPages)[page] = host;

  /// the word at [addr] in mapped memory, or null if it is unmapped
  int? mappedWord(int addr, {IrEndian endian = IrEndian.little}) {
    final masked = addr & addrMask;
    final page = readPages[masked >>> pageBits];
    if (page == null) return null;
    final (host, offset) = page;
    return host.buffer.asByteData(host.offsetInBytes).getUint32(
        offset + (masked & (pageSize - 1)),
        endian == IrEndian.big ? Endian.big : Endian.little);
  }

  /// registers [f] and returns its id for [IrBuilder.call]
  int addHelper(JitHelper f);

  bool contains(int pc, int tag);

  /// compiles [block], replacing the block with the same key
  void install(IrBlock block);

  /// removes the block (pc, tag); blocks linked to it miss afterwards
  void invalidate(int pc, int tag);

  /// removes every block
  void clear();

  /// runs from the block (pc, tag) until a block exits, and returns the
  /// reason; see [JitReason] and [JitCtx]
  int run(int pc, int tag);

  void dispose();
}
