import 'dart:ffi';
import 'dart:typed_data';

import 'ir.dart';
import 'runtime.dart';
import 'x64/backend.dart';

/// Page-granular memory of the host OS.
abstract class _Os {
  /// zeroed read-write memory, or 0 on failure
  int alloc(int size);
  void free(int addr, int size);
  bool protect(int addr, int size, {required bool exec});
  bool get win64;

  static final _Os? current = switch (Abi.current()) {
    Abi.linuxX64 || Abi.androidX64 => _Posix(),
    Abi.windowsX64 => _Windows(),
    _ => null,
  };
}

typedef _MmapC = IntPtr Function(IntPtr, IntPtr, Int32, Int32, Int32, IntPtr);
typedef _Mmap = int Function(int, int, int, int, int, int);
typedef _MprotectC = Int32 Function(IntPtr, IntPtr, Int32);
typedef _Mprotect = int Function(int, int, int);
typedef _MunmapC = Int32 Function(IntPtr, IntPtr);
typedef _Munmap = int Function(int, int);

final class _Posix extends _Os {
  late final DynamicLibrary _libc = () {
    try {
      final lib = DynamicLibrary.process();
      lib.lookup('mmap');
      return lib;
    } catch (_) {
      return DynamicLibrary.open('libc.so');
    }
  }();
  late final _mmap = _libc.lookupFunction<_MmapC, _Mmap>('mmap');
  late final _mprotect =
      _libc.lookupFunction<_MprotectC, _Mprotect>('mprotect');
  late final _munmap = _libc.lookupFunction<_MunmapC, _Munmap>('munmap');

  static const _read = 1, _write = 2, _exec = 4;
  static const _privateAnonymous = 0x22; // Linux and Android

  @override
  bool get win64 => false;

  @override
  int alloc(int size) {
    final p = _mmap(0, size, _read | _write, _privateAnonymous, -1, 0);
    return p == -1 ? 0 : p;
  }

  @override
  void free(int addr, int size) => _munmap(addr, size);

  @override
  bool protect(int addr, int size, {required bool exec}) =>
      _mprotect(addr, size, exec ? _read | _exec : _read | _write) == 0;
}

typedef _VirtualAllocC = IntPtr Function(IntPtr, IntPtr, Uint32, Uint32);
typedef _VirtualAlloc = int Function(int, int, int, int);
typedef _VirtualProtectC = Int32 Function(IntPtr, IntPtr, Uint32, IntPtr);
typedef _VirtualProtect = int Function(int, int, int, int);
typedef _VirtualFreeC = Int32 Function(IntPtr, IntPtr, Uint32);
typedef _VirtualFree = int Function(int, int, int);

final class _Windows extends _Os {
  late final _kernel32 = DynamicLibrary.open('kernel32.dll');
  late final _virtualAlloc =
      _kernel32.lookupFunction<_VirtualAllocC, _VirtualAlloc>('VirtualAlloc');
  late final _virtualProtect = _kernel32
      .lookupFunction<_VirtualProtectC, _VirtualProtect>('VirtualProtect');
  late final _virtualFree =
      _kernel32.lookupFunction<_VirtualFreeC, _VirtualFree>('VirtualFree');
  late final int _oldProtect = alloc(4096);

  static const _commitReserve = 0x3000, _release = 0x8000;
  static const _readWrite = 0x04, _executeRead = 0x20;

  @override
  bool get win64 => true;

  @override
  int alloc(int size) => _virtualAlloc(0, size, _commitReserve, _readWrite);

  @override
  void free(int addr, int size) => _virtualFree(addr, 0, _release);

  @override
  bool protect(int addr, int size, {required bool exec}) =>
      _virtualProtect(
          addr, size, exec ? _executeRead : _readWrite, _oldProtect) !=
      0;
}

bool get supported => _Os.current != null;

JitRuntime? create(int ctxWords, int addrMask, JitRead read, JitWrite write) {
  final os = _Os.current;
  return os == null ? null : _X64Runtime(os, ctxWords, addrMask, read, write);
}

typedef _HelperC = Uint32 Function(Uint32, Uint32, Uint32);
typedef _EnterC = Uint32 Function(IntPtr);
typedef _Enter = int Function(int);

final class _X64Runtime extends JitRuntime implements X64Env {
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

  final _callables = <NativeCallable<_HelperC>>[];
  final _helperAddrs = <int>[];
  late final int _readFn, _writeFn;

  /// installed entries by key
  final _blocks = <(int, int), int>{};

  /// the link slots of each target key
  final _slotsOf = <(int, int), List<int>>{};
  int _slotCount = 0;

  @override
  late final int exitStub;

