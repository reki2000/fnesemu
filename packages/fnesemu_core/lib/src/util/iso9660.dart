import 'dart:typed_data';

/// The 2048 bytes of user data in a raw sector (mode 1 or mode 2 form 1).
Uint8List userData(Uint8List raw) {
  if (raw.length < 2352) return Uint8List(0);
  final offset = raw[15] == 2 ? 24 : 16;
  return Uint8List.sublistView(raw, offset, offset + 2048);
}

/// One file or directory of an ISO 9660 volume, from its directory
/// record. The name has no version suffix; the self and parent records
/// of a directory are named `.` and `..`.
class Iso9660Entry {
  final String name;
  final int lba;
  final int size;
  final bool isDirectory;

  /// The recording date of the record; [year] is the full year.
  final int year, month, day, hour, minute, second;

  const Iso9660Entry(this.name, this.lba, this.size, this.isDirectory,
      [this.year = 0,
      this.month = 0,
      this.day = 0,
      this.hour = 0,
      this.minute = 0,
      this.second = 0]);
}

/// Reads the ISO 9660 directory structure of a disc. Sectors come from
/// [readUser], which returns the 2048 user data bytes of a sector.
class Iso9660 {
  final Future<Uint8List> Function(int lba) readUser;

  Iso9660(this.readUser);

  Future<Iso9660Entry?>? _root;
  final _listings = <int, Future<List<Iso9660Entry>>>{};

  /// The root directory of the volume, or null when sector 16 holds no
  /// primary volume descriptor.
  Future<Iso9660Entry?> get root => _root ??= _readRoot();

  Future<Iso9660Entry?> _readRoot() async {
    final pvd = await readUser(16);
    if (pvd.length < 190 || String.fromCharCodes(pvd, 1, 6) != 'CD001') {
      return null;
    }
    return _parseRecord(pvd, 156);
  }

  static Iso9660Entry _parseRecord(Uint8List sector, int at) {
    final view = ByteData.sublistView(sector);
    final nameLength = sector[at + 32];
    final String name;
    if (nameLength == 1 && sector[at + 33] == 0) {
      name = '.';
    } else if (nameLength == 1 && sector[at + 33] == 1) {
      name = '..';
    } else {
      final stored =
          String.fromCharCodes(sector, at + 33, at + 33 + nameLength);
      name = stored.split(';').first;
    }
    return Iso9660Entry(
      name,
      view.getUint32(at + 2, Endian.little),
      view.getUint32(at + 10, Endian.little),
      sector[at + 25] & 2 != 0,
      1900 + sector[at + 18],
      sector[at + 19],
      sector[at + 20],
      sector[at + 21],
      sector[at + 22],
      sector[at + 23],
    );
  }

  /// The entries of the directory [dir], in record order, including the
  /// `.` and `..` records the directory starts with.
  Future<List<Iso9660Entry>> list(Iso9660Entry dir) =>
      _listings.putIfAbsent(dir.lba, () => _readDirectory(dir));

  Future<List<Iso9660Entry>> _readDirectory(Iso9660Entry dir) async {
    final entries = <Iso9660Entry>[];
    for (var offset = 0; offset < dir.size; offset += 2048) {
      final sector = await readUser(dir.lba + offset ~/ 2048);
      var at = 0;
      while (at < sector.length) {
        final length = sector[at];
        if (length == 0) break;
        entries.add(_parseRecord(sector, at));
        at += length;
      }
    }
    return entries;
  }

  /// The entry at [path], a `/`-separated path from the root whose
  /// components match case-insensitively, or null. The components `.`
  /// and `..` walk the tree as usual.
  Future<Iso9660Entry?> find(String path) async {
    final rootDir = await root;
    if (rootDir == null) return null;
    var dir = rootDir;
    final parents = <Iso9660Entry>[];
    final parts =
        path.split('/').where((part) => part.isNotEmpty).toList();
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part == '.') continue;
      if (part == '..') {
        if (parents.isNotEmpty) dir = parents.removeLast();
        continue;
      }
      Iso9660Entry? next;
      for (final entry in await list(dir)) {
        if (entry.name.toUpperCase() == part.toUpperCase()) {
          next = entry;
          break;
        }
      }
      if (next == null) return null;
      if (i + 1 < parts.length) {
        if (!next.isDirectory) return null;
        parents.add(dir);
        dir = next;
      } else {
        return next;
      }
    }
    return dir;
  }

  /// The location of the file [name] at the root of the disc, or null.
  Future<({int lba, int size})?> findRootFile(String name) async {
    final dir = await root;
    if (dir == null) return null;
    for (final entry in await list(dir)) {
      if (entry.name.toUpperCase() == name.toUpperCase()) {
        return (lba: entry.lba, size: entry.size);
      }
    }
    return null;
  }

  /// The contents of a file found by [findRootFile].
  Future<Uint8List> readFile(({int lba, int size}) file) async {
    final out = BytesBuilder();
    for (var i = 0; i * 2048 < file.size; i++) {
      out.add(await readUser(file.lba + i));
    }
    return Uint8List.sublistView(out.toBytes(), 0, file.size);
  }
}
