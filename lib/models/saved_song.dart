class SavedSong {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String? artUri;
  final String? spotifyUrl;
  final String? youtubeUrl;
  final String? appleMusicUrl;
  final DateTime dateAdded;
  final String? releaseDate;

  SavedSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.artUri,
    this.spotifyUrl,
    this.youtubeUrl,
    this.appleMusicUrl,
    required this.dateAdded,
    this.releaseDate,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'artUri': artUri,
      'spotifyUrl': spotifyUrl,
      'youtubeUrl': youtubeUrl,
      'appleMusicUrl': appleMusicUrl,
      'dateAdded': dateAdded.toIso8601String(),
      'releaseDate': releaseDate,
    };
  }

  factory SavedSong.fromJson(Map<String, dynamic> json) {
    return SavedSong(
      id: json['id'],
      title: json['title'],
      artist: json['artist'],
      album: json['album'],
      artUri: json['artUri'],
      spotifyUrl: json['spotifyUrl'],
      youtubeUrl: json['youtubeUrl'],
      appleMusicUrl: json['appleMusicUrl'],
      dateAdded: DateTime.parse(json['dateAdded']),
      releaseDate: json['releaseDate'],
    );
  }

  SavedSong copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? artUri,
    String? spotifyUrl,
    String? youtubeUrl,
    String? appleMusicUrl,
    DateTime? dateAdded,
    String? releaseDate,
  }) {
    return SavedSong(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      artUri: artUri ?? this.artUri,
      spotifyUrl: spotifyUrl ?? this.spotifyUrl,
      youtubeUrl: youtubeUrl ?? this.youtubeUrl,
      appleMusicUrl: appleMusicUrl ?? this.appleMusicUrl,
      dateAdded: dateAdded ?? this.dateAdded,
      releaseDate: releaseDate ?? this.releaseDate,
    );
  }
}
