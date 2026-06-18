import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/saved_song.dart';
import 'dart:math';

final Random _random = Random();

String getRandomUserAgent() {
  final osOptions = [
    'Windows NT 10.0; Win64; x64',
    'Macintosh; Intel Mac OS X 10_15_7',
    'Macintosh; Intel Mac OS X 14_5',
    'X11; Linux x86_64',
    'X11; Ubuntu; Linux x86_64',
    'Linux; Android 14; SM-S918B',
    'Linux; Android 15; Pixel 9 Pro',
    'iPhone; CPU iPhone OS 17_4_1 like Mac OS X',
    'iPad; CPU OS 17_4_1 like Mac OS X',
  ];
  
  final browsers = [
    'Chrome/${_random.nextInt(20) + 110}.0.${_random.nextInt(9999)}.${_random.nextInt(150)}',
    'Firefox/${_random.nextInt(20) + 110}.0',
    'Safari/605.1.15',
    'Edge/${_random.nextInt(20) + 110}.0.${_random.nextInt(9999)}.${_random.nextInt(150)}',
  ];

  final os = osOptions[_random.nextInt(osOptions.length)];
  final browser = browsers[_random.nextInt(browsers.length)];

  if (browser.startsWith('Firefox')) {
    final version = browser.split('/')[1];
    return 'Mozilla/5.0 ($os; rv:$version) Gecko/20100101 $browser';
  } else if (browser.startsWith('Safari') && os.contains('Mac OS X')) {
    return 'Mozilla/5.0 ($os) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/${_random.nextInt(3) + 15}.0 Safari/605.1.15';
  } else {
    // Chrome or Edge (or Safari on non-mac, fallback to webkit structure)
    return 'Mozilla/5.0 ($os) AppleWebKit/537.36 (KHTML, like Gecko) $browser Safari/537.36';
  }
}

String getRandomLanguage() {
  const langs = [
    'it-IT,it;q=0.9',
    'en-US,en;q=0.9',
    'fr-FR,fr;q=0.9',
    'es-ES,es;q=0.9',
    'de-DE,de;q=0.9',
    'en-GB,en;q=0.9',
  ];

  return langs[_random.nextInt(langs.length)];
}


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
      final headers = {
        'User-Agent': getRandomUserAgent(),
        'Accept': 'application/json',
        'Accept-Language': getRandomLanguage(),
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      };
      print('iTunes Request Headers:');
      headers.forEach((k, v) => print('$k: $v'));

      final response = await http.get(
        url,
        headers: headers,
      )
      .timeout(const Duration(seconds: 10));
      print('url:' + url.toString());
      print('headers:' + headers.toString());
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List<dynamic>? ?? [];

        if (results.isEmpty) {
          return await _searchDeezerFallback(query, limit, countryCode);
        }

        return results.map<SongSearchResult>((item) {
          String artworkUrl = item['artworkUrl100'] ?? '';
          if (artworkUrl.isNotEmpty) {
            artworkUrl = artworkUrl.replaceAll('100x100', '600x600');
          }

          String releaseDate = item['releaseDate'] ?? '';

          final int trackTimeMillis = item['trackTimeMillis'] as int? ?? 0;
          final duration = trackTimeMillis > 0 ? Duration(milliseconds: trackTimeMillis) : null;

          final song = SavedSong(
            id: item['trackId']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
            title: item['trackName'] ?? 'Unknown Title',
            artist: item['artistName'] ?? 'Unknown Artist',
            album: item['collectionName'] ?? 'Unknown Album',
            artUri: artworkUrl,
            appleMusicUrl: item['trackViewUrl'],
            youtubeUrl: null,
            dateAdded: DateTime.now(),
            releaseDate: releaseDate,
            duration: duration,
            genre: item['primaryGenreName'] ?? 'Pop',
            extras: item,
          );

          return SongSearchResult(
            song: song,
            genre: item['primaryGenreName'] ?? 'Pop',
          );
        }).toList();
      } else {
        print('Music Search Status Error: ${response.statusCode}');
        return await _searchDeezerFallback(query, limit, countryCode);
      }
    } catch (e) {
      print('Music Search Error: $e');
      return await _searchDeezerFallback(query, limit, countryCode);
    }
  }

  Future<List<SongSearchResult>> _searchDeezerFallback(String query, int limit, String? countryCode) async {
    try {
      print('Falling back to Deezer API for query: $query');
      final term = Uri.encodeQueryComponent(query);
      final urlString = 'https://api.deezer.com/search?q=$term&limit=$limit';
      final url = Uri.parse(urlString);

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['data'] as List<dynamic>? ?? [];

        return results.map<SongSearchResult>((item) {
          final title = item['title'] ?? 'Unknown Title';
          final artist = item['artist']?['name'] ?? 'Unknown Artist';
          final album = item['album']?['title'] ?? 'Unknown Album';
          
          String artworkUrl = item['album']?['cover_xl'] ?? item['album']?['cover_large'] ?? '';

          final int durationSec = item['duration'] as int? ?? 0;
          final duration = durationSec > 0 ? Duration(seconds: durationSec) : null;

          final song = SavedSong(
            id: item['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
            title: title,
            artist: artist,
            album: album,
            artUri: artworkUrl,
            dateAdded: DateTime.now(),
            duration: duration,
            genre: 'Pop', // Deezer search doesn't return genre directly in this endpoint
          );

          return SongSearchResult(
            song: song,
            genre: 'Pop',
          );
        }).toList();
      }
    } catch (e) {
      print('Deezer Fallback Error: $e');
    }
    return [];
  }
}
