class RecentGame {
  final String id, core, name;
  final String? folder;
  final int count, lastPlayed;
  final bool? disc;
  final String? path;
  const RecentGame(
      {required this.id,
      required this.core,
      required this.name,
      this.folder,
      this.disc,
      this.path,
      required this.count,
      required this.lastPlayed});
  bool get isDisc => disc ?? folder != null;
  String get sourcePath => path ?? name;
  String get blobKey => '$core/recent-rom/$id';
  Map<String, Object?> toJson() => {
        'id': id,
        'core': core,
        'name': name,
        'folder': folder,
        'disc': isDisc,
        'path': path,
        'count': count,
        'lastPlayed': lastPlayed
      };
  factory RecentGame.fromJson(Map<String, dynamic> json) => RecentGame(
      id: json['id'] as String,
      core: json['core'] as String,
      name: json['name'] as String,
      folder: json['folder'] as String?,
      disc: json['disc'] as bool?,
      path: json['path'] as String?,
      count: json['count'] as int,
      lastPlayed: json['lastPlayed'] as int);
}
