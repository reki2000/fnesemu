import 'dart:convert';
import 'dart:typed_data';

import 'memory.dart';
import 'memstick.dart';

/// The save data dialog of sceUtility, without a screen of its own.
///
/// The game fills a parameter block and starts the dialog; the dialog
/// reads or writes `ms0:/PSP/SAVEDATA/<game name><save name>/` and reports
/// its result in the block. The work runs at once when the dialog starts,
/// and the status then steps through the dialog states on each status
/// call, the way a dialog the player confirms at once would. Where the
/// player would pick an entry from a list, the dialog takes the entry the
/// block's focus names.
///
/// The offsets of the parameter block follow the public SDK headers. The
/// error codes are as recalled from the public SDK error list, not checked
/// against hardware.
class PspSavedataDialog {
  PspSavedataDialog(this.mem, this._stick);

  final PspMemory mem;
  final PspMemStick Function() _stick;
  PspMemStick get memStick => _stick();

  /// The dialog states the status call reports.
  static const statusNone = 0,
      statusInit = 1,
      statusVisible = 2,
      statusQuit = 3,
      statusFinished = 4;

  static const errorLoadNoData = 0x80110307;
  static const errorSaveAccess = 0x80110385;
  static const errorDeleteNoData = 0x80110347;

  /// The result of a list dialog the player left without choosing.
  static const resultCancel = 1;

  int status = statusNone;
  int param = 0;

  /// The mode of the last dialog, for the log.
  int mode = -1;

  // The parameter block: the common dialog header and the save data
  // fields after it.
  static const _size = 0x00,
      _result = 0x1c,
      _mode = 0x30,
      _gameName = 0x3c,
      _saveName = 0x4c,
      _saveNameList = 0x60,
      _fileName = 0x64,
      _dataBuf = 0x74,
      _dataBufSize = 0x78,
      _dataSize = 0x7c,
      _sfoTitle = 0x80,
      _sfoSavedataTitle = 0x100,
      _sfoDetail = 0x180,
      _sfoParentalLevel = 0x580,
      _icon0 = 0x584,
      _icon1 = 0x594,
      _pic1 = 0x5a4,
      _snd0 = 0x5b4,
      _focus = 0x5c8;

  static const _sfoName = 'PARAM.SFO';
  static const _files = [
    (_icon0, 'ICON0.PNG'),
    (_icon1, 'ICON1.PMF'),
    (_pic1, 'PIC1.PNG'),
    (_snd0, 'SND0.AT3'),
  ];

  /// Starts a dialog with the parameter block at [at]; fails while one is
  /// still open.
  int initStart(int at) {
    if (status != statusNone) return 0x80110001;
    param = at;
    mode = mem.read32(at + _mode);
    mem.write32(at + _result, _run(at, mode));
    memStick.flush();
    status = statusInit;
    return 0;
  }

  int getStatus() {
    final now = status;
    if (status == statusInit) {
      status = statusVisible;
    } else if (status == statusVisible) {
      status = statusQuit;
    } else if (status == statusFinished) {
      status = statusNone;
    }
    return now;
  }

  int shutdownStart() {
    if (status != statusQuit) return 0x80110001;
    status = statusFinished;
    return 0;
  }

  int _run(int at, int mode) {
    switch (mode) {
      case 0: // automatic load
      case 2: // load
        return _load(at, _string(at + _saveName, 20));
      case 1: // automatic save
      case 3: // save
        return _save(at, _string(at + _saveName, 20));
      case 4: // load from a list
        final name = _pick(at, forSave: false);
        if (name == null) return errorLoadNoData;
        _writeString(at + _saveName, name, 20);
        return _load(at, name);
      case 5: // save to a list
        final name = _pick(at, forSave: true);
        if (name == null) return resultCancel;
        _writeString(at + _saveName, name, 20);
        return _save(at, name);
      case 7: // delete
        return _delete(at, _string(at + _saveName, 20));
      default:
        // The list deletion and the modes that only report sizes or
        // lists: a player leaving the dialog.
        return resultCancel;
    }
  }

  String _dir(int at, String saveName) =>
      'PSP/SAVEDATA/${_string(at + _gameName, 13)}$saveName';

