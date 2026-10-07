import 'dart:typed_data';

import 'package:fnesemu/core/md/md.dart';

import 'cdrom_drive.dart';
import 'core.dart';
import 'gb/gb.dart';
import 'gba/gba.dart';
import 'nes/nes.dart';
import 'n64/n64.dart';
import 'pce/pce.dart';
import 'ps/ps.dart';
import 'ss/ss.dart';
import 'snes/snes.dart';

/// a system the emulator runs. one core class can serve several systems,
/// such as md, md cdrom and 32x.
class CoreSystem {
  final String id;

  /// short name shown in the GUI
  final String name;

  /// extensions of the rom files
  final List<String> extensions;

  /// number of the BIOS files, 0 if the system has no BIOS
  final int biosFiles;

  /// true if the system does not run without its BIOS
  final bool biosRequired;

  /// id of the system whose discs this system plays, null if no cdrom
  final String? disc;

  const CoreSystem(this.id, this.name,
      {this.extensions = const [],
      this.biosFiles = 0,
      this.biosRequired = false,
      this.disc});

  bool get hasBios => biosFiles > 0;

  @override
  String toString() => name;
}

class CoreFactory {
  static const systems = [
    CoreSystem("nes", "nes", extensions: ["nes"]),
    // a cdrom system card loaded as a rom plays pce cd discs as well
    CoreSystem("pce", "pce", extensions: ["pce"], disc: "pcecd"),
    CoreSystem("pcecd", "pce", biosFiles: 1, biosRequired: true, disc: "pcecd"),
    CoreSystem("md", "md", extensions: ["gen", "md", "bin"]),
    CoreSystem("mdcd", "md", biosFiles: 1, biosRequired: true, disc: "mdcd"),
    CoreSystem("32x", "32x", extensions: ["32x"], biosFiles: 3),
    CoreSystem("ps", "ps1",
        extensions: ["exe"], biosFiles: 1, biosRequired: true, disc: "ps"),
    CoreSystem("ss", "ss", biosFiles: 1, biosRequired: true, disc: "ss"),
    CoreSystem("gb", "gb", extensions: ["gb"]),
    CoreSystem("gba", "gba", extensions: ["gba"], biosFiles: 1),
    CoreSystem("snes", "snes", extensions: ["sfc", "smc"]),
    CoreSystem("n64", "n64", extensions: ["n64", "z64", "v64"]),
  ];

  /// md cdrom and 32x share the BIOS menu entry of md. returns the system of
  /// such a BIOS file told apart by its size (and the role within 32x), or
  /// null if it is neither
  static (String system, String role)? mdBiosOf(Uint8List data) =>
      switch (data.length) {
        0x20000 => ('mdcd', 'md cdrom'),
        0x100 => ('32x', '68000'),
        0x800 => ('32x', 'sh-2 master'),
        0x400 => ('32x', 'sh-2 slave'),
        _ => null,
      };

  /// extensions of the files in a zip which can be loaded
  static final extensions = [for (final s in systems) ...s.extensions];

  static CoreSystem system(String id) => systems.firstWhere((s) => s.id == id,
      orElse: () => throw Exception('unsupported system: $id'));

  /// creates the core of the system [id]
  static Core of(String id) {
    // Explicit returns retain Core as the result type when every concrete
    // core also implements FrameRunner (the inferred common type is Object).
    switch (id) {
      case 'nes':
        return Nes();
      case 'pce' || 'pcecd':
        return Pce();
      case 'md':
        return Md();
      case 'mdcd':
        return Md(cdBoot: true);
      case '32x':
        return Md(expansionBoot: true);
      case 'ps':
        return Ps();
      case 'ss':
        return Ss();
      case 'gb':
        return Gb();
      case 'gba':
        return Gba();
      case 'snes':
        return Snes();
      case 'n64':
        return N64();
      default:
        throw Exception('unsupported system: $id');
    }
  }

  /// returns the system of the rom file [name]
  static CoreSystem systemOfFile(String name, Uint8List body) {
    final ext = name.substring(name.lastIndexOf(".") + 1).toLowerCase();

    for (final s in systems) {
      if (s.extensions.contains(ext)) {
        return s.id == "md" && _is32x(body) ? system("32x") : s;
      }
    }

    throw Exception('unsupported file: $name');
  }

  static bool _is32x(Uint8List body) =>
      body.length >= 0x110 &&
      String.fromCharCodes(body.sublist(0x100, 0x110)).contains('32X');

  /// returns the system of the disc in [drive] from its header, or null.
  /// [drive] must be ready.
  static Future<CoreSystem?> systemOfDisc(CdromDrive drive) async {
    final toc = drive.status.toc;
    final firstData = toc.tracks.where((t) => !t.isAudio).firstOrNull;
    if (firstData == null) {
      return null;
    }

    final start = firstData.startLba;
    final head = await _read(drive, start);
    if (_contains(head, "SEGADISCSYSTEM")) return system("mdcd");
    if (_contains(head, "SEGA SEGASATURN")) return system("ss");

    if (_contains(
            await _read(drive, start + 4), "Sony Computer Entertainment") ||
        _contains(await _read(drive, start + 16), "PLAYSTATION")) {
      return system("ps");
    }

    // the second sector of the data track. a few sectors around it are also
    // checked, since the index of some cue files is off by a few frames
    for (final lba in [start + 1, start, start + 2, start + 3]) {
      if (_contains(await _read(drive, lba), "PC Engine CD-ROM SYSTEM")) {
        return system("pcecd");
      }
    }

    return null;
  }

  // waits for the sector read in the background
  static Future<Uint8List> _read(CdromDrive drive, int lba) async {
    for (int i = 0; i < 5000; i++) {
      final data = drive.read(lba);
      if (data != null) return data;
      await Future.delayed(const Duration(milliseconds: 1));
    }
    return Uint8List(0);
  }

  static bool _contains(Uint8List sector, String s) =>
      String.fromCharCodes(sector).contains(s);
}
