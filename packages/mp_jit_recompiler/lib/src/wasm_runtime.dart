import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'ir.dart';
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

JitRuntime? create(int ctxWords, int addrMask, JitRead read, JitWrite write) =>
    supported ? _WasmRuntime(ctxWords, addrMask, read, write) : null;

/// A fixed linear memory keeps every Dart view valid for the runtime's
/// lifetime; growing a non-shared Wasm memory would detach existing views.
final class _WasmRuntime extends JitRuntime implements WasmEnv {
  static const _memoryBytes = 64 << 20;
  static const _maxSlots = 1 << 19;
  static const _maxBlocks = 4096;

  final _Memory _memory =
      _Memory({'initial': 1024, 'maximum': 1024}.jsify()! as JSObject);
  final _Table _table = _Table({
    'element': 'anyfunc',
    'initial': 256,
    'maximum': _maxSlots
  }.jsify()! as JSObject);
  late final ByteBuffer _buffer = _memory.buffer.toDart;
  int _next = 4096, _slotCount = 1;
  bool _disposed = false;
  final _hostOffsets = Map<Uint8List, int>.identity();
  final _keys = <(int, int), int>{};
  final _blocks = <(int, int), int>{};
  final _helpers = <JSFunction>[];
  late final JSFunction _readFn, _writeFn, _enter;
  late final Uint32List _ctx, _reads, _writes, _slotWords, _dynWords;

  @override
  late final int ctxOffset, readTable, writeTable, slots, dyn;
  @override
  int get helperCount => _helpers.length;

  _WasmRuntime(int ctxWords, super.addrMask, super.read, super.write) {
    ctxOffset = _allocate(ctxWords * 4);
    _ctx = _buffer.asUint32List(ctxOffset, ctxWords);
    final pages = (addrMask >>> JitRuntime.pageBits) + 1;
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
    env['memory'] = _memory;
    env['table'] = _table;
    if (helpers) {
      env['f0'] = _readFn;
      env['f1'] = _writeFn;
      for (int i = 0; i < _helpers.length; i++) {
        env['f${i + 2}'] = _helpers[i];
      }
    }
    final imports = JSObject()..['env'] = env;
    return _Instance(_Module(bytes.toJS), imports).exports['run'] as JSFunction;
  }

  int _allocate(int size) {
    _checkAlive();
    if (size < 0 || size > _memoryBytes - _next) {
      throw StateError('Wasm JIT linear memory exhausted');
    }
    final offset = _next;
    _next += (size + JitRuntime.pageSize - 1) & ~(JitRuntime.pageSize - 1);
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
  void install(IrBlock block) {
    _checkAlive();
    checkBlock(block);
    if (_blocks.length >= _maxBlocks || _slotCount >= _maxSlots - 3) clear();
    final slot = slotFor(block.pc, block.tag);
    final function = _instantiate(WasmBackend.compile(block, this));
    _table.set(slot, function);
    _slotWords[slot] = slot;
    _blocks[(block.pc, block.tag)] = slot;
    final d = WasmBackend.dynIndex(block.pc, block.tag) * 3;
    _dynWords[d] = block.pc;
    _dynWords[d + 1] = block.tag;
    _dynWords[d + 2] = slot;
  }

  @override
  void invalidate(int pc, int tag) {
    _checkAlive();
    final slot = _blocks.remove((pc, tag));
    if (slot == null) return;
    _slotWords[slot] = 0;
    _table.set(slot, null);
    final d = WasmBackend.dynIndex(pc, tag) * 3;
    if (_dynWords[d] == pc && _dynWords[d + 1] == tag) _dynWords[d + 2] = 0;
  }

  @override
  int run(int pc, int tag) {
    _checkAlive();
    final slot = _blocks[(pc, tag)];
    if (slot == null) {
      _ctx[JitCtx.exitPc] = pc;
      _ctx[JitCtx.exitTag] = tag;
      return _ctx[JitCtx.exitReason] = JitReason.miss;
    }
    return (_enter.callAsFunction(null, slot.toJS) as JSNumber).toDartInt;
  }

  @override
  void clear() {
    _checkAlive();
    for (final slot in _blocks.values) {
      _table.set(slot, null);
    }
    _blocks.clear();
    _keys.clear();
    _slotWords.fillRange(0, _slotCount, 0);
    _dynWords.fillRange(0, _dynWords.length, 0);
    _slotCount = 1;
  }

  @override
  void dispose() {
    if (_disposed) return;
    clear();
    _helpers.clear();
    _hostOffsets.clear();
    _disposed = true;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('JIT runtime is disposed');
  }
}
