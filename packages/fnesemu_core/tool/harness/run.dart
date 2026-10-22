import 'dart:io';

import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:image/image.dart' as img;

import 'debug_views.dart';
import 'options.dart';
import 'session.dart';

const runUsage = """
run <core> <media...> [options]: runs the core and writes the screen and the audio
  -f, --frames N     frames to run (default: 600)
  -e, --every N      save frame_NNNNN.png every N frames (default: 60)
  -s, --start N      save the pngs only from frame N on (default: 0)
  -o, --out DIR      output directory (default: /tmp/core_harness)
  -w, --wav          also write audio.wav (16bit pcm)
  -v, --vram         ps: also write vram.png (the whole 1024x512 VRAM)
  -d, --debug        also write the debugger views at the last frame
                     (bg.png, vram.png, colors.png, sprites.txt; snes: snes.txt,
                     vram.bin, layerN.png)
  writes state.txt (the core dump) at the end""";

Future<void> run(List<String> args) async {
  final o = Options.parse(args,
      valued: {...mediaValued, "--frames", "--every", "--start", "--out"},
      flags: {...mediaFlags, "--wav", "--vram", "--debug"},
      aliases: {
        ...mediaAliases,
        "-f": "--frames",
        "-e": "--every",
        "-s": "--start",
        "-o": "--out",
        "-w": "--wav",
        "-v": "--vram",
        "-d": "--debug",
      });
  final (name, files) = coreAndFiles(o);
  final frames = o.integer("--frames", 600);
  final every = o.integer("--every", 60);
  final start = o.integer("--start", 0);
  final outDir = o["--out"] ?? "/tmp/core_harness";

  final s = await Session.open(name, files, o);
  final core = s.core;
  Directory(outDir).createSync(recursive: true);
  final sw = Stopwatch()..start();

  while (s.frame < frames) {
    if (!await s.stepFrame()) {
      stdout.writeln("stopped at frame ${s.frame}\n${core.dump()}");
      savePng(core.imageBuffer(), "$outDir/stopped.png");
      exit(2);
    }
    if (s.frame % every == 0 && s.frame >= start) {
      final path = framePath(outDir, s.frame);
      savePng(core.imageBuffer(), path);
      stdout.writeln("frame ${s.frame} "
          "(${(sw.elapsedMilliseconds / s.frame).toStringAsFixed(1)} ms/frame) "
          "pc:${core.programCounter(0).toRadixString(16)} audio-peak:"
          "${s.peak.toStringAsFixed(3)} -> $path");
    }
  }

  if (o.flag("--wav") && s.pcm.length > 0) {
    File("$outDir/audio.wav").writeAsBytesSync(s.wav());
  }
  if (o.flag("--vram") && core is Ps) _saveVram(core, "$outDir/vram.png");
  if (o.flag("--debug")) writeDebugViews(core, outDir);
  File("$outDir/state.txt").writeAsStringSync(core.dump());
  stdout.writeln(core.dump());
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
