import 'dart:typed_data';

import '../../cdrom.dart';
import 'disc.dart';

/// Explicit diagnostic loading for an unscrambled program, not BIOS disc boot.
/// IP.BIN layout: Marcus Comstedt's original hardware notes, November 2000.
/// https://mc.pp.se/dc/ip.bin.html
class DcBootstrap {
  DcBootstrap(this.ip, this.program, this.name, this.programLba,
      {required this.bootAreaPresent});
  final Uint8List ip, program;
  final String name;
  final int programLba;
  final bool bootAreaPresent;
}

Future<DcBootstrap> loadDcBootstrap(CdromDrive drive,
    {Future<void> Function()? waitForSector,
    bool Function()? isCurrent}) async {
  final initial = drive.status;
  if (!initial.isReady) throw StateError('No ready DC disc');
  final tracks = initial.toc.tracks.where((track) => !track.isAudio).toList();
  if (tracks.isEmpty) throw const FormatException('No DC data track');
  final track = tracks.last;
  if (track.startLba < 0 ||
      track.sectors < 16 ||
      track.startLba + track.sectors > initial.toc.totalSectors) {
    throw const FormatException('Invalid bootstrap data track bounds');
  }
  const blockSize = 2048;

  Future<Uint8List> block(int relative) async {
    if (isCurrent != null && !isCurrent()) {
      throw StateError('Core changed during disc bootstrap loading');
    }
    if (relative < 0 || relative >= track.sectors) {
      throw const FormatException('ISO block exceeds data track');
    }
    var raw = drive.read(track.startLba + relative);
    for (var attempt = 0; raw == null && attempt < 5000; attempt++) {
      if ((isCurrent != null && !isCurrent()) ||
          !drive.status.isReady ||
          drive.status.discId != initial.discId) {
        throw const FormatException('Disc changed during bootstrap loading');
      }
      if (waitForSector != null) {
        await waitForSector();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      raw = drive.read(track.startLba + relative);
    }
    if (!drive.status.isReady ||
        drive.status.discId != initial.discId ||
        raw?.length != cdSectorSize) {
      throw const FormatException('Disc changed or sector read failed');
    }
    final sector = raw!;
    for (var i = 0; i < cdSync.length; i++) {
      if (sector[i] != cdSync[i]) {
        throw const FormatException('Missing bootstrap sector sync');
      }
    }
    if (sector[15] == 1) return Uint8List.sublistView(sector, 16, 2064);
    if (sector[15] == 2 && sector[18] & 0x20 == 0) {
      for (var i = 16; i < 20; i++) {
        if (sector[i] != sector[i + 4]) {
          throw const FormatException('Mismatched Mode 2 subheaders');
        }
      }
      return Uint8List.sublistView(sector, 24, 2072);
    }
    throw const FormatException('Bootstrap requires Mode 1 or Mode 2 Form 1');
  }

  Uint8List? primary;
  for (var i = 16; i < 48; i++) {
    final data = await block(i);
    if (String.fromCharCodes(data.sublist(1, 6)) != 'CD001' || data[6] != 1) {
      throw const FormatException('Missing ISO volume descriptor');
    }
    if (data[0] == 255) break;
    if (data[0] == 1) {
      primary = data;
      break;
    }
  }
  if (primary == null || _both(primary, 128, 2) != blockSize) {
    throw const FormatException('Missing 2048-byte ISO primary volume');
  }
  final volumeBlocks = _both(primary, 80, 4);
  if (volumeBlocks < 16 || volumeBlocks > track.sectors) {
    throw const FormatException('ISO volume exceeds data track');
  }

  // Directory records address absolute disc LBAs, so a volume in a later
  // session starts at its track's LBA rather than at zero.
  Future<Uint8List> extent(int lba, int size) async {
    final start = lba - track.startLba;
    if (start < 0 || size < 1 || start + (size + 2047) ~/ 2048 > volumeBlocks) {
      throw const FormatException('ISO extent exceeds volume');
    }
    final data = Uint8List(size);
    for (var offset = 0; offset < size; offset += blockSize) {
      final sector = await block(start + offset ~/ blockSize);
      final end = (offset + blockSize).clamp(0, size);
      data.setRange(offset, end, sector);
    }
    return data;
  }

  final rootStart = _both(primary, 158, 4);
  final rootSize = _both(primary, 166, 4);
  if (rootSize > 256 * 1024) {
    throw const FormatException(
        'Bootstrap root directory exceeds diagnostic bound');
  }
  final root = await extent(rootStart, rootSize);
  final entries = <String, (int, int)>{};
  for (var offset = 0; offset < root.length;) {
    final size = root[offset];
    if (size == 0) {
      offset = (offset ~/ blockSize + 1) * blockSize;
      continue;
    }
    if (size < 34 ||
        offset + size > root.length ||
        offset % blockSize + size > blockSize) {
      throw const FormatException('Malformed ISO directory record');
    }
    final record = Uint8List.sublistView(root, offset, offset + size);
    final nameSize = record[32];
    if (33 + nameSize > size) {
      throw const FormatException('Malformed ISO filename');
    }
    if (record[25] & 0x82 == 0 &&
        record[1] == 0 &&
        record[26] == 0 &&
        record[27] == 0) {
      final name = String.fromCharCodes(record.sublist(33, 33 + nameSize))
          .split(';')
          .first
          .toUpperCase();
      entries[name] = (_both(record, 2, 4), _both(record, 10, 4));
    }
    offset += size;
  }

  bool header(Uint8List data) =>
      data.length >= 256 &&
      String.fromCharCodes(data.sublist(0, dcDiscSignature.length)) ==
          dcDiscSignature;
  var ip = await extent(track.startLba, 32768);
  final bootAreaPresent = header(ip);
  if (!bootAreaPresent) {
    final entry = entries['IP.BIN'];
    if (entry == null || entry.$2 != 32768) {
      throw const FormatException('Missing 32 KiB IP.BIN');
    }
    ip = await extent(entry.$1, entry.$2);
  }
  if (!header(ip)) throw const FormatException('Missing IP.BIN identity');
  final name =
      String.fromCharCodes(ip.sublist(0x60, 0x70)).trim().toUpperCase();
  final entry = entries[name];
  if (entry == null || entry.$2 < 2 || entry.$2 > 0xff0000) {
    throw FormatException('Missing or oversized boot program: $name');
  }
  return DcBootstrap(
      ip, await extent(entry.$1, entry.$2), name, entry.$1,
      bootAreaPresent: bootAreaPresent);
}

// ECMA-119 stores directory lengths and positions in both byte orders.
int _both(Uint8List data, int offset, int width) {
  var little = 0, big = 0;
  for (var i = 0; i < width; i++) {
    little |= data[offset + i] << (i * 8);
    big = (big << 8) | data[offset + width + i];
  }
  if (little != big) throw const FormatException('ISO byte orders disagree');
  return little;
}
