import 'dart:typed_data';

import '../cdrom_drive.dart';
import '../core.dart';
import '../core_module.dart';
import '../media_input.dart';
import 'md.dart';

CoreModule createModule() => MdModule();

class MdModule extends CoreModule {
  static const cartridge = CoreSystem('md', 'md',
      debugPaletteCount: 4, extensions: ['gen', 'md', 'bin']);
  static const cd = CoreSystem('mdcd', 'md',
      debugPaletteCount: 4, biosFiles: 1, biosRequired: true, disc: 'mdcd');
  static const expansion = CoreSystem('32x', '32x',
      debugPaletteCount: 4, extensions: ['32x'], biosFiles: 3);
  @override
  List<CoreSystem> get systems => [cartridge, cd, expansion];
  @override
  int get order => 2;
  @override
  int get discPriority => 0;
  @override
  List<BiosSetup> get biosSetups => [
        BiosSetup.group('md', [cd, expansion],
            labels: ['cdrom', '32x'],
            prepare: (files, existing) => biosUpdates(
                files.map((file) => (file.$2, file.$1)).toList(),
                saved32x: existing[expansion.id] ?? []))
      ];
  @override
  Core create(String id) =>
      Md(cdBoot: id == cd.id, expansionBoot: id == expansion.id);
  @override
  CoreSystem? identifyRom(String name, Uint8List body) {
    final ext = mediaExtension(name);
    if (ext == '32x') return expansion;
    if (!cartridge.extensions.contains(ext)) return null;
    return body.length >= 0x110 &&
            String.fromCharCodes(body.sublist(0x100, 0x110)).contains('32X')
        ? expansion
        : cartridge;
  }

  @override
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async {
    final start = firstDataLba(drive);
    return start != null &&
            sectorContains(await readDiscSector(drive, start), 'SEGADISCSYSTEM')
        ? cd
        : null;
  }

  static (String system, String role)? biosRole(Uint8List data) =>
      switch (data.length) {
        0x20000 => ('mdcd', 'md cdrom'),
        0x100 => ('32x', '68000'),
        0x800 => ('32x', 'sh-2 master'),
        0x400 => ('32x', 'sh-2 slave'),
        _ => null,
      };

  /// Distributes a combined MD BIOS selection and preserves unselected roles.
  /// The application treats the returned files as opaque storage updates.
  static Map<String, List<(String, Uint8List)>> biosUpdates(
      List<(Uint8List, String)> selected,
      {List<(String, Uint8List)> saved32x = const []}) {
    final cd = <(String, Uint8List)>[];
    final expansion = <String, (String, Uint8List)>{};
    for (final (data, name) in selected) {
      switch (biosRole(data)) {
        case ('mdcd', _):
          cd.add((name, data));
        case ('32x', final role):
          expansion[role] = (name, data);
        default:
          throw FormatException('Not a BIOS of md cdrom or 32x: $name');
      }
    }
    if (cd.length > 1) {
      throw ArgumentError('Select one md cdrom BIOS: ${cd.length} selected');
    }
    final updates = <String, List<(String, Uint8List)>>{};
    if (cd.isNotEmpty) updates['mdcd'] = cd;
    if (expansion.isNotEmpty) {
      for (final (name, data) in saved32x) {
        final role = biosRole(data)?.$2;
        if (role != null) expansion.putIfAbsent(role, () => (name, data));
      }
      updates['32x'] = expansion.values.toList();
    }
    return updates;
  }
}
