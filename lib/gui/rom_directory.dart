/// A ROM directory: its stable identity and platform permission/restore
/// token.
class RomDirectory {
  final String id, name;
  final String? restoreKey;

  /// the full path shown in the menu, [name] if unknown
  final String path;

  const RomDirectory(this.id, this.name, this.restoreKey, {String? path})
      : path = path ?? name;

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'restoreKey': restoreKey, 'path': path};

  factory RomDirectory.fromJson(Map<String, dynamic> json) => RomDirectory(
      json['id'] as String,
      json['name'] as String,
      json['restoreKey'] as String?,
      path: json['path'] as String?);
}
