// headless harness for the cores on develop (nes / pce / md / ps / snes / gb / gba / n64):
// runs a rom, dumps frames as png and the audio output as wav
//
// usage: dart run tool/core_harness.dart <nes|fds|pce|md|mdcd|32x|ps|snes|gb|gba|n64> <rom|bios> [disc] [options]
//   -f, --frames N   number of frames to run (default: 600)
//   -e, --every N    save a png every N frames (default: 60)
//   -o, --out DIR    output directory (default: /tmp/core_harness)
//   -p, --press F:B  press button B (name or index) at frame F (repeatable)
//   -H, --hold N     frames to hold a pressed button (default: 10)
//   -s, --start N    save pngs only from frame N on (default: 0)
//   -w, --wav        also write audio.wav (16bit pcm) to the output directory
//   -b, --bios FILE  gba/fds: BIOS image (required for fds)
//   -3, --boot A,B,C 32x: boot roms (main 256B, master 2048B, slave 1024B)
//   -x, --exe FILE   ps: run this PS-EXE after the BIOS boot (test programs)
//   -v, --vram       ps: also write vram.png (the whole 1024x512 VRAM)
//
//   -r, --frame-runner  execute whole frames inside the core
//
// files: <out>/frame_NNNNN.png, <out>/audio.wav, <out>/state.txt
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:image/image.dart' as img;

import 'cdrom_drive.dart';
import 'local_disc.dart';
import 'ps_io.dart';

Future<void> main(List<String> args) async {
  int frames = 600;
  int every = 60;
  String outDir = "/tmp/core_harness";
  final presses = <(int, String)>[];
  int holdFrames = 10;
  bool wav = false;
  int saveFrom = 0;
  String? bios;
  String? boot32x;
  String? exe;
  bool vram = false;
  bool frameRunner = false;
  final files = <String>[];

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "-f" || "--frames":
        frames = int.parse(args[++i]);
      case "-e" || "--every":
        every = int.parse(args[++i]);
      case "-o" || "--out":
        outDir = args[++i];
      case "-H" || "--hold":
        holdFrames = int.parse(args[++i]);
      case "-s" || "--start":
        saveFrom = int.parse(args[++i]);
      case "-w" || "--wav":
        wav = true;
      case "-b" || "--bios":
        bios = args[++i];
      case "-3" || "--boot":
        boot32x = args[++i];
      case "-x" || "--exe":
        exe = args[++i];
      case "-r" || "--frame-runner":
        frameRunner = true;
      case "-v" || "--vram":
        vram = true;
      case "-p" || "--press":
        final p = args[++i].split(":");
        presses.add((int.parse(p[0]), p[1]));
      default:
        files.add(args[i]);
    }
  }

  if (files.length < 2) {
    print(
        "usage: core_harness <nes|fds|pce|md|mdcd|32x|ps|snes|gb|gba|n64> <rom|bios> [disc] "
        "[-f frames] [-e every] [-o dir] [-p F:B] [-w]");
    exit(1);
  }

  Directory(outDir).createSync(recursive: true);

  final core = _createCore(files[0]);
  core.setSram(Sram());
  if (bios != null && (core is Gba || files[0] == "fds")) {
    core.setBiosFiles([File(bios).readAsBytesSync()]);
  }
  if (files[0] == "32x") {
    final roms =
        boot32x!.split(",").map((f) => File(f).readAsBytesSync()).toList();
    (core as Md)
        .setExpansionBootRoms(main: roms[0], master: roms[1], slave: roms[2]);
  }
  SimpleCdromDrive? drive;
  if (files.length > 2) {
    drive = SimpleCdromDrive();
    await drive.insert(localDisc(files[2]));
    if (!drive.status.isReady) throw "cannot read disc: ${files[2]}";
  }
  // the md cdrom core needs the disc before the bios
  if (files[0] == "mdcd" && drive != null) {
    core.setCdromDrive(drive);
  }
  if (core is Ps) {
    core.setBiosFiles([_loadRom(files[1])]); // rom: the ps bios
  } else {
    core.setRom(_loadRom(files[1]));
  }
  if (files[0] != "mdcd" && drive != null) {
    core.setCdromDrive(drive);
  }
  // gba boots from setRom; a reset afterwards drops the boot state
  if (files[0] != "gba" && files[0] != "mdcd" && files[0] != "32x") {
    core.reset();
  }
  if (exe != null) core.setRom(File(exe).readAsBytesSync());

  final buttons = core.buttons;
  final pressList = presses.map((p) {
    final idx = int.tryParse(p.$2) ??
        buttons.indexWhere((b) => b.name.toLowerCase() == p.$2.toLowerCase());
    if (idx < 0 || idx >= buttons.length) {
      throw "unknown button: ${p.$2} (${buttons.map((b) => b.name).join(",")})";
    }
    return (p.$1, idx);
  }).toList();

  final pcm = BytesBuilder();
  int sampleRate = 0, channels = 0;
  double peak = 0;
  core.onAudio((buf) {
    sampleRate = buf.sampleRate;
    channels = buf.channels;
    for (final s in buf.buffer) {
      if (s.abs() > peak) peak = s.abs();
      final v = (s.clamp(-1.0, 1.0) * 32767).round();
      pcm.addByte(v & 0xff);
      pcm.addByte((v >> 8) & 0xff);
    }
  });

  final sw = Stopwatch()..start();
  int lines = 0;
  int frame = 0;

  while (frame < frames) {
    final r =
        frameRunner ? core.runFrame(core.scanlinesInFrame) : core.exec(false);
    if (r.stopped) {
      print("stopped at frame $frame\n${core.dump()}");
      _savePng(core.imageBuffer(), "$outDir/stopped.png");
      exit(2);
    }
    if (!r.scanlineRendered) continue;
    lines += frameRunner ? core.scanlinesInFrame : 1;
    if (lines < core.scanlinesInFrame) continue;
    lines = 0;
    frame++;
    // sectors are read in the background: wait for them at each frame so
    // that the result does not depend on the speed of the disc
    await drive?.settle();

    for (final (f, b) in pressList) {
      if (frame == f) core.padDown(0, buttons[b]);
      if (frame == f + holdFrames) core.padUp(0, buttons[b]);
    }

    if (frame % every == 0 && frame >= saveFrom) {
      final path = "$outDir/frame_${frame.toString().padLeft(5, "0")}.png";
      _savePng(core.imageBuffer(), path);
      print("frame $frame "
          "(${(sw.elapsedMilliseconds / frame).toStringAsFixed(1)} ms/frame) "
          "pc:${core.programCounter(0).toRadixString(16)} audio-peak:"
          "${peak.toStringAsFixed(3)} -> $path");
    }
  }

  if (wav && pcm.length > 0) {
    File("$outDir/audio.wav")
        .writeAsBytesSync(_wav(pcm.toBytes(), sampleRate, channels));
  }
  if (vram && core is Ps) {
    _saveVram(core, "$outDir/vram.png");
  }
  File("$outDir/state.txt").writeAsStringSync(core.dump());
  print(core.dump());
}

