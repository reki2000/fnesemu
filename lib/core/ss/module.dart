import 'dart:typed_data';
import '../core.dart';
import '../storage_key.dart';
import '../core_module.dart';
import '../cdrom_drive.dart';
import '../media_input.dart';
import 'ss.dart';

CoreModule createModule() => SsModule();

class SsModule extends CoreModule {
  static const system =
      CoreSystem('ss', 'ss', biosFiles: 1, biosRequired: true, disc: 'ss');
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 4;
  @override
  int get discPriority => 10;
  @override
  int get legacyPriority => 1;
  @override
  String? legacyStorageKey(String key) =>
      key == 'ss_bram' ? StorageKey.of('ss', StorageKey.sram, 'bram') : null;
  @override
  Core create(String id) => Ss();
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
    return sectorContains(await readDiscSector(drive, start), 'SEGA SEGASATURN')
        ? system
        : null;
  }
}
