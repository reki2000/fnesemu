import 'dart:typed_data';

import '../../core.dart';
import '../../sram.dart';
import '../../state.dart';
import '../../util/uint8list.dart';
import 'fault.dart';
import 'maple_device.dart';
import 'memory_card_lcd.dart';
import 'memory_card_timer.dart';

// device information text, as character codes
const dcMemoryCardProductName = '\x56\x49\x53\x55\x41\x4c\x20\x4d\x45\x4d\x4f'
    '\x52\x59';

/// Memory card storage bring-up from the memory card peripheral specification Rev. 1.00 and FT1 Rev. 0.80.
/// Packet-level LCD and timer state do not emulate the standalone memory card CPU.
class DcMemoryCard implements DcMapleDevice {
  DcMemoryCard({this.unit = 1}) {
    if (unit != 1 && unit != 2) throw ArgumentError.value(unit, 'unit');
    _data.fillRange(0, size, 255);
  }
  static const size = 128 * 1024, blockSize = 512;
  final int unit;
  final lcd = DcMemoryCardLcd();
  final timer = DcMemoryCardTimer();

  @override
  void tickMasterClocks(int clocks) => timer.tickMasterClocks(clocks);
  final _data = Uint8List(size), _pending = Uint8List(blockSize);
  Sram? _storage;
  bool _identified = false, _killed = false;
  int _writeBlock = -1, _nextPhase = 0;
  int _lastBlock = -1, _lastPhase = 0, _error = 0;

  /// Preflight destination-owned storage before a parent commits device state.
  void validateStateTarget() {
    if (_storage != null && _storage!.data.length != size) {
      throw const StateMismatch('Memory card storage binding layout');
    }
  }

  void saveState(StateWriter writer) {
    writer.section('dc.memory_card');
    writer.int64(unit);
    writer.bytes(exportImage());
    writer.bytes(_pending);
    writer.ints([_writeBlock, _nextPhase, _lastBlock, _lastPhase, _error]);
    writer.boolean(_identified);
    writer.boolean(_killed);
    lcd.saveState(writer);
    timer.saveState(writer);
  }

  void loadState(StateReader reader) {
    validateStateTarget();
    reader.section('dc.memory_card');
    final savedUnit = reader.int64();
    final image = reader.bytes(), pending = reader.bytes(), v = reader.ints();
    final identified = reader.boolean(), killed = reader.boolean();
    final restoredLcd = DcMemoryCardLcd()..loadState(reader);
    final restoredTimer = DcMemoryCardTimer()..loadState(reader);
    if (savedUnit != unit ||
        image.length != size ||
        pending.length != blockSize ||
        v.length != 5 ||
        v[0] < -1 ||
        v[0] > 255 ||
        v[1] < 0 ||
        v[1] > 3 ||
        (v[0] >= 0) != (v[1] != 0) ||
        v[2] < -1 ||
        v[2] > 0xffff ||
        v[3] < 0 ||
        v[3] > 255 ||
        ![0, 1, 2, 4, 16].contains(v[4])) {
      throw const StateMismatch('Memory card storage or protocol state');
    }
    final writer = StateWriter('dc.memory_card.transfer', 1, 0);
    restoredLcd.saveState(writer);
    restoredTimer.saveState(writer);
    final components =
        StateReader(writer.take(), 'dc.memory_card.transfer', 1, 0);
    lcd.loadState(components);
    timer.loadState(components);
    components.end();
    _data.setAll(0, image);
    // Use the bound storage path for region activation and dirty tracking.
    final storage = _storage;
    if (storage != null) {
      for (var address = 0; address < size; address++) {
        storage.write8(address, image[address]);
      }
    }
    _pending.setAll(0, pending);
    _writeBlock = v[0];
    _nextPhase = v[1];
    _lastBlock = v[2];
    _lastPhase = v[3];
    _error = v[4];
    _identified = identified;
    _killed = killed;
  }

  int _byte(int offset) => _storage?.read8(offset) ?? _data[offset];
  void _store(int offset, int value) {
    _data[offset] = value;
    _storage?.write8(offset, value);
  }

  void attachStorage(Sram storage, String location) {
    final current = exportImage();
    storage.init(
        StorageKey.of('dc', StorageKey.sram, 'memory_card_$location'), current);
    if (storage.data.length != size) {
      throw StateError('Memory card storage must be 128 KiB');
    }
    _storage = storage;
    resetDevice();
  }

  Uint8List exportImage() => Uint8List.fromList([
        for (var i = 0; i < size; i++) _byte(i),
      ]);

  /// Imports a raw byte image without synthesizing filesystem or factory data.
  void loadImage(Uint8List bytes) {
    if (bytes.length != size)
      throw ArgumentError('Memory card image must be 128 KiB');
    resetDevice();
    for (var i = 0; i < size; i++) {
      _store(i, bytes[i]);
    }
  }

  @override
  void resetDevice() {
    lcd.reset();
    timer.reset();
    _identified = _killed = false;
    _writeBlock = _lastBlock = -1;
    _nextPhase = _lastPhase = _error = 0;
  }

