import 'disc_image.dart';
import 'disc_source.dart';
import 'filesystem_api.dart';
import 'image_api.dart';

/// a disc image in a [DiscFolder], parsed by [DiscFolder.parse]
class DiscImageFile {
  final DiscFolder folder;

  /// the .cue, .iso or .bin file
  final String path;

  /// the paths of the files the .cue file refers to, found in the folder.
  /// they are parts of this image, not disc images or ROMs by themselves.
  /// empty for an .iso/.bin file.
  final List<String> referredFiles;

  /// the names written in the .cue file which are not in the folder
  final List<String> missingFiles;

  const DiscImageFile(
      this.folder, this.path, this.referredFiles, this.missingFiles);

  bool get isCue => path.toLowerCase().endsWith(".cue");

  /// true if all the files of the image are in the folder
  bool get isComplete =>
      missingFiles.isEmpty && (!isCue || referredFiles.isNotEmpty);

  /// the image to read by [parseSource]
  DiscSource open() => folder.source(path);
}

/// the files of a [DiscDirectory]. the files referred from a .cue file are
/// found by the names written in it, relative to the .cue file and ignoring
/// the case.
class DiscFolder {
  static const _maxCueBytes = 1 << 20;

  /// Normalized path -> file. Reuse this index when parsing many images.
  final Map<String, DiscFile> _index;

  DiscFolder(Iterable<DiscFile> files)
      : _index = {for (final file in files) _key('', file.path)!: file};

  DiscFile _file(String path) =>
      _index[_key('', path)] ??
      (throw ArgumentError('cdrom: file not found in the directory: $path'));

  /// the path of [name] written in the .cue file at [cuePath], or null if it
  /// is not in the folder
  String? resolve(String cuePath, String name) {
    final key = _key(_dirOf(cuePath), name);
    return key == null ? null : _index[key]?.path;
  }

  /// parses the .cue/.iso/.bin file at [path]. throws if a .cue file cannot
  /// be read.
  Future<DiscImageFile> parse(String path) async {
    if (!path.toLowerCase().endsWith(".cue")) {
      return DiscImageFile(this, path, const [], const []);
    }

    final names = ParsedDiscImage.cueFileNames(
        await readText(_file(path), maxBytes: _maxCueBytes));

    final referred = <String>[];
    final missing = <String>[];
    for (final name in names) {
      final found = resolve(path, name);
      found == null ? missing.add(name) : referred.add(found);
    }
    return DiscImageFile(this, path, referred, missing);
  }

  /// the disc image of the .cue/.iso/.bin file at [path]
  DiscSource source(String path) => DiscSource(_file(path), (name) {
        final found = resolve(path, name);
        if (found == null) {
          throw DiscParseException(path, 'Referenced file not found: $name',
              referencedPath: name);
        }
        return _file(found);
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