  _X64Runtime(this._os, int ctxWords, super.addrMask, super.read, super.write) {
    try {
      final pages = (addrMask >>> JitRuntime.pageBits) + 1;
      _ctxAddr = _alloc(ctxWords * 4);
      _ctx = Pointer<Uint32>.fromAddress(_ctxAddr).asTypedList(ctxWords);
      _readTable = _alloc(pages * 8);
      _writeTable = _alloc(pages * 8);
      _readTableView =
          Pointer<Uint64>.fromAddress(_readTable).asTypedList(pages);
      _writeTableView =
          Pointer<Uint64>.fromAddress(_writeTable).asTypedList(pages);
      _slots = _alloc(_maxSlots * 8);
      _slotView = Pointer<Uint64>.fromAddress(_slots).asTypedList(_maxSlots);
      _dyn = _alloc(X64Backend.dynEntries << X64Backend.dynEntryBits);
      _dynView = Pointer<Uint64>.fromAddress(_dyn)
          .asTypedList(X64Backend.dynEntries * 2);
      _code = _alloc(_codeSize);

      _readFn = _callable((a, b, c) => read(a, b));
      _writeFn = _callable((a, b, c) {
        write(a, c, c == 4 ? b : b & ((1 << (c * 8)) - 1));
        return 0;
      });

      final (bytes, exitOffset) = X64Backend.trampoline(
          win64: _os.win64,
          ctx: _ctxAddr,
          readTable: _readTable,
          writeTable: _writeTable,
          slots: _slots,
          dyn: _dyn);
      _write(0, bytes);
      exitStub = _code + exitOffset;
      _codeStart = (bytes.length + 63) & ~63;
      _codeEnd = _codeStart;
      _enter = Pointer<NativeFunction<_EnterC>>.fromAddress(_code)
          .asFunction<_Enter>();
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  int _alloc(int size) {
    size = (size + JitRuntime.pageSize - 1) & ~(JitRuntime.pageSize - 1);
    final p = _os.alloc(size);
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
    // only the pages written to are made writable
    final start = offset & ~(JitRuntime.pageSize - 1);
    final end = (offset + bytes.length + JitRuntime.pageSize - 1) &
        ~(JitRuntime.pageSize - 1);
    if (!_os.protect(_code + start, end - start, exec: false)) {
      throw StateError('cannot make JIT code writable');
    }
    Pointer<Uint8>.fromAddress(_code + offset)
        .asTypedList(bytes.length)
        .setAll(0, bytes);
    if (!_os.protect(_code + start, end - start, exec: true)) {
      throw StateError('cannot make JIT code executable');
    }
  }

  @override
  Uint32List get ctx => _ctx;

  @override
  Uint8List alloc(int size) {
    final p = _alloc(size);
    final view = Pointer<Uint8>.fromAddress(p).asTypedList(size);
    _hostAddr[view] = p;
    return view;
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

  // X64Env

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
    final page = readPages[masked >>> JitRuntime.pageBits];
    if (page == null) return null;
    return _hostAddr[page.$1]! + page.$2 + (masked & (JitRuntime.pageSize - 1));
  }

  @override
  int slotFor(int pc, int tag) {
    if (_slotCount == _maxSlots) throw _Full();
    final s = _slotCount++;
    (_slotsOf[(pc, tag)] ??= []).add(s);
    _slotView[s] = _blocks[(pc, tag)] ?? 0;
    return s;
  }

  // JitRuntime

  @override
  bool contains(int pc, int tag) => _blocks.containsKey((pc, tag));

  @override
  void install(IrBlock block) {
    _checkAlive();
    checkBlock(block);
    List<int> bytes;
    int at;
    try {
      at = _codeEnd;
      bytes = X64Backend.compile(block, _code + at, this);
      if (at + bytes.length > _codeSize) throw _Full();
    } on _Full {
      clear();
      at = _codeEnd;
      bytes = X64Backend.compile(block, _code + at, this);
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
    _blocks[key] = entry;
    for (final s in _slotsOf[key] ?? const <int>[]) {
      _slotView[s] = entry;
    }
    final d = X64Backend.dynIndex(block.pc, block.tag) * 2;
    _dynView[d] = block.pc | block.tag << 32;
    _dynView[d + 1] = entry;
  }

  @override
  void invalidate(int pc, int tag) {
    final key = (pc, tag);
    if (_blocks.remove(key) == null) return;
    for (final s in _slotsOf[key] ?? const <int>[]) {
      _slotView[s] = 0;
    }
    final d = X64Backend.dynIndex(pc, tag) * 2;
    if (_dynView[d] == (pc | tag << 32)) _dynView[d + 1] = 0;
  }

  @override
  void clear() {
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
    final entry = _blocks[(pc, tag)];
    if (entry == null) {
      _ctx[JitCtx.exitReason] = JitReason.miss;
      _ctx[JitCtx.exitPc] = pc;
      _ctx[JitCtx.exitTag] = tag;
      return JitReason.miss;
    }
    return _enter(entry);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('JIT runtime is disposed');
    if (_failed) throw StateError('JIT code protection failed');
  }

  @override
  void dispose() {
    if (_disposed) return;
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
