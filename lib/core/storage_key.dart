/// Keys of the persistent storage are `<core>/<kind>/<name>`.
///
/// kinds:
///   sram   - battery backup RAM, memory cards
///   bios   - system ROM images supplied by the user
///   keymap - key assignments
class StorageKey {
  static const sram = "sram";
  static const bios = "bios";
  static const keymap = "keymap";

  static String of(String core, String kind, String name) =>
      "$core/$kind/$name";

  static String kindOf(String key) {
    final parts = key.split("/");
    return parts.length >= 3 ? parts[1] : "";
  }
}
