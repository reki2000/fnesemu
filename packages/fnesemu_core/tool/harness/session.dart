import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:image/image.dart' as img;

import '../cdrom_drive.dart';
import '../input_sequence.dart';
import '../local_disc.dart';
import '../ps_io.dart';
import 'options.dart';

/// the options that set up the core, shared by the subcommands that run it
const mediaValued = {"--bios", "--boot", "--exe", "--input"};
const mediaFlags = {"--fast-boot", "--fixed-clock", "--log-cd", "--frame-runner"};
const mediaAliases = {
  "-b": "--bios",
  "-3": "--boot",
  "-x": "--exe",
  "-i": "--input",
  "-r": "--frame-runner",
};

const mediaUsage = """
  <core> <rom|bios> [disc]   the core (nes fds pce md mdcd 32x ps ss snes gb gba n64
                             sms mk3 smstms gg ws wsc) and its media
  -i, --input SEQ    the button presses, in the syntax of tool/input_sequence.dart
  -b, --bios FILE    gba / fds: the BIOS image (required for fds)
  -3, --boot A,B,C   32x: the boot roms (main 256B, master 2048B, slave 1024B)
  -x, --exe FILE     ps: run this PS-EXE after the BIOS boot
  --fast-boot        ps: skip the logo animation of the BIOS
  --fixed-clock      ss: the real time clock always reads 2000-01-01
  --log-cd           ss: log the commands of the CD block
  -r, --frame-runner run whole frames inside the core instead of exec()""";

/// the core name and the media files of the positional arguments
(String, List<String>) coreAndFiles(Options o) {
  if (o.positional.length < 2) throw UsageError("the core and its media");
  return (o.positional.first, o.positional.sublist(1));
}

/// creates the core of [name] as the gui does
Core createCore(String name) =>
    name == "ps" ? createPsForTools() : CoreFactory.of(name);

/// the button names of [core], in the order of the pad
List<String> buttonNames(Core core) => core.buttons.map((b) => b.name).toList();

/// the presses of [input]; an error in it ends the harness
List<(int, int, int)> readPresses(String? input, List<String> buttons) {
  try {
    return resolveInput(input ?? "", buttons);
  } on InputError catch (e) {
    stderr.writeln(e);
    exit(64);
  }
}

/// a core with its media and input, run frame by frame
class Session {
  final String name;
  final Core core;
  final SimpleCdromDrive? drive;
  final PadPlayer pad;
  final List<String> buttons;
  final List<PadButton> _pads;
  final bool frameRunner;

  /// the frames run so far
  int frame = 0;
  int _lines = 0;

  /// the audio output as 16bit pcm, when it is recorded
  final pcm = BytesBuilder();
  int sampleRate = 0, channels = 0;
  double peak = 0;

  Session._(this.name, this.core, this.drive, this.pad, this.buttons,
      this.frameRunner)
      : _pads = core.buttons;

