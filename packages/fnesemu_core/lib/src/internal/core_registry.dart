import '../core_module.dart';
import 'core_registry_generated.dart';

List<CoreModule> _modules = createInstalledCoreModules()
  ..sort((a, b) => a.order.compareTo(b.order));

/// Internal registry used by the public factory.
List<CoreModule> get installedCoreModules => _modules;

/// Internal composition hook, also used by package boundary tests.
void registerCoreModules(Iterable<CoreModule> modules) {
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
