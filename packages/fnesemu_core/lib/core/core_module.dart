import 'dart:typed_data';
import 'cdrom_drive.dart';
import 'core.dart';

typedef BiosFile = (String, Uint8List);
typedef BiosUpdates = Map<String, List<BiosFile>>;
typedef BiosPreparer = BiosUpdates Function(
    List<BiosFile>, Map<String, List<BiosFile>>);

enum MediaHint { unknown, rom, disc, ambiguous }

class CoreSystem {
  final String id, name;
  final List<String> extensions;
  final int biosFiles;
  final bool biosRequired;
  final int debugPaletteCount, debugVramBits;
  final String? disc;
  const CoreSystem(this.id, this.name,
      {this.extensions = const [],
      this.biosFiles = 0,
      this.biosRequired = false,
      this.disc,
      this.debugPaletteCount = 1,
      this.debugVramBits = 8});
  bool get hasBios => biosFiles > 0;
  @override
  String toString() => name;
}

/// Public BIOS setup metadata and an optional module-owned file interpreter.
class BiosSetup {
  final String name;
  final List<CoreSystem> systems;
  final List<String>? labels;
  final BiosPreparer? _prepare;
  BiosSetup.single(CoreSystem system)
      : name = system.name,
        systems = [system],
        labels = null,
        _prepare = null;
  const BiosSetup.group(this.name, this.systems,
      {this.labels, required BiosPreparer prepare})
      : _prepare = prepare;
  int get maxFiles => systems.fold(0, (sum, system) => sum + system.biosFiles);
  BiosUpdates prepare(List<BiosFile> files,
      {Map<String, List<BiosFile>> existing = const {}}) {
    final handler = _prepare;
    if (handler != null) return handler(files, existing);
    final system = systems.single;
    if (files.length != system.biosFiles) {
      throw ArgumentError(
          '${system.name} requires ${system.biosFiles} BIOS files: ${files.length} selected');
    }
    return {system.id: files};
  }

  String summary(Map<String, List<String>> names) {
    if (systems.length == 1) {
      final system = systems.single, files = names[systems.single.id] ?? [];
      return files.isNotEmpty
          ? files.join(', ')
          : 'BIOS not set${system.biosRequired ? "" : " (optional)"}';
    }
    if (systems.every((system) => (names[system.id] ?? []).isEmpty)) {
      return 'BIOS not set';
    }
    return [
      for (var i = 0; i < systems.length; i++)
        '${labels?[i] ?? systems[i].name}: ${(names[systems[i].id] ?? []).isEmpty ? "-" : names[systems[i].id]!.join(", ")}'
            '${(names[systems[i].id] ?? []).isNotEmpty && names[systems[i].id]!.length < systems[i].biosFiles ? " (${names[systems[i].id]!.length}/${systems[i].biosFiles})" : ""}'
    ].join(' / ');
  }
}

/// Concrete modules own construction and all media ownership decisions.
abstract class CoreModule {
  List<CoreSystem> get systems;
  int get order => 100;
  int get discPriority => 100;
  List<BiosSetup> get biosSetups =>
      systems.where((system) => system.hasBios).map(BiosSetup.single).toList();
  Core create(String id);
  CoreSystem? identifyRom(String name, Uint8List body);
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async => null;
  MediaHint mediaHint(String name) => MediaHint.unknown;
}

String mediaExtension(String name) =>
    name.substring(name.lastIndexOf('.') + 1).toLowerCase();
