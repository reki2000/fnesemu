import 'disc_image.dart';
import 'disc_source.dart';

/// the files a .cue file refers to, in a [DiscFolder]
class CueReferences {
  /// the paths of the files found in the folder
  final List<String> found;

  /// the names written in the .cue file which are not in the folder
  final List<String> missing;

  /// false if the .cue file cannot be read
  final bool readable;

  const CueReferences(this.found, this.missing, {this.readable = true});

  static const unreadable = CueReferences([], [], readable: false);

  /// true if the .cue file is a disc image with all of its files
  bool get isComplete => readable && found.isNotEmpty && missing.isEmpty;
}

/// the files of a [DiscDirectory]. the files referred from a .cue file are
/// found by the names written in it, relative to the .cue file and ignoring
/// the case.
class DiscFolder {
  static const _maxCueBytes = 1 << 20;

  final DiscDirectory dir;

  /// [_key] of the path -> the path
  final Map<String, String> _index;

  /// [files] are the paths of [DiscDirectory.walk]
  DiscFolder(this.dir, Iterable<String> files)
      : _index = {for (final f in files) _key('', f)!: f};

  /// the path of [name] written in the .cue file at [cuePath], or null if it
  /// is not in the folder
  String? resolve(String cuePath, String name) {
    final key = _key(_dirOf(cuePath), name);
    return key == null ? null : _index[key];
  }

  /// the files the .cue file at [cuePath] refers to. a file found here is a
  /// part of the disc image, not a disc image or a ROM by itself, even if the
  /// .cue file is not complete.
  Future<CueReferences> cueReferences(String cuePath) async {
    DiscFile? file;
    final List<String> names;
    try {
      file = dir.open(cuePath);
      names =
          DiscImage.cueFileNames(await readText(file, maxBytes: _maxCueBytes));
    } catch (_) {
      return CueReferences.unreadable;
    } finally {
      await file?.close();
    }

    final found = <String>[];
    final missing = <String>[];
    for (final name in names) {
      final path = resolve(cuePath, name);
      path == null ? missing.add(name) : found.add(path);
    }
    return CueReferences(found, missing);
  }

  /// the disc image of the .cue/.iso/.bin file at [path]
  DiscSource source(String path) => DiscSource(dir.open(path), (name) {
        final found = resolve(path, name);
        if (found == null) {
          throw ArgumentError("cdrom: file not found in the folder: $name");
        }
        return dir.open(found);
      });

  /// normalizes a path written in a .cue file ('\' or '/', '.', '..')
  /// relative to [baseDir] ('' or 'a/b'), into a lower case key. returns null
  /// if it goes out of the folder.
  static String? _key(String baseDir, String name) {
    final parts = <String>[];
    final all = [
      ...baseDir.split('/'),
      ...name.replaceAll('\\', '/').split('/'),
    ];
    for (final p in all) {
      if (p.isEmpty || p == '.') continue;
      if (p == '..') {
        if (parts.isEmpty) return null;
        parts.removeLast();
      } else {
        parts.add(p);
      }
    }
    return parts.join('/').toLowerCase();
  }

  static String _dirOf(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }
}
