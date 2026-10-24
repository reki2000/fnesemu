import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'ir.dart';
import 'optimizer.dart';
import 'runtime.dart';
import 'wasm/backend.dart';

@JS('WebAssembly.Memory')
extension type _Memory._(JSObject _) implements JSObject {
  external factory _Memory(JSObject descriptor);
  external JSArrayBuffer get buffer;
}
@JS('WebAssembly.Table')
extension type _Table._(JSObject _) implements JSObject {
  external factory _Table(JSObject descriptor);
  external int get length;
  external int grow(int count);
  external void set(int index, JSFunction? value);
}
@JS('WebAssembly.Module')
extension type _Module._(JSObject _) implements JSObject {
  external factory _Module(JSUint8Array bytes);
}
@JS('WebAssembly.Instance')
extension type _Instance._(JSObject _) implements JSObject {
  external factory _Instance(_Module module, JSObject imports);
  external JSObject get exports;
}

/// Capability detection includes policy restrictions on compiling Wasm.
/// No dynamic JavaScript evaluation or external loader is needed.
final bool supported = () {
  try {
    _Module(Uint8List.fromList([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]).toJS);
    return true;
  } catch (_) {
    return false;
  }
}();

JitRuntime? create(int ctxWords, int addrMask, JitRead read, JitWrite write,
        int pageShift) =>
    supported ? _WasmRuntime(ctxWords, addrMask, read, write, pageShift) : null;

/// One fixed linear memory holds every Wasm runtime, so runtimes can map
/// each other's guest buffers as native runtimes do. It never grows, which
/// keeps every Dart view valid; growing would detach existing views.
final class _LinearMemory {
  static const bytes = 64 << 20;
  final memory = _Memory(
      {'initial': bytes >> 16, 'maximum': bytes >> 16}.jsify()! as JSObject);
  late final ByteBuffer buffer = memory.buffer.toDart;

  /// Free ranges as (offset, size), sorted by offset. Offset zero is never
  /// allocated, so a zero page-table entry means unmapped.
  final _free = <(int, int)>[
    (JitRuntime.pageSize, bytes - JitRuntime.pageSize)
  ];

  static int _round(int size) => size == 0
      ? JitRuntime.pageSize
      : (size + JitRuntime.pageSize - 1) & ~(JitRuntime.pageSize - 1);

  /// Returns zeroed memory, aligned to the host page size.
  int allocate(int size) {
    if (size < 0) throw ArgumentError.value(size, 'size');
    size = _round(size);
    for (var i = 0; i < _free.length; i++) {
      final (offset, free) = _free[i];
      if (free < size) continue;
      if (free == size) {
        _free.removeAt(i);
      } else {
        _free[i] = (offset + size, free - size);
      }
      // Fill in JavaScript rather than crossing interop for each byte.
      buffer
          .asUint8List(offset, size)
          .toJS
          .callMethod<JSAny?>('fill'.toJS, 0.toJS);
      return offset;
    }
    throw StateError('Wasm JIT linear memory exhausted');
  }

  void release(int offset, int size) {
    size = _round(size);
    var i = 0;
    while (i < _free.length && _free[i].$1 < offset) {
      i++;
    }
    _free.insert(i, (offset, size));
    if (i + 1 < _free.length && offset + size == _free[i + 1].$1) {
      _free[i] = (offset, size + _free[i + 1].$2);
      _free.removeAt(i + 1);
    }
    if (i > 0 && _free[i - 1].$1 + _free[i - 1].$2 == offset) {
      _free[i - 1] = (_free[i - 1].$1, _free[i - 1].$2 + _free[i].$2);
      _free.removeAt(i);
    }
  }
}

final _linear = _LinearMemory();

final class _WasmRuntime extends JitRuntime implements WasmEnv {
  static const _maxSlots = 1 << 19;
  static const _maxBlocks = 4096;

  final _Table _table = _Table({
    'element': 'anyfunc',
    'initial': 256,
    'maximum': _maxSlots
  }.jsify()! as JSObject);
  ByteBuffer get _buffer => _linear.buffer;
  int _slotCount = 1;
  bool _disposed = false;
  final _allocations = <(int, int)>[];

