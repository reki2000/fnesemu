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
