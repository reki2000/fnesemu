import 'dart:io';


class DiscLoader {
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
              return cueFile;
            } else if (f is File) {
              final lower = f.path.toLowerCase();
              final suffix = lower.split('.').last;
              if (!['iso', 'bin', 'cue'].contains(suffix)) {
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
