import 'dart:typed_data';
import '../core.dart';
import '../storage_key.dart';
import '../core_module.dart';
import 'nes.dart';

CoreModule createModule() => NesModule();

class NesModule extends CoreModule {
  static const cartridge = CoreSystem('nes', 'nes', extensions: ['nes']);
  static const disk = CoreSystem('fds', 'fds',
      extensions: ['fds'], biosFiles: 1, biosRequired: true);
  @override
  List<CoreSystem> get systems => [cartridge, disk];
  @override
  int get order => 0;
  @override
  int get legacyPriority => 1000;
  @override
  String? legacyStorageKey(String key) =>
      RegExp(r'^[0-9a-f]{8}$', caseSensitive: false).hasMatch(key)
          ? StorageKey.of(cartridge.id, StorageKey.sram, key)
          : null;
  @override
  Core create(String id) => Nes(diskSystem: id == disk.id);
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      switch (mediaExtension(name)) {
        'nes' => cartridge,
        'fds' => disk,
        _ => null,
      };
}
