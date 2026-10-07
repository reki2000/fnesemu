/// A directory's stable identity and platform permission/restore token.
class GameDirectory {
  final String id, name;
  final String? restoreKey;
  const GameDirectory(this.id, this.name, this.restoreKey);
  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'restoreKey': restoreKey};
  factory GameDirectory.fromJson(Map<String, dynamic> json) => GameDirectory(
      json['id'] as String,
      json['name'] as String,
      json['restoreKey'] as String?);
}
