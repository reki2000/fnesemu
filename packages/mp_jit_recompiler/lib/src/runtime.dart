import 'dart:typed_data';

import 'compilation_stats.dart';
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

/// Diagnostic callback after an actual native return, including zero-work exits.
/// [budget] and [cycles] describe the complete linked native invocation.
/// A null [faultAddress] means no fault address was observed; 0xffffffff is
/// reserved as the diagnostic sentinel. Callbacks perturb host throughput.
typedef JitNativeExit = void Function(int entryPc, int exitPc, int reason,
    int budget, int cycles, int stop, int? faultAddress);

/// The map key of a block entry. The pc and the tag are 32-bit context words.
/// An int key avoids allocating and hashing a record on every dispatch.
@pragma('vm:prefer-inline')
int jitKey(int pc, int tag) => tag << 32 | pc & 0xffffffff;

/// Runs [IrBlock]s on guest state shared with the host.
///
/// The host owns the guest state through views returned by [ctx] and
/// [alloc], so nothing is copied when a run starts or returns. Guest
/// addresses are masked with `addrMask` and mapped in fixed-size pages; an
/// access to an unmapped page calls the read or write function given to
/// the constructor. Blocks are found by (pc, tag); a run continues from
/// block to block until one exits, and returns its reason.
abstract class JitRuntime {
  /// Entries into compiled code (FFI on native hosts, the dispatcher on Wasm),
  /// including zero-work returns but excluding lookup misses.
  /// Native links between blocks do not increment this lifetime counter.
  int nativeEntries = 0;

  /// Optional return-level diagnostics; does not instrument individual blocks.
  JitNativeExit? onNativeExit;

  /// Optional compilation and cache telemetry; enabling it does not clear code.
  JitCompilationStats? compilationStats;

  /// Diagnostic histogram of positive guest cycles actually consumed per entry.
  /// Enable before installing blocks; entry callbacks change host throughput.
  final executedBlockCycles = <int, int>{};

  /// Profiles entries into blocks; the reference executor does not support it.
  void enableBlockProfiling() {
    throw UnsupportedError('Block profiling requires a compiled runtime');
  }

  static const pageBits = 12;
  static const pageSize = 1 << pageBits;

  /// The compiled runtime of this host: x86-64 or ARM64 on native hosts,
  /// Wasm on the Web, or null when compilation is unavailable or blocked.
  static JitRuntime? native(
          {required int ctxWords,
          required int addrMask,
          required JitRead read,
          required JitWrite write,
          int pageShift = pageBits}) =>
      host.create(ctxWords, addrMask, read, write, pageShift);

  /// a runtime that interprets the IR, available on every platform
  static JitRuntime interpreter(
          {required int ctxWords,
          required int addrMask,
          required JitRead read,
          required JitWrite write,
          int pageShift = pageBits}) =>
      IrInterpreterRuntime(ctxWords, addrMask, read, write, pageShift);

  /// Whether [native] can compile blocks on this host.
  static bool get nativeSupported => host.supported;

  /// Claims the host's shared guest memory pool for a new core, on hosts
  /// that have one: every live runtime is retired and the pool returns to
  /// its initial state, so the core's runtimes allocate from an empty pool
  /// instead of competing with a previous core's allocations until they
  /// run out. Hosts whose runtimes own their memory do nothing. A core
  /// calls this once when it initializes, before creating its runtimes.
  static void resetPool() => host.resetPool();

  final int addrMask;
  final JitRead read;
  final JitWrite write;

  /// Guest mapping granularity, independent of the host allocation page size.
  final int pageShift;
  int get pageBytes => 1 << pageShift;

  JitRuntime(this.addrMask, this.read, this.write,
      [this.pageShift = pageBits]) {
    if (pageShift < 3 || pageShift > pageBits) {
      throw ArgumentError.value(
          pageShift, 'pageShift', 'expected 3 through 12');
    }
  }

  /// the context words; the first [JitCtx.user] words are reserved
  Uint32List get ctx;

  /// How often a host should see a block run before installing it. Below
  /// it, running the guest code in the host interpreter costs less than
  /// compiling; an estimate from the compile time of this executor.
  int get compileThreshold => 1;

  /// Validate before compiling or publishing links to a block. Every
  /// executor supports the complete IR on every platform.
  void checkBlock(IrBlock block) {
    block.checkContext(ctx.length);
    for (final inst in block.insts) {
      if (inst.translation < 0) continue;
      final id = inst.translationTable;
      if (id >= translationTables.length ||
          translationTables[id].write != (inst.op == IrOp.store) ||
          inst.translationKey >= pageBytes) {
        throw ArgumentError('invalid translation $id/${inst.translationKey}');
      }
    }
  }

  /// zeroed memory which can be mapped with [mapPages]
  Uint8List alloc(int size);

  int get exitPc => ctx[JitCtx.exitPc];
  int get exitTag => ctx[JitCtx.exitTag];

