import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';

import 'cdrom_drive.dart';
import 'local_disc.dart';

/// An original sector-read diagnostic, separate from BIOS/game boot validation.
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln('Usage: dart run tool/dc_disc_probe.dart DISC_IMAGE [LBA]');
    exitCode = 64;
    return;
  }
  final lba = args.length == 2 ? int.parse(args[1]) : 16;
  final drive = SimpleCdromDrive();
  await drive.insert(localDisc(args[0]));
  final toc = drive.status.toc;
  if (!drive.status.isReady ||
      lba < 0 ||
      lba >= toc.totalSectors ||
      lba + 150 > 0xffffff ||
      toc.isAudioLba(lba)) {
    throw ArgumentError(
        'The diagnostic requires a readable Mode 1 data sector');
  }
  final identified = await CoreFactory.systemOfDisc(drive);
  final core = Dc();
  try {
    core.setRom(_program(lba + 150));
    core.setCdromDrive(drive);
    var executed = 0;
    for (; executed < 100000 && core.read(0, 0x8c021000) == 0; executed++) {
      if (core.exec(false).stopped) break;
      if (drive.hasPendingReads) await drive.settle();
    }
    final done = core.read(0, 0x8c021000) == 1;
    final expected = done ? drive.read(lba) : null;
    var matches = done &&
        expected != null &&
        expected.length == 2352 &&
        expected[15] == 1;
    if (matches) {
      for (var i = 0; i < 2048; i++) {
        if (core.read(0, 0x8c020000 + i) != expected[16 + i]) {
          matches = false;
          break;
        }
      }
    }
    stdout.writeln(jsonEncode({
      'lba': lba,
      'discSectors': toc.totalSectors,
      'discTracks': toc.trackCount,
      'identifiedSystem': identified?.id,
      'instructions': executed,
      'completed': done,
      'matchesDrive': matches,
      'stop': core.stopReason,
    }));
    if (!matches) exitCode = 2;
  } finally {
    core.dispose();
  }
}

Uint8List _program(int fad) {
  final words = <int>[];
  const literals = [
    0xa05f709c,
    0xa05f7080,
    0xa05f7018,
    0x8c010400,
    0x8c020000,
    0xa05f7090,
    0xa05f7094,
    0x8c021000,
    1024
  ];
  for (var register = 1; register <= literals.length; register++) {
    final base = (words.length * 2 + 4) & ~3;
    words.add(
        0xd000 | (register << 8) | ((0x300 + (register - 1) * 4 - base) ~/ 4));
  }
  void waitBusy() => words.addAll([0x6030, 0xc880, 0x8bfc]);
  for (var command = 0; command < 2; command++) {
    words.addAll([0xe000, 0x2600, 0xe008, 0x2700, 0xe0a0, 0x2100]);
    waitBusy();
    for (var word = 0; word < 6; word++) {
      words.addAll([0x6045, 0x2201]);
    }
    waitBusy();
    if (command == 0) {
      words.addAll(List.filled(5, 0x6021));
    } else {
      words.addAll([0x6021, 0x2501, 0x7502, 0x4910, 0x8bfa]);
    }
  }
  words.addAll([0xe001, 0x2800, 0xaffe, 0x0009]);
  final bytes = Uint8List(0x418), data = ByteData(0x418);
  for (var i = 0; i < words.length; i++) {
    data.setUint16(i * 2, words[i], Endian.little);
  }
  for (var i = 0; i < literals.length; i++) {
    data.setUint32(0x300 + i * 4, literals[i], Endian.little);
  }
  bytes.setAll(0, data.buffer.asUint8List());
  bytes.setAll(0x400, [
    0x13,
    0,
    0,
    0,
    10,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0x30,
    0x24,
    (fad >> 16) & 255,
    (fad >> 8) & 255,
    fad & 255,
    0,
    0,
    0,
    0,
    0,
    1,
    0
  ]);
  return bytes;
}
