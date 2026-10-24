import 'dart:ffi';
import 'dart:typed_data';

import 'arm64/backend.dart';
import 'ir.dart';
import 'native_env.dart';
import 'native_memory.dart';
import 'optimizer.dart';
import 'runtime.dart';
import 'x64/backend.dart';

/// Native publication includes instruction-cache synchronization and keeps
/// per-thread JIT write protection inside the native helper.
final class _Os {
  final bool win64;
  final bool arm64;
  _Os({this.win64 = false, this.arm64 = false});
  static final _Os? current = switch (Abi.current()) {
    Abi.linuxX64 || Abi.androidX64 => _Os(),
    Abi.windowsX64 => _Os(win64: true),
    Abi.linuxArm64 || Abi.androidArm64 || Abi.macosArm64 => _Os(arm64: true),
    Abi.windowsArm64 => _Os(arm64: true),
    _ => null,
  };
  int get pageSize => nativePageSize();
  int alloc(int size, {bool code = false}) =>
      nativeAlloc(size, code ? 1 : 0).address;
  void free(int address, int size) =>
      nativeFree(Pointer<Uint8>.fromAddress(address), size);
}

bool get supported => _Os.current != null;

JitRuntime? create(
  int ctxWords,
  int addrMask,
  JitRead read,
  JitWrite write,
  int pageShift,
) {
  final os = _Os.current;
  return os == null
      ? null
      : _NativeRuntime(os, ctxWords, addrMask, read, write, pageShift);
}

typedef _HelperC = Uint32 Function(Uint32, Uint32, Uint32);
typedef _EnterC = Uint32 Function(IntPtr);
typedef _Enter = int Function(int);

final class _NativeRuntime extends JitRuntime implements NativeEnv {
  final _Os _os;
  final _allocs = <(int, int)>[];
  final _hostAddr = Map<Uint8List, int>.identity();

  static const _codeSize = 64 << 20;
  static const _maxSlots = 1 << 19;

  late final int _ctxAddr, _readTable, _writeTable, _slots, _dyn, _code;
  late final Uint32List _ctx;
  late final Uint64List _readTableView, _writeTableView, _slotView, _dynView;
  late final _Enter _enter;
  late final int _codeStart;
  int _codeEnd = 0;
  bool _disposed = false;
  bool _failed = false;
  @override
  int blockEntryFn = 0;
  int? _profileBudget;

  @override
  void enableBlockProfiling() {
    _checkAlive();
    if (_blocks.isNotEmpty) throw StateError('Clear blocks before profiling');
    if (blockEntryFn != 0) return;
    blockEntryFn = _callable((_, __, ___) {
      _finishProfileBlock();
      _profileBudget = _ctx[JitCtx.budget].toSigned(32);
      return 0;
    });
  }