  /// The read and write pages: a host buffer and its offset for each page.
  late final readPages =
      List<(Uint8List, int)?>.filled((addrMask >>> pageShift) + 1, null);
  late final writePages =
      List<(Uint8List, int)?>.filled((addrMask >>> pageShift) + 1, null);

  /// Allows buffers allocated by [owner] to be mapped in this runtime.
  /// The owner must outlive this runtime's mappings and compiled execution.
  /// Executors with separate linear memories may reject sharing.
  void shareBuffer(JitRuntime owner, Uint8List buffer) {
    throw UnsupportedError('This executor cannot share another runtime buffer');
  }

  /// maps [size] bytes of guest memory at [guestAddr] to [host] from
  /// [offset]; [host] must be returned by [alloc]
  void mapPages(int guestAddr, int size, Uint8List host,
      {int offset = 0, bool read = true, bool write = true}) {
    if ((guestAddr | size | offset) & (pageBytes - 1) != 0) {
      throw ArgumentError('unaligned page mapping');
    }
    if (offset + size > host.length) {
      throw ArgumentError('page mapping beyond the host buffer');
    }
    for (int p = 0; p < size; p += pageBytes) {
      final page = ((guestAddr + p) & addrMask) >>> pageShift;
      if (read) setPage(false, page, (host, offset + p));
      if (write) setPage(true, page, (host, offset + p));
    }
  }

  void unmapPages(int guestAddr, int size,
      {bool read = true, bool write = true}) {
    for (int p = 0; p < size; p += pageBytes) {
      final page = ((guestAddr + p) & addrMask) >>> pageShift;
      if (read) setPage(false, page, null);
      if (write) setPage(true, page, null);
    }
  }

  void setPage(bool write, int page, (Uint8List, int)? host) {
    (write ? writePages : readPages)[page] = host;
    // Slots follow their guest page, for example into code protection.
    for (var id = 0; id < translationTables.length; id++) {
      final table = translationTables[id];
      if (table.write != write || table._live == 0) continue;
      final pages = table._pages;
      for (var slot = 0; slot < pages.length; slot++) {
        if (pages[slot] != page) continue;
        if (host == null) {
          _clearSlot(id, slot);
        } else {
          writeTranslationSlot(id, slot, table._keys[slot], host);
        }
      }
    }
  }

  /// The translation tables, by the id that [IrTranslation.table] holds.
  final translationTables = <JitTranslationTable>[];

  /// Adds a table of [slots] virtual pages, a power of two, for loads or,
  /// with [write], for stores, and returns its id. Guest addresses from
  /// [directStart] up to [directEnd] bypass the table.
  int addTranslationTable({
    required bool write,
    int slots = 1024,
    int directStart = 0,
    int directEnd = 0,
  }) {
    if (slots <= 0 || slots & (slots - 1) != 0 || slots > 1 << 20) {
      throw ArgumentError.value(slots, 'slots', 'expected a power of two');
    }
    if (directStart < 0 ||
        directEnd > 0x100000000 ||
        directEnd < directStart ||
        (directStart | directEnd) & (pageBytes - 1) != 0) {
      throw ArgumentError('invalid direct window');
    }
    translationTables.add(
      JitTranslationTable._(write, slots, directStart, directEnd),
    );
    final id = translationTables.length - 1;
    createTranslationTable(id);
    return id;
  }

  /// Maps the virtual page of [address] under [key] to the guest page of
  /// [physical]. The slot stays empty while that page is unmapped for the
  /// table's access.
  void mapTranslation(int table, int address, int key, int physical) {
    if (key <= 0 || key >= pageBytes) {
      throw ArgumentError.value(key, 'key', 'expected 1 to the page size');
    }
    final t = translationTables[table];
    final slot = t.slotOf(address, pageShift);
    final page = (physical & addrMask) >>> pageShift;
    final host = (t.write ? writePages : readPages)[page];
    if (host == null) {
      _clearSlot(table, slot);
      return;
    }
    if (t._keys[slot] == 0) t._live++;
    final slotKey = (address & ~(pageBytes - 1) & 0xffffffff) | key;
    t._keys[slot] = slotKey;
    t._pages[slot] = page;
    writeTranslationSlot(table, slot, slotKey, host);
  }

  /// Empties the slot of [address] when it holds that virtual page.
  void unmapTranslation(int table, int address) {
    final t = translationTables[table];
    final slot = t.slotOf(address, pageShift);
    if (t._keys[slot] != 0 &&
        (t._keys[slot] ^ address) & ~(pageBytes - 1) & 0xffffffff == 0) {
      _clearSlot(table, slot);
    }
  }

  /// Empties every slot of a table.
  void clearTranslations(int table) {
    final t = translationTables[table];
    if (t._live == 0) return;
    for (var slot = 0; slot < t.slots; slot++) {
      if (t._keys[slot] != 0) _clearSlot(table, slot);
    }
  }

  /// The guest address that [address] translates to under [key], or null
  /// when its slot misses. Addresses in the direct window are returned as
  /// they are.
  int? translate(int table, int key, int address) {
    final t = translationTables[table];
    address &= 0xffffffff;
    if (t.isDirect(address)) return address;
    final slot = t.slotOf(address, pageShift);
    if (t._keys[slot] != ((address & ~(pageBytes - 1)) | key)) return null;
    return (t._pages[slot] << pageShift) | (address & (pageBytes - 1));
  }

