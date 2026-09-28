// Run real SNES cartridges without the Flutter UI and capture rendered frames.
// dart run lib/tools/snes_harness.dart <rom-or-directory> [frames] [output-dir]
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/core/snes/snes.dart';
import 'package:fnesemu/core/snes/rom/snes_file.dart';
import 'package:fnesemu/core/snes/component/ppu_render.dart';
import 'package:image/image.dart' as image;

void main(List<String> args) {
  if (args.isEmpty || args.length > 3) {
    stderr.writeln(
      'Usage: dart run lib/tools/snes_harness.dart '
      '<rom-or-directory> [frames=180] [output-dir=/tmp/snes-harness]',
    );
    exitCode = 64;
    return;
  }

  final input = FileSystemEntity.typeSync(args[0]);
  final frames = args.length > 1 ? int.parse(args[1]) : 180;
  if (frames < 1) throw ArgumentError.value(frames, 'frames');
  final output = Directory(args.length > 2 ? args[2] : '/tmp/snes-harness')
    ..createSync(recursive: true);
  final roms = input == FileSystemEntityType.directory
      ? Directory(args[0])
          .listSync()
          .whereType<File>()
          .where(
            (f) => RegExp(
              r'\.(sfc|smc)$',
              caseSensitive: false,
            ).hasMatch(f.path),
          )
          .toList()
      : [File(args[0])];
  if (roms.isEmpty) throw StateError('No .sfc/.smc files found');

  for (final rom in roms) {
    final bytes = rom.readAsBytesSync();
    final header = SnesFile()..load(bytes);
    final core = Snes()..setRom(bytes);
    final name = rom.uri.pathSegments.last.replaceFirst(
      RegExp(r'\.(sfc|smc)$', caseSensitive: false),
      '',
    );
    stdout.writeln(
      '$name: ${header.title}, ${header.mapping.name}, '
      '${header.rom.length} bytes',
    );

    var scanlines = 0;
    var instructions = 0;
    for (var frame = 1; frame <= frames; frame++) {
      while (scanlines < core.scanlinesInFrame) {
        final result = core.exec(false);
        instructions++;
        if (result.stopped) {
          throw StateError(
            '$name stopped at frame $frame, '
            'PC=0x${core.programCounter(0).toRadixString(16)}: '
            '${core.dump()}',
          );
        }
        if (result.scanlineRendered) scanlines++;
        if (instructions > frames * 1000000) {
          throw StateError('$name exceeded instruction limit at frame $frame');
        }
      }
      scanlines = 0;
      if (frame == 1 || frame % 30 == 0 || frame == frames) {
        final pixels = core.imageBuffer();
        final rgba = Uint8List.fromList(
          pixels.buffer.sublist(0, pixels.width * pixels.height * 4),
        );
        final picture = image.Image.fromBytes(
          width: pixels.width,
          height: pixels.height,
          bytes: rgba.buffer,
          order: image.ChannelOrder.rgba,
        );
        final path =
            '${output.path}/$name-${frame.toString().padLeft(4, '0')}.png';
        File(path).writeAsBytesSync(image.encodePng(picture));
        final distinct =
            core.ppu.buffer.take(pixels.width * pixels.height).toSet().length;
        stdout.writeln(
          '  frame $frame: PC=0x${core.programCounter(0).toRadixString(16)} '
          'mode=${core.ppu.bgMode} blank=${core.ppu.forcedBlank} '
          'colors=$distinct image=$path '
          'layers=${core.ppu.mainScreenEnable.toRadixString(16)} '
          'maps=${core.ppu.bgs.map((bg) => bg.tilemapAddr.toRadixString(16)).join(",")}',
        );
        if (frame == frames) {
          stdout.writeln(
              '  BG: ${core.ppu.bgs.map((bg) => "(${bg.hofs},${bg.vofs}) ${bg.charBase.toRadixString(16)} ${bg.wideX}/${bg.wideY} big=${bg.bigChar}").join(" ")}');
          stdout.writeln(
              '  HDMA: ${core.dma.hdmaEnableMask.toRadixString(16)} ${core.dma.channels.map((c) => "${c.bbad.toRadixString(16)}:${c.dmap.toRadixString(16)}:${c.a1tAddr.toRadixString(16)}").join(" ")}');
          stdout.writeln(
              '  windows: ${core.ppu.w12sel.toRadixString(16)} tmw=${core.ppu.tmw.toRadixString(16)} ${core.ppu.w1Left}-${core.ppu.w1Right} ${core.ppu.w2Left}-${core.ppu.w2Right}');
          File('${output.path}/$name-vram.bin').writeAsBytesSync(core.ppu.vram);
        }
        if (frame == frames) {
          final enabled = core.ppu.mainScreenEnable;
          for (var layer = 0; layer < 5; layer++) {
            if (enabled & (1 << layer) == 0) continue;
            core.ppu.mainScreenEnable = 1 << layer;
            for (var line = 1; line <= 224; line++) {
              core.ppu.renderScanline(line);
            }
            final isolated = core.imageBuffer();
            final layerImage = image.Image.fromBytes(
              width: isolated.width,
              height: isolated.height,
              bytes: Uint8List.fromList(isolated.buffer
                      .sublist(0, isolated.width * isolated.height * 4))
                  .buffer,
              order: image.ChannelOrder.rgba,
            );
            File('${output.path}/$name-layer$layer.png')
                .writeAsBytesSync(image.encodePng(layerImage));
          }
          core.ppu.mainScreenEnable = enabled;
        }
      }
    }
  }
}
