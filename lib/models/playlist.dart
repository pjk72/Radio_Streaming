import 'saved_song.dart';

class Playlist {
  final String id;
  final String name;
  final List<SavedSong> songs;
  final DateTime createdAt;
  final String creator; // 'app', 'user', 'spotify', etc.

  Playlist({
    required this.id,
    required this.name,
    required this.songs,
    required this.createdAt,
    this.creator = 'app',
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'songs': songs.map((s) => s.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'creator': creator,
    };
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'],
      name: json['name'],
      songs: (json['songs'] as List<dynamic>)
          .map((s) => SavedSong.fromJson(s))
          .toList(),
      createdAt: DateTime.parse(json['createdAt']),
      creator: json['creator'] ?? 'app',
    );
  }
  Playlist copyWith({
    String? id,
    String? name,
    List<SavedSong>? songs,
    DateTime? createdAt,
    String? creator,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      songs: songs ?? this.songs,
      createdAt: createdAt ?? this.createdAt,
      creator: creator ?? this.creator,
    );
  }
}
