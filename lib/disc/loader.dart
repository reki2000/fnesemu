import 'dart:io';

import 'cue.dart';
import 'disc.dart';
import 'empty.dart';
import 'iso.dart';

class DiscLoader {
  static Disc load(String path) {
    if (path.toLowerCase().endsWith(".iso") ||
        path.toLowerCase().endsWith(".bin")) {
      return IsoDisc(path);
    } else if (path.toLowerCase().endsWith(".cue")) {
      return CueDisc(path);
    } else {
      return EmptyDisc();
    }
  }

  static List<String> discoverDiscs(String dir) {
    final foundNames = <String>{};

    if (dir.isNotEmpty && Directory(dir).existsSync()) {
      final discs = Directory(dir)
          .listSync()
          .map((f) {
            if (f is Directory) {
              final files = f.listSync().whereType<File>();
              final cueFile = files
                      .where((file) => file.path.toLowerCase().endsWith('.cue'))
                      .firstOrNull
                      ?.path ??
                  "";
              if (cueFile.isNotEmpty) {
                foundNames.add(cueFile.replaceAll(".cue", ""));
              }
            } else if (f is File) {
              final lower = f.path.toLowerCase();
              final suffix = lower.split('.').last;
              if (!['iso', 'bin'].contains(suffix)) {
                return ""; // skip unsupported file types
              }
              if (foundNames.contains(lower.replaceAll(".$suffix", ""))) {
                return ""; // skip if already found as cue track
              }
              return f.path;
            }
            return "";
          })
          .where((p) => p.isNotEmpty)
          .toList();

      return discs;
    }

    return [];
  }
}