  void _finishProfileBlock() {
    final before = _profileBudget;
    _profileBudget = null;
    if (before == null) return;
    final spent = before - _ctx[JitCtx.budget].toSigned(32);
    // Refunded entries which execute no guest work are not executed blocks.
    if (spent > 0) {
      executedBlockCycles.update(spent, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  final _callables = <NativeCallable<_HelperC>>[];
  final _helperAddrs = <int>[];
  late final int _readFn, _writeFn;

  /// installed entries by key
  final _blocks = <(int, int), (int entry, int cost)>{};

  /// the link slots of each target key
  final _slotsOf = <(int, int), List<int>>{};
  int _slotCount = 0;

  @override
  late final int exitStub;

  _NativeRuntime(
    this._os,
    int ctxWords,
    super.addrMask,
    super.read,
    super.write,
    super.pageShift,
  ) {
    try {
      final pages = (addrMask >>> pageShift) + 1;
      _ctxAddr = _alloc(ctxWords * 4);
      _ctx = Pointer<Uint32>.fromAddress(_ctxAddr).asTypedList(ctxWords);
      _readTable = _alloc(pages * 8);
      _writeTable = _alloc(pages * 8);
      _readTableView = Pointer<Uint64>.fromAddress(
        _readTable,
      ).asTypedList(pages);
      _writeTableView = Pointer<Uint64>.fromAddress(
        _writeTable,
      ).asTypedList(pages);
      _slots = _alloc(_maxSlots * 8);
      _slotView = Pointer<Uint64>.fromAddress(_slots).asTypedList(_maxSlots);
      _dyn = _alloc(X64Backend.dynEntries << X64Backend.dynEntryBits);
      _dynView = Pointer<Uint64>.fromAddress(
        _dyn,
      ).asTypedList(X64Backend.dynEntries * 2);
      _code = _alloc(_codeSize, code: true);

      _readFn = _callable((a, b, c) => read(a, b));
      _writeFn = _callable((a, b, c) {
        write(a, c, c == 4 ? b : b & ((1 << (c * 8)) - 1));
        return 0;
      });

      final trampoline = _os.arm64
          ? Arm64Backend.trampoline
          : X64Backend.trampoline;
      final (bytes, exitOffset) = trampoline(
        win64: _os.win64,
        ctx: _ctxAddr,
        readTable: _readTable,
        writeTable: _writeTable,
        slots: _slots,
        dyn: _dyn,
      );
      _write(0, bytes);
      exitStub = _code + exitOffset;
      _codeStart = (bytes.length + 63) & ~63;
      _codeEnd = _codeStart;
      _enter = Pointer<NativeFunction<_EnterC>>.fromAddress(
        _code,
      ).asFunction<_Enter>();
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  int _alloc(int size, {bool code = false}) {
    final page = _os.pageSize;
    size = (size + page - 1) & ~(page - 1);
    final p = _os.alloc(size, code: code);
    if (p == 0) throw StateError('cannot allocate $size bytes');
    _allocs.add((p, size));
    return p;
  }

  int _callable(JitHelper f) {
    final c = NativeCallable<_HelperC>.isolateLocal(f, exceptionalReturn: 0)
      ..keepIsolateAlive = false;
    _callables.add(c);
    return c.nativeFunction.address;
  }

  void _write(int offset, List<int> bytes) {
    final buffer = _os.alloc(bytes.length);
    if (buffer == 0) throw StateError('cannot allocate code staging buffer');
    try {
      Pointer<Uint8>.fromAddress(
        buffer,
      ).asTypedList(bytes.length).setAll(0, bytes);
      if (nativeWrite(
            Pointer<Uint8>.fromAddress(_code + offset),
            Pointer<Uint8>.fromAddress(buffer),
            bytes.length,
          ) ==
          0) {
        throw StateError('cannot publish JIT code');
      }
    } finally {
      _os.free(buffer, bytes.length);
    }
  }

  @override
  Uint32List get ctx => _ctx;

  /// about 0.5ms to translate and install a block
  @override
  int get compileThreshold => 4;

  @override
  Uint8List alloc(int size) {
    final p = _alloc(size);
    final view = Pointer<Uint8>.fromAddress(p).asTypedList(size);
    _hostAddr[view] = p;
    return view;
  }

  @override
  void shareBuffer(JitRuntime owner, Uint8List buffer) {
    if (owner is! _NativeRuntime || !owner._hostAddr.containsKey(buffer)) {
      throw ArgumentError('buffer must belong to a live native runtime');
    }
    owner._checkAlive();
    _hostAddr[buffer] = owner._hostAddr[buffer]!;
  }

  @override
  void setPage(bool write, int page, (Uint8List, int)? host) {
    super.setPage(write, page, host);
    final entry = host == null ? 0 : _hostAddr[host.$1]! + host.$2;
    (write ? _writeTableView : _readTableView)[page] = entry;
  }

  @override
  int addHelper(JitHelper f) {
    _helperAddrs.add(_callable(f));
    return _helperAddrs.length - 1;
  }

  // NativeEnv

  @override
  bool get win64 => _os.win64;

  @override
  int get readFn => _readFn;

  @override
  int get writeFn => _writeFn;

  @override
  int helperFn(int id) => _helperAddrs[id];

  @override
  int? guardAddr(int guestAddr) {
    final masked = guestAddr & addrMask;
    final page = readPages[masked >>> pageShift];
    if (page == null) return null;
    return _hostAddr[page.$1]! + page.$2 + (masked & (pageBytes - 1));
  }

  @override
  int slotFor(int pc, int tag) {
    if (_slotCount == _maxSlots) throw _Full();
    final s = _slotCount++;
    (_slotsOf[(pc, tag)] ??= []).add(s);
    _slotView[s] = _blocks[(pc, tag)]?.$1 ?? 0;
    return s;
  }

  // JitRuntime

  @override
  bool contains(int pc, int tag) => _blocks.containsKey((pc, tag));

  @override
  int? blockCost(int pc, int tag) => _blocks[(pc, tag)]?.$2;

  @override
  int installBlock(IrBlock block) {
    _checkAlive();
    checkBlock(block);
    block = optimizeIrBlock(block);
    List<int> bytes;
    int at;
    try {
      at = _codeEnd;
      bytes = _os.arm64
          ? Arm64Backend.compile(block, _code + at, this)
          : X64Backend.compile(block, _code + at, this);
      if (at + bytes.length > _codeSize) throw _Full();
    } on _Full {
      clear();
      at = _codeEnd;
      bytes = _os.arm64
          ? Arm64Backend.compile(block, _code + at, this)
          : X64Backend.compile(block, _code + at, this);
    }
    try {
      _write(at, bytes);
    } catch (_) {
      // A failed protection change may leave existing code non-executable.
      // Keep shared guest buffers alive until their owner disposes the core.
      _failed = true;
      rethrow;
    }
    _codeEnd = (at + bytes.length + 15) & ~15;

    final key = (block.pc, block.tag);
    final entry = _code + at;
    _blocks[key] = (entry, block.cost);
    for (final s in _slotsOf[key] ?? const <int>[]) {
      _slotView[s] = entry;
    }
    final d = X64Backend.dynIndex(block.pc, block.tag) * 2;
    _dynView[d] = block.pc | block.tag << 32;
    _dynView[d + 1] = entry;
    return bytes.length;
  }

  @override
  void invalidate(int pc, int tag) {
    final key = (pc, tag);
    if (_blocks.remove(key) == null) return;
    compilationStats?.recordInvalidation(pc, tag);
    for (final s in _slotsOf[key] ?? const <int>[]) {
      _slotView[s] = 0;
    }
    final d = X64Backend.dynIndex(pc, tag) * 2;
    if (_dynView[d] == (pc | tag << 32)) _dynView[d + 1] = 0;
  }

  @override
  void clear() {
    compilationStats?.recordCacheClear(_blocks.length);
    _blocks.clear();
    _slotsOf.clear();
    _slotView.fillRange(0, _slotCount, 0);
    _slotCount = 0;
    _dynView.fillRange(0, _dynView.length, 0);
    _codeEnd = _codeStart;
  }

  @override
  int run(int pc, int tag) {
    _checkAlive();
    final entry = _blocks[(pc, tag)]?.$1;
    if (entry == null) {
      _ctx[JitCtx.exitReason] = JitReason.miss;
      _ctx[JitCtx.exitPc] = pc;
      _ctx[JitCtx.exitTag] = tag;
      return JitReason.miss;
    }
    nativeEntries++;
    final observe = onNativeExit;
    if (blockEntryFn == 0 && observe == null) {
      final reason = _enter(entry);
      if (reason == JitReason.miss) _refreshExitTarget();
      return reason;
    }
    final budget = _ctx[JitCtx.budget].toSigned(32);
    if (observe != null) _ctx[JitCtx.faultAddr] = 0xffffffff;
    try {
      final reason = _enter(entry);
      if (reason == JitReason.miss) _refreshExitTarget();
      if (observe != null) {
        final fault = _ctx[JitCtx.faultAddr];
        observe(
          pc,
          exitPc,
          reason,
          budget,
          budget - _ctx[JitCtx.budget].toSigned(32),
          _ctx[JitCtx.stop],
          fault == 0xffffffff ? null : fault,
        );
      }
      return reason;
    } finally {
      if (blockEntryFn != 0) _finishProfileBlock();
    }
  }

  // A cold installation may evict a hot indirect target from the direct-mapped table.
  // A native miss to an installed block refreshes it without compilation.
  void _refreshExitTarget() {
    final pc = exitPc, tag = exitTag;
    final entry = _blocks[(pc, tag)]?.$1;
    if (entry == null) return;
    final d = X64Backend.dynIndex(pc, tag) * 2;
    _dynView[d] = pc | tag << 32;
    _dynView[d + 1] = entry;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('JIT runtime is disposed');
    if (_failed) throw StateError('JIT code protection failed');
  }

  @override
  void dispose() {
    if (_disposed) return;
    compilationStats?.recordCacheClear(_blocks.length);
    _disposed = true;
    for (final c in _callables) {
      c.close();
    }
    _callables.clear();
    for (final (p, size) in _allocs) {
      _os.free(p, size);
    }
    _allocs.clear();
  }
}

final class _Full implements Exception {}