  /// Returns the memory of runtimes dropped without [dispose]; the shared
  /// linear memory would otherwise keep it forever.
  static final _finalizer = Finalizer<List<(int, int)>>((allocations) {
    for (final (offset, size) in allocations) {
      _linear.release(offset, size);
    }
  });
  final _hostOffsets = Map<Uint8List, int>.identity();
  final _keys = <(int, int), int>{};
  final _blocks = <(int, int), (int slot, int cost)>{};
  final _helpers = <JSFunction>[];
  late final JSFunction _readFn, _writeFn, _enter;
  late final Uint32List _ctx, _reads, _writes, _slotWords, _dynWords;

  @override
  late final int ctxOffset, readTable, writeTable, slots, dyn;
  @override
  int get helperCount => _helpers.length;

  JSFunction? _profileFn;
  int? _profileBudget;

  @override
  bool get profileBlocks => _profileFn != null;

  @override
  void enableBlockProfiling() {
    _checkAlive();
    if (_blocks.isNotEmpty) throw StateError('Clear blocks before profiling');
    _profileFn ??= ((int _, int __, int ___) {
      _finishProfileBlock();
      _profileBudget = _ctx[JitCtx.budget].toSigned(32);
      return 0;
    }).toJS;
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

  _WasmRuntime(
      int ctxWords, super.addrMask, super.read, super.write, super.pageShift) {
    _finalizer.attach(this, _allocations, detach: this);
    ctxOffset = _allocate(ctxWords * 4);
    _ctx = _buffer.asUint32List(ctxOffset, ctxWords);
    final pages = (addrMask >>> pageShift) + 1;
    readTable = _allocate(pages * 4);
    writeTable = _allocate(pages * 4);
    _reads = _buffer.asUint32List(readTable, pages);
    _writes = _buffer.asUint32List(writeTable, pages);
    slots = _allocate(_maxSlots * 4);
    _slotWords = _buffer.asUint32List(slots, _maxSlots);
    dyn = _allocate(WasmBackend.dynEntries * 12);
    _dynWords = _buffer.asUint32List(dyn, WasmBackend.dynEntries * 3);
    _readFn = ((int addr, int size, int _) =>
        read(addr.toUnsigned(32), size).toSigned(32)).toJS;
    _writeFn = ((int addr, int value, int size) {
      write(
          addr.toUnsigned(32),
          size,
          value.toUnsigned(32) &
              (size == 4 ? 0xffffffff : (1 << (size * 8)) - 1));
      return 0;
    }).toJS;
    _enter = _instantiate(WasmBackend.dispatcher(ctxOffset), helpers: false);
  }

  JSFunction _instantiate(Uint8List bytes, {bool helpers = true}) {
    final env = JSObject();
    env['memory'] = _linear.memory;
    env['table'] = _table;
    if (helpers) {
      env['f0'] = _readFn;
      env['f1'] = _writeFn;
      for (int i = 0; i < _helpers.length; i++) {
        env['f${i + 2}'] = _helpers[i];
      }
      if (_profileFn case final profile?) {
        env['f${_helpers.length + 2}'] = profile;
      }
    }
    final imports = JSObject()..['env'] = env;
    return _Instance(_Module(bytes.toJS), imports).exports['run'] as JSFunction;
  }

  int _allocate(int size) {
    _checkAlive();
    final offset = _linear.allocate(size);
    _allocations.add((offset, size));
    return offset;
  }

  @override
  Uint32List get ctx => _ctx;

  /// about 3ms to translate, compile and instantiate a block
  @override
  int get compileThreshold => 32;

  @override
  Uint8List alloc(int size) {
    final offset = _allocate(size);
    final bytes = _buffer.asUint8List(offset, size);
    _hostOffsets[bytes] = offset;
    return bytes;
  }

  @override
  void shareBuffer(JitRuntime owner, Uint8List buffer) {
    _checkAlive();
    if (owner is! _WasmRuntime || !owner._hostOffsets.containsKey(buffer)) {
      throw ArgumentError('buffer must belong to a live Wasm runtime');
    }
    owner._checkAlive();
    _hostOffsets[buffer] = owner._hostOffsets[buffer]!;
  }

  @override
  void setPage(bool write, int page, (Uint8List, int)? host) {
    _checkAlive();
    final pointer = host == null ? 0 : _hostOffsets[host.$1]! + host.$2;
    super.setPage(write, page, host);
    (write ? _writes : _reads)[page] = pointer;
  }

  @override
  int addHelper(JitHelper helper) {
    _checkAlive();
    _helpers.add(((int a, int b, int c) =>
        helper(a.toUnsigned(32), b.toUnsigned(32), c.toUnsigned(32))
            .toSigned(32)).toJS);
    return _helpers.length - 1;
  }

  @override
  int slotFor(int pc, int tag) => _keys.putIfAbsent((pc, tag), () {
        if (_slotCount >= _maxSlots) {
          throw StateError('Wasm JIT link slots exhausted');
        }
        final slot = _slotCount++;
        if (slot >= _table.length) _table.grow((slot + 1 - _table.length));
        return slot;
      });

  @override
  bool contains(int pc, int tag) => _blocks.containsKey((pc, tag));

  @override
  int? blockCost(int pc, int tag) => _blocks[(pc, tag)]?.$2;

  @override
  int installBlock(IrBlock block) {
    _checkAlive();
    checkBlock(block);
    block = optimizeIrBlock(block);
    if (_blocks.length >= _maxBlocks || _slotCount >= _maxSlots - 3) clear();
    final slot = slotFor(block.pc, block.tag);
    final bytes = WasmBackend.compile(block, this);
    final function = _instantiate(bytes);
    _table.set(slot, function);
    _slotWords[slot] = slot;
    _blocks[(block.pc, block.tag)] = (slot, block.cost);
    final d = WasmBackend.dynIndex(block.pc, block.tag) * 3;
    _dynWords[d] = block.pc;
    _dynWords[d + 1] = block.tag;
    _dynWords[d + 2] = slot;
    return bytes.length;
  }

  @override
  void invalidate(int pc, int tag) {
    _checkAlive();
    final slot = _blocks.remove((pc, tag))?.$1;
    if (slot == null) return;
    compilationStats?.recordInvalidation(pc, tag);
    _slotWords[slot] = 0;
    _table.set(slot, null);
    final d = WasmBackend.dynIndex(pc, tag) * 3;
    if (_dynWords[d] == pc && _dynWords[d + 1] == tag) _dynWords[d + 2] = 0;
  }

  @override
  int run(int pc, int tag) {
    _checkAlive();
    final slot = _blocks[(pc, tag)]?.$1;
    if (slot == null) {
      _ctx[JitCtx.exitPc] = pc;
      _ctx[JitCtx.exitTag] = tag;
      return _ctx[JitCtx.exitReason] = JitReason.miss;
    }
    nativeEntries++;
    final observe = onNativeExit;
    final budget = _ctx[JitCtx.budget].toSigned(32);
    if (observe != null) _ctx[JitCtx.faultAddr] = 0xffffffff;
    try {
      final reason =
          (_enter.callAsFunction(null, slot.toJS) as JSNumber).toDartInt;
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
      if (_profileFn != null) _finishProfileBlock();
    }
  }

  // A cold installation may evict a hot indirect target from the direct-mapped table.
  // A miss to an installed block refreshes it without compilation.
  void _refreshExitTarget() {
    final pc = exitPc, tag = exitTag;
    final target = _blocks[(pc, tag)]?.$1;
    if (target == null) return;
    final d = WasmBackend.dynIndex(pc, tag) * 3;
    _dynWords[d] = pc;
    _dynWords[d + 1] = tag;
    _dynWords[d + 2] = target;
  }

  @override
  void clear() {
    _checkAlive();
    compilationStats?.recordCacheClear(_blocks.length);
    for (final slot in _blocks.values) {
      _table.set(slot.$1, null);
    }
    _blocks.clear();
    _keys.clear();
    _slotWords.toJS.callMethod<JSAny?>(
        'fill'.toJS, 0.toJS, 0.toJS, _slotCount.toJS);
    _dynWords.toJS.callMethod<JSAny?>('fill'.toJS, 0.toJS);
    _slotCount = 1;
  }

  @override
  void dispose() {
    if (_disposed) return;
    clear();
    _helpers.clear();
    _hostOffsets.clear();
    _finalizer.detach(this);
    for (final (offset, size) in _allocations) {
      _linear.release(offset, size);
    }
    _allocations.clear();
    _disposed = true;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('JIT runtime is disposed');
  }
}