  int _load(int at, String saveName) {
    final dir = memStick.lookup(_dir(at, saveName));
    final file = dir == null
        ? null
        : memStick
            .lookup('${_dir(at, saveName)}/${_string(at + _fileName, 13)}');
    if (file == null || file.isDirectory) return errorLoadNoData;
    final buf = mem.read32(at + _dataBuf);
    final size = file.size < mem.read32(at + _dataBufSize)
        ? file.size
        : mem.read32(at + _dataBufSize);
    mem.writeBytes(buf, file.content.sublist(0, size));
    mem.write32(at + _dataSize, size);
    final sfo = memStick.lookup('${_dir(at, saveName)}/$_sfoName');
    if (sfo != null) {
      final values = readSfo(sfo.content);
      _writeString(at + _sfoTitle, '${values['TITLE'] ?? ''}', 0x80);
      _writeString(
          at + _sfoSavedataTitle, '${values['SAVEDATA_TITLE'] ?? ''}', 0x80);
      _writeString(
          at + _sfoDetail, '${values['SAVEDATA_DETAIL'] ?? ''}', 0x400);
      final level = values['PARENTAL_LEVEL'];
      mem.write8(at + _sfoParentalLevel, level is int ? level : 0);
    }
    return 0;
  }

  int _save(int at, String saveName) {
    final path = _dir(at, saveName);
    var dir = memStick.lookup(path);
    if (dir == null) {
      var built = '';
      for (final part in path.split('/')) {
        built = built.isEmpty ? part : '$built/$part';
        if (memStick.lookup(built) == null) memStick.mkdir(built);
      }
      dir = memStick.lookup(path);
    }
    if (dir == null || !dir.isDirectory) return errorSaveAccess;
    final data = mem.read32(at + _dataBuf);
    final size = mem.read32(at + _dataSize);
    final fileName = _string(at + _fileName, 13);
    if (fileName.isNotEmpty) {
      _writeFile('$path/$fileName', mem.readBytes(data, size));
    }
    _writeFile(
        '$path/$_sfoName',
        writeSfo({
          'CATEGORY': 'MS',
          'PARENTAL_LEVEL': mem.read8(at + _sfoParentalLevel),
          'SAVEDATA_DETAIL': _string(at + _sfoDetail, 0x400),
          'SAVEDATA_DIRECTORY': '${_string(at + _gameName, 13)}$saveName',
          'SAVEDATA_TITLE': _string(at + _sfoSavedataTitle, 0x80),
          'TITLE': _string(at + _sfoTitle, 0x80),
        }));
    for (final (field, name) in _files) {
      final buf = mem.read32(at + field), size = mem.read32(at + field + 8);
      if (buf != 0 && size > 0) {
        _writeFile('$path/$name', mem.readBytes(buf, size));
      }
    }
    return 0;
  }

  int _delete(int at, String saveName) {
    final path = _dir(at, saveName);
    final dir = memStick.lookup(path);
    if (dir == null || !dir.isDirectory) return errorDeleteNoData;
    for (final child in [...dir.children.values]) {
      memStick.remove(child);
    }
    memStick.remove(dir);
    return 0;
  }

  void _writeFile(String path, List<int> bytes) {
    final node = memStick.lookup(path) ?? memStick.createFile(path);
    if (node == null || node.isDirectory) return;
    node.content
      ..clear()
      ..addAll(bytes);
    node.modified = memStick.clock();
  }

  /// The entry of the save name list the focus names; null when there is
  /// none to load, or no entry at all to save to. The focus values are
  /// those of the public SDK headers: the first or last entry, the latest
  /// or oldest data, and the first or last entry without data.
  String? _pick(int at, {required bool forSave}) {
    final names = <String>[];
    final list = mem.read32(at + _saveNameList);
    if (list != 0) {
      for (var i = 0; i < 1000; i++) {
        final name = _string(list + i * 20, 20);
        if (name.isEmpty) break;
        names.add(name);
      }
    }
    if (names.isEmpty) {
      final name = _string(at + _saveName, 20);
      if (name.isNotEmpty) names.add(name);
    }
    if (names.isEmpty) return null;
    final saved = <String, int>{};
    for (final name in names) {
      final dir = memStick.lookup(_dir(at, name));
      if (dir != null && dir.isDirectory) saved[name] = dir.modified;
    }
    final empty = [
      for (final n in names)
        if (!saved.containsKey(n)) n
    ];
    String? latest, oldest;
    for (final MapEntry(key: name, value: time) in saved.entries) {
      if (latest == null || time > saved[latest]!) latest = name;
      if (oldest == null || time < saved[oldest]!) oldest = name;
    }
    final focus = mem.read32(at + _size) > _focus ? mem.read32(at + _focus) : 0;
    if (!forSave) {
      if (saved.isEmpty) return null;
      return switch (focus) {
        1 => names.firstWhere(saved.containsKey),
        2 => names.lastWhere(saved.containsKey),
        4 => oldest,
        _ => latest,
      };
    }
    return switch (focus) {
      1 => names.first,
      2 => names.last,
      4 => oldest ?? empty.first,
      7 => empty.isEmpty ? latest : empty.first,
      8 => empty.isEmpty ? latest : empty.last,
      _ => latest ?? empty.first,
    };
  }

