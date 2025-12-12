import 'dart:async';
import 'package:audio_service/audio_service.dart';

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import '../models/station.dart';
import '../data/station_data.dart' as default_data;

import '../models/saved_song.dart';
import '../models/playlist.dart';
import '../services/playlist_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/radio_audio_handler.dart'; // Import for casting
import '../services/backup_service.dart';

// ...

class RadioProvider with ChangeNotifier {
  List<Station> stations = [];
  static const String _keySavedStations = 'saved_stations';

  Future<void> _loadStations() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonStr = prefs.getString(_keySavedStations);

    if (jsonStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        stations = decoded.map((e) => Station.fromJson(e)).toList();
        notifyListeners();
      } catch (e) {
        // Fallback if parse error
        stations = List.from(default_data.stations);
        _saveStations(); // Reset corrupt data
      }
    } else {
      // First run: use default
      stations = List.from(default_data.stations);
      _saveStations();
    }
    notifyListeners();
  }

  Future<void> _saveStations() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(stations.map((s) => s.toJson()).toList());
    await prefs.setString(_keySavedStations, encoded);
    notifyListeners();
  }

  Future<void> addStation(Station s) async {
    stations.add(s);
    await _saveStations();
  }

  Future<void> editStation(Station updated) async {
    final index = stations.indexWhere((s) => s.id == updated.id);
    if (index != -1) {
      stations[index] = updated;
      await _saveStations();

      // If currently playing this station, update current metadata if needed
      if (_currentStation?.id == updated.id) {
        _currentStation = updated;
        notifyListeners();
      }
    }
  }

  Future<void> deleteStation(int id) async {
    stations.removeWhere((s) => s.id == id);
    // Also remove from favorites and order
    if (_favorites.contains(id)) toggleFavorite(id);
    _stationOrder.remove(id);

    await _saveStations();
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
  }

  final AudioHandler _audioHandler;
  final PlaylistService _playlistService = PlaylistService();

  List<Playlist> _playlists = [];
  List<Playlist> get playlists => _playlists;

  // ... existing members

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  final BackupService _backupService;
  BackupService get backupService => _backupService;

  RadioProvider(this._audioHandler, this._backupService) {
    _backupService.addListener(notifyListeners);
    _checkAutoBackup(); // Start check
    // Listen to playback state from AudioService
    _audioHandler.playbackState.listen((state) {
      bool playing = state.playing;

      // Check for error message updates
      if (state.errorMessage != _errorMessage) {
        _errorMessage = state.errorMessage;
        notifyListeners();
      }

      if (_isPlaying != playing) {
        _isPlaying = playing; // Update local state

        // If we just started playing via toggle/external, schedule.
        // NOTE: playStation() handles its own scheduling to support station switching where playing state might not toggle.
        _metadataTimer?.cancel();
        if (_isPlaying) {
          _metadataTimer = Timer(
            const Duration(seconds: 5),
            _attemptRecognition,
          );
        }

        notifyListeners();
      }
    });

    // Listen to media item changes (if updated from outside or by handler, e.g. Android Auto)
    _audioHandler.mediaItem.listen((item) {
      if (item == null) return;

      // If the media item ID (URL) differs from current station, it means
      // Android Auto or another source changed the station.
      if (_currentStation?.url != item.id) {
        // Find the station by URL
        try {
          final newStation = stations.firstWhere((s) => s.url == item.id);

          // Update local state without triggering a play command (since it's already playing)
          _currentStation = newStation;
          _isLoading = false;

          // Reset metadata for the new station
          _currentTrack = "Live Broadcast";
          _currentArtist =
              ""; // Placeholder, actual values would come from item.extras or similar
          _currentAlbum = ""; // Placeholder
          _currentAlbumArt = null; // Placeholder
          _currentArtistImage = null; // Placeholder
          _currentSpotifyUrl = null; // Placeholder
          _currentYoutubeUrl = null; // Placeholder
          _currentReleaseDate = null; // Placeholder
          _currentGenre = null; // Placeholder

          _isRecognizing = false;

          _isRecognizing = false;

          notifyListeners();

          // Restart recognition for the new station
          _metadataTimer?.cancel();
          if (_isPlaying) {
            _metadataTimer = Timer(
              const Duration(seconds: 5),
              _attemptRecognition,
            );
          }
        } catch (_) {
          // Station not found in our list, ignore or handle custom
        }
      }
    });

    // Set initial volume if possible, or just default local
    setVolume(_volume);

    // Load persisted playlist
    _loadPlaylists();
    _loadStationOrder();
    _loadStations();

    // Connect AudioHandler callbacks
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.onSkipNext = playNextFavorite;
      _audioHandler.onSkipPrevious = playPreviousFavorite;
    }
  }

  // Import for casting
  // Note: Since RadioAudioHandler is imported via 'services/radio_audio_handler.dart' but access might be ambiguous if not imported.
  // RadioAudioHandler needs to be imported in RadioProvider file?
  // It is NOT currently imported in the view_file of RadioProvider.
  // I must add the import first!
  // I'll do it in a separate step if needed, but I can add it here if I replace top imports.
  // Let's assume I need to add import.

  List<Station> get _visualFavoriteOrder {
    if (_favorites.isEmpty) return [];

    // 1. Get Favorites (uses station order)
    final favs = allStations.where((s) => _favorites.contains(s.id)).toList();

    // 2. Group by Genre (matches HomeScreen)
    final Map<String, List<Station>> grouped = {};
    for (var s in favs) {
      if (!grouped.containsKey(s.genre)) grouped[s.genre] = [];
      grouped[s.genre]!.add(s);
    }

    // 3. Sort Genres (matches HomeScreen)
    final categories = grouped.keys.toList();
    categories.sort((a, b) {
      int indexA = genreOrder.indexOf(a);
      int indexB = genreOrder.indexOf(b);
      if (indexA == -1) indexA = 999;
      if (indexB == -1) indexB = 999;
      return indexA.compareTo(indexB);
    });

    // 4. Flatten
    return categories.expand((cat) => grouped[cat]!).toList();
  }

  void playNextFavorite() {
    // If no favorites, use all stations (custom order)
    final List<Station> list = _favorites.isEmpty
        ? allStations
        : _visualFavoriteOrder;

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int nextIndex = 0;
    if (currentIndex != -1) {
      nextIndex = (currentIndex + 1) % list.length;
    }

    playStation(list[nextIndex]);
  }

  void playPreviousFavorite() {
    final List<Station> list = _favorites.isEmpty
        ? allStations
        : _visualFavoriteOrder;

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int prevIndex = 0;
    if (currentIndex != -1) {
      prevIndex = (currentIndex - 1 + list.length) % list.length;
    } else {
      prevIndex = list.length - 1;
    }

    playStation(list[prevIndex]);
  }

  Future<void> _loadPlaylists() async {
    _playlists = await _playlistService.loadPlaylists();
    notifyListeners();
  }

  Future<void> createPlaylist(String name) async {
    await _playlistService.createPlaylist(name);
    await _loadPlaylists();
  }

  Future<void> deletePlaylist(String id) async {
    await _playlistService.deletePlaylist(id);
    await _loadPlaylists();
  }

  Future<String?> addToPlaylist(String? playlistId) async {
    if (_currentTrack == "Live Broadcast") return null;

    // Create Song Object
    final song = SavedSong(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: _currentTrack,
      artist: _currentArtist,
      album: _currentAlbum,
      artUri: _currentAlbumArt,
      spotifyUrl: _currentSpotifyUrl,
      youtubeUrl: _currentYoutubeUrl,
      appleMusicUrl:
          "https://music.apple.com/search?term=${Uri.encodeComponent("$_currentTrack $_currentArtist")}",
      dateAdded: DateTime.now(),
    );

    // 1. Exclusive Auto-Genre Logic
    // If adding to default (playlistId == null) AND genre is known...
    if (playlistId == null &&
        _currentGenre != null &&
        _currentGenre!.isNotEmpty) {
      final genreName = _currentGenre!;

      // Check if playlist exists
      String? existingPlaylistId;
      try {
        final genrePlaylist = _playlists.firstWhere(
          (p) => p.name.toLowerCase() == genreName.toLowerCase(),
        );
        existingPlaylistId = genrePlaylist.id;
      } catch (_) {
        existingPlaylistId = null;
      }

      if (existingPlaylistId == null) {
        // Create it
        final newPlaylist = await _playlistService.createPlaylist(genreName);
        existingPlaylistId = newPlaylist.id;
      }

      await _playlistService.addSongToPlaylist(existingPlaylistId, song);
      await _loadPlaylists();
      return genreName; // Added to Genre Playlist ONLY
    }

    // 2. Default Logic (Favorites or Explicit Playlist)
    final targetId =
        playlistId ?? (playlists.isNotEmpty ? playlists.first.id : null);
    if (targetId == null) return null;

    await _playlistService.addSongToPlaylist(targetId, song);
    await _loadPlaylists();

    // Find name
    final p = playlists.firstWhere(
      (p) => p.id == targetId,
      orElse: () => playlists.first,
    );
    return p.name;
  }

  Future<void> removeFromPlaylist(String playlistId, String songId) async {
    await _playlistService.removeSongFromPlaylist(playlistId, songId);
    await _loadPlaylists();

    if (playlistId == 'favorites') return;

    final p = _playlists.firstWhere(
      (element) => element.id == playlistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    if (p.id.isNotEmpty && p.songs.isEmpty) {
      await _playlistService.deletePlaylist(playlistId);
      await _loadPlaylists();
    }
  }

  Future<void> moveSong(
    String songId,
    String fromPayloadId,
    String toPayloadId,
  ) async {
    await _playlistService.moveSong(songId, fromPayloadId, toPayloadId);
    await _loadPlaylists();

    if (fromPayloadId == 'favorites') return;

    final p = _playlists.firstWhere(
      (element) => element.id == fromPayloadId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    if (p.id.isNotEmpty && p.songs.isEmpty) {
      await _playlistService.deletePlaylist(fromPayloadId);
      await _loadPlaylists();
    }
  }

  // ... rest of class
  // final AudioPlayer _audioPlayer = AudioPlayer(); // Removed

  Station? _currentStation;
  bool _isPlaying = false;
  double _volume = 0.8;
  final List<int> _favorites = [];
  String _currentTrack = "Live Broadcast";
  String _currentArtist = "Unknown Artist";
  String _currentAlbum = "";
  String? _currentAlbumArt;
  String? _currentArtistImage;
  String? _currentSpotifyUrl;
  String? _currentYoutubeUrl;
  String? _currentReleaseDate;
  String? _currentGenre;

  bool _isLoading = false;
  bool _isRecognizing = false;
  final List<String> _metadataLog = [];

  bool get isLoading => _isLoading;
  bool get isRecognizing => _isRecognizing;
  Timer? _metadataTimer;

  // ACRCloud Credentials
  final String _acrHost = "identify-eu-west-1.acrcloud.com";
  final String _acrAccessKey = "7009a942fd57981882bc0fb39f9e3ed5";
  final String _acrSecretKey = "DryrXroZvB6uLY8wAJ0jKAkgCiJD2hToDSk0Pdnx";

  Station? get currentStation => _currentStation;
  bool get isPlaying => _isPlaying;
  //   bool get isLoading => _isLoading; // duplicate removed
  double get volume => _volume;
  List<int> get favorites => _favorites;
  List<String> get metadataLog => _metadataLog;
  String _lastApiResponse = "No API response yet.";
  String get lastApiResponse => _lastApiResponse;

  // Return sorted stations if custom order exists, otherwise default list
  List<Station> get allStations {
    if (!_useCustomOrder || _stationOrder.isEmpty) return stations;

    // Create a map for fast lookup
    final Map<int, Station> stationMap = {for (var s in stations) s.id: s};
    final List<Station> sorted = [];

    // Add stations in order
    for (var id in _stationOrder) {
      if (stationMap.containsKey(id)) {
        sorted.add(stationMap[id]!);
        stationMap.remove(id);
      }
    }

    // Append any new/remaining stations that weren't in the saved order
    sorted.addAll(stationMap.values);

    return sorted;
  }

  String get currentTrack => _currentTrack;
  String get currentArtist => _currentArtist;
  String get currentAlbum => _currentAlbum;
  String? get currentAlbumArt => _currentAlbumArt;
  String? get currentArtistImage => _currentArtistImage;
  String? get currentSpotifyUrl => _currentSpotifyUrl;
  String? get currentYoutubeUrl => _currentYoutubeUrl;
  String? get currentReleaseDate => _currentReleaseDate;
  String? get currentGenre => _currentGenre;

  bool get isCurrentSongSaved {
    if (_currentTrack == "Live Broadcast" || _playlists.isEmpty) return false;

    for (var p in _playlists) {
      if (p.songs.any(
        (s) => s.title == _currentTrack && s.artist == _currentArtist,
      )) {
        return true;
      }
    }
    return false;
  }

  // Station Ordering
  List<int> _stationOrder = [];
  bool _useCustomOrder = false;
  bool get useCustomOrder => _useCustomOrder;

  static const String _keyFavorites = 'favorites';
  static const String _keyStationOrder = 'station_order';

  static const String _keyGenreOrder = 'genre_order';
  static const String _keyCategoryOrder = 'category_order'; // New
  static const String _keyUseCustomOrder = 'use_custom_order';

  List<String> _genreOrder = [];
  List<String> get genreOrder => _genreOrder;

  List<String> _categoryOrder = [];
  List<String> get categoryOrder => _categoryOrder;

  Future<void> _loadStationOrder() async {
    final prefs = await SharedPreferences.getInstance();

    _useCustomOrder = prefs.getBool(_keyUseCustomOrder) ?? false;

    final List<String>? orderStr = prefs.getStringList(_keyStationOrder);
    if (orderStr != null) {
      _stationOrder = orderStr
          .map((e) => int.tryParse(e) ?? -1)
          .where((e) => e != -1)
          .toList();
    }

    // Load Favorites
    final List<String>? favStr = prefs.getStringList(_keyFavorites);
    if (favStr != null) {
      _favorites.clear();
      _favorites.addAll(
        favStr.map((e) => int.tryParse(e) ?? -1).where((e) => e != -1),
      );
    }
    // Load Genre Order
    final List<String>? genreStr = prefs.getStringList(_keyGenreOrder);
    if (genreStr != null) {
      _genreOrder = genreStr;
    }

    // Load Category Order
    final List<String>? categoryStr = prefs.getStringList(_keyCategoryOrder);
    if (categoryStr != null) {
      _categoryOrder = categoryStr;
    }

    notifyListeners();
  }

  Future<void> reorderGenres(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = _genreOrder.removeAt(oldIndex);
    _genreOrder.insert(newIndex, item);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyGenreOrder, _genreOrder);
  }

  Future<void> reorderCategories(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = _categoryOrder.removeAt(oldIndex);
    _categoryOrder.insert(newIndex, item);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyCategoryOrder, _categoryOrder);
  }

  // Helper to ensure all genres are in the order list (if new ones appear)
  void syncGenres(List<String> currentGenres) {
    bool changed = false;
    // Add missing
    for (var g in currentGenres) {
      if (!_genreOrder.contains(g)) {
        _genreOrder.add(g);
        changed = true;
      }
    }
    // Remove obsolete
    _genreOrder.removeWhere((g) => !currentGenres.contains(g));

    if (changed) {
      // Save silently? Or just wait for next reorder?
      // Better to save if we modified meaningful state, but avoiding IO spam is good.
    }
  }

  void syncCategories(List<String> currentCategories) {
    bool changed = false;
    for (var c in currentCategories) {
      if (!_categoryOrder.contains(c)) {
        _categoryOrder.add(c);
        changed = true;
      }
    }
    _categoryOrder.removeWhere((c) => !currentCategories.contains(c));
    if (changed) {
      notifyListeners();
    }
  }

  Future<void> setCustomOrder(bool enabled) async {
    _useCustomOrder = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseCustomOrder, enabled);
  }

  Future<void> reorderStations(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    // Ensure we have a working list populated with all IDs if _stationOrder was empty/partial
    if (_stationOrder.isEmpty || _stationOrder.length != stations.length) {
      _stationOrder = allStations.map((s) => s.id).toList();
    }

    final int item = _stationOrder.removeAt(oldIndex);
    _stationOrder.insert(newIndex, item);

    // Auto-enable custom order if we reorder
    if (!_useCustomOrder) {
      _useCustomOrder = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyUseCustomOrder, true);
    }

    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyStationOrder,
      _stationOrder.map((e) => e.toString()).toList(),
    );
  }

  void _addLog(String message) {
    final time =
        "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}";
    _metadataLog.insert(0, "[$time] $message");
    if (_metadataLog.length > 50) _metadataLog.removeLast();
    notifyListeners();
  }

  Future<List<int>> _captureBytes(String url, {int depth = 0}) async {
    if (depth > 5) throw Exception("Redirection/Playlist Limit Reached");

    final uri = Uri.parse(url);
    final client = http.Client();
    final request = http.Request('GET', uri);

    // Add User-Agent to avoid blocking by some servers
    request.headers['User-Agent'] =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36';

    final streamResponse = await client.send(request);

    if (streamResponse.statusCode != 200) {
      client.close();
      throw Exception("Status ${streamResponse.statusCode} from $url");
    }

    List<int> buffer = [];
    int maxAudioBytes = 200 * 1024; // ~15 seconds
    bool checkedType = false;
    bool isPlaylist = false;

    await for (var chunk in streamResponse.stream) {
      buffer.addAll(chunk);

      if (!checkedType) {
        // Check first few bytes for #EXTM3U signature
        if (buffer.length >= 7) {
          try {
            // We only decode the start to check signature
            final prefix = utf8.decode(
              buffer.sublist(0, 7),
              allowMalformed: true,
            );
            if (prefix.contains("#EXTM3U")) {
              isPlaylist = true;
            }
          } catch (_) {
            // Binary data likely
          }
          checkedType = true;
        }
      }

      // If it's NOT a playlist, and we have enough audio, stop.
      if (checkedType && !isPlaylist && buffer.length >= maxAudioBytes) {
        client.close();
        break;
      }
    }

    // Ensure client is closed
    client.close();

    if (isPlaylist) {
      try {
        final content = utf8.decode(buffer, allowMalformed: true);
        final lines = content.split('\n');
        for (var line in lines) {
          line = line.trim();
          if (line.isNotEmpty && !line.startsWith("#")) {
            // Found next URL
            Uri nextUri = uri.resolve(line);
            return _captureBytes(nextUri.toString(), depth: depth + 1);
          }
        }
      } catch (e) {
        throw Exception("Failed to parse M3U8: $e");
      }
      throw Exception("Empty M3U8 playlist");
    }

    return buffer;
  }

  Future<void> _attemptRecognition() async {
    if (!_isPlaying || _currentStation == null) return;

    final String capturedStationUrl = _currentStation!.url;

    _isRecognizing = true;
    notifyListeners();

    _addLog(">>> SEARCH START: Music Recognition <<<");
    notifyListeners();

    bool matchFound = false;

    try {
      _addLog("Capturing audio stream...");
      List<int> audioBuffer = await _captureBytes(capturedStationUrl);

      if (audioBuffer.isEmpty) {
        throw Exception("Stream buffer empty (CORS or Net Error)");
      }

      _addLog(
        "Audio captured (${audioBuffer.length} bytes). Sending to API...",
      );

      String timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000)
          .toString();
      String stringToSign =
          "POST\n/v1/identify\n$_acrAccessKey\naudio\n1\n$timestamp";

      var hmac = Hmac(sha1, utf8.encode(_acrSecretKey));
      var digest = hmac.convert(utf8.encode(stringToSign));
      String signature = base64.encode(digest.bytes);

      var uri = Uri.parse("https://$_acrHost/v1/identify");
      var multipartRequest = http.MultipartRequest("POST", uri);
      multipartRequest.fields['access_key'] = _acrAccessKey;
      multipartRequest.fields['data_type'] = 'audio';
      multipartRequest.fields['signature_version'] = '1';
      multipartRequest.fields['signature'] = signature;
      multipartRequest.fields['timestamp'] = timestamp;
      multipartRequest.fields['sample_bytes'] = audioBuffer.length.toString();

      multipartRequest.files.add(
        http.MultipartFile.fromBytes(
          'sample',
          audioBuffer,
          filename: 'sample.mp3',
        ),
      );

      var res = await multipartRequest.send();
      _addLog("API Response Code: ${res.statusCode}");

      var responseBody = await res.stream.bytesToString();
      _lastApiResponse = responseBody; // Save raw JSON
      notifyListeners();

      var json = jsonDecode(responseBody);
      var status = json['status'];

      if (status != null && status['code'] == 0) {
        var metadata = json['metadata'];
        if (metadata != null &&
            metadata['music'] != null &&
            (metadata['music'] as List).isNotEmpty) {
          matchFound = true; // SUCCESS
          var music = metadata['music'][0];
          String title = music['title'];
          String artist =
              (music['artists'] != null &&
                  (music['artists'] as List).isNotEmpty)
              ? music['artists'][0]['name']
              : "Unknown";

          String? albumArt;
          String? artistImg;
          String albumName = "";
          String? spotifyUrl;
          String? youtubeUrl;
          String? releaseDate = music['release_date'];
          String? genreName;
          if (music['genres'] != null && (music['genres'] as List).isNotEmpty) {
            genreName = music['genres'][0]['name'];
          }

          if (music['album'] != null) {
            albumName = music['album']['name'] ?? "";
            if (music['album']['cover'] != null) {
              albumArt = music['album']['cover'];
            }
          }

          // External Metadata Handling (Spotify, Deezer, Youtube)
          if (music['external_metadata'] != null) {
            var ext = music['external_metadata'];
            if (ext.containsKey('spotify')) {
              var spot = ext['spotify'];
              if (albumArt == null &&
                  spot['album'] != null &&
                  spot['album']['images'] != null) {
                var imgs = spot['album']['images'] as List;
                if (imgs.isNotEmpty) albumArt = imgs[0]['url'];
              }
              if (spot['artists'] != null) {
                var artists = spot['artists'] as List;
                if (artists.isNotEmpty && artists[0]['images'] != null) {
                  var imgs = artists[0]['images'] as List;
                  if (imgs.isNotEmpty) artistImg = imgs[0]['url'];
                }
              }
              if (spot['track'] != null && spot['track']['id'] != null) {
                spotifyUrl =
                    "https://open.spotify.com/track/${spot['track']['id']}";
              }
            }
            if (ext.containsKey('youtube')) {
              var yt = ext['youtube'];
              if (yt['vid'] != null) {
                youtubeUrl = "https://www.youtube.com/watch?v=${yt['vid']}";
              }
            }
            if (ext.containsKey('deezer')) {
              var deez = ext['deezer'];
              if (albumArt == null &&
                  deez['album'] != null &&
                  deez['album']['cover'] != null) {
                albumArt = deez['album']['cover'];
              }
              if (artistImg == null && deez['artists'] != null) {
                var artists = deez['artists'] as List;
                if (artists.isNotEmpty && artists[0]['picture'] != null) {
                  artistImg = artists[0]['picture'];
                }
              }
            }
          }

          // Fallbacks
          if (spotifyUrl == null) {
            String safeTitle = title.trim();
            String safeArtist = artist.trim();

            List<String> terms = [safeTitle];
            if (safeArtist.isNotEmpty && safeArtist != "Unknown") {
              terms.add(safeArtist);
            }
            String query = Uri.encodeComponent(terms.join(" "));
            spotifyUrl = "https://open.spotify.com/search/$query?type=track";
          }
          if (youtubeUrl == null) {
            String safeTitle = title.trim();
            String safeArtist = artist.trim();

            List<String> terms = [safeTitle];
            if (safeArtist.isNotEmpty && safeArtist != "Unknown") {
              terms.add(safeArtist);
            }
            String query = Uri.encodeComponent(terms.join(" "));
            youtubeUrl = "https://www.youtube.com/results?search_query=$query";
          }

          if (albumArt == null || albumArt.isEmpty) {
            try {
              String query = "$title $artist";
              albumArt = await _fetchArtFromItunes(query);
            } catch (_) {}
          }

          if (artistImg == null || artistImg.isEmpty) {
            try {
              artistImg = await _fetchArtistImageFromItunes(artist);
            } catch (_) {}
          }

          // Update State
          if (_currentStation?.url != capturedStationUrl) return;

          // Check if data actually changed to verify if update is needed
          final bool hasChanged =
              title != _currentTrack ||
              artist != _currentArtist ||
              (albumArt ?? _currentStation?.logo) != _currentAlbumArt;

          _currentSpotifyUrl = spotifyUrl;
          _currentYoutubeUrl = youtubeUrl;
          _currentTrack = title;
          _currentArtist = artist;
          _currentAlbum = albumName;
          _currentAlbumArt = albumArt ?? _currentStation?.logo;
          _currentArtistImage = artistImg ?? _currentStation?.logo;
          _currentReleaseDate = releaseDate;
          _currentGenre = genreName;

          // UPDATE AUDIO HANDLER (Android Auto) - Only if changed
          if (hasChanged) {
            _audioHandler.updateMediaItem(
              MediaItem(
                id: _currentStation!.url,
                title: title,
                artist: "$artist • $genreName",
                album: albumName.isNotEmpty
                    ? "$albumName • $genreName"
                    : genreName,
                genre: genreName,
                artUri: (albumArt ?? artistImg ?? _currentStation!.logo) != null
                    ? Uri.parse(
                        (albumArt ?? artistImg ?? _currentStation!.logo)!,
                      )
                    : null,
                extras: {
                  'url': _currentStation!.url,
                  'spotifyUrl': _currentSpotifyUrl,
                  'youtubeUrl': _currentYoutubeUrl,
                },
              ),
            );
            _addLog("SUCCESS: Identified '$title' by $artist (Updated UI)");
          } else {
            _addLog("SUCCESS: Confirmed '$title' by $artist (No UI Change)");
          }

          notifyListeners();
        } else {
          _addLog("RESULT: No music found.");
        }
      } else {
        _addLog("API ERROR: ${status['msg']}");
      }
    } catch (e) {
      _addLog("ERROR: $e");
    } finally {
      // 2. CHECK IF FAILED -> RESTORE DEFAULT
      // Verify station hasn't changed during process
      if (!matchFound &&
          _currentStation != null &&
          _currentStation!.url == capturedStationUrl) {
        // Only revert to default if we are currently showing a song
        // (i.e., prevent redundant updates if we are already showing station info)
        bool isAlreadyDefault =
            _currentTrack == "Live Broadcast" &&
            _currentArtist == _currentStation!.name;

        if (!isAlreadyDefault) {
          _currentTrack = "Live Broadcast";
          _currentArtist = _currentStation!.name;
          _currentAlbum = "Live Radio";
          _currentAlbumArt = _currentStation!.logo;
          _currentArtistImage = null;

          // Clear external links since we failed to find music
          _currentSpotifyUrl = null;
          _currentYoutubeUrl = null;

          _audioHandler.updateMediaItem(
            MediaItem(
              id: _currentStation!.url,
              title: _currentStation!.name,
              artist: _currentStation!.genre,
              album: "Live Radio",
              artUri: _currentStation!.logo != null
                  ? Uri.parse(_currentStation!.logo!)
                  : null,
              extras: {'url': _currentStation!.url},
            ),
          );
        }
      }

      _isRecognizing = false;
      _addLog("<<< SEARCH END >>>");
      notifyListeners();

      if (_isPlaying) {
        _metadataTimer = Timer(
          const Duration(seconds: 45),
          _attemptRecognition,
        );
      }
    }
  }

  Future<String?> _fetchArtFromItunes(String query) async {
    try {
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=song&limit=1",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['resultCount'] > 0) {
          return json['results'][0]['artworkUrl100'].replaceAll(
            '100x100bb',
            '600x600bb',
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _fetchArtistImageFromItunes(String artistName) async {
    // 1. Try Deezer (Best for Artist Profile Pictures)
    try {
      final uri = Uri.parse(
        "https://api.deezer.com/search/artist?q=${Uri.encodeComponent(artistName)}&limit=1",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['data'] != null && (json['data'] as List).isNotEmpty) {
          String? picture =
              json['data'][0]['picture_xl'] ??
              json['data'][0]['picture_big'] ??
              json['data'][0]['picture_medium'];
          if (picture != null && picture.isNotEmpty) return picture;
        }
      }
    } catch (e) {
      _addLog("Deezer Artist Error: $e");
    }

    // 2. Fallback to iTunes (Album Art as Artist Image)
    try {
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(artistName)}&entity=album&limit=1",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['resultCount'] > 0) {
          String? artUrl = json['results'][0]['artworkUrl100'];
          if (artUrl != null) {
            return artUrl.replaceAll('100x100bb', '600x600bb');
          }
        }
      }
    } catch (e) {
      _addLog("iTunes Artist Fallback Error: $e");
    }
    return null;
  }

  void playStation(Station station) async {
    _metadataTimer?.cancel();

    try {
      if (_currentStation?.id == station.id && _isPlaying) {
        pause();
        return;
      }

      _currentStation = station;
      _isLoading = true;
      _currentTrack = "Live Broadcast";
      _currentArtist = "";
      _currentAlbum = "";
      _currentAlbumArt = null;
      _currentArtistImage = null;
      _currentSpotifyUrl = null;
      _currentYoutubeUrl = null;

      _addLog("Connecting: ${station.name}...");
      notifyListeners();

      // USE AUDIO HANDLER
      await _audioHandler.playFromUri(Uri.parse(station.url), {
        'title': station.name,
        'artist': station.genre,
        'album': 'Live Radio',
        'artUri': station.logo,
      });

      _isLoading = false;
      _addLog("Playing via Service");

      // Explicitly schedule recognition since playback state might not toggle
      if (_isPlaying) {
        _metadataTimer = Timer(const Duration(seconds: 5), _attemptRecognition);
      }
    } catch (e) {
      _isLoading = false;
      _addLog("Error: $e");
      notifyListeners();
    }
  }

  void togglePlay() {
    if (_currentStation == null) {
      if (stations.isNotEmpty) playStation(stations[0]);
      return;
    }
    if (_isPlaying) {
      pause();
    } else {
      resume();
    }
  }

  void pause() async {
    // _metadataTimer?.cancel(); // Handled by listener
    await _audioHandler.pause();
    // playing state listener will update _isPlaying
  }

  void resume() async {
    if (_currentStation != null) {
      await _audioHandler.play();
    }
  }

  void playNext() {
    playNextFavorite();
  }

  void playPrevious() {
    playPreviousFavorite();
  }

  void setVolume(double vol) {
    _volume = vol;
    _audioHandler.customAction('setVolume', {'volume': vol});
    notifyListeners();
  }

  void toggleFavorite(int id) async {
    if (_favorites.contains(id)) {
      _favorites.remove(id);
    } else {
      _favorites.add(id);
    }
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyFavorites,
      _favorites.map((e) => e.toString()).toList(),
    );
  }

  // --- Backup & Restore Logic ---

  String _backupFrequency = 'manual';
  String get backupFrequency => _backupFrequency;
  bool _isBackingUp = false;
  bool get isBackingUp => _isBackingUp;
  bool _isRestoring = false;
  bool get isRestoring => _isRestoring;

  Future<void> _checkAutoBackup() async {
    // Wait for auth to settle
    await Future.delayed(const Duration(seconds: 2));
    if (!_backupService.isSignedIn) return;

    final prefs = await SharedPreferences.getInstance();
    _backupFrequency = prefs.getString('backup_frequency') ?? 'manual';
    final lastBackup = prefs.getInt('last_backup_ts') ?? 0;

    if (_backupFrequency == 'manual') return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - lastBackup;

    bool due = false;
    if (_backupFrequency == 'daily' && diff > 86400000) due = true;
    if (_backupFrequency == 'weekly' && diff > 604800000) due = true;

    if (due) {
      await performBackup();
    }
  }

  Future<void> setBackupFrequency(String freq) async {
    _backupFrequency = freq;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backup_frequency', freq);
    notifyListeners();
    // Check immediately if we switched to auto and it is due
    _checkAutoBackup();
  }

  Future<void> performBackup() async {
    if (!_backupService.isSignedIn) return;

    _isBackingUp = true;
    notifyListeners();

    try {
      final data = {
        'stations': stations.map((s) => s.toJson()).toList(),
        'favorites': _favorites,
        'station_order': _stationOrder,
        'genre_order': _genreOrder,
        'playlists': _playlists.map((p) => p.toJson()).toList(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'version': 1,
      };

      await _backupService.uploadBackup(jsonEncode(data));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'last_backup_ts',
        DateTime.now().millisecondsSinceEpoch,
      );

      _addLog("Backup Complete");
    } catch (e) {
      _addLog("Backup Failed: $e");
      rethrow;
    } finally {
      _isBackingUp = false;
      notifyListeners();
    }
  }

  Future<void> restoreBackup() async {
    if (!_backupService.isSignedIn) return;

    _isRestoring = true;
    notifyListeners();

    try {
      final jsonStr = await _backupService.downloadBackup();
      if (jsonStr == null) {
        throw Exception("No backup found");
      }

      final data = jsonDecode(jsonStr);

      // Restore Stations
      if (data['stations'] != null) {
        final List<dynamic> sList = data['stations'];
        final List<Station> backupStations = sList
            .map((e) => Station.fromJson(e))
            .toList();

        // Merge Logic: Keep local "new" stations
        final Map<int, Station> mergedMap = {for (var s in stations) s.id: s};

        for (var s in backupStations) {
          mergedMap[s.id] = s;
        }

        stations = mergedMap.values.toList();
        await _saveStations(); // Persist
      }

      // Restore Favorites
      if (data['favorites'] != null) {
        _favorites.clear();
        _favorites.addAll((data['favorites'] as List).map((e) => e as int));
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _keyFavorites,
          _favorites.map((e) => e.toString()).toList(),
        );
      }

      // Restore Orders
      if (data['station_order'] != null) {
        _stationOrder = (data['station_order'] as List)
            .map((e) => e as int)
            .toList();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _keyStationOrder,
          _stationOrder.map((e) => e.toString()).toList(),
        );
      }
      if (data['genre_order'] != null) {
        _genreOrder = (data['genre_order'] as List)
            .map((e) => e as String)
            .toList();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_keyGenreOrder, _genreOrder);
      }

      // Playlists
      if (data['playlists'] != null) {
        final List<dynamic> pList = data['playlists'];
        final List<Playlist> backupPlaylists = pList
            .map((e) => Playlist.fromJson(e))
            .toList();

        // Merge Logic: Keep local "new" playlists that aren't in backup
        // 1. Create Map of current local playlists
        final Map<String, Playlist> mergedMap = {
          for (var p in _playlists) p.id: p,
        };

        // 2. Update/Add playlists from backup (Backup is source of truth for its own data)
        for (var p in backupPlaylists) {
          mergedMap[p.id] = p;
        }

        // 3. Result contains Backup versions + New Local versions
        _playlists = mergedMap.values.toList();
        await _playlistService.saveAll(_playlists);
      }

      _addLog("Restore Complete");
      notifyListeners();
    } catch (e) {
      _addLog("Restore Failed: $e");
      rethrow;
    } finally {
      _isRestoring = false;
      notifyListeners();
    }
  }

  Future<void> reloadPlaylists() async {
    _playlists = await _playlistService.loadPlaylists();
    notifyListeners();
  }
}
