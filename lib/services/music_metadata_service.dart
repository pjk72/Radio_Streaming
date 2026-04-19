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
    String? countryCode,
  }) async {
    // Basic cleaning of query
    final term = Uri.encodeQueryComponent(query);
    String urlString =
        '$_baseUrl?term=$term&media=music&entity=song&limit=$limit';

    if (countryCode != null && countryCode.isNotEmpty) {
      urlString += '&country=${countryCode.toLowerCase()}';
    }

    final url = Uri.parse(urlString);

    try {
      final response = await http.get(
        url,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List<dynamic>? ?? [];

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
            id: item['trackId']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
            title: item['trackName'] ?? 'Unknown Title',
            artist: item['artistName'] ?? 'Unknown Artist',
            album: item['collectionName'] ?? 'Unknown Album',
            artUri: artworkUrl,
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
        print('Music Search Status Error: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Music Search Error: $e');
      return [];
    }
  }
}
