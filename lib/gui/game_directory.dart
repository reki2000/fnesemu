/// A directory's stable identity and platform permission/restore token.
class GameDirectory {
  final String id, name;
  final String? restoreKey;

  /// the full path shown in the menu, [name] if unknown
  final String path;

  const GameDirectory(this.id, this.name, this.restoreKey, {String? path})
      : path = path ?? name;

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'restoreKey': restoreKey, 'path': path};

  factory GameDirectory.fromJson(Map<String, dynamic> json) => GameDirectory(
      json['id'] as String,
      json['name'] as String,
      json['restoreKey'] as String?,
      path: json['path'] as String?);
}
