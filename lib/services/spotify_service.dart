import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_song.dart';
import 'log_service.dart';

class SpotifyService {
  static const String _clientId = "596732e2f8c542cea5cbac1f4e3a6b5b";
  static const String _clientSecret = "b3ab74b0037b4361842531dc80282d48";
  //static const String _redirectUri = "http://127.0.0.1:8888/callback";
  static const String _redirectUri = 'musicstream://callback';
  String get redirectUri => _redirectUri;

  static const String _keyAccessToken = 'spotify_access_token_v2';
  static const String _keyRefreshToken = 'spotify_refresh_token_v2';
  static const String _keyExpiresAt = 'spotify_expires_at_v2';

  int _lastTotal = 0;
  int get lastTotal => _lastTotal;

  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_keyAccessToken);
    _refreshToken = prefs.getString(_keyRefreshToken);
    final expiresStr = prefs.getString(_keyExpiresAt);
    if (expiresStr != null) {
      _expiresAt = DateTime.parse(expiresStr);
    }
  }

  bool get isLoggedIn =>
      _accessToken != null &&
      (_expiresAt == null || _expiresAt!.isAfter(DateTime.now()));

  String getLoginUrl() {
    // aligning scopes with Exportify to ensure identical access levels
    final scope = Uri.encodeComponent(
      "playlist-read-private playlist-read-collaborative user-library-read",
    );
    return "https://accounts.spotify.com/authorize?show_dialog=true&response_type=code&client_id=$_clientId&redirect_uri=${Uri.encodeComponent(_redirectUri)}&scope=$scope";
  }

  Future<bool> handleAuthCode(String code) async {
    final response = await http.post(
      Uri.parse("https://accounts.spotify.com/api/token"),
      headers: {
        'Authorization':
            'Basic ${base64Encode(utf8.encode("$_clientId:$_clientSecret"))}',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': _redirectUri,
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      await _saveTokens(data);
      return true;
    }
    return false;
  }

  Future<void> _saveTokens(Map<String, dynamic> data) async {
    _accessToken = data['access_token'];
    if (data.containsKey('refresh_token')) {
      _refreshToken = data['refresh_token'];
    }
    final int expiresIn = data['expires_in'];
    _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAccessToken, _accessToken!);
    if (_refreshToken != null) {
      await prefs.setString(_keyRefreshToken, _refreshToken!);
    }
    await prefs.setString(_keyExpiresAt, _expiresAt!.toIso8601String());
  }

  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyRefreshToken);
    await prefs.remove(_keyExpiresAt);
  }

  Future<List<Map<String, dynamic>>> getUserPlaylists() async {
    if (!isLoggedIn && _refreshToken != null) {
      await _refreshAccessToken();
    }
    if (!isLoggedIn) return [];

    final List<Map<String, dynamic>> allPlaylists = [];
    const int limit = 50;
    String baseUrl = "https://api.spotify.com/v1/me/playlists";

    LogService().log(
      "SpotifyService: Fetching playlists (strategy: parallel by offset)...",
    );

    try {
      // 1. Fetch first page to get 'total'
      final firstPageUrl = "$baseUrl?limit=$limit&offset=0";
      final firstResp = await http.get(
        Uri.parse(firstPageUrl),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (firstResp.statusCode == 200) {
        final data = jsonDecode(firstResp.body);
        final int total = data['total'] ?? 0;
        final List<dynamic>? items = data['items'];

        LogService().log("SpotifyService: Total playlists available: $total");

        if (items != null) {
          // Debug Log: Print all names found in raw JSON
          try {
            final names = items
                .map((i) => i != null ? i['name'].toString() : 'null')
                .toList();
            LogService().log("SpotifyService: Raw items in first page: $names");
          } catch (e) {
            LogService().log("SpotifyService: Could not list raw names: $e");
          }

          _processPlaylistItems(items, allPlaylists);
        }

        // 2. Fetch remaining pages in parallel if needed
        if (total > limit) {
          List<Future<void>> requests = [];

          for (int offset = limit; offset < total; offset += limit) {
            // Stagger requests slightly to avoid immediate 429s (similar to JS logic)
            final delayMs = (offset ~/ limit) * 100;

            requests.add(
              Future.delayed(Duration(milliseconds: delayMs), () async {
                try {
                  final url = "$baseUrl?limit=$limit&offset=$offset";
                  final resp = await http.get(
                    Uri.parse(url),
                    headers: {'Authorization': 'Bearer $_accessToken'},
                  );

                  if (resp.statusCode == 200) {
                    final pageData = jsonDecode(resp.body);
                    final List<dynamic>? pageItems = pageData['items'];
                    if (pageItems != null) {
                      _processPlaylistItems(pageItems, allPlaylists);
                    }
                  } else {
                    LogService().log(
                      "SpotifyService: Failed to fetch offset $offset: ${resp.statusCode}",
                    );
                  }
                } catch (e) {
                  LogService().log(
                    "SpotifyService: Error fetching offset $offset: $e",
                  );
                }
              }),
            );
          }

          await Future.wait(requests);
        }
      } else {
        LogService().log(
          "SpotifyService: Error fetching first page: ${firstResp.statusCode}",
        );
      }
    } catch (e) {
      LogService().log("SpotifyService: Exception fetching playlists: $e");
    }

    // Add "Liked Songs" as a virtual playlist
    allPlaylists.insert(0, {
      'name': 'Liked Songs',
      'id': 'liked_songs',
      'tracks': {'total': '?'},
      'images': [
        {'url': 'https://misc.scdn.co/liked-songs/liked-songs-640.png'},
      ],
      'owner': {'display_name': 'You'},
    });

    // Deduplicate just in case parallel requests messed something up (unlikely with distinct offsets but safe)
    final uniquePlaylists = {
      for (var p in allPlaylists) p['id']: p,
    }.values.toList();

    LogService().log(
      "SpotifyService: Final resolved playlists count: ${uniquePlaylists.length}",
    );
    return uniquePlaylists;
  }

  void _processPlaylistItems(
    List<dynamic> items,
    List<Map<String, dynamic>> targetList,
  ) {
    for (var item in items) {
      if (item != null) {
        try {
          final mapItem = Map<String, dynamic>.from(item);
          // Ensure basic fields for UI safety
          mapItem.putIfAbsent('tracks', () => {'total': 0});
          mapItem.putIfAbsent('owner', () => {'display_name': 'Unknown'});
          mapItem.putIfAbsent('images', () => []);

          // Use a thread-safe way to add if this wasn't single-threaded event loop,
          // but in Dart event loop, adding to list is safe from async callbacks.
          targetList.add(mapItem);

          LogService().log("SpotifyService: Found '${mapItem['name']}'");
        } catch (e) {
          // ignore bad items
        }
      }
    }
  }

  Future<List<SavedSong>> getPlaylistTracks(
    String playlistId, {
    int? total,
    Function(double)? onProgress,
  }) async {
    if (!isLoggedIn && _refreshToken != null) {
      await _refreshAccessToken();
    }
    if (!isLoggedIn) return [];

    List<SavedSong> allTracks = [];
    final String baseUrl = playlistId == 'liked_songs'
        ? "https://api.spotify.com/v1/me/tracks"
        : "https://api.spotify.com/v1/playlists/$playlistId/tracks";

    LogService().log(
      "SpotifyService: Starting fetch for $playlistId (Total: $total)",
    );

    // Define the mapper to convert Spotify JSON to SavedSong
    SavedSong? mapItem(dynamic item) {
      final track = item['track'];
      if (track == null) return null;
      final album = track['album'];
      final artists = track['artists'] as List;
      final String artistNames = artists.map((a) => a['name']).join(', ');
      String? artUri;
      if (album != null &&
          album['images'] != null &&
          (album['images'] as List).isNotEmpty) {
        artUri = album['images'][0]['url'];
      }
      return SavedSong(
        id: track['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        title: track['name'] ?? "Unknown Title",
        artist: artistNames,
        album: album != null ? album['name'] : "Unknown Album",
        artUri: artUri,
        spotifyUrl: track['external_urls'] != null
            ? track['external_urls']['spotify']
            : null,
        dateAdded: DateTime.now(),
      );
    }

    if (total != null && total > 0) {
      final int limit = 50;
      int completedPages = 0;
      final int totalPages = (total / limit).ceil();

      if (total > 50) {
        // Parallel fetch strategy
        final List<Future<http.Response>> requests = [];
        for (int offset = 0; offset < total; offset += limit) {
          final request = http
              .get(
                Uri.parse("$baseUrl?limit=$limit&offset=$offset"),
                headers: {'Authorization': 'Bearer $_accessToken'},
              )
              .timeout(const Duration(seconds: 15));

          // Monitor each request for progress
          requests.add(
            request.then((response) {
              if (response.statusCode == 200) {
                final data = jsonDecode(response.body);
                final List<dynamic> items = data['items'];
                allTracks.addAll(items.map(mapItem).whereType<SavedSong>());
              }
              completedPages++;
              onProgress?.call(completedPages / totalPages);
              return response;
            }),
          );
        }
        await Future.wait(requests);
      } else {
        // Sequential/Single page fetch
        final response = await http
            .get(
              Uri.parse("$baseUrl?limit=$limit&offset=0"),
              headers: {'Authorization': 'Bearer $_accessToken'},
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final List<dynamic> items = data['items'];
          allTracks.addAll(items.map(mapItem).whereType<SavedSong>());
        }
        onProgress?.call(1.0);
      }
    } else {
      // Sequential/Paginated fetch (fallback or small playlists)
      String? nextUrl = "$baseUrl?limit=50";
      int pages = 0;
      while (nextUrl != null && pages < 20) {
        // Safety limit: 1000 tracks
        final response = await http
            .get(
              Uri.parse(nextUrl),
              headers: {'Authorization': 'Bearer $_accessToken'},
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final List<dynamic> items = data['items'];
          allTracks.addAll(items.map(mapItem).whereType<SavedSong>());
          nextUrl = data['next'];
          pages++;
          onProgress?.call(pages / 20.0); // Rough estimate
        } else {
          break;
        }
      }
      onProgress?.call(1.0);
    }

    LogService().log(
      "SpotifyService: Finished fetch. Total tracks: ${allTracks.length}",
    );
    return allTracks;
  }

  Future<void> _refreshAccessToken() async {
    if (_refreshToken == null) return;

    final response = await http.post(
      Uri.parse("https://accounts.spotify.com/api/token"),
      headers: {
        'Authorization':
            'Basic ${base64Encode(utf8.encode("$_clientId:$_clientSecret"))}',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'grant_type': 'refresh_token', 'refresh_token': _refreshToken},
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      await _saveTokens(data);
    }
  }

  Future<String?> getArtistImage(String spotifyId) async {
    if (!isLoggedIn && _refreshToken != null) {
      await _refreshAccessToken();
    }
    if (!isLoggedIn) return null;

    try {
      // 1. Get Track (to get Artist ID) - Wait, we might be passed a Track ID or Artist ID?
      // The parameter calls it spotifyId. If it's a Track ID, we need to look up track -> artist -> image.
      // If it's an Artist ID, we look up artist -> image.
      // Usage in RadioProvider implies we are extracting it from a Track URL.

      // So first, fetch Track to get Artist ID
      final trackResp = await http.get(
        Uri.parse("https://api.spotify.com/v1/tracks/$spotifyId"),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (trackResp.statusCode == 200) {
        final trackData = jsonDecode(trackResp.body);
        final artists = trackData['artists'] as List;
        if (artists.isNotEmpty) {
          final artistId = artists[0]['id'];

          // 2. Fetch Artist to get Image
          final artistResp = await http.get(
            Uri.parse("https://api.spotify.com/v1/artists/$artistId"),
            headers: {'Authorization': 'Bearer $_accessToken'},
          );

          if (artistResp.statusCode == 200) {
            final artistData = jsonDecode(artistResp.body);
            final images = artistData['images'] as List;
            if (images.isNotEmpty) {
              return images[0]['url'];
            }
          }
        }
      }
    } catch (e) {
      LogService().log("SpotifyService: Error fetching artist image: $e");
    }
    return null;
  }
}
