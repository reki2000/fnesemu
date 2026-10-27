import 'dart:typed_data';

/// Reads the ISO 9660 directory structure of a disc to find a file. Sectors
/// come from [readUser], which returns the 2048 user data bytes of a sector.
class Iso9660 {
  final Future<Uint8List> Function(int lba) readUser;

  Iso9660(this.readUser);

  /// the location of the file at the root of the disc, or null
  Future<({int lba, int size})?> findRootFile(String name) async {
    final pvd = await readUser(16);
    if (pvd.length < 190 || String.fromCharCodes(pvd, 1, 6) != 'CD001') {
      return null;
    }
    final root = ByteData.sublistView(pvd);
    final dirLba = root.getUint32(156 + 2, Endian.little);
    final dirSize = root.getUint32(156 + 10, Endian.little);
    for (var offset = 0; offset < dirSize; offset += 2048) {
      final sector = await readUser(dirLba + offset ~/ 2048);
      final view = ByteData.sublistView(sector);
      var at = 0;
      while (at < sector.length) {
        final length = sector[at];
        if (length == 0) break;
        final nameLength = sector[at + 32];
        final entry =
            String.fromCharCodes(sector, at + 33, at + 33 + nameLength);
        if (entry.split(';').first.toUpperCase() == name.toUpperCase()) {
          return (
            lba: view.getUint32(at + 2, Endian.little),
            size: view.getUint32(at + 10, Endian.little)
          );
        }
        at += length;
      }
    }
    return null;
  }

  /// the contents of a file found by [findRootFile]
  Future<Uint8List> readFile(({int lba, int size}) file) async {
    final out = BytesBuilder();
    for (var i = 0; i * 2048 < file.size; i++) {
      out.add(await readUser(file.lba + i));
    }
    return Uint8List.sublistView(out.toBytes(), 0, file.size);
  }
}