Core _createCore(String name) {
  switch (name) {
    case 'nes':
      return Nes();
    case 'fds':
      return Nes(diskSystem: true);
    case 'pce':
      return Pce();
    case 'md':
      return Md();
    case 'mdcd':
      return Md(cdBoot: true);
    case '32x':
      return Md(expansionBoot: true);
    case 'ps':
      return createPsForTools();
    case 'snes':
      return Snes();
    case 'gb':
      return Gb();
    case 'gba':
      return Gba();
    case 'n64':
      return N64();
    default:
      throw ArgumentError('unknown core: $name');
  }
}

Uint8List _wav(Uint8List pcm, int rate, int channels) {
  final h = ByteData(44);
  void tag(int o, String s) {
    for (int i = 0; i < 4; i++) {
      h.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, "RIFF");
  h.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, "WAVE");
  tag(12, "fmt ");
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, channels, Endian.little);
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * channels * 2, Endian.little);
  h.setUint16(32, channels * 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, "data");
  h.setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...pcm]);
}

Uint8List _loadRom(String path) {
  final bytes = File(path).readAsBytesSync();
  if (!path.toLowerCase().endsWith(".zip")) return bytes;
  final archive = ZipDecoder().decodeBytes(bytes);
  final f = archive.files.firstWhere((f) => f.isFile);
  return Uint8List.fromList(f.content as List<int>);
}

void _savePng(ImageBuffer buf, String path) {
  if (buf.width == 0) return;
  final image = img.Image.fromBytes(
      width: buf.width,
      height: buf.height,
      bytes: buf.buffer.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba);
  File(path).writeAsBytesSync(img.encodePng(image));
}

// dumps the whole VRAM (1024x512, 15bit) as a png
void _saveVram(Ps ps, String path) {
  final fb = ps.gpu.frameBuffer16;
  final image = img.Image(width: 1024, height: 512);
  for (int y = 0; y < 512; y++) {
    for (int x = 0; x < 1024; x++) {
      final c = fb[y * 1024 + x];
      int e(int v) => (v << 3) | (v >> 2);
      image.setPixelRgb(
          x, y, e(c & 0x1f), e((c >> 5) & 0x1f), e((c >> 10) & 0x1f));
    }
  }
  File(path).writeAsBytesSync(img.encodePng(image));
}
