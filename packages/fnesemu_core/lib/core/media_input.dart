import 'dart:typed_data';

import 'cdrom_drive.dart';

int? firstDataLba(CdromDrive drive) => drive.status.toc.tracks
    .where((track) => !track.isAudio)
    .firstOrNull
    ?.startLba;
Future<Uint8List> readDiscSector(CdromDrive drive, int lba) async {
  for (var attempt = 0; attempt < 5000; attempt++) {
    final data = drive.read(lba);
    if (data != null) return data;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return Uint8List(0);
}

bool sectorContains(Uint8List bytes, String signature) =>
    String.fromCharCodes(bytes).contains(signature);
