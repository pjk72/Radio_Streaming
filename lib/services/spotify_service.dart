import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_song.dart';
import '../models/playlist.dart';
import 'log_service.dart';

class SpotifyService {
  static const String _clientId = "596732e2f8c542cea5cbac1f4e3a6b5b";
  static const String _clientSecret = "b3ab74b0037b4361842531dc80282d48";
  static const String _redirectUri = "http://127.0.0.1:8888/callback";
  String get redirectUri => _redirectUri;

  static const String _keyAccessToken = 'spotify_access_token';
  static const String _keyRefreshToken = 'spotify_refresh_token';
  static const String _keyExpiresAt = 'spotify_expires_at';

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
    final scope = Uri.encodeComponent(
      "playlist-read-private playlist-read-collaborative user-library-read",
    );
    return "https://accounts.spotify.com/authorize?response_type=code&client_id=$_clientId&redirect_uri=${Uri.encodeComponent(_redirectUri)}&scope=$scope";
  }

  Future<bool> handleAuthCode(String code) async {
    final response = await http.post(
      Uri.parse("https://accounts.spotify.com/api/token"),
      headers: {
        'Authorization':
            'Basic ' + base64Encode(utf8.encode("$_clientId:$_clientSecret")),
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

    List<Map<String, dynamic>> allPlaylists = [];
    String? nextUrl = "https://api.spotify.com/v1/me/playlists?limit=50";

    while (nextUrl != null) {
      final response = await http.get(
        Uri.parse(nextUrl),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        allPlaylists.addAll(List<Map<String, dynamic>>.from(data['items']));
        nextUrl = data['next'];
      } else {
        break;
      }
    }

    // Add "Liked Songs" as a virtual playlist
    allPlaylists.insert(0, {
      'name': 'Liked Songs',
      'id': 'liked_songs',
      'tracks': {'total': '?'},
      'images': [
        {'url': 'https://misc.scdn.co/liked-songs/liked-songs-640.png'},
      ],
    });

    return allPlaylists;
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
            'Basic ' + base64Encode(utf8.encode("$_clientId:$_clientSecret")),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'grant_type': 'refresh_token', 'refresh_token': _refreshToken},
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      await _saveTokens(data);
    }
  }
}
