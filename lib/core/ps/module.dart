import 'dart:typed_data';
import '../core.dart';
import '../storage_key.dart';
import '../core_module.dart';
import '../cdrom_drive.dart';
import '../media_input.dart';
import 'ps.dart';

CoreModule createModule() => PsModule();

class PsModule extends CoreModule {
  static const system = CoreSystem('ps', 'ps1',
      biosFiles: 1, biosRequired: true, disc: 'ps', extensions: ['exe']);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 3;
  @override
  int get discPriority => 20;
  @override
  int get legacyPriority => 0;
  @override
  String? legacyStorageKey(String key) => key == 'psx_mem1'
      ? StorageKey.of('ps', StorageKey.sram, 'memcard1')
      : null;
  @override
  Core create(String id) => Ps();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
  @override
  MediaHint mediaHint(String name) => switch (mediaExtension(name)) {
        'cue' || 'iso' => MediaHint.disc,
        'bin' => MediaHint.ambiguous,
        _ => MediaHint.unknown,
      };
  @override
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async {
    final start = firstDataLba(drive);
    if (start == null) return null;
    return sectorContains(await readDiscSector(drive, start + 4),
                'Sony Computer Entertainment') ||
            sectorContains(
                await readDiscSector(drive, start + 16), 'PLAYSTATION')
        ? system
        : null;
  }
}
