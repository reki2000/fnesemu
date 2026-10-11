import 'dart:typed_data';
import 'src/cdrom_drive.dart';
import 'src/core.dart';
import 'src/core_module.dart';
import 'src/internal/core_registry.dart';
export 'src/core_module.dart' show BiosFile, BiosSetup, BiosUpdates, CoreSystem;

/// Registry and delegation only. This library imports no concrete core.
class CoreFactory {
  static List<CoreSystem> get systems => List.unmodifiable(
      installedCoreModules.expand((module) => module.systems));
  static List<BiosSetup> get biosSetups => List.unmodifiable(
      installedCoreModules.expand((module) => module.biosSetups));
  static List<String> get extensions =>
      systems.expand((system) => system.extensions).toList();
  static CoreSystem? systemOrNull(String id) =>
      systems.where((system) => system.id == id).firstOrNull;
  static CoreSystem system(String id) =>
      systemOrNull(id) ?? (throw StateError('Unsupported core: $id'));
  static Core of(String id) {
    for (final module in installedCoreModules) {
      if (module.systems.any((system) => system.id == id)) {
        return module.create(id);
      }
    }
    throw StateError('Unsupported core: $id');
  }

  static CoreSystem? findRom(String name, Uint8List body) {
    for (final module in installedCoreModules) {
      final system = module.identifyRom(name, body);
      if (system != null) return system;
    }
    return null;
  }

  static CoreSystem systemOfFile(String name, Uint8List body) =>
      findRom(name, body) ?? (throw FormatException('Unsupported file: $name'));
  static Future<CoreSystem?> systemOfDisc(CdromDrive drive) async {
    final modules = installedCoreModules.toList()
      ..sort((a, b) => a.discPriority.compareTo(b.discPriority));
    for (final module in modules) {
      final system = await module.identifyDisc(drive);
      if (system != null) return system;
    }
    return null;
  }
}
