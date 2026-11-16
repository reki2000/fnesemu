import 'dart:convert';

import '../../cdrom.dart';
import '../../util/iso9660.dart';

export '../../util/iso9660.dart';

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
