import 'dart:io';
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
import 'package:workmanager/workmanager.dart';
import '../services/background_tasks.dart';
import '../services/backup_service.dart';
import '../utils/genre_mapper.dart';
import '../services/song_link_service.dart';
import '../services/music_metadata_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:youtube_player_flutter/youtube_player_flutter.dart';

// ...

class RadioProvider with ChangeNotifier {
  List<Station> stations = [];
  static const String _keySavedStations = 'saved_stations';
  static const String _keyStartOption =
      'start_option'; // 'none', 'last', 'specific'
  static const String _keyStartupStationId = 'startup_station_id';
  static const String _keyLastPlayedStationId = 'last_played_station_id';
  static const String _keyCompactView = 'compact_view';
  static const String _keyShuffleMode = 'shuffle_mode';
  static const String _keyInvalidSongIds = 'invalid_song_ids';

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
    _updateAudioHandler();
    notifyListeners();
    _updateAudioHandler();
    notifyListeners();
    // Defer startup playback slightly to ensure UI is ready if needed, or just run it.
    // However, we shouldn't block.
    // _handleStartupPlayback(); // Removed automatic call
    _ensureStationImages();
  }

  void _ensureStationImages() {
    bool changed = false;
    for (int i = 0; i < stations.length; i++) {
      final s = stations[i];
      if (s.logo == null || s.logo!.isEmpty) {
        final split = s.genre.split(RegExp(r'[|/,]'));
        if (split.isNotEmpty) {
          final firstGenre = split.first.trim();
          if (firstGenre.isNotEmpty) {
            final img = GenreMapper.getGenreImage(firstGenre);
            if (img != null) {
              stations[i] = Station(
                id: s.id,
                name: s.name,
                genre: s.genre,
                url: s.url,
                icon: s.icon,
                logo: img,
                color: s.color,
                category: s.category,
              );
              changed = true;
            }
          }
        }
      }
    }

    if (changed) {
      _saveStations();
    }
  }

  Future<void> handleStartupPlayback() async {
    final prefs = await SharedPreferences.getInstance();
    _startOption = prefs.getString(_keyStartOption) ?? 'none';
    _startupStationId = prefs.getInt(_keyStartupStationId);

    if (_startOption == 'none') return;

    int? targetId;

    if (_startOption == 'last') {
      targetId = prefs.getInt(_keyLastPlayedStationId);
    } else if (_startOption == 'specific') {
      targetId = _startupStationId;
    }

    if (targetId != null) {
      try {
        final station = stations.firstWhere((s) => s.id == targetId);
        playStation(station);
      } catch (e) {
        // Station likely deleted
      }
    }
  }

  Future<void> _saveStations() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(stations.map((s) => s.toJson()).toList());
    await prefs.setString(_keySavedStations, encoded);
    _updateAudioHandler();
    notifyListeners();
  }

  void _updateAudioHandler() {
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.updateStations(stations);
    }
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
  final SongLinkService _songLinkService = SongLinkService();
  final MusicMetadataService _musicMetadataService = MusicMetadataService();

  List<Playlist> _playlists = [];
  List<Playlist> get playlists => _playlists;
  DateTime? _lastPlayNextTime;
  DateTime? _zeroDurationStartTime;
  DateTime? _lastProcessingTime;
  Duration? _lastMonitoredPosition;
  DateTime? _lastMonitoredPositionTime;

  // ... existing members

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  final BackupService _backupService;
  BackupService get backupService => _backupService;

  int _lastBackupTs = 0;
  int get lastBackupTs => _lastBackupTs;

  String _lastBackupType = 'manual';
  String get lastBackupType => _lastBackupType;

  String _startOption = 'none'; // 'none', 'last', 'specific'
  String get startOption => _startOption;
  int? _startupStationId;
  int? get startupStationId => _startupStationId;

  bool _isCompactView = false;
  bool get isCompactView => _isCompactView;

  RadioProvider(this._audioHandler, this._backupService) {
    _backupService.addListener(notifyListeners);
    _checkAutoBackup(); // Start check
    // Listen to playback state from AudioService
    _audioHandler.playbackState.listen((state) {
      bool playing = state.playing;

      // Handle External Pause (Notification interaction)
      // Handle External Pause (Notification interaction)
      if (!playing && _hiddenAudioController != null && !_ignoringPause) {
        // If notification was paused by user, pause YouTube too
        _hiddenAudioController!.pause();
      }

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
        // if (_isPlaying) {
        //   _metadataTimer = Timer(
        //     const Duration(seconds: 5),
        //     _attemptRecognition, // FAZIO -- Intervallo ricerca musica via riconoscimento API
        //   );
        // }

        notifyListeners();
      }
    });

    // Listen to media item changes (if updated from outside or by handler, e.g. Android Auto)
    _audioHandler.mediaItem.listen((item) {
      if (item == null) return;

      // If the media item ID (URL) differs from current station, it means
      // Android Auto or another source changed the station.
      if (_currentStation?.url != item.id) {
        // Prevent interference if we are handling YouTube locally
        if ((_currentStation?.url.startsWith('youtube://') ?? false) ||
            (item.id == 'external_audio')) {
          return;
        }

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

          notifyListeners();

          // Restart recognition for the new station
          _metadataTimer?.cancel();
          // if (_isPlaying) {
          //  _metadataTimer = Timer(
          //    const Duration(seconds: 5),
          //     _attemptRecognition, // FAZIO -- Intervallo ricerca musica via riconoscimento API
          //   );
          // }
        } catch (_) {
          // Check if it is a playlist song request from Android Auto
          if (item.extras?['type'] == 'playlist_song') {
            final String? videoId = item.extras?['videoId'];
            final String? playlistId = item.extras?['playlistId'];
            final String? songId = item.extras?['songId'];

            if (videoId != null && songId != null) {
              // Trigger playback
              // We use a microtask to avoid recursive updates if this listener fired during an update
              Future.microtask(() {
                playYoutubeAudio(
                  videoId,
                  songId,
                  playlistId: playlistId,
                  overrideTitle: item.title,
                  overrideArtist: item.artist,
                  overrideArtUri: item.artUri?.toString(),
                );
              });
            }
          }
        }
      }
    });

    // Set initial volume if possible, or just default local
    setVolume(_volume);

    // Load persisted playlist
    _loadPlaylists();
    _loadStationOrder();
    _loadStartupSettings(); // Load this before stations
    _loadYouTubeSettings();
    _loadStations();

    // Connect AudioHandler callbacks
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.onSkipNext = playNextFavorite;
      _audioHandler.onSkipPrevious = playPreviousFavorite;
    }
  }

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
    List<Station> list;

    if (_useCustomOrder) {
      // If user has manually reordered, respectful that specific order (Flat)
      if (_favorites.isNotEmpty) {
        list = allStations.where((s) => _favorites.contains(s.id)).toList();
      } else {
        list = allStations;
      }
    } else {
      // Default behavior: Genre Grouped
      list = _favorites.isEmpty ? allStations : _visualFavoriteOrder;
    }

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int nextIndex = 0;
    if (currentIndex != -1) {
      nextIndex = (currentIndex + 1) % list.length;
    }

    playStation(list[nextIndex]);
  }

  void playPreviousFavorite() {
    List<Station> list;

    if (_useCustomOrder) {
      // If user has manually reordered, respectful that specific order (Flat)
      if (_favorites.isNotEmpty) {
        list = allStations.where((s) => _favorites.contains(s.id)).toList();
      } else {
        list = allStations;
      }
    } else {
      // Default behavior: Genre Grouped
      list = _favorites.isEmpty ? allStations : _visualFavoriteOrder;
    }

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
          _currentAppleMusicUrl ??
          "https://music.apple.com/search?term=${Uri.encodeComponent("$_currentTrack $_currentArtist")}",
      dateAdded: DateTime.now(),
      releaseDate: _currentReleaseDate,
    );

    // 1. Auto-Classification Logic (Default / Heart Button)
    if (playlistId == null) {
      // Determine effective genre
      String effectiveGenre = _currentGenre ?? _currentStation?.genre ?? "Mix";

      // Clean up genre string
      if (effectiveGenre.contains('|')) {
        effectiveGenre = effectiveGenre.split('|').first.trim();
      }
      if (effectiveGenre.contains('/')) {
        effectiveGenre = effectiveGenre.split('/').first.trim();
      }

      if (effectiveGenre.trim().isEmpty ||
          effectiveGenre.toLowerCase() == 'unknown') {
        effectiveGenre = "Mix";
      }

      await _playlistService.addToGenrePlaylist(effectiveGenre, song);
      await _loadPlaylists();
      return effectiveGenre;
    }

    // 2. Explicit Target Logic (e.g. Move to Favorites)
    await _playlistService.addSongToPlaylist(playlistId, song);
    await _loadPlaylists();

    // Find name for return value
    final p = playlists.firstWhere(
      (p) => p.id == playlistId,
      orElse: () => playlists.first, // Fallback safe
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

  Future<void> restoreSongToPlaylist(String playlistId, SavedSong song) async {
    await _playlistService.addSongToPlaylist(playlistId, song);
    await _loadPlaylists();
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

  Future<void> moveSongs(
    List<String> songIds,
    String fromPayloadId,
    String toPayloadId,
  ) async {
    await _playlistService.moveSongs(songIds, fromPayloadId, toPayloadId);
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

  Future<void> restoreSongsToPlaylist(
    String playlistId,
    List<SavedSong> songs, {
    String? playlistName,
  }) async {
    await _playlistService.restoreSongsToPlaylist(
      playlistId,
      songs,
      playlistName: playlistName,
    );
    await _loadPlaylists();
  }

  Future<void> removeSongsFromPlaylist(
    String playlistId,
    List<String> songIds,
  ) async {
    await _playlistService.removeSongsFromPlaylist(playlistId, songIds);
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

  Future<List<SongSearchResult>> searchMusic(String query) async {
    return await _musicMetadataService.searchSongs(query: query, limit: 40);
  }

  Future<void> addFoundSongToGenre(SongSearchResult result) async {
    // Check if result.genre is valid, otherwise use default
    String genre = result.genre;
    if (genre.isEmpty) genre = "Mix";

    await _playlistService.addToGenrePlaylist(genre, result.song);
    await _loadPlaylists();
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
  String? _currentAppleMusicUrl;
  String? _currentDeezerUrl;
  String? _currentTidalUrl;
  String? _currentAmazonMusicUrl;
  String? _currentNapsterUrl;

  String? _currentReleaseDate;
  String? _currentGenre;

  bool _isLoading = false;
  bool _isRecognizing = false;
  final List<String> _metadataLog = [];

  // Track invalid songs
  final List<String> _invalidSongIds = [];
  List<String> get invalidSongIds => _invalidSongIds;

  bool get isLoading => _isLoading;
  bool get isRecognizing => _isRecognizing;
  bool _hasPerformedRestore = false;
  bool get hasPerformedRestore => _hasPerformedRestore;
  Timer? _metadataTimer;
  Timer? _playbackMonitor; // Robust backup for end-of-song detection
  Timer? _invalidDetectionTimer;

  // ACRCloud Credentials
  final String _acrHost = "identify-eu-west-1.acrcloud.com";
  final String _acrAccessKey = "e763fb2faa97925d26fcfba2c8e29f34";
  final String _acrSecretKey = "Pg8Htq25c39YswVQXga3ExXsaUSu2qTbxCACyqgY";

  Station? get currentStation => _currentStation;
  bool get isPlaying => _isPlaying;
  //   bool get isLoading => _isLoading; // duplicate removed
  double get volume => _volume;
  List<int> get favorites => _favorites;
  List<String> get metadataLog => _metadataLog;
  String _lastApiResponse = "No API response yet.";
  String get lastApiResponse => _lastApiResponse;
  String _lastSongLinkResponse = "No SongLink response yet.";
  String get lastSongLinkResponse => _lastSongLinkResponse;

  // Backup Override
  bool _backupOverride = false;
  bool get backupOverride => _backupOverride;

  // Backup State
  bool _isBackingUp = false;
  bool get isBackingUp => _isBackingUp;

  bool _isRestoring = false;
  bool get isRestoring => _isRestoring;

  void enableBackupOverride() {
    _backupOverride = true;
    notifyListeners();
  }

  bool get canInitiateBackup =>
      !_isBackingUp &&
      !_isRestoring &&
      (_lastBackupTs != 0 || _hasPerformedRestore || _backupOverride);

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
  String? get currentAppleMusicUrl => _currentAppleMusicUrl;
  String? get currentDeezerUrl => _currentDeezerUrl;
  String? get currentTidalUrl => _currentTidalUrl;
  String? get currentAmazonMusicUrl => _currentAmazonMusicUrl;
  String? get currentNapsterUrl => _currentNapsterUrl;

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
  static const String _keyHasPerformedRestore = 'has_performed_restore';
  // Persistent Youtube Player State via WebView
  // Persistent Youtube Player State
  YoutubePlayerController? _hiddenAudioController;
  String? _audioOnlySongId;

  YoutubePlayerController? get hiddenAudioController => _hiddenAudioController;
  String? get audioOnlySongId => _audioOnlySongId;
  String? _currentPlayingPlaylistId;
  String? get currentPlayingPlaylistId => _currentPlayingPlaylistId;

  bool _isShuffleMode = false;
  bool get isShuffleMode => _isShuffleMode;

  bool _isRepeatMode = true;
  bool get isRepeatMode => _isRepeatMode;

  bool _ignoringPause = false;

  // Shuffle Logic
  List<int> _shuffledIndices = [];

  List<SavedSong> get activeQueue {
    if (_currentPlayingPlaylistId == null) return [];

    final playlist = playlists.firstWhere(
      (p) => p.id == _currentPlayingPlaylistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );

    if (playlist.songs.isEmpty) return [];

    if (_isShuffleMode && _shuffledIndices.length == playlist.songs.length) {
      return _shuffledIndices.map((i) => playlist.songs[i]).toList();
    }

    return playlist.songs;
  }

  void toggleShuffle() async {
    _isShuffleMode = !_isShuffleMode;

    if (_isShuffleMode && _currentPlayingPlaylistId != null) {
      _generateShuffleList();
    } else {
      _shuffledIndices.clear();
    }

    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShuffleMode, _isShuffleMode);
  }

  void _generateShuffleList() {
    if (_currentPlayingPlaylistId == null) return;

    final playlist = playlists.firstWhere(
      (p) => p.id == _currentPlayingPlaylistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );

    if (playlist.songs.isEmpty) return;

    _shuffledIndices = List.generate(playlist.songs.length, (i) => i);
    _shuffledIndices.shuffle();

    // Optional: Move current song to start of shuffle list so we don't jump?
    // Or just let the user find their place.
    // Better UX: If we are playing song X, find X in shuffled list and swap it to current position?
    // No, standard shuffle usually just reshuffles the queue.
    // But to support "Previous" correctly, we need a consistent list.
    // Let's ensure the current song remains the "current" one in the shuffled context.

    if (_audioOnlySongId != null) {
      final currentIndex = playlist.songs.indexWhere(
        (s) => s.id == _audioOnlySongId,
      );
      if (currentIndex != -1) {
        // Move current song index to the beginning (or handle it logically)
        // Actually, pure random shuffle is fine, we just need to find where the current song IS in the shuffled list
        // and continue from there.
      }
    }
  }

  void toggleRepeat() {
    _isRepeatMode = !_isRepeatMode;
    notifyListeners();
  }

  Future<void> playYoutubeAudio(
    String videoId,
    String songId, {
    String? playlistId,
    String? overrideTitle,
    String? overrideArtist,
    String? overrideAlbum,
    String? overrideArtUri,
  }) async {
    _metadataTimer?.cancel(); // CANCEL recognition timer
    _invalidDetectionTimer?.cancel(); // CANCEL invalid detection timer
    _invalidDetectionTimer = null;

    String? oldPlaylistId = _currentPlayingPlaylistId;
    _currentPlayingPlaylistId = playlistId;

    if (playlistId != null && oldPlaylistId != playlistId && _isShuffleMode) {
      _generateShuffleList();
    }

    // Determine metadata: Use overrides if provided, otherwise fallback to search
    String title = overrideTitle ?? "Audio";
    String artist = overrideArtist ?? "YouTube";
    String? artwork = overrideArtUri;
    String? album = overrideAlbum;
    String? releaseDate;

    // Only search if we don't have overrides
    if (overrideTitle == null) {
      // Use current playlist if available for better lookup, otherwise search all
      List<Playlist> searchLists = playlistId != null
          ? playlists.where((p) => p.id == playlistId).toList()
          : playlists;

      // Fallback to searching all if specific lookup fails
      if (searchLists.isEmpty) searchLists = playlists;

      for (var p in searchLists) {
        final match = p.songs.firstWhere(
          (s) => s.id == songId,
          orElse: () => SavedSong(
            id: '',
            title: '',
            artist: '',
            album: '',
            dateAdded: DateTime.now(),
          ),
        );
        if (match.id.isNotEmpty) {
          title = match.title;
          artist = match.artist;
          artwork = match.artUri;
          album = match.album;
          releaseDate = match.releaseDate;
          break;
        }
      }
    }

    // --------------------------------------------------------------------------------
    // 1. UPDATE UI IMMEDIATELY (Prevent flicker / "No Station")
    // --------------------------------------------------------------------------------

    String playlistName = "Playlist";
    if (playlistId != null) {
      try {
        final pl = playlists.firstWhere((p) => p.id == playlistId);
        playlistName = pl.name;
      } catch (_) {}
    }

    _currentStation = Station(
      id: -999, // Dummy ID for external playback
      name: playlistName,
      genre: "My Playlist",
      url: "youtube://$videoId",
      icon: "youtube",
      color: "0xFFFF0000",
      logo: artwork,
      category: "Playlist",
    );
    _currentTrack = title;
    _currentArtist = artist;
    _currentAlbum = album ?? ""; // Empty instead of "Playlist"
    _currentAlbumArt = artwork;
    _currentReleaseDate = releaseDate;
    _currentArtistImage = null;
    _isPlaying = true; // Show 'Pause' icon
    // _isLoading = true; // Optional: Show loading state, but better to show song info

    notifyListeners(); // <--- CRITICAL: Update UI BEFORE async delays

    // --------------------------------------------------------------------------------
    // 2. BACKGROUND TASKS
    // --------------------------------------------------------------------------------

    // Switch to external playback mode
    _ignoringPause = true; // Prevent internal stop from pausing YouTube
    try {
      await _audioHandler.customAction('startExternalPlayback', {
        'title': title,
        'artist': artist,
        'artUri': artwork,
      });
    } finally {
      // Delay disabling flag slightly to ensure async events are processed
      Future.delayed(const Duration(seconds: 1), () {
        _ignoringPause = false;
      });
    }

    // Enable Wakelock
    try {
      if (!kIsWeb) {
        WakelockPlus.enable();
      }
    } catch (_) {}

    if (_hiddenAudioController != null) {
      if (_hiddenAudioController!.initialVideoId == videoId ||
          _hiddenAudioController!.metadata.videoId == videoId) {
        _hiddenAudioController!.seekTo(const Duration(seconds: 0));
        _hiddenAudioController!.play();
      } else {
        // Remove listener to prevent 'ended' event of previous video triggering next
        _hiddenAudioController!.removeListener(_youtubeListener);
        _hiddenAudioController!.load(videoId);
        // Listener will be re-added below if needed, but safer to add it cleanly
      }
    } else {
      _hiddenAudioController = YoutubePlayerController(
        initialVideoId: videoId,
        flags: const YoutubePlayerFlags(
          autoPlay: true,
          mute: false,
          enableCaption: false,
          hideControls: true,
          forceHD: false,
        ),
      );
    }

    // Ensure listener is attached (remove first to avoid duplicates)
    _hiddenAudioController!.removeListener(_youtubeListener);
    _hiddenAudioController!.addListener(_youtubeListener);

    _audioOnlySongId = songId;
    _audioOnlySongId = songId;
    // _isLoading = false; // Moved to listener to wait for actual playback
    notifyListeners();

    // Start Monitor
    _startPlaybackMonitor();
  }

  bool _isCheckingStallInternet = false;

  Future<bool> _hasInternetConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _startPlaybackMonitor() {
    _stopPlaybackMonitor();
    _playbackMonitor = Timer.periodic(const Duration(milliseconds: 300), (
      timer,
    ) async {
      if (_hiddenAudioController == null) {
        timer.cancel();
        return;
      }

      try {
        final value = _hiddenAudioController!.value;

        // Notify AudioHandler of position for Android Auto Progress Bar
        _audioHandler.customAction('updatePlaybackPosition', {
          'position': value.position.inMilliseconds,
          'duration': value.metaData.duration.inMilliseconds,
          'isPlaying': value.isPlaying,
        });

        // Only check if we are actually playing
        if (value.playerState == PlayerState.playing) {
          final position = value.position;
          final duration = value.metaData.duration;

          // --- STALL DETECTION (Only check at start of song < 15s) ---
          if (position.inSeconds < 15) {
            if (_lastMonitoredPosition == position) {
              if (_lastMonitoredPositionTime == null) {
                _lastMonitoredPositionTime = DateTime.now();
              } else {
                final diff = DateTime.now().difference(
                  _lastMonitoredPositionTime!,
                );
                if (diff.inSeconds > 5) {
                  if (_isCheckingStallInternet) return;

                  _isCheckingStallInternet = true;
                  final hasInternet = await _hasInternetConnection();
                  _isCheckingStallInternet = false;

                  if (hasInternet) {
                    // Ricontrolla condizione di stallo dopo l'attesa
                    if (_hiddenAudioController != null &&
                        _hiddenAudioController!.value.playerState ==
                            PlayerState.playing &&
                        _hiddenAudioController!.value.position ==
                            _lastMonitoredPosition) {
                      debugPrint(
                        "Stallo Rilevato (>5s) e Internet OK. Segnalo canzone invalida.",
                      );
                      _markCurrentSongAsInvalid(); // Segnala come invalida
                      playNext(false); // Passa alla successiva

                      _lastMonitoredPosition = null;
                      _lastMonitoredPositionTime = null;
                      return;
                    }
                  } else {
                    debugPrint(
                      "Stallo Rilevato (>5s) - Nessuna connessione Internet. Attendo...",
                    );
                  }
                }
              }
            } else {
              _lastMonitoredPosition = position;
              _lastMonitoredPositionTime = DateTime.now();
            }
          }
          // -----------------------

          if (duration.inMilliseconds > 0) {
            final remainingMs =
                duration.inMilliseconds - position.inMilliseconds;

            if (remainingMs <= 1000 && !_isLoading) {
              _isLoading = true;
              notifyListeners();

              debugPrint(
                "PlaybackMonitor: Progress nearly reached duration (remaining: $remainingMs ms). Simulating click.",
              );
              // Force next - Simulate user click (true) 1s early
              playNext(true);
            }
          }
        } else {
          // Not playing, reset stall tracker
          _lastMonitoredPosition = null;
          _lastMonitoredPositionTime = null;
        }
      } catch (e) {
        // safeguards
      }
    });
  }

  void _stopPlaybackMonitor() {
    _playbackMonitor?.cancel();
    _playbackMonitor = null;
  }

  Future<void> stopYoutubeAudio() async {
    if (_hiddenAudioController != null) {
      final controller = _hiddenAudioController!;

      // Remove listener to prevent memory leaks or unwanted callbacks
      controller.removeListener(_youtubeListener);
      _stopPlaybackMonitor();

      // Clear reference immediately to update UI
      _hiddenAudioController = null;
      _audioOnlySongId = null;
      _invalidDetectionTimer?.cancel();
      _invalidDetectionTimer = null;
      _zeroDurationStartTime = null;
      _lastMonitoredPosition = null;
      _lastMonitoredPositionTime = null;

      // Reset PlayerBar Metadata
      _currentPlayingPlaylistId = null;
      _currentStation = null;
      _currentTrack = "Live Broadcast";
      _currentArtist = "";
      _currentAlbum = "";
      _currentAlbumArt = null;
      _isPlaying = false;

      notifyListeners();

      // Dispose controller to close connections
      controller.pause();
      controller.dispose();

      await _audioHandler.customAction('stopExternalPlayback');

      try {
        if (!kIsWeb) {
          WakelockPlus.disable();
        }
      } catch (_) {}
    }
  }

  void _youtubeListener() {
    if (_hiddenAudioController == null) return;

    final value = _hiddenAudioController!.value;
    final state = value.playerState;

    // 1. Explicit Error Check
    if (value.errorCode != 0) {
      debugPrint(
        "YouTube Player Error: ${value.errorCode}. Marking song invalid.",
      );
      _markCurrentSongAsInvalid();
      playNext(false);
      return;
    }

    // 2. Health Check: "Stuck" detection
    bool isProcessing = state == PlayerState.buffering;
    if (_isPlaying &&
        (state == PlayerState.unknown || state == PlayerState.cued)) {
      isProcessing = true;
    }

    if (isProcessing) {
      _zeroDurationStartTime = null;

      if (_lastProcessingTime == null) {
        _lastProcessingTime = DateTime.now();
      } else {
        final diff = DateTime.now().difference(_lastProcessingTime!);
        if (diff.inSeconds > 10) {
          debugPrint(
            "Playback Processing Timeout (>10s in $state). Marking invalid.",
          );
          _markCurrentSongAsInvalid();
          playNext(false);
          _lastProcessingTime = null;
          return;
        }
      }

      if (!_isLoading) {
        _isLoading = true;
        notifyListeners();
      }
    } else {
      // Not processing (Playing, Paused, Ended, or Cued-while-paused)
      _lastProcessingTime = null;
    }

    if (state == PlayerState.playing) {
      if (_isLoading) {
        _isLoading = false;
        notifyListeners();
      }
      if (!_isPlaying) {
        _isPlaying = true;
        notifyListeners();
      }

      // Check for Zero Duration (Invalid Song) with Timestamp Approach
      if (_hiddenAudioController != null) {
        final duration = _hiddenAudioController!.value.metaData.duration;
        if (duration.inMilliseconds == 0) {
          if (_isPlaying) {
            if (_zeroDurationStartTime == null) {
              _zeroDurationStartTime = DateTime.now();
              debugPrint(
                "Detected Zero Duration. Starting invalid detection timer...",
              );
            } else {
              // Check elapsed time
              final diff = DateTime.now().difference(_zeroDurationStartTime!);
              if (diff.inSeconds >= 5) {
                debugPrint(
                  "Song has had Zero Duration for >5s in Playing State. Marking invalid.",
                );
                _markCurrentSongAsInvalid();
                playNext(false);
                _zeroDurationStartTime = null;
              }
            }
          } else {
            _zeroDurationStartTime = null;
          }
        } else {
          // Duration is valid
          _zeroDurationStartTime = null;
        }

        // Preload next song logic
        final position = _hiddenAudioController!.value.position;
        if (duration.inSeconds > 10) {
          final remaining = duration - position;
          if (remaining.inMilliseconds < 3500 && remaining.inMilliseconds > 0) {
            _preloadNextSong();
          }
        }
      }
    } else if (state == PlayerState.paused) {
      _zeroDurationStartTime = null;
      if (_isLoading) {
        _isLoading = false;
        notifyListeners();
      }
      if (_isPlaying) {
        _isPlaying = false;
        notifyListeners();
      }
    } else if (state == PlayerState.cued) {
      _zeroDurationStartTime = null;
      if (_isLoading) {
        _isLoading = false;
        notifyListeners();
      }
    } else if (state == PlayerState.ended) {
      _zeroDurationStartTime = null;
      if (!_isLoading) {
        _isLoading = true;
        notifyListeners();
        playNext(true);
      }
    } else if (state == PlayerState.unknown) {
      // Often happens on error
      // We can debounce this too? Usually just ignore or treat as buffering?
    }
  }

  void clearYoutubeAudio() {
    _stopPlaybackMonitor();
    _hiddenAudioController?.dispose();
    _hiddenAudioController = null;
    _audioOnlySongId = null;
    _currentPlayingPlaylistId = null;
    _currentStation = null; // Also clear station
    notifyListeners();
  }

  static const String _keyPreferYouTubeAudioOnly = 'prefer_youtube_audio_only';

  bool _preferYouTubeAudioOnly = false;
  bool get preferYouTubeAudioOnly => _preferYouTubeAudioOnly;

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

  Future<void> moveCategory(
    String category,
    String? afterCategory,
    String? beforeCategory,
  ) async {
    final int currentIndex = _categoryOrder.indexOf(category);
    if (currentIndex == -1) return;

    _categoryOrder.removeAt(currentIndex);

    int targetIndex = -1;

    if (afterCategory != null) {
      final afterIndex = _categoryOrder.indexOf(afterCategory);
      if (afterIndex != -1) {
        targetIndex = afterIndex + 1;
      }
    } else if (beforeCategory != null) {
      final beforeIndex = _categoryOrder.indexOf(beforeCategory);
      if (beforeIndex != -1) {
        targetIndex = beforeIndex;
      }
    }

    if (targetIndex != -1) {
      if (targetIndex > _categoryOrder.length) {
        _categoryOrder.add(category);
      } else {
        _categoryOrder.insert(targetIndex, category);
      }
    } else {
      // Fallback: Reference not found.
      // If we intended to put it BEFORE something, and that something is missing/unknown,
      // putting it at the TOP is usually safer/more expected than the bottom for visibility.
      // If 'after' was specified but missing, we fall through to here? No, 'after' logic handles itself.
      if (beforeCategory != null) {
        _categoryOrder.insert(0, category);
      } else {
        // Default (after=null, before=null) -> Top? or Bottom?
        // Usually implies empty list or drag to start?
        _categoryOrder.insert(0, category);
      }
    }

    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyCategoryOrder, _categoryOrder);
  }

  Future<void> moveStation(
    int stationId,
    int? afterStationId,
    int? beforeStationId,
  ) async {
    // Ensure order list is fully populated
    if (_stationOrder.isEmpty || _stationOrder.length != stations.length) {
      // Re-sync with current stations if needed
      final existing = _stationOrder.toSet();
      final missing = stations
          .where((s) => !existing.contains(s.id))
          .map((s) => s.id);
      _stationOrder.addAll(missing);
    }

    // Auto-enable custom order
    if (!_useCustomOrder) {
      _useCustomOrder = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyUseCustomOrder, true);
    }

    final int currentIndex = _stationOrder.indexOf(stationId);
    if (currentIndex == -1) return;

    _stationOrder.removeAt(currentIndex);

    int targetIndex = -1;

    if (afterStationId != null) {
      final afterIndex = _stationOrder.indexOf(afterStationId);
      if (afterIndex != -1) {
        targetIndex = afterIndex + 1;
      }
    } else if (beforeStationId != null) {
      final beforeIndex = _stationOrder.indexOf(beforeStationId);
      if (beforeIndex != -1) {
        targetIndex = beforeIndex;
      }
    }

    if (targetIndex != -1) {
      if (targetIndex > _stationOrder.length) {
        _stationOrder.add(stationId);
      } else {
        _stationOrder.insert(targetIndex, stationId);
      }
    } else {
      // Fallback
      if (beforeStationId != null) {
        _stationOrder.insert(0, stationId);
      } else if (afterStationId != null) {
        _stationOrder.add(stationId);
      } else {
        _stationOrder.insert(0, stationId);
      }
    }

    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyStationOrder,
      _stationOrder.map((e) => e.toString()).toList(),
    );
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

  Future<void> _saveHasPerformedRestore() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHasPerformedRestore, _hasPerformedRestore);
  }

  Future<void> _loadStartupSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _startOption = prefs.getString(_keyStartOption) ?? 'none';
    _hasPerformedRestore = prefs.getBool(_keyHasPerformedRestore) ?? false;
    _startupStationId = prefs.getInt(_keyStartupStationId);
    _isCompactView = prefs.getBool(_keyCompactView) ?? false;
    _isShuffleMode = prefs.getBool(_keyShuffleMode) ?? false;

    // Load invalid songs
    final invalidList = prefs.getStringList(_keyInvalidSongIds);
    if (invalidList != null) {
      _invalidSongIds.clear();
      _invalidSongIds.addAll(invalidList);
    }
  }

  Future<void> setStartOption(String option) async {
    _startOption = option;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyStartOption, option);
    notifyListeners();
  }

  Future<void> setStartupStationId(int? id) async {
    _startupStationId = id;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_keyStartupStationId);
    } else {
      await prefs.setInt(_keyStartupStationId, id);
    }
    notifyListeners();
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
    if (capturedStationUrl.startsWith('youtube://')) return;

    _isRecognizing = true;
    notifyListeners();

    _addLog(">>> SEARCH START: Music Recognition <<<");
    notifyListeners();

    bool matchFound = false;

    try {
      // 1. CLEAR/INIT LOG
      _lastSongLinkResponse = "Song Link: Waiting for recognition...";
      notifyListeners();

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

          // Use Song.link API if we have enough info
          String? appleUrl;
          String? deezerUrl;
          String? tidalUrl;
          String? amazonUrl;
          String? napsterUrl;

          // NOTE: SongLink fetching is now manual via fetchSmartLinks()
          // to save API calls and performance.

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
            // Save as last played
            final prefs = await SharedPreferences.getInstance();
            if (_currentStation != null) {
              await prefs.setInt(_keyLastPlayedStationId, _currentStation!.id);
            }

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
          _currentAppleMusicUrl = appleUrl;
          _currentDeezerUrl = deezerUrl;
          _currentTidalUrl = tidalUrl;
          _currentAmazonMusicUrl = amazonUrl;
          _currentNapsterUrl = napsterUrl;
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
                  'appleMusicUrl': _currentAppleMusicUrl,
                  'deezerUrl': _currentDeezerUrl,
                  'tidalUrl': _currentTidalUrl,
                  'amazonMusicUrl': _currentAmazonMusicUrl,
                  'napsterUrl': _currentNapsterUrl,
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
          _lastSongLinkResponse =
              "Song Link: Skipped (ACRCloud found no match)";
          notifyListeners();
        }
      } else {
        _addLog("API ERROR: ${status['msg']}");
      }
    } catch (e) {
      _addLog("ERROR: $e");
      _lastSongLinkResponse = "Song Link: Error during process ($e)";
      notifyListeners();
    } finally {
      // 2. CHECK IF FAILED -> RESTORE DEFAULT
      // Verify station hasn't changed during process
      if (!matchFound &&
          _currentStation != null &&
          _currentStation!.url == capturedStationUrl &&
          !_currentStation!.url.startsWith('youtube://')) {
        // Only revert to default if we are currently showing a song
        // (i.e., prevent redundant updates if we are already showing station info)
        bool isAlreadyDefault =
            _currentTrack == _currentStation!.name &&
            _currentArtist == _currentStation!.genre;

        if (!isAlreadyDefault) {
          _currentTrack = _currentStation!.name;
          _currentArtist = _currentStation!.genre;
          _currentAlbum = "Live Radio";
          _currentAlbumArt = _currentStation!.logo;
          _currentArtistImage = null;

          // Clear external links since we failed to find music
          _currentSpotifyUrl = null;
          _currentYoutubeUrl = null;
          _currentAppleMusicUrl = null;
          _currentDeezerUrl = null;
          _currentTidalUrl = null;
          _currentAmazonMusicUrl = null;
          _currentNapsterUrl = null;

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

      //      if (_isPlaying) {
      //        _metadataTimer = Timer(
      //          const Duration(seconds: 45),
      //          _attemptRecognition, // FAZIO -- Intervallo ricerca musica via riconoscimento API
      //        );
      //      }
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

  Future<String?> _fetchItunesUrl(String query) async {
    try {
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=song&limit=1",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['resultCount'] > 0) {
          return json['results'][0]['trackViewUrl'];
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

    // If we're playing from a playlist (YouTube), stop it first
    if (_hiddenAudioController != null) {
      clearYoutubeAudio();
      _isShuffleMode = false;
    }

    // Save as "last played" immediately
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLastPlayedStationId, station.id);

    try {
      if (_currentStation?.id == station.id && _isPlaying) {
        pause();
        return;
      }

      _currentStation = station;
      _isLoading = true;
      _currentTrack = station.name;
      _currentArtist = station.genre;
      _currentAlbum = "";
      _currentAlbumArt = station.logo;
      _currentArtistImage = null;
      _currentSpotifyUrl = null;
      _currentYoutubeUrl = null;
      _currentAppleMusicUrl = null;
      _currentDeezerUrl = null;
      _currentTidalUrl = null;
      _currentAmazonMusicUrl = null;
      _currentNapsterUrl = null;

      // _addLog("Connecting: ${station.name}...");
      notifyListeners();

      // USE AUDIO HANDLER
      await _audioHandler.playFromUri(Uri.parse(station.url), {
        'title': station.name,
        'artist': station.genre,
        'album': 'Live Radio',
        'artUri': station.logo,
      });

      _isLoading = false;
      // _addLog("Playing via Service");

      // Explicitly schedule recognition since playback state might not toggle
      // Explicitly schedule recognition for the new station
      // This is needed because if we switch stations while already playing,
      // the 'playing' state toggle listener won't fire.
      // _metadataTimer = Timer(const Duration(seconds: 5), _attemptRecognition); // FAZIO -- Intervallo ricerca musica via riconoscimento API
    } catch (e) {
      _isLoading = false;
      // _addLog("Error: $e");
      notifyListeners();
    }
  }

  void togglePlay() {
    if (_hiddenAudioController != null) {
      if (_hiddenAudioController!.value.isPlaying) {
        _hiddenAudioController!.pause();
        _isPlaying = false;
      } else {
        _hiddenAudioController!.play();
        _isPlaying = true;
      }
      notifyListeners();
      return;
    }

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

  void stop() async {
    await _audioHandler.stop();
  }

  void resume() async {
    if (_currentStation != null) {
      await _audioHandler.play();
    }
  }

  void playNext([bool userInitiated = true]) {
    // Debounce to ensure it only clicks once within a short window (2 seconds)
    final now = DateTime.now();
    if (_lastPlayNextTime != null &&
        now.difference(_lastPlayNextTime!) < const Duration(seconds: 2)) {
      debugPrint("playNext: Ignored (Debounced)");
      return;
    }
    _lastPlayNextTime = now;

    if (_hiddenAudioController != null || _currentPlayingPlaylistId != null) {
      _playNextInPlaylist(userInitiated: userInitiated);
    } else {
      playNextFavorite();
    }
  }

  void playPrevious() {
    if (_hiddenAudioController != null || _currentPlayingPlaylistId != null) {
      _playPreviousInPlaylist();
    } else {
      playPreviousFavorite();
    }
  }

  // Preloading State
  String? _preloadedVideoId;
  String? _preloadedSongId;
  bool _isPreloading = false;

  SavedSong? _getNextSongInPlaylist() {
    if (_currentPlayingPlaylistId == null) return null;

    final playlist = playlists.firstWhere(
      (p) => p.id == _currentPlayingPlaylistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    if (playlist.songs.isEmpty) return null;

    // Filter out invalid songs to prevent playing them
    // Logic: Look for the next song. If invalid, keep looking.
    // We limit this to the playlist length to avoid infinite loops if ALL are invalid.

    int currentIndex = -1;
    if (_audioOnlySongId != null) {
      currentIndex = playlist.songs.indexWhere((s) => s.id == _audioOnlySongId);
    }

    int attempts = 0;
    // We Loop to find a VALID formatted song
    while (attempts < playlist.songs.length) {
      int nextIndex = 0;

      if (_isShuffleMode) {
        if (_shuffledIndices.length != playlist.songs.length) {
          _generateShuffleList();
        }

        int currentShuffledIndex = -1;
        if (currentIndex != -1) {
          currentShuffledIndex = _shuffledIndices.indexOf(currentIndex);
        }

        if (currentShuffledIndex != -1) {
          if (currentShuffledIndex + 1 >= _shuffledIndices.length) {
            nextIndex = _shuffledIndices[0];
          } else {
            nextIndex = _shuffledIndices[currentShuffledIndex + 1];
          }
        } else {
          if (_shuffledIndices.isNotEmpty) {
            nextIndex = _shuffledIndices[0];
          }
        }
      } else {
        if (currentIndex != -1) {
          if (currentIndex + 1 >= playlist.songs.length) {
            nextIndex = 0;
          } else {
            nextIndex = currentIndex + 1;
          }
        } else {
          nextIndex = 0;
        }
      }

      final candidate = playlist.songs[nextIndex];
      // Check if this candidate is valid
      if (!_invalidSongIds.contains(candidate.id)) {
        return candidate;
      }

      // If invalid, we pretend we just played it, and look for the next one
      currentIndex = nextIndex;
      attempts++;
    }

    return null; // All songs invalid or list empty
  }

  Future<void> _preloadNextSong() async {
    if (_isPreloading || _preloadedVideoId != null) return;

    final nextSong = _getNextSongInPlaylist();
    if (nextSong == null) return;

    // Don't preload if it's the same song (looping 1 song) to avoid confusion?
    // Actually fine.

    _isPreloading = true;
    _preloadedSongId = nextSong.id;
    // debugPrint("Preloading next song: ${nextSong.title}");

    try {
      String? videoId;
      if (nextSong.youtubeUrl != null) {
        videoId = YoutubePlayer.convertUrlToId(nextSong.youtubeUrl!);
      }

      if (videoId == null) {
        final links = await resolveLinks(
          title: nextSong.title,
          artist: nextSong.artist,
          spotifyUrl: nextSong.spotifyUrl,
          youtubeUrl: nextSong.youtubeUrl,
        );
        final url = links['youtube'];
        if (url != null) {
          videoId = YoutubePlayer.convertUrlToId(url);
        }
      }

      if (videoId != null) {
        _preloadedVideoId = videoId;
        // debugPrint("Preloaded Video ID: $videoId");
      }
    } catch (e) {
      // Ignore preload errors, will retry on actual play
    } finally {
      _isPreloading = false;
    }
  }

  Future<void> _playNextInPlaylist({bool userInitiated = true}) async {
    final nextSong = _getNextSongInPlaylist();
    if (nextSong != null && _currentPlayingPlaylistId != null) {
      await playPlaylistSong(nextSong, _currentPlayingPlaylistId!);
    }
  }

  Future<void> _playPreviousInPlaylist() async {
    if (_currentPlayingPlaylistId == null || _audioOnlySongId == null) return;

    final playlist = playlists.firstWhere(
      (p) => p.id == _currentPlayingPlaylistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    if (playlist.songs.isEmpty) return;

    final currentOriginalIndex = playlist.songs.indexWhere(
      (s) => s.id == _audioOnlySongId,
    );
    if (currentOriginalIndex == -1) return;

    int prevIndex;

    if (_isShuffleMode) {
      // Ensure shuffle list is valid
      if (_shuffledIndices.length != playlist.songs.length) {
        _generateShuffleList();
      }

      int currentShuffledIndex = _shuffledIndices.indexOf(currentOriginalIndex);
      if (currentShuffledIndex == -1) {
        _generateShuffleList();
        currentShuffledIndex = _shuffledIndices.indexOf(currentOriginalIndex);
      }

      if (currentShuffledIndex - 1 < 0) {
        // Start of shuffled list
        prevIndex =
            _shuffledIndices[_shuffledIndices.length - 1]; // Loop to end
      } else {
        prevIndex = _shuffledIndices[currentShuffledIndex - 1];
      }
    } else {
      // Normal Order
      prevIndex =
          (currentOriginalIndex - 1 + playlist.songs.length) %
          playlist.songs.length;
    }

    final prevSong = playlist.songs[prevIndex];

    await playPlaylistSong(prevSong, playlist.id);
  }

  Future<void> playPlaylistSong(SavedSong song, String playlistId) async {
    // Optimistic UI update
    _currentTrack = song.title;
    _currentArtist = song.artist;
    _currentAlbum = song.album; // Optimistic Album
    _currentAlbumArt = song.artUri;
    _audioOnlySongId =
        song.id; // Also update ID so ID-based UI remains consistent

    // Resolve Playlist Name
    String playlistName = "Playlist";
    try {
      final pl = playlists.firstWhere((p) => p.id == playlistId);
      playlistName = pl.name;
    } catch (_) {}

    // Optimistically set station to prevent "Select a station" flash
    _currentStation = Station(
      id: -999,
      name: playlistName,
      genre: "My Playlist",
      url: "youtube://loading",
      icon: "youtube",
      color: "0xFF212121",
      logo: song.artUri,
      category: "Playlist",
    );
    _metadataTimer?.cancel(); // CANCEL recognition timer
    _isLoading = true;
    notifyListeners();

    try {
      String? videoId;

      // Check Preloaded Data
      if (song.id == _preloadedSongId && _preloadedVideoId != null) {
        videoId = _preloadedVideoId;
        _preloadedVideoId = null;
        _preloadedSongId = null;
      }

      if (videoId == null && song.youtubeUrl != null) {
        videoId = YoutubePlayer.convertUrlToId(song.youtubeUrl!);
      }

      if (videoId == null) {
        final links = await resolveLinks(
          title: song.title,
          artist: song.artist,
          spotifyUrl: song.spotifyUrl,
          youtubeUrl: song.youtubeUrl,
        ).timeout(const Duration(seconds: 10));

        final url = links['youtube'];
        if (url != null) {
          videoId = YoutubePlayer.convertUrlToId(url);
        }
      }

      if (videoId != null) {
        await playYoutubeAudio(
          videoId,
          song.id,
          playlistId: playlistId,
          overrideTitle: song.title,
          overrideArtist: song.artist,
          overrideAlbum: song.album,
          overrideArtUri: song.artUri,
        ); // Recursive metadata update
      } else {
        // Link resolution failed - Auto-Skip to next
        await Future.delayed(
          const Duration(seconds: 1),
        ); // Delay to prevent rapid loops
        playNext(false);
      }
    } catch (e) {
      _isLoading = false;
      notifyListeners();

      // Error occurred - Auto-Skip
      await Future.delayed(const Duration(seconds: 1));
      playNext(false);
    }
  }

  void previewSong(SavedSong song) {
    _currentTrack = song.title;
    _currentArtist = song.artist;
    _currentAlbum = song.album;
    _currentAlbumArt = song.artUri;
    // Do NOT set isLoading or trigger audio.
    // Just update UI to reflect selection.
    notifyListeners();
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

  // --- External Links (SongLink) ---

  Future<void> fetchSmartLinks() async {
    if (_currentTrack == "Live Broadcast") return;

    final links = await resolveLinks(
      title: _currentTrack,
      artist: _currentArtist,
      spotifyUrl: _currentSpotifyUrl,
      youtubeUrl: _currentYoutubeUrl,
    );

    // Update State
    if (links.containsKey('spotify')) _currentSpotifyUrl = links['spotify'];
    if (links.containsKey('youtube')) _currentYoutubeUrl = links['youtube'];
    if (links.containsKey('appleMusic')) {
      _currentAppleMusicUrl = links['appleMusic'];
    }
    if (links.containsKey('deezer')) _currentDeezerUrl = links['deezer'];
    if (links.containsKey('tidal')) _currentTidalUrl = links['tidal'];
    if (links.containsKey('amazonMusic')) {
      _currentAmazonMusicUrl = links['amazonMusic'];
    }
    if (links.containsKey('napster')) _currentNapsterUrl = links['napster'];

    notifyListeners();

    // Update Notification/Audio Service
    if (_currentStation != null) {
      _audioHandler.updateMediaItem(
        MediaItem(
          id: _currentStation!.url,
          title: _currentTrack,
          artist: "$_currentArtist • $_currentGenre",
          album: _currentAlbum.isNotEmpty
              ? "$_currentAlbum • $_currentGenre"
              : _currentGenre,
          genre: _currentGenre,
          artUri: _currentAlbumArt != null
              ? Uri.parse(_currentAlbumArt!)
              : null,
          extras: {
            'url': _currentStation!.url,
            'spotifyUrl': _currentSpotifyUrl,
            'youtubeUrl': _currentYoutubeUrl,
            'appleMusicUrl': _currentAppleMusicUrl,
            'deezerUrl': _currentDeezerUrl,
            'tidalUrl': _currentTidalUrl,
            'amazonMusicUrl': _currentAmazonMusicUrl,
            'napsterUrl': _currentNapsterUrl,
          },
        ),
      );
    }
  }

  // --- Backup & Restore Logic ---

  String _backupFrequency = 'manual';
  String get backupFrequency => _backupFrequency;

  Future<void> _checkAutoBackup() async {
    // Wait for auth to settle
    await Future.delayed(const Duration(seconds: 2));

    final prefs = await SharedPreferences.getInstance();
    _backupFrequency = prefs.getString('backup_frequency') ?? 'manual';
    _lastBackupTs = prefs.getInt('last_backup_ts') ?? 0;
    _lastBackupType = prefs.getString('last_backup_type') ?? 'manual';
    notifyListeners();

    // Sync Workmanager Schedule
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      if (_backupFrequency == 'daily') {
        Workmanager().registerPeriodicTask(
          kAutoBackupTask,
          kAutoBackupTask,
          frequency: const Duration(hours: 24),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else if (_backupFrequency == 'weekly') {
        Workmanager().registerPeriodicTask(
          kAutoBackupTask,
          kAutoBackupTask,
          frequency: const Duration(days: 7),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else {
        Workmanager().cancelByUniqueName(kAutoBackupTask);
      }
    }

    if (!_backupService.isSignedIn) return;

    if (_backupFrequency == 'manual') return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - _lastBackupTs;

    bool due = false;
    if (_backupFrequency == 'daily' && diff > 86400000) due = true;
    if (_backupFrequency == 'weekly' && diff > 604800000) due = true;

    if (due) {
      await performBackup(isAuto: true);
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

  Future<void> performBackup({bool isAuto = false}) async {
    if (!_backupService.isSignedIn) return;

    _isBackingUp = true;
    notifyListeners();

    try {
      final data = {
        'stations': stations.map((s) => s.toJson()).toList(),
        'favorites': _favorites,
        'station_order': _stationOrder,
        'genre_order': _genreOrder,
        'category_order': _categoryOrder,
        'invalid_song_ids': _invalidSongIds,
        'playlists': _playlists.map((p) => p.toJson()).toList(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'version': 1,
        'type': isAuto ? 'auto' : 'manual',
      };

      await _backupService.uploadBackup(jsonEncode(data));

      final prefs = await SharedPreferences.getInstance();
      _lastBackupTs = DateTime.now().millisecondsSinceEpoch;
      _lastBackupType = isAuto ? 'auto' : 'manual';
      await prefs.setInt('last_backup_ts', _lastBackupTs);
      await prefs.setString('last_backup_type', _lastBackupType);
      notifyListeners();

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
      if (data['category_order'] != null) {
        _categoryOrder = (data['category_order'] as List)
            .map((e) => e as String)
            .toList();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_keyCategoryOrder, _categoryOrder);
      }

      // Restore Invalid Songs
      if (data['invalid_song_ids'] != null) {
        final List<String> loadedInvalid = (data['invalid_song_ids'] as List)
            .map((e) => e.toString())
            .toList();

        // Merge with existing
        for (var id in loadedInvalid) {
          if (!_invalidSongIds.contains(id)) {
            _invalidSongIds.add(id);
          }
        }

        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
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
      _hasPerformedRestore = true;
      await _saveHasPerformedRestore();
      notifyListeners();
    } catch (e) {
      if (e.toString().contains("No backup found")) {
        _hasPerformedRestore = true;
        await _saveHasPerformedRestore();
      }
      _addLog("Restore Failed: $e");
      rethrow;
    } finally {
      _isRestoring = false;
      notifyListeners();
    }
  }

  Future<void> setPreferYouTubeAudioOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    _preferYouTubeAudioOnly = value;
    await prefs.setBool(_keyPreferYouTubeAudioOnly, value);
    notifyListeners();
  }

  Future<void> _loadYouTubeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _preferYouTubeAudioOnly =
        prefs.getBool(_keyPreferYouTubeAudioOnly) ?? false;
  }

  Future<Map<String, String>> resolveLinks({
    required String title,
    required String artist,
    String? spotifyUrl,
    String? youtubeUrl,
  }) async {
    try {
      _lastSongLinkResponse = "Song Link: Fetching for '$title'...";
      notifyListeners();

      // Determine best source URL for SongLink
      String? sourceUrl;
      String? spotId;

      // 1. Try Spotify ID first
      if (spotifyUrl != null && spotifyUrl.contains('/track/')) {
        spotId = spotifyUrl.split('track/').last.split('?').first;
      }

      // 2. Fallback to full URLs
      // Filter out generic search URLs which SongLink likely can't handle
      if (spotifyUrl != null && !spotifyUrl.contains('/search')) {
        sourceUrl = spotifyUrl;
      }

      if (sourceUrl == null &&
          youtubeUrl != null &&
          !youtubeUrl.contains('search_query') &&
          !youtubeUrl.contains('/results')) {
        sourceUrl = youtubeUrl;
      }

      // 2b. EMERGENCY FALLBACK: iTunes Search
      // If we don't have a specific track link, use Title + Artist to find one via iTunes
      if (sourceUrl == null) {
        sourceUrl = await _fetchItunesUrl("$title $artist");
      }

      // Debug Log construction
      String debugLog = "--- SONG LINK CHECK (Manual) ---\n";
      debugLog += "1. Metadata: Title='$title', Artist='$artist'\n";
      debugLog +=
          "2. Initial URLs: Spotify='${spotifyUrl ?? 'null'}', Youtube='${youtubeUrl ?? 'null'}'\n";
      debugLog += "3. Extracted SpotID: '${spotId ?? 'null'}'\n";
      debugLog += "4. Selected Source URL: '${sourceUrl ?? 'null'}'\n";
      debugLog += "----------------------------\n\n";

      _lastSongLinkResponse = "${debugLog}Fetching API...";
      notifyListeners();

      final links = await _songLinkService.fetchLinks(
        spotifyId: spotId,
        url: sourceUrl,
        countryCode: _currentStation?.countryCode ?? 'IT',
      );

      // Log Capture
      String serviceLog = _songLinkService.lastRawJson;
      if (serviceLog.isEmpty) {
        serviceLog = jsonEncode(links);
      }
      _lastSongLinkResponse = debugLog + serviceLog;
      notifyListeners();

      return links;
    } catch (e) {
      if (_songLinkService.lastRawJson.isNotEmpty) {
        _lastSongLinkResponse = _songLinkService.lastRawJson;
      } else {
        _lastSongLinkResponse = "Error: $e";
      }
      notifyListeners();
      return {};
    }
  }

  Future<void> reloadPlaylists() async {
    _playlists = await _playlistService.loadPlaylists();
    notifyListeners();
  }

  Future<void> setCompactView(bool value) async {
    _isCompactView = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCompactView, value);
    notifyListeners();
  }

  void _markCurrentSongAsInvalid() {
    if (_audioOnlySongId != null) {
      if (!_invalidSongIds.contains(_audioOnlySongId!)) {
        _invalidSongIds.add(_audioOnlySongId!);
        notifyListeners();

        // Persist immediately
        SharedPreferences.getInstance().then((prefs) {
          prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
        });
      }
    }
  }

  void unmarkSongAsInvalid(String songId) {
    if (_invalidSongIds.contains(songId)) {
      _invalidSongIds.remove(songId);
      notifyListeners();

      // Persist immediately
      SharedPreferences.getInstance().then((prefs) {
        prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
      });
    }
  }
}
