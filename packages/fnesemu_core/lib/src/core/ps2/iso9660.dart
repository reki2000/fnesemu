import 'dart:convert';
import 'dart:typed_data';

import '../../cdrom.dart';

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

/// The 2048 bytes of user data in a raw sector (mode 1 or mode 2 form 1).
Uint8List userData(Uint8List raw) {
  if (raw.length < 2352) return Uint8List(0);
  final offset = raw[15] == 2 ? 24 : 16;
  return Uint8List.sublistView(raw, offset, offset + 2048);
}

/// The text of SYSTEM.CNF at the root of the disc in [drive], or null
Future<String?> readSystemCnf(CdromDrive drive) async {
  final start = drive.firstDataLba;
  if (start == null) return null;
  final iso =
      Iso9660((lba) async => userData(await drive.readWhenReady(start + lba)));
  final file = await iso.findRootFile('SYSTEM.CNF');
  if (file == null) return null;
  return utf8.decode(await iso.readFile(file), allowMalformed: true);
}

/// the sectors of the longest CD (99 minutes); a larger disc is a DVD
const _cdSectors = 99 * 60 * 75;

/// True if the disc in [drive] is a DVD: larger than a CD, or with a UDF
/// volume recognition sequence after the ISO 9660 descriptors. PS2 DVDs are
/// mastered as UDF bridge discs and PS2 CDs as plain ISO 9660 ones.
Future<bool> isDvd(CdromDrive drive) async {
  if (drive.status.toc.totalSectors > _cdSectors) return true;
  final start = drive.firstDataLba;
  if (start == null) return false;
  for (var lba = 16; lba < 32; lba++) {
    final sector = userData(await drive.readWhenReady(start + lba));
    if (sector.length < 6) return false;
    final id = String.fromCharCodes(sector, 1, 6);
    if (id == 'BEA01' || id == 'NSR02' || id == 'NSR03') return true;
    if (id != 'CD001' && id != 'BOOT2' && id != 'CDW02') return false;
  }
  return false;
}

/// The file name of the BOOT2 line in SYSTEM.CNF without the directory and
/// the version, such as `ABCD_123.45`, or null
String? bootFileName(String systemCnf) {
  final match =
      RegExp(r'^\s*BOOT2\s*=\s*(\S+)', multiLine: true).firstMatch(systemCnf);
  if (match == null) return null;
  return match[1]!.split(RegExp(r'[:\\/]')).last.split(';').first;
}
