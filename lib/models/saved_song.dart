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
  final bool isValid;
  final Duration? duration;
  final String? localPath;
  final String? provider;
  final String? rawStreamUrl;

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
    this.isValid = true,
    this.duration,
    this.localPath,
    this.provider,
    this.rawStreamUrl,
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
      'isValid': isValid,
      'duration': duration?.inMilliseconds,
      'localPath': localPath,
      'provider': provider,
      'rawStreamUrl': rawStreamUrl,
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
      isValid: json['isValid'] ?? true,
      duration: json['duration'] != null
          ? Duration(milliseconds: json['duration'])
          : null,
      localPath: json['localPath'],
      provider: json['provider'],
      rawStreamUrl: json['rawStreamUrl'],
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
    bool? isValid,
    Duration? duration,
    String? localPath,
    String? provider,
    String? rawStreamUrl,
    bool forceClearLocalPath = false,
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
      isValid: isValid ?? this.isValid,
      duration: duration ?? this.duration,
      localPath: forceClearLocalPath ? null : (localPath ?? this.localPath),
      provider: provider ?? this.provider,
      rawStreamUrl: rawStreamUrl ?? this.rawStreamUrl,
    );
  }

  bool get isDownloaded {
    if (localPath == null || localPath!.isEmpty) return false;
    final path = localPath!.toLowerCase();
    return path.contains('_secure.') ||
        path.endsWith('.mst') ||
        path.contains('offline_music');
  }
}