  void _clearSlot(int table, int slot) {
    final t = translationTables[table];
    if (t._keys[slot] != 0) t._live--;
    t._keys[slot] = 0;
    t._pages[slot] = -1;
    writeTranslationSlot(table, slot, 0, null);
  }

  /// Backend hooks for the storage of a table that compiled code reads.
  void createTranslationTable(int table) {}
  void writeTranslationSlot(
    int table,
    int slot,
    int key,
    (Uint8List, int)? host,
  ) {}

  /// the word at [addr] in mapped memory, or null if it is unmapped
  int? mappedWord(int addr, {IrEndian endian = IrEndian.little}) {
    final masked = addr & addrMask;
    final page = readPages[masked >>> pageShift];
    if (page == null) return null;
    final (host, offset) = page;
    return host.buffer.asByteData(host.offsetInBytes).getUint32(
        offset + (masked & (pageBytes - 1)),
        endian == IrEndian.big ? Endian.big : Endian.little);
  }

  /// registers [f] and returns its id for [IrBuilder.call]
  int addHelper(JitHelper f);

  bool contains(int pc, int tag);

  /// compiles [block], replacing the block with the same key
  void install(IrBlock block) {
    final stats = compilationStats;
    if (stats == null) {
      installBlock(block);
    } else {
      stats.measureInstallation(block, () => installBlock(block));
    }
  }

  /// Backend publication primitive; callers use [install] for shared telemetry.
  /// Returns emitted payload bytes, excluding allocation padding and shared stubs.
  /// The reference executor returns zero because it retains IR instead of code.
  int installBlock(IrBlock block);

  /// removes the block (pc, tag); blocks linked to it miss afterwards
  void invalidate(int pc, int tag);

  /// removes every block
  void clear();

  /// runs from the block (pc, tag) until a block exits, and returns the
  /// reason; see [JitReason] and [JitCtx]
  int run(int pc, int tag);

  void dispose();
}

/// Lifecycle helpers shared by the compiled runtimes (native and Wasm), which enter generated code, profile block entries and report native exits the same way; the interpreter does not use them.
mixin CompiledRuntimeHelpers on JitRuntime {
  int? _profileBudget;

  /// Starts profiling a block entry: the entry first closes the previous block's profile, then records the budget it starts from.
  void beginProfileBlock() {
    finishProfileBlock();
    _profileBudget = ctx[JitCtx.budget].toSigned(32);
  }

  /// Closes the current block's profile, recording the guest cycles it spent.
  void finishProfileBlock() {
    final before = _profileBudget;
    _profileBudget = null;
    if (before == null) return;
    final spent = before - ctx[JitCtx.budget].toSigned(32);
    // Refunded entries which execute no guest work are not executed blocks.
    if (spent > 0) {
      executedBlockCycles.update(spent, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  /// Refreshes the direct-mapped dynamic table entry for the current exit target, which a miss may have evicted, through the runtime's own table accessors.
  void refreshExitTarget(int? Function(int pc, int tag) lookup,
      void Function(int pc, int tag, int target) write) {
    final pc = exitPc, tag = exitTag;
    final target = lookup(pc, tag);
    if (target == null) return;
    write(pc, tag, target);
  }

  /// Enters compiled code for (pc, tag) through [enter], refreshes the dynamic table on a miss through [refresh], reports the exit to [onNativeExit] when one is registered, and closes the block profile when [profiled].
  int enterCompiled(int pc, int Function() enter, void Function() refresh,
      {required bool profiled}) {
    final observe = onNativeExit;
    final budget = ctx[JitCtx.budget].toSigned(32);
    if (observe != null) ctx[JitCtx.faultAddr] = 0xffffffff;
    try {
      final reason = enter();
      if (reason == JitReason.miss) refresh();
      if (observe != null) {
        final fault = ctx[JitCtx.faultAddr];
        observe(
          pc,
          exitPc,
          reason,
          budget,
          budget - ctx[JitCtx.budget].toSigned(32),
          ctx[JitCtx.stop],
          fault == 0xffffffff ? null : fault,
        );
      }
      return reason;
    } finally {
      if (profiled) finishProfileBlock();
    }
  }
}

/// A translation table of a runtime, see [JitRuntime.addTranslationTable].
final class JitTranslationTable {
  final bool write;
  final int slots, directStart, directEnd;
  final Uint32List _keys;
  final Int32List _pages;
  int _live = 0;
  JitTranslationTable._(
    this.write,
    this.slots,
    this.directStart,
    this.directEnd,
  ) : _keys = Uint32List(slots),
      _pages = Int32List(slots)..fillRange(0, slots, -1);

  bool isDirect(int address) => address >= directStart && address < directEnd;
  int slotOf(int address, int pageShift) =>
      ((address & 0xffffffff) >>> pageShift) & (slots - 1);
}
