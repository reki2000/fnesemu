// a single .iso/.bin file: one data track, raw (2352 bytes/sector) or cooked
// (2048 bytes/sector)
import '../../filesystem_api.dart';
import '../../image_api.dart';
import '../disc_source.dart';
import '../file_image.dart';

/// a single data track, raw (2352 bytes/sector) or cooked (2048 bytes)
Future<FileImage> openIso(DiscSource source) async {
  final file = source.main;
  final length = await file.length();
  final cooked = await _isCooked(file, length, source.name);
  final sectors = FileImage.sectorsOf(length, cooked);
  if (sectors == 0) {
    throw const FormatException("cdrom: empty image");
  }
  return FileImage(source, DiscToc([DiscTrack(1, false, 0, sectors)], sectors),
      [Extent(0, sectors, file, 0, cooked: cooked)]);
}

// raw images start with the sync pattern. cooked ones have "CD001" at
// sector 16, or are an .iso whose size is a multiple of 2048 without sync
Future<bool> _isCooked(DiscFile file, int length, String name) async {
  // a size which is a multiple of 2352 but not of 2048 is a raw image
  if (length % FileImage.sectorSize == 0 &&
      length % FileImage.cookedSectorSize != 0) {
    return false;
  }
  final head = await file.read(0, FileImage.sync.length);
  var hasSync = head.length == FileImage.sync.length;
  for (int i = 0; hasSync && i < FileImage.sync.length; i++) {
    hasSync = head[i] == FileImage.sync[i];
  }
  if (hasSync) return false;

  const pvd = 16 * FileImage.cookedSectorSize + 1;
  if (length > pvd + 5 &&
      String.fromCharCodes(await file.read(pvd, 5)) == "CD001") {
    return true;
  }
  return name.toLowerCase().endsWith(".iso") &&
      length % FileImage.cookedSectorSize == 0;
}
