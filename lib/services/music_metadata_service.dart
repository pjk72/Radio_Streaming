import 'dart:convert';
import 'package:flutter/foundation.dart';
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

class ArtistSearchResult {
  final String id;
  final String name;
  final String genre;
  final String? imageUrl;
  final String? url;

  ArtistSearchResult({
    required this.id,
    required this.name,
    required this.genre,
    this.imageUrl,
    this.url,
  });
}

class AlbumSearchResult {
  final String id;
  final String albumName;
  final String artistName;
  final String? artworkUrl;
  final String? releaseDate;
  final int? trackCount;

  AlbumSearchResult({
    required this.id,
    required this.albumName,
    required this.artistName,
    this.artworkUrl,
    this.releaseDate,
    this.trackCount,
  });
}

class MusicMetadataService {
  static const String _baseUrl = 'https://itunes.apple.com/search';

  static String _normalize(String s) {
    const from =
        'àáâäãåèéêëìíîïòóôöõùúûüçñÀÁÂÄÃÅÈÉÊËÌÍÎÏÒÓÔÖÕÙÚÛÜÇÑ';
    const to =
        'aaaaaaeeeeiiiiooooouuuucnAAAAAAEEEEIIIIOOOOOUUUUCN';
    var out = s.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      out = out.replaceAll(from[i], to[i]);
    }
    return out;
  }

  List<String> _queryTokens(String query) => _normalize(query)
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toList();

  bool _matchesAllTokens(String text, List<String> tokens) {
    if (tokens.isEmpty) return true;
    final t = _normalize(text);
    return tokens.every(t.contains);
  }

  static String _normalizeBaseName(String name) {
    final withoutParens = _normalize(name).replaceAll(RegExp(r'\([^)]*\)'), '');
    return withoutParens.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _normalizeArtworkPath(String url) {
    var s = url.trim().toLowerCase();
    s = s.replaceAll(RegExp(r'/\d+x\d+[-0-9a-z]*\.jpg$'), '');
    return s;
  }

  List<ArtistSearchResult> _dedupArtists(List<ArtistSearchResult> artists) {
    final seen = <String>{};
    return artists.where((a) {
      final key = '${_normalize(a.name)}|${(a.imageUrl ?? '').toLowerCase()}';
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();
  }

  List<AlbumSearchResult> _dedupAlbums(List<AlbumSearchResult> albums) {
    final seen = <String>{};
    return albums.where((a) {
      final key = '${_normalizeBaseName(a.albumName)}|'
          '${_normalizeArtworkPath(a.artworkUrl ?? '')}';
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();
  }

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
      debugPrint('iTunes Request Headers:');
      headers.forEach((k, v) => debugPrint('$k: $v'));

      final response = await http.get(
        url,
        headers: headers,
      )
      .timeout(const Duration(seconds: 10));
      debugPrint('url: $url');
      debugPrint('headers: $headers');
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
        debugPrint('Music Search Status Error: ${response.statusCode}');
        return await _searchDeezerFallback(query, limit, countryCode);
      }
    } catch (e) {
      debugPrint('Music Search Error: $e');
      return await _searchDeezerFallback(query, limit, countryCode);
    }
  }

  Future<List<ArtistSearchResult>> searchArtists({
    required String query,
    int limit = 10,
    String? countryCode,
  }) async {
    final term = Uri.encodeQueryComponent(query);
    String urlString =
        '$_baseUrl?term=$term&media=music&entity=musicArtist&attribute=artistTerm&limit=$limit';

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
      final response = await http.get(url, headers: headers)
          .timeout(const Duration(seconds: 10));
      debugPrint('iTunes Artist Search URL: $url');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List<dynamic>? ?? [];

        if (results.isEmpty) {
          return await _searchDeezerArtistsFallback(query, limit);
        }

        final tokens = _queryTokens(query);
        final artists = results.map<ArtistSearchResult>((item) {
          return ArtistSearchResult(
            id: item['artistId']?.toString() ??
                DateTime.now().millisecondsSinceEpoch.toString(),
            name: item['artistName'] ?? 'Unknown Artist',
            genre: item['primaryGenreName'] ?? '',
            url: item['artistLinkUrl'],
          );
        }).toList();
        return _dedupArtists(
          artists
              .where((a) => _matchesAllTokens(a.name, tokens))
              .toList(),
        );
      } else {
        debugPrint('Artist Search Status Error: ${response.statusCode}');
        return await _searchDeezerArtistsFallback(query, limit);
      }
    } catch (e) {
      debugPrint('Artist Search Error: $e');
      return await _searchDeezerArtistsFallback(query, limit);
    }
  }

  Future<List<ArtistSearchResult>> _searchDeezerArtistsFallback(
    String query,
    int limit,
  ) async {
    try {
      final term = Uri.encodeQueryComponent(query);
      final urlString =
          'https://api.deezer.com/search/artist?q=$term&limit=$limit';
      final url = Uri.parse(urlString);

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['data'] as List<dynamic>? ?? [];

        final tokens = _queryTokens(query);
        return _dedupArtists(
          results
              .map<ArtistSearchResult>((item) {
                return ArtistSearchResult(
                  id: item['id']?.toString() ?? '',
                  name: item['name'] ?? 'Unknown Artist',
                  genre: '',
                  imageUrl: item['picture_xl'] ?? item['picture_big'] ?? '',
                  url: item['link'],
                );
              })
              .toList()
              .where((a) => _matchesAllTokens(a.name, tokens))
              .toList(),
        );
      }
    } catch (e) {
      debugPrint('Deezer Artist Search Error: $e');
    }
    return [];
  }

  Future<List<AlbumSearchResult>> searchAlbums({
    required String query,
    int limit = 10,
    String? countryCode,
  }) async {
    final term = Uri.encodeQueryComponent(query);
String urlString =
        '$_baseUrl?term=$term&media=music&entity=album&attribute=albumTerm&limit=$limit';

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
      final response = await http.get(url, headers: headers)
          .timeout(const Duration(seconds: 10));
      debugPrint('iTunes Album Search URL: $url');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List<dynamic>? ?? [];

        if (results.isEmpty) {
          return await _searchDeezerAlbumsFallback(query, limit);
        }

        final tokens = _queryTokens(query);
        final albums = results.map<AlbumSearchResult>((item) {
          String artworkUrl = item['artworkUrl100'] ?? '';
          if (artworkUrl.isNotEmpty) {
            artworkUrl = artworkUrl.replaceAll('100x100', '600x600');
          }

          return AlbumSearchResult(
            id: item['collectionId']?.toString() ??
                DateTime.now().millisecondsSinceEpoch.toString(),
            albumName: item['collectionName'] ?? 'Unknown Album',
            artistName: item['artistName'] ?? 'Unknown Artist',
            artworkUrl: artworkUrl,
            releaseDate: item['releaseDate'],
            trackCount: item['trackCount'] as int?,
          );
        }).toList();
        return _dedupAlbums(
          albums
              .where(
                (a) =>
                    _matchesAllTokens(a.albumName, tokens) ||
                    _matchesAllTokens(a.artistName, tokens),
              )
              .toList(),
        );
      } else {
        debugPrint('Album Search Status Error: ${response.statusCode}');
        return await _searchDeezerAlbumsFallback(query, limit);
      }
    } catch (e) {
      debugPrint('Album Search Error: $e');
      return await _searchDeezerAlbumsFallback(query, limit);
    }
  }

  Future<List<AlbumSearchResult>> _searchDeezerAlbumsFallback(
    String query,
    int limit,
  ) async {
    try {
      final term = Uri.encodeQueryComponent(query);
      final urlString = 'https://api.deezer.com/search/album?q=$term&limit=$limit';
      final url = Uri.parse(urlString);

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['data'] as List<dynamic>? ?? [];

        final tokens = _queryTokens(query);
        return _dedupAlbums(
          results
              .map<AlbumSearchResult>((item) {
                return AlbumSearchResult(
                  id: item['id']?.toString() ?? '',
                  albumName: item['title'] ?? 'Unknown Album',
                  artistName: item['artist']?['name'] ?? 'Unknown Artist',
                  artworkUrl: item['cover_xl'] ?? item['cover_big'] ?? '',
                  releaseDate: item['release_date'],
                  trackCount: item['nb_tracks'] as int?,
                );
              })
              .toList()
              .where(
                (a) =>
                    _matchesAllTokens(a.albumName, tokens) ||
                    _matchesAllTokens(a.artistName, tokens),
              )
              .toList(),
        );
      }
    } catch (e) {
      debugPrint('Deezer Album Search Error: $e');
    }
    return [];
  }

  Future<List<SongSearchResult>> _searchDeezerFallback(String query, int limit, String? countryCode) async {
    try {
      debugPrint('Falling back to Deezer API for query: $query');
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
      debugPrint('Deezer Fallback Error: $e');
    }
    return [];
  }
}
