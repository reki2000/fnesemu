import 'dart:typed_data';

import 'cdrom_drive.dart';
import 'core_debug.dart';
import 'pad_button.dart';
import 'sram.dart';
import 'types.dart';
import 'video_debug.dart';

/// Base contract for emulator cores. Optional features default to no output.
/// Timing, execution and ROM/reset operations must be implemented by a core.
/// A plain [Core] represents the unloaded state for the controller and GUI.
class Core extends CoreDebug {
  @override
  List<DebugVideoLayer> get videoLayers => [
        DebugVideoLayer('Framebuffer', (_) => DebugRaster.copy(imageBuffer()),
            kind: DebugLayerKind.framebuffer),
      ];

  int get systemClockHz => throw UnimplementedError('Core.systemClockHz');

  int get scanlinesInFrame => throw UnimplementedError('Core.scanlinesInFrame');
  int get clocksInScanline => throw UnimplementedError('Core.clocksInScanline');

  /// exec 1 cpu instruction and render image/audio if it passed enough cycles
  /// returns current elapsed CPU cycles(clocks) and bool - false when unimplemented instruction is found
  ExecResult exec(bool step) => throw UnimplementedError('Core.exec');

  /// Executes until [scanlines] scanlines have been rendered, or execution
  /// stops. The returned clocks and flags belong to the last instruction.
  /// Used during normal execution; cores may override with a faster loop.
  /// A nonpositive count executes nothing and returns zero elapsed clocks.
  ExecResult runFrame(int scanlines) {
    var result = ExecResult(0, false, false);
    while (scanlines > 0) {
      result = exec(false);
      if (result.stopped) return result;
      if (result.scanlineRendered) scanlines--;
    }
    return result;
  }

  /// returns screen image buffer
  ImageBuffer imageBuffer() => ImageBuffer.empty();

  // receives callback to push rendered audio buffer
  void onAudio(void Function(AudioBuffer) onAudio) {}

  /// connects the CD-ROM drive. cores without a CD-ROM ignore it
  void setCdromDrive(CdromDrive drive) {}

  /// sets the BIOS (system ROM) images supplied by the user. called before
  /// [setRom], or instead of it to boot the BIOS without a cartridge.
  /// cores without a BIOS ignore it
  void setBiosFiles(List<Uint8List> files) {}

  /// set sram storage interface
  void setSram(Sram sram) {}

  /// releases what the core holds outside the Dart heap; the core is not
  /// used afterwards
  void dispose() {}

  /// Saves the logical emulation state at a frame boundary, for restoring
  /// into a new instance of the same core with the same media. Cores
  /// without state support throw [UnsupportedError].
  Uint8List saveState() => throw UnsupportedError('Core.saveState');

  /// Restores a state from [saveState]; throws a StateMismatch for another
  /// core, media or format version. Callbacks, media and configuration of
  /// this instance are kept.
  void loadState(Uint8List state) =>
      throw UnsupportedError('Core.loadState');

  /// handles reset button events
  void reset() => throw UnimplementedError('Core.reset');

  /// handles pad down/up events
  void padDown(int controllerId, PadButton k) {}
  void padUp(int controllerId, PadButton k) {}

  /// returns list of buttons
  List<PadButton> get buttons => const [];

  // loads an rom file.
  // throws exception if the mapper type of the rom file is not supported.
  void setRom(Uint8List body) => throw UnimplementedError('Core.setRom');
}

/// Keys of the persistent storage are `<core>/<kind>/<name>`, except for the
/// settings which do not belong to a core: `settings/<name>`.
///
/// kinds:
///   sram   - battery backup RAM, memory cards
///   bios   - system ROM images supplied by the user
///   keymap - key assignments
///   settings - application settings stored as UTF-8 text (no core)
class StorageKey {
  static const sram = "sram";
  static const bios = "bios";
  static const keymap = "keymap";
  static const settings = "settings";

  static String of(String core, String kind, String name) =>
      "$core/$kind/$name";

  static String setting(String name) => "$settings/$name";

  static String kindOf(String key) {
    if (key.startsWith("$settings/")) return settings;
    final parts = key.split("/");
    return parts.length >= 3 ? parts[1] : "";
  }
}
