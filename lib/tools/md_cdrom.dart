import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/md/md.dart';
import '../core/pad_button.dart';
import '../cdrom/async_cdrom_drive.dart';
import '../cdrom/disc_source_local.dart';

/// Headless BIOS/disc smoke runner with optional input and frame captures.
Future<void> main(List<String> args) async {
  final paths = args.where((arg) => !arg.startsWith('--')).toList();
  if (paths.length < 2 || paths.length > 3) {
    stderr.writeln(
        'Usage: dart run lib/tools/md_cdrom.dart <128 KiB BIOS> <disc.cue|disc.iso|disc.bin> [frames] [--start-frame=N] [--out=DIR] [--every=N]');
    exitCode = 64;
    return;
  }
  String? option(String name) => args
      .where((arg) => arg.startsWith('--$name='))
      .map((arg) => arg.substring(name.length + 3))
      .firstOrNull;
  final frames = paths.length == 3 ? int.tryParse(paths[2]) : 600;
  final startText = option('start-frame');
  final startFrame = startText == null ? null : int.tryParse(startText);
  final everyText = option('every');
  final every = everyText == null ? 300 : int.tryParse(everyText);
  if (frames == null ||
      frames <= 0 ||
      every == null ||
      every <= 0 ||
      (startText != null && (startFrame == null || startFrame < 0))) {
    stderr
        .writeln('frames/every must be positive and start-frame non-negative');
    exitCode = 64;
    return;
  }
  final drive = AsyncCdromDrive();
  await drive.eject(discSourceFromPath(paths[1]));
  if (!drive.status.isReady) {
    stderr.writeln('Could not load disc: ${paths[1]}');
    exitCode = 66;
    return;
  }
  final md = Md(cdBoot: true)
    ..setCdromDrive(drive)
    ..setRom(File(paths[0]).readAsBytesSync());
  final output = option('out');
  if (output != null) Directory(output).createSync(recursive: true);
  int frame = 0;
  bool startPressed = false;
  void capture(String name) {
    if (output == null) return;
    final buf = md.imageBuffer();
    final bytes =
        Uint8List.sublistView(buf.buffer, 0, buf.width * buf.height * 4);
    final image = img.Image.fromBytes(
        width: buf.width,
        height: buf.height,
        bytes: bytes.buffer,
        bytesOffset: bytes.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba);
    File('$output/$name.png').writeAsBytesSync(img.encodePng(image));
    File('$output/$name.txt').writeAsStringSync(md.dump());
  }

  while (frame < frames) {
    if (startFrame != null) {
      final pressed = frame >= startFrame && frame < startFrame + 15;
      if (pressed != startPressed) {
        if (pressed) {
          md.padDown(0, const PadButton('Start'));
        } else {
          md.padUp(0, const PadButton('Start'));
        }
        startPressed = pressed;
      }
    }
    final result = md.exec(false);
    if (result.stopped) {
      capture('stopped-$frame');
      stderr.writeln(md.dump());
      exitCode = 1;
      return;
    }
    if (result.scanlineRendered && md.vdp.vCounter == 0) {
      frame++;
      await drive.settle(); // result must not depend on the speed of the disc
      if (frame % every == 0 || frame == frames) {
        stdout.writeln(
            'frame:$frame main:${md.cpuM68.pc.toRadixString(16)} sub:${md.cdrom!.cpu.pc.toRadixString(16)} CDD:${md.cdrom!.drive.status.toRadixString(16)} LBA:${md.cdrom!.drive.lba}');
        capture('frame-$frame');
      }
    }
  }
  stdout.writeln(md.dump());
}