  /// loads the media of [o] into the core of [name]; with [recordAudio],
  /// keeps the audio output in [pcm]
  static Future<Session> open(String name, List<String> files, Options o,
      {bool recordAudio = true}) async {
    final core = createCore(name);
    final buttons = buttonNames(core);
    final pad = PadPlayer(readPresses(o["--input"], buttons), buttons.length);
    core.setSram(Sram());

    final bios = o["--bios"];
    if (bios != null) {
      if (core is! Gba && name != "fds") {
        throw UsageError("--bios is for gba and fds");
      }
      core.setBiosFiles([File(bios).readAsBytesSync()]);
    }
    final boot = o["--boot"];
    if (name == "32x") {
      if (boot == null) throw UsageError("32x needs --boot");
      final roms =
          boot.split(",").map((f) => File(f).readAsBytesSync()).toList();
      (core as Md)
          .setExpansionBootRoms(main: roms[0], master: roms[1], slave: roms[2]);
    }
    SimpleCdromDrive? drive;
    if (files.length > 1) {
      drive = SimpleCdromDrive();
      await drive.insert(localDisc(files[1]));
      if (!drive.status.isReady) throw "cannot read disc: ${files[1]}";
    }
    // the md cdrom core needs the disc before the bios
    if (name == "mdcd" && drive != null) core.setCdromDrive(drive);
    if (core is Ps) {
      core.fastBoot = o.flag("--fast-boot"); // patches the bios when it is set
      core.setBiosFiles([loadRom(files[0])]);
    } else {
      if (o.flag("--fast-boot")) throw UsageError("--fast-boot is for ps");
      core.setRom(loadRom(files[0]));
    }
    if (name != "mdcd" && drive != null) core.setCdromDrive(drive);
    // gba boots from setRom; a reset afterwards drops the boot state
    if (name != "gba" && name != "mdcd" && name != "32x") core.reset();
    if (core is Ss) {
      core.cdblock.log = o.flag("--log-cd");
      if (o.flag("--fixed-clock")) core.smpc.clock = () => DateTime(2000, 1, 1);
    } else if (o.flag("--fixed-clock") || o.flag("--log-cd")) {
      throw UsageError("--fixed-clock and --log-cd are for ss");
    }
    final exe = o["--exe"];
    if (exe != null) core.setRom(File(exe).readAsBytesSync());

    final session = Session._(
        name, core, drive, pad, buttons, o.flag("--frame-runner"));
    if (recordAudio) core.onAudio(session.record);
    return session;
  }

  /// keeps [buf] in [pcm]
  void record(AudioBuffer buf) {
    sampleRate = buf.sampleRate;
    channels = buf.channels;
    for (final s in buf.buffer) {
      if (s.abs() > peak) peak = s.abs();
      final v = (s.clamp(-1.0, 1.0) * 32767).round();
      pcm.addByte(v & 0xff);
      pcm.addByte((v >> 8) & 0xff);
    }
  }

  /// counts the scanline that [r] rendered; true when it ends a frame
  bool endsFrame(ExecResult r) {
    if (!r.scanlineRendered) return false;
    if (++_lines < core.scanlinesInFrame) return false;
    _lines = 0;
    return true;
  }

  /// runs the core to the end of the next frame; false when the core stopped
  bool execFrame() {
    if (frameRunner) return !core.runFrame(core.scanlinesInFrame).stopped;
    while (true) {
      final r = core.exec(false);
      if (r.stopped) return false;
      if (endsFrame(r)) return true;
    }
  }

  /// counts the frame, waits for the disc and applies the presses
  Future<void> endFrame() async {
    frame++;
    // sectors are read in the background: wait for them at each frame so
    // that the result does not depend on the speed of the disc
    await drive?.settle();
    pad.step(frame, (b, down) {
      down ? core.padDown(0, _pads[b]) : core.padUp(0, _pads[b]);
    });
  }

  /// runs the next frame; false when the core stopped
  Future<bool> stepFrame() async {
    if (!execFrame()) return false;
    await endFrame();
    return true;
  }

  /// the recorded audio as a wav file
  Uint8List wav() => wavBytes(pcm.toBytes(), sampleRate, channels);
}

/// the path of the png of [frame] in [dir]
String framePath(String dir, int frame) =>
    "$dir/frame_${frame.toString().padLeft(5, "0")}.png";

Uint8List loadRom(String path) {
  final bytes = File(path).readAsBytesSync();
  if (!path.toLowerCase().endsWith(".zip")) return bytes;
  final archive = ZipDecoder().decodeBytes(bytes);
  final f = archive.files.firstWhere((f) => f.isFile);
  return Uint8List.fromList(f.content as List<int>);
}

void savePng(ImageBuffer buf, String path) {
  if (buf.width == 0) return;
  final image = img.Image.fromBytes(
      width: buf.width,
      height: buf.height,
      bytes: buf.buffer.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba);
  File(path).writeAsBytesSync(img.encodePng(image));
}

/// 16bit pcm as a wav file
Uint8List wavBytes(Uint8List pcm, int rate, int channels) {
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