  Uint8List _info() {
    final data = Uint8List(112);
    // Highest function first: timer, LCD, then 512-byte RA=1/WA=4 storage.
    data.setAll(0,
        [0, 0, 0, 14, 0x7e, 0x7e, 0x3f, 0x40, 0, 5, 0x10, 0, 0, 0x0f, 0x41, 0]);
    data[16] = 2;
    data.fillRange(18, 108, 32);
    data.setAll(18, dcMemoryCardProductName.codeUnits);
    data.setAll(48, dcPeripheralLicense.codeUnits);
    data.setUint16LE(108, 100);
    data.setUint16LE(110, 130);
    return data;
  }

  @override
  Uint8List? exchange(Uint8List request, int port) {
    final host = port << 6, address = host | unit;
    if (_killed ||
        request.length < 4 ||
        request[1] != address ||
        request[2] != host ||
        request.length != (request[3] + 1) * 4) {
      return null;
    }
    Uint8List reply(int code, [List<int> bytes = const []]) =>
        Uint8List.fromList([code, host, address, bytes.length ~/ 4, ...bytes]);
    Uint8List failure(int code, {int? block, int? phase}) {
      _error = code;
      if (block != null) _lastBlock = block;
      if (phase != null) _lastPhase = phase;
      _writeBlock = -1;
      _nextPhase = 0;
      return reply(0xfb, [0, 0, 0, code]);
    }

    final command = request[0];
    if (_writeBlock >= 0 && command != 12) {
      return failure(2); // A different command interrupts the write group.
    }
    if (command == 1) {
      if (request.length != 4) return null;
      _identified = true;
      return reply(5, _info());
    }
    if (!_identified) return null;
    if (command == 2) {
      throw const DcUnsupported('Memory card extended device information');
    }
    if (command == 3 || command == 4) {
      if (request.length != 4) return null;
      resetDevice();
      _killed = command == 4;
      return reply(7);
    }
    if (command != 9 &&
        command != 10 &&
        command != 11 &&
        command != 12 &&
        command != 13 &&
        command != 14) {
      return reply(0xfd);
    }
    if (request.length < 8) return failure(16);
    final function = request.getUint32BE(4);
    if (function == 4 || function == 8) {
      if (_writeBlock >= 0) return failure(2);
      final result = function == 4
          ? lcd.command(command, request)
          : timer.command(command, request);
      return reply(result.$1, result.$2);
    }
    if (function != 2) {
      if (_writeBlock >= 0) {
        failure(2);
      }
      return reply(0xfe);
    }
    if (command == 9 || command == 14) return reply(0xfd);
    if (request.length < 12) return failure(16);
    final partition = request[8], phase = request[9];
    final block = request.getUint16BE(10);
    if (partition != 0) return failure(1, block: block, phase: phase);
    if (command == 10) {
      if (request.length != 12) return failure(16);
      if (phase != 0 || block != 0) return failure(2);
      const root = 255 * blockSize;
      if (!List.generate(16, (i) => _byte(root + i)).every((b) => b == 0x55)) {
        throw const DcUnsupported(
            'Memory card unformatted media factory parameters');
      }
      // FT1 fixes capacity, partition and root location in ROM; other fields
      // come from the system area of an already formatted card.
      return reply(8, [
        0,
        0,
        0,
        2,
        255,
        0,
        0,
        0,
        255,
        0,
        for (var i = 0x46; i < 0x58; i++) _byte(root + i)
      ]);
    }
    if (block >= 256) return failure(4, block: block, phase: phase);
    if (command == 13) {
      if (request.length != 12) return failure(16);
      if (block != _lastBlock || phase != _lastPhase + 1) return failure(2);
      return _error != 0 ? reply(0xfb, [0, 0, 0, _error]) : reply(7);
    }
    if (command == 11) {
      if (request.length != 12) return failure(16, block: block, phase: phase);
      if (phase != 0) return failure(2, block: block, phase: phase);
      _lastBlock = block;
      _lastPhase = phase;
      _error = 0;
      return reply(8, [
        0,
        0,
        0,
        2,
        0,
        0,
        request[10],
        request[11],
        for (var i = 0; i < blockSize; i++) _byte(block * blockSize + i)
      ]);
    }
    if (request.length != 140) return failure(16, block: block, phase: phase);
    if (phase >= 4 ||
        phase != _nextPhase ||
        (phase != 0 && block != _writeBlock)) {
      return failure(2, block: block, phase: phase);
    }
    if (phase == 0) _writeBlock = block;
    _pending.setRange(phase * 128, (phase + 1) * 128, request, 12);
    _nextPhase++;
    _lastBlock = block;
    _lastPhase = phase;
    _error = 0;
    if (_nextPhase == 4) {
      for (var i = 0; i < blockSize; i++) {
        _store(block * blockSize + i, _pending[i]);
      }
      _writeBlock = -1;
      _nextPhase = 0;
    }
    return reply(7);
  }
}
