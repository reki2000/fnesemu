import 'dart:typed_data';

import '../cdrom/async_cdrom_drive.dart';
import '../cdrom/image_file.dart';
import 'cdrom_drive.dart';
import 'core_module.dart';

/// I/O orchestration of discs, independent of any console format.
Future<bool> probeDiscSource(Iterable<MediaHint> hints, DiscSource source,
    Future<CoreSystem?> Function(CdromDrive) identify) async {
  final available = hints.toSet();
  if (available.contains(MediaHint.disc)) return true;
  if (!available.contains(MediaHint.ambiguous)) return false;
  final drive = AsyncCdromDrive();
  try {
    await drive.insert(source);
    return drive.status.isReady && await identify(drive) != null;
  } finally {
    await drive.eject();
  }
}

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
