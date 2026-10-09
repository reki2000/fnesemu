import 'dart:typed_data';
import 'cdrom_drive.dart';
import 'core.dart';
import 'core_module.dart';
import 'installed_core_modules.dart';
export 'core_module.dart';

/// Registry and delegation only. This library imports no concrete core.
class CoreFactory {
  static List<CoreModule> _modules = createInstalledCoreModules()
    ..sort((a, b) => a.order.compareTo(b.order));
  static void registerModules(Iterable<CoreModule> modules) {
    final installed = modules.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final ids = <String>{};
    for (final module in installed) {
      for (final system in module.systems) {
        if (!ids.add(system.id)) {
          throw ArgumentError('Duplicate core: ${system.id}');
        }
      }
    }
    _modules = installed;
  }

  static List<CoreSystem> get systems =>
      List.unmodifiable(_modules.expand((module) => module.systems));
  static List<BiosSetup> get biosSetups =>
      List.unmodifiable(_modules.expand((module) => module.biosSetups));
  static List<String> get extensions =>
      systems.expand((system) => system.extensions).toList();
  static CoreSystem? systemOrNull(String id) =>
      systems.where((system) => system.id == id).firstOrNull;
  static CoreSystem system(String id) =>
      systemOrNull(id) ?? (throw StateError('Unsupported core: $id'));
  static Core of(String id) {
    for (final module in _modules) {
      if (module.systems.any((system) => system.id == id)) {
        return module.create(id);
      }
    }
    throw StateError('Unsupported core: $id');
  }

  static CoreSystem? findRom(String name, Uint8List body) {
    for (final module in _modules) {
      final system = module.identifyRom(name, body);
      if (system != null) return system;
    }
    return null;
  }

  static CoreSystem systemOfFile(String name, Uint8List body) =>
      findRom(name, body) ?? (throw FormatException('Unsupported file: $name'));
  static Future<CoreSystem?> systemOfDisc(CdromDrive drive) async {
    final modules = _modules.toList()
      ..sort((a, b) => a.discPriority.compareTo(b.discPriority));
    for (final module in modules) {
      final system = await module.identifyDisc(drive);
      if (system != null) return system;
    }
    return null;
  }

  /// whether a file of [name] is a disc image: [MediaHint.disc] if a core
  /// takes it as a disc, [MediaHint.ambiguous] if it can be a disc or a ROM
  /// (the disc is identified by [systemOfDisc]).
  static MediaHint mediaHint(String name) {
    final hints = _modules.map((module) => module.mediaHint(name)).toSet();
    if (hints.contains(MediaHint.disc)) return MediaHint.disc;
    if (hints.contains(MediaHint.ambiguous)) return MediaHint.ambiguous;
    return MediaHint.unknown;
  }
}
