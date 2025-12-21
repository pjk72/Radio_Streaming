import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/saved_song.dart';

class SongSearchResult {
  final SavedSong song;
  final String genre;

  SongSearchResult({required this.song, required this.genre});
}

class MusicMetadataService {
  static const String _baseUrl = 'https://itunes.apple.com/search';

  Future<List<SongSearchResult>> searchSongs({
    required String query,
    int limit = 10,
  }) async {
    // Basic cleaning of query
    final term = Uri.encodeComponent(query);
    final url = Uri.parse(
      '$_baseUrl?term=$term&media=music&entity=song&limit=$limit',
    );

    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List<dynamic>;

        return results.map<SongSearchResult>((item) {
          // Extract higher resolution image if possible (600x600)
          String artworkUrl = item['artworkUrl100'] ?? '';
          if (artworkUrl.isNotEmpty) {
            artworkUrl = artworkUrl.replaceAll('100x100', '600x600');
          }

          // Handle Date
          // iTunes date format: "2005-03-01T08:00:00Z"
          String releaseDate = item['releaseDate'] ?? '';

          final song = SavedSong(
            id: item['trackId'].toString(),
            title: item['trackName'] ?? 'Unknown Title',
            artist: item['artistName'] ?? 'Unknown Artist',
            album: item['collectionName'] ?? 'Unknown Album',
            artUri: artworkUrl,
            spotifyUrl: null, // iTunes doesn't give Spotify links obviously
            appleMusicUrl: item['trackViewUrl'],
            youtubeUrl: null,
            dateAdded:
                DateTime.now(), // This is "now" because we are creating the object now
            releaseDate: releaseDate,
          );

          return SongSearchResult(
            song: song,
            genre: item['primaryGenreName'] ?? 'Pop',
          );
        }).toList();
      } else {
        throw Exception('Failed to search music: ${response.statusCode}');
      }
    } catch (e) {
      print('Music Search Error: $e');
      return [];
    }
  }
}
