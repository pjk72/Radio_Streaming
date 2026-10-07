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

  // Cache for Deezer track and album details to avoid repeated network requests
  final Map<dynamic, Map<String, dynamic>> _deezerTrackDetailsCache = {};
  final Map<dynamic, Map<String, dynamic>> _deezerAlbumDetailsCache = {};

  Future<Map<String, dynamic>?> _getDeezerTrackDetails(dynamic trackId) async {
    if (trackId == null) return null;
    if (_deezerTrackDetailsCache.containsKey(trackId)) {
      return _deezerTrackDetailsCache[trackId];
    }
    try {
      final url = Uri.parse('https://api.deezer.com/track/$trackId');
      final response = await http.get(url).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        if (data != null && !data.containsKey('error')) {
          _deezerTrackDetailsCache[trackId] = data;
          if (_deezerTrackDetailsCache.length > 200) {
            _deezerTrackDetailsCache.remove(_deezerTrackDetailsCache.keys.first);
          }
          return data;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> _getDeezerAlbumDetails(dynamic albumId) async {
    if (albumId == null) return null;
    if (_deezerAlbumDetailsCache.containsKey(albumId)) {
      return _deezerAlbumDetailsCache[albumId];
    }
    try {
      final url = Uri.parse('https://api.deezer.com/album/$albumId');
      final response = await http.get(url).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        if (data != null && !data.containsKey('error')) {
          _deezerAlbumDetailsCache[albumId] = data;
          if (_deezerAlbumDetailsCache.length > 200) {
            _deezerAlbumDetailsCache.remove(_deezerAlbumDetailsCache.keys.first);
          }
          return data;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Searches Deezer directly for a track by title and artist to find release date
  Future<String?> fetchDeezerReleaseDate(String title, String artist) async {
    try {
      final cleanQuery = "$title $artist".trim();
      final term = Uri.encodeQueryComponent(cleanQuery);
      final url = Uri.parse('https://api.deezer.com/search?q=$term&limit=1');
      final response = await http.get(url).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['data'] as List<dynamic>? ?? [];
        if (results.isNotEmpty) {
          final trackId = results.first['id'];
          if (trackId != null) {
            final trackDetails = await _getDeezerTrackDetails(trackId);
            if (trackDetails != null) {
              final rDate = trackDetails['release_date']?.toString();
              if (rDate != null && rDate.isNotEmpty && rDate != '0000-00-00') {
                return rDate;
              }
              final albumRDate = trackDetails['album']?['release_date']?.toString();
              if (albumRDate != null && albumRDate.isNotEmpty && albumRDate != '0000-00-00') {
                return albumRDate;
              }
            }
          }
          final albumId = results.first['album']?['id'];
          if (albumId != null) {
            final albumDetails = await _getDeezerAlbumDetails(albumId);
            if (albumDetails != null) {
              final albRDate = albumDetails['release_date']?.toString();
              if (albRDate != null && albRDate.isNotEmpty && albRDate != '0000-00-00') {
                return albRDate;
              }
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }


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

        final songFutures = results.take(limit).map<Future<SongSearchResult>>((item) async {
          String artworkUrl = item['artworkUrl100'] ?? '';
          if (artworkUrl.isNotEmpty) {
            artworkUrl = artworkUrl.replaceAll('100x100', '600x600');
          }

          String? releaseDate = item['releaseDate']?.toString();
          if (releaseDate != null && releaseDate.trim().isEmpty) {
            releaseDate = null;
          }

          final title = item['trackName'] ?? 'Unknown Title';
          final artist = item['artistName'] ?? 'Unknown Artist';

          // If iTunes didn't provide releaseDate, try Deezer lookup
          if (releaseDate == null || releaseDate.isEmpty) {
            releaseDate = await fetchDeezerReleaseDate(title, artist);
          }

          final int trackTimeMillis = item['trackTimeMillis'] as int? ?? 0;
          final duration = trackTimeMillis > 0 ? Duration(milliseconds: trackTimeMillis) : null;

          final song = SavedSong(
            id: item['trackId']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
            title: title,
            artist: artist,
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

        return await Future.wait(songFutures);
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

        final songFutures = results.take(limit).map<Future<SongSearchResult>>((item) async {
          final title = item['title'] ?? 'Unknown Title';
          final artist = item['artist']?['name'] ?? 'Unknown Artist';
          final album = item['album']?['title'] ?? 'Unknown Album';
          
          String artworkUrl = item['album']?['cover_xl'] ?? item['album']?['cover_large'] ?? '';

          int durationSec = item['duration'] as int? ?? 0;
          String? releaseDate;
          String genre = 'Pop';

          final trackId = item['id'];
          final albumId = item['album']?['id'];

          // 1. Fetch track details for release_date
          if (trackId != null) {
            final trackDetails = await _getDeezerTrackDetails(trackId);
            if (trackDetails != null) {
              final rDate = trackDetails['release_date']?.toString();
              if (rDate != null && rDate.isNotEmpty && rDate != '0000-00-00') {
                releaseDate = rDate;
              } else {
                final albumRDate = trackDetails['album']?['release_date']?.toString();
                if (albumRDate != null && albumRDate.isNotEmpty && albumRDate != '0000-00-00') {
                  releaseDate = albumRDate;
                }
              }
              final tDur = trackDetails['duration'] as int? ?? 0;
              if (tDur > 0) durationSec = tDur;
            }
          }

          // 2. Fetch album details for genre (and fallback release_date if still missing)
          if (albumId != null) {
            final albumDetails = await _getDeezerAlbumDetails(albumId);
            if (albumDetails != null) {
              if (releaseDate == null || releaseDate.isEmpty) {
                final albRDate = albumDetails['release_date']?.toString();
                if (albRDate != null && albRDate.isNotEmpty && albRDate != '0000-00-00') {
                  releaseDate = albRDate;
                }
              }
              final genresList = albumDetails['genres']?['data'] as List<dynamic>?;
              if (genresList != null && genresList.isNotEmpty) {
                final gName = genresList[0]['name']?.toString();
                if (gName != null && gName.isNotEmpty) {
                  genre = gName;
                }
              }
            }
          }

          final duration = durationSec > 0 ? Duration(seconds: durationSec) : null;

          final song = SavedSong(
            id: item['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
            title: title,
            artist: artist,
            album: album,
            artUri: artworkUrl,
            dateAdded: DateTime.now(),
            duration: duration,
            genre: genre,
            releaseDate: releaseDate,
            extras: item,
          );

          return SongSearchResult(
            song: song,
            genre: genre,
          );
        }).toList();

        return await Future.wait(songFutures);
      }
    } catch (e) {
      debugPrint('Deezer Fallback Error: $e');
    }
    return [];
  }
}
