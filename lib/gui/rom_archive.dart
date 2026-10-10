import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cdrom_image/cdrom_image.dart';
import 'package:fnesemu_core/core/core_api.dart';

bool isZip(String name) => name.toLowerCase().endsWith('.zip');

/// true if [names] of the entries of a zip have a CD-ROM image (.cue or
/// .iso). they are not supported in a zip: the zip is not taken as a ROM,
/// and its .bin files are not taken as ROMs.
bool hasDiscImage(Iterable<String> names) =>
    names.any((name) => DiscFileKind.of(name) == DiscFileKind.image);

/// the names of the entries of a zip file of [length] bytes, read from its
/// central directory by [read] without reading the entries
Future<List<String>> zipEntryNames(
    int length, Future<Uint8List> Function(int offset, int length) read) async {
  // the end of central directory record: 22 bytes and a comment up to 64KiB
  const eocdSize = 22;
  final tailLength = min(length, eocdSize + 0xffff);
  final tail = await read(length - tailLength, tailLength);
  final t = ByteData.sublistView(tail);
  var eocd = -1;
  for (int i = tail.length - eocdSize; i >= 0; i--) {
    if (t.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('Not a zip file');

  final entries = t.getUint16(eocd + 10, Endian.little);
  final size = t.getUint32(eocd + 12, Endian.little);
  final offset = t.getUint32(eocd + 16, Endian.little);
  if (entries == 0xffff || size == 0xffffffff || offset == 0xffffffff) {
    throw const FormatException('Zip64 is not supported');
  }

  final dir = await read(offset, size);
  final d = ByteData.sublistView(dir);
  final names = <String>[];
  var pos = 0;
  for (int i = 0; i < entries && pos + 46 <= dir.length; i++) {
    if (d.getUint32(pos, Endian.little) != 0x02014b50) {
      throw const FormatException('Broken zip central directory');
    }
    final nameLength = d.getUint16(pos + 28, Endian.little);
    final extraLength = d.getUint16(pos + 30, Endian.little);
    final commentLength = d.getUint16(pos + 32, Endian.little);
    names.add(utf8.decode(dir.sublist(pos + 46, pos + 46 + nameLength),
        allowMalformed: true));
    pos += 46 + nameLength + extraLength + commentLength;
  }
  return names;
}

/// the ROM in the file [name]: the first entry of a zip archive which a core
/// recognizes, or the file itself
(Uint8List, String) unpackRom(Uint8List bytes, String name) {
  if (!isZip(name)) return (bytes, name);
  final archive = ZipDecoder().decodeBytes(bytes);
  if (hasDiscImage(archive.map((entry) => entry.name))) {
    throw FormatException('CD-ROM images in a zip are not supported: $name');
  }
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final data = Uint8List.fromList(entry.content as List<int>);
    if (CoreFactory.findRom(entry.name, data) != null) {
      return (data, entry.name);
    }
  }
  throw FormatException('No supported ROM in archive: $name');
}