  String _string(int at, int max) {
    final bytes = <int>[];
    for (var i = 0; i < max; i++) {
      final b = mem.read8(at + i);
      if (b == 0) break;
      bytes.add(b);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  void _writeString(int at, String text, int max) {
    final bytes = utf8.encode(text);
    final n = bytes.length < max - 1 ? bytes.length : max - 1;
    for (var i = 0; i < max; i++) {
      mem.write8(at + i, i < n ? bytes[i] : 0);
    }
  }
}

/// Writes a system file object (PARAM.SFO) holding [values], strings as
/// UTF-8 and integers as 32-bit words, with the keys in sorted order.
Uint8List writeSfo(Map<String, Object> values) {
  final keys = values.keys.toList()..sort();
  final keyTable = BytesBuilder();
  final dataTable = BytesBuilder();
  final entries = ByteData(keys.length * 16);
  for (var i = 0; i < keys.length; i++) {
    final value = values[keys[i]]!;
    final List<int> data;
    final int format, length;
    if (value is int) {
      data = (ByteData(4)..setUint32(0, value, Endian.little))
          .buffer
          .asUint8List();
      format = 0x0404;
      length = 4;
    } else {
      final text = utf8.encode('$value');
      length = text.length + 1;
      data = [...text, ...List.filled((length + 3 & ~3) - text.length, 0)];
      format = 0x0204;
    }
    entries
      ..setUint16(i * 16, keyTable.length, Endian.little)
      ..setUint16(i * 16 + 2, format, Endian.little)
      ..setUint32(i * 16 + 4, length, Endian.little)
      ..setUint32(i * 16 + 8, data.length, Endian.little)
      ..setUint32(i * 16 + 12, dataTable.length, Endian.little);
    keyTable.add([...ascii.encode(keys[i]), 0]);
    dataTable.add(data);
  }
  while (keyTable.length % 4 != 0) {
    keyTable.addByte(0);
  }
  final keyStart = 20 + keys.length * 16;
  final dataStart = keyStart + keyTable.length;
  final header = ByteData(20)
    ..setUint32(0, 0x46535000, Endian.little)
    ..setUint32(4, 0x101, Endian.little)
    ..setUint32(8, keyStart, Endian.little)
    ..setUint32(12, dataStart, Endian.little)
    ..setUint32(16, keys.length, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(entries.buffer.asUint8List())
        ..add(keyTable.takeBytes())
        ..add(dataTable.takeBytes()))
      .takeBytes();
}

/// Reads the values of a system file object; an empty map when [bytes]
/// is not one.
Map<String, Object> readSfo(List<int> bytes) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  if (bytes.length < 20 || data.getUint32(0, Endian.little) != 0x46535000) {
    return {};
  }
  final keyStart = data.getUint32(8, Endian.little);
  final dataStart = data.getUint32(12, Endian.little);
  final count = data.getUint32(16, Endian.little);
  final values = <String, Object>{};
  for (var i = 0; i < count && 20 + i * 16 + 16 <= bytes.length; i++) {
    final e = 20 + i * 16;
    var k = keyStart + data.getUint16(e, Endian.little);
    final key = StringBuffer();
    while (k < bytes.length && bytes[k] != 0) {
      key.writeCharCode(bytes[k++]);
    }
    final format = data.getUint16(e + 2, Endian.little);
    final length = data.getUint32(e + 4, Endian.little);
    final at = dataStart + data.getUint32(e + 12, Endian.little);
    if (at + length > bytes.length) continue;
    if (format == 0x0404) {
      values['$key'] = data.getUint32(at, Endian.little);
    } else {
      var end = at + length;
      while (end > at && bytes[end - 1] == 0) {
        end--;
      }
      values['$key'] =
          utf8.decode(bytes.sublist(at, end), allowMalformed: true);
    }
  }
  return values;
}
