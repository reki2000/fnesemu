class RecentGame {
  final String id, core, name;
  final String? folder;
  final int count, lastPlayed;
  const RecentGame(
      {required this.id,
      required this.core,
      required this.name,
      this.folder,
      required this.count,
      required this.lastPlayed});
  bool get isDisc => folder != null;
  String get blobKey => '$core/recent-rom/$id';
  Map<String, Object?> toJson() => {
        'id': id,
        'core': core,
        'name': name,
        'folder': folder,
        'count': count,
        'lastPlayed': lastPlayed
      };
  factory RecentGame.fromJson(Map<String, dynamic> json) => RecentGame(
      id: json['id'] as String,
      core: json['core'] as String,
      name: json['name'] as String,
      folder: json['folder'] as String?,
      count: json['count'] as int,
      lastPlayed: json['lastPlayed'] as int);
}
