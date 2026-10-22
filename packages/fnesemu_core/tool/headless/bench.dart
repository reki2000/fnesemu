import 'dart:convert';
import 'dart:io';

import 'package:fnesemu_core/src/types.dart';

import 'options.dart';
import 'session.dart';

const benchUsage = """
bench <core> <media...> [options]: times the frames after a warmup
  --warmup N         frames to run before timing (default: 0)
  --measure N        frames in a timed block (default: 600)
  --repetitions N    timed blocks one after another (default: 1)
  --lock FILE        hold flock(1) on FILE during each timed block (a shared lock,
                     e.g. /tmp/claude-1000/fnesemu-bench.lock)
  --sync DIR         instead of --lock: write DIR/ready.<pid> before the first
                     block and wait for DIR/go (a runner times two builds side by side)
  --checksum         also print fnv-1a hashes of the frame images and the audio
  --hashes FILE      write the image hash of every frame to FILE
  -o, --out DIR      write frame_NNNNN.png every --every frames, audio.wav and
                     state.txt
  -e, --every N      the png interval for --out (default: 300)
  prints a JSON line for each block. The timed part of a frame is the core
  execution and one imageBuffer() call, as in the gui; waiting for the disc,
  the input, the hashes and the files are outside of it. With --checksum the
  audio is hashed while the core runs.""";

Future<void> bench(List<String> args) async {
  final o = Options.parse(args,
      valued: {
        ...mediaValued,
        "--warmup",
        "--measure",
        "--repetitions",
        "--lock",
        "--sync",
        "--hashes",
        "--out",
        "--every",
      },
      flags: {...mediaFlags, "--checksum"},
      aliases: {...mediaAliases, "-o": "--out", "-e": "--every"});
  final (name, files) = coreAndFiles(o);
  final warmup = o.integer("--warmup", 0);
  final measure = o.integer("--measure", 600);
  final repetitions = o.integer("--repetitions", 1);
  final every = o.integer("--every", 300);
  final outDir = o["--out"];
  final checksum = o.flag("--checksum");
  final hashes = o["--hashes"] == null ? null : StringBuffer();
  if (measure <= 0 || repetitions <= 0 || warmup < 0) {
    throw UsageError("--measure and --repetitions take positive numbers");
  }

  final s = await Session.open(name, files, o, recordAudio: outDir != null);
  final core = s.core;
  if (outDir != null) Directory(outDir).createSync(recursive: true);
  var imageHash = _fnvBasis, audioHash = _fnvBasis;
  if (checksum) {
    core.onAudio((buf) {
      if (outDir != null) s.record(buf);
      for (final v in buf.buffer) {
        audioHash = _fnv(audioHash, (v.clamp(-1.0, 1.0) * 32767).round());
      }
    });
  }

  final ticksPerSecond = _ticksPerSecond();
  final timer = Stopwatch();
  final end = warmup + measure * repetitions;
  Process? lock;
  var cpuStart = 0;
  try {
    while (s.frame < end) {
      final blockStart = s.frame >= warmup && (s.frame - warmup) % measure == 0;
      if (blockStart) {
        lock = await _acquire(o["--lock"], s.frame == warmup ? o["--sync"] : null);
        timer.reset();
        cpuStart = _cpuTicks();
      }
      final timed = s.frame >= warmup;
      if (timed) timer.start();
      final running = s.execFrame();
      final image = core.imageBuffer();
      timer.stop();
      if (!running) throw StateError("stopped at frame ${s.frame}");
      await s.endFrame();

      if (checksum || hashes != null) {
        final h = _hashImage(image);
        imageHash = _fnv(imageHash, h);
        hashes?.writeln("${s.frame} ${h.toRadixString(16)}");
      }
      if (outDir != null && s.frame % every == 0) {
        savePng(image, framePath(outDir, s.frame));
      }
      if (s.frame <= warmup && s.frame % 600 == 0) {
        stderr.writeln("warmup ${s.frame}/$warmup");
      }
      if (timed && (s.frame - warmup) % measure == 0) {
        final cpuUs = (_cpuTicks() - cpuStart) * 1000000 ~/ ticksPerSecond;
        await _release(lock);
        lock = null;
        final us = timer.elapsedMicroseconds;
        stdout.writeln(jsonEncode({
          "core": name,
          "frameRunner": s.frameRunner,
          "rep": (s.frame - warmup) ~/ measure - 1,
          "fromFrame": s.frame - measure + 1,
          "toFrame": s.frame,
          "frames": measure,
          "us": us,
          "msPerFrame": us / measure / 1000,
          "fps": us > 0 ? measure * 1000000 / us : null,
          "cpuUs": cpuUs,
          "cpuMsPerFrame": cpuUs / measure / 1000,
          "cpuFps": cpuUs > 0 ? measure * 1000000 / cpuUs : null,
          "pc": core.programCounter(0),
          if (checksum) "imageHash": imageHash.toRadixString(16),
          if (checksum) "audioHash": audioHash.toRadixString(16),
        }));
      }
    }
  } finally {
    // releases the lock also when the core stops or a file cannot be written
    await _release(lock);
  }
  if (hashes != null) File(o["--hashes"]!).writeAsStringSync("$hashes");
  if (outDir != null) {
    if (s.pcm.length > 0) File("$outDir/audio.wav").writeAsBytesSync(s.wav());
    File("$outDir/state.txt").writeAsStringSync(core.dump());
  }
}

const _fnvBasis = 0x811c9dc5;

int _fnv(int h, int v) => ((h ^ (v & 0xffffffff)) * 0x01000193) & 0xffffffff;

int _hashImage(ImageBuffer image) {
  var h = _fnvBasis;
  for (final p in image.buffer) {
    h = _fnv(h, p);
  }
  return h;
}

/// takes the lock (or waits for the go of [syncDir]); the process holds the
/// lock until its stdin is closed
Future<Process?> _acquire(String? path, String? syncDir) async {
  if (syncDir != null) {
    File("$syncDir/ready.$pid").writeAsStringSync("");
    while (!File("$syncDir/go").existsSync()) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    return null;
  }
  if (path == null) return null;
  final p = await Process.start("flock", [path, "sh", "-c", "echo locked; read x"]);
  final ready = await p.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  if (ready != "locked") throw StateError("the lock $path is not taken");
  return p;
}

Future<void> _release(Process? lock) async {
  if (lock == null) return;
  lock.stdin.writeln();
  await lock.stdin.close();
  await lock.exitCode;
}

int _ticksPerSecond() {
  try {
    return int.parse(
        (Process.runSync("getconf", ["CLK_TCK"]).stdout as String).trim());
  } catch (_) {
    return 100;
  }
}

/// the user + system cpu time of this process in clock ticks (linux), 0
/// when it is not available
int _cpuTicks() {
  try {
    final stat = File("/proc/self/stat").readAsStringSync();
    final f = stat.substring(stat.lastIndexOf(")") + 2).split(" ");
    return int.parse(f[11]) + int.parse(f[12]);
  } catch (_) {
    return 0;
  }
}
