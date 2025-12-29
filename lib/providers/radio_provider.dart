import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';

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
import '../services/log_service.dart';
import '../services/lyrics_service.dart';
import '../services/spotify_service.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:youtube_player_flutter/youtube_player_flutter.dart';

// ...

class RadioProvider with ChangeNotifier {
  List<Station> stations = [];
  static const String _keySavedStations = 'saved_stations';
  Timer? _metadataTimer;
  static const String _keyStartOption =
      'start_option'; // 'none', 'last', 'specific'
  static const String _keyStartupStationId = 'startup_station_id';
  static const String _keyLastPlayedStationId = 'last_played_station_id';
  static const String _keyCompactView = 'compact_view';
  static const String _keyShuffleMode = 'shuffle_mode';
  static const String _keyInvalidSongIds = 'invalid_song_ids';
  static const String _keyManageGridView = 'manage_grid_view';
  static const String _keyManageGroupingMode = 'manage_grouping_mode';

  bool _isImportingSpotify = false;
  double _spotifyImportProgress = 0;
  String? _spotifyImportName;

  bool get isImportingSpotify => _isImportingSpotify;
  double get spotifyImportProgress => _spotifyImportProgress;
  String? get spotifyImportName => _spotifyImportName;

  Future<void> _loadStations() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonStr = prefs.getString(_keySavedStations);

    final invalidIds = prefs.getStringList(_keyInvalidSongIds);
    if (invalidIds != null) {
      _invalidSongIds.clear();
      _invalidSongIds.addAll(invalidIds);
    }

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
    _setupAudioHandlerCallbacks(); // Ensure callbacks are set
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
      // Send ALL stations to the background handler (Android Auto)
      // This ensures Next/Prev buttons work for the entire list, not just favorites.
      _audioHandler.updateStations(stations);
    }
  }

  void refreshAudioHandlerPlaylists() {
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.refreshPlaylists();
    }
  }

  void _setupAudioHandlerCallbacks() {
    if (_audioHandler is RadioAudioHandler) {
      final handler = _audioHandler;
      handler.onSkipNext = () {
        if (_currentPlayingPlaylistId != null) {
          playNext(true);
        } else {
          playNextStationInFavorites();
        }
      };
      handler.onSkipPrevious = () {
        if (_currentPlayingPlaylistId != null) {
          playPrevious();
        } else {
          playPreviousStationInFavorites();
        }
      };
      handler.onPreloadNext = _preloadNextSong;
    }
  }

  Future<void> _preloadNextSong() async {
    // Only preload if we are in playlist mode using native player
    if (_currentPlayingPlaylistId == null) return;

    // Just find the next song
    final nextSong = _getNextSongInPlaylist();
    if (nextSong != null) {
      String? videoId;

      if (nextSong.youtubeUrl != null) {
        videoId = YoutubePlayer.convertUrlToId(nextSong.youtubeUrl!);
      } else if (nextSong.id.length == 11) {
        // Fallback ID
        videoId = nextSong.id;
      }

      // If still null, try to resolve via search (Heavy!)
      if (videoId == null) {
        try {
          final links = await resolveLinks(
            title: nextSong.title,
            artist: nextSong.artist,
            spotifyUrl: nextSong.spotifyUrl,
          ).timeout(const Duration(seconds: 8));

          final url = links['youtube'];
          if (url != null) {
            videoId = YoutubePlayer.convertUrlToId(url);
            if (videoId == null && url.contains('v=')) {
              videoId = url.split('v=').last.split('&').first;
            }
          }
        } catch (e) {
          // resolution failed silently
        }
      }

      if (videoId != null) {
        if (_audioHandler is RadioAudioHandler) {
          _audioHandler.preloadNextStream(videoId, nextSong.id);
        }
      }
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
  AudioHandler get audioHandler => _audioHandler;
  Timer? _youtubeKeepAliveTimer;
  final PlaylistService _playlistService = PlaylistService();
  final SongLinkService _songLinkService = SongLinkService();
  final MusicMetadataService _musicMetadataService = MusicMetadataService();
  final LyricsService _lyricsService = LyricsService();
  final SpotifyService _spotifyService = SpotifyService();
  SpotifyService get spotifyService => _spotifyService;

  List<Playlist> _playlists = [];
  List<Playlist> get playlists => _playlists;

  List<SavedSong> _allUniqueSongs = [];
  List<SavedSong> get allUniqueSongs => _allUniqueSongs;
  Playlist? _tempPlaylist;
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

  bool _isManageGridView = false;
  bool get isManageGridView => _isManageGridView;

  int _manageGroupingMode = 0; // 0: none, 1: genre, 2: origin
  int get manageGroupingMode => _manageGroupingMode;

  bool _isOffline = false; // Internal connectivity state

  RadioProvider(this._audioHandler, this._backupService) {
    // connectivity_plus listener
    Connectivity().onConnectivityChanged.listen((results) {
      final bool isNowOffline = results.contains(ConnectivityResult.none);
      // Detected change from Offline -> Online
      if (_isOffline && !isNowOffline) {
        LogService().log("Internet Restored: Attempting auto-resume...");
        _retryAfterConnectionRestored();
      }
      _isOffline = isNowOffline;
    });
    // Check initial state
    Connectivity().checkConnectivity().then((results) {
      _isOffline = results.contains(ConnectivityResult.none);
    });

    _backupService.addListener(notifyListeners);
    _playlistService.onPlaylistsUpdated.listen((_) => reloadPlaylists());
    _checkAutoBackup(); // Start check
    // Listen to playback state from AudioService
    _audioHandler.playbackState.listen((state) {
      bool playing = state.playing;

      // Handle External Pause (Notification interaction)
      if (_hiddenAudioController != null && !_ignoringPause) {
        if (!playing && _isPlaying) {
          _hiddenAudioController!.pause();
        } else if (playing && !_isPlaying) {
          // Re-sync YouTube state if notification was resumed
          _hiddenAudioController!.play();
        }
      }

      // Check for error message updates
      if (state.errorMessage != _errorMessage) {
        _errorMessage = state.errorMessage;
        notifyListeners();
      }

      if (_isPlaying != playing) {
        if (!_ignoringPause) {
          _isPlaying = playing;
          notifyListeners();
        }
      }

      // Sync loading state for Radio (when no YouTube controller is active)
      if (_hiddenAudioController == null) {
        final bool isBuffering =
            state.processingState == AudioProcessingState.buffering;
        final bool isReadyOrError =
            state.processingState == AudioProcessingState.ready ||
            state.processingState == AudioProcessingState.error;

        if (isBuffering && !_isLoading) {
          _isLoading = true;
          notifyListeners();
        } else if (isReadyOrError && _isLoading) {
          _isLoading = false;
          notifyListeners();
        }
      }
    });

    // Listen to media item updates to capture duration
    _audioHandler.mediaItem.listen((item) {
      if (item != null &&
          item.duration != null &&
          _currentPlayingPlaylistId != null &&
          _audioOnlySongId != null) {
        _updateCurrentSongDuration(item.duration!);
      }
    });

    // Listen to media item changes (if updated from outside or by handler, e.g. Android Auto)
    _audioHandler.mediaItem.listen((item) {
      if (item == null) return;

      // CRITICAL FIX: Detect Radio Mode Return
      // If we are playing a station, ensure we exit Playlist Mode immediately
      if (item.extras?['type'] == 'station' ||
          stations.any((s) => s.url == item.id)) {
        _currentPlayingPlaylistId = null;
      }

      // 1. Sync Metadata if it changed (within same station or from external source)
      bool metadataChanged = false;
      if (_currentTrack != item.title) {
        _currentTrack = item.title;
        metadataChanged = true;
      }
      if (_currentArtist != (item.artist ?? "")) {
        _currentArtist = item.artist ?? "";
        metadataChanged = true;
      }
      if (_currentAlbum != (item.album ?? "")) {
        _currentAlbum = item.album ?? "";
        metadataChanged = true;
      }
      if (_currentAlbumArt != item.artUri?.toString()) {
        _currentAlbumArt = item.artUri?.toString();
        metadataChanged = true;
      }

      if (metadataChanged) {
        // Trigger lyrics fetch and other updates
        fetchLyrics();
        notifyListeners();
      }

      // 2. Handle Station/Source Change
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
          _currentPlayingPlaylistId =
              null; // FORCE RESET: We are in Radio Mode now

          // If it was a station switch from outside but metadata was already handled above,
          // we might want to ensure track isn't reset to "Live Broadcast" if item has info.
          if (item.title == "Station" || item.title == newStation.name) {
            _currentTrack = "Live Broadcast";
            _currentArtist = "";
          }

          notifyListeners();
        } catch (_) {
          // Check if it is a playlist song request from Android Auto
          if (item.extras?['type'] == 'playlist_song') {
            final String? videoId = item.extras?['videoId'];
            final String? playlistId = item.extras?['playlistId'];
            final String? songId = item.extras?['songId'];

            if (videoId != null && songId != null) {
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

          // Check if it is a playlist command (Play All / Shuffle)
          if (item.extras?['type'] == 'playlist_cmd') {
            final String? playlistId = item.extras?['playlistId'];
            final String? cmd = item.extras?['cmd'];
            if (playlistId != null) {
              Future.microtask(() async {
                try {
                  final playlist = playlists.firstWhere(
                    (p) => p.id == playlistId,
                  );
                  if (playlist.songs.isEmpty) return;

                  if (cmd == 'shuffle') {
                    if (!_isShuffleMode) toggleShuffle();
                    // Play random
                    final random = Random();
                    final song =
                        playlist.songs[random.nextInt(playlist.songs.length)];
                    playPlaylistSong(song, playlistId);
                  } else {
                    // Play all (start from first)
                    if (_isShuffleMode) toggleShuffle();
                    playPlaylistSong(playlist.songs.first, playlistId);
                  }
                } catch (_) {}
              });
            }
          }
        }
      }
    });

    // Set initial volume if possible, or just default local
    setVolume(_volume);

    // Initialize Spotify
    _spotifyService.init().then((_) => notifyListeners());

    // Load persisted playlist
    _loadPlaylists();
    _loadStationOrder();
    _loadStartupSettings(); // Load this before stations
    _loadYouTubeSettings();
    _loadManageSettings();
    _loadStations();
  }

  Future<void> _loadManageSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isManageGridView = prefs.getBool(_keyManageGridView) ?? false;
    _manageGroupingMode = prefs.getInt(_keyManageGroupingMode) ?? 0;
    notifyListeners();
  }

  void playNextFavorite() {
    // Navigate through ALL stations, not just favorites
    final list = allStations;

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int nextIndex = 0;
    if (currentIndex != -1) {
      nextIndex = (currentIndex + 1) % list.length;
    }

    playStation(list[nextIndex]);
  }

  void playPreviousFavorite() {
    // Navigate through ALL stations, not just favorites
    final list = allStations;

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

  void playNextStationInFavorites() {
    List<Station> list = allStations
        .where((s) => _favorites.contains(s.id))
        .toList();
    if (list.isEmpty) list = allStations;

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int nextIndex = 0;
    if (currentIndex != -1) {
      nextIndex = (currentIndex + 1) % list.length;
    }

    playStation(list[nextIndex]);
  }

  void playPreviousStationInFavorites() {
    List<Station> list = allStations
        .where((s) => _favorites.contains(s.id))
        .toList();
    if (list.isEmpty) list = allStations;

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
    final result = await _playlistService.loadPlaylistsResult();
    _playlists = result.playlists;
    _allUniqueSongs = result.uniqueSongs;

    refreshAudioHandlerPlaylists(); // Force AA update
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
      duration: _audioHandler.mediaItem.value?.duration,
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

  Future<void> renamePlaylist(String id, String newName) async {
    await _playlistService.renamePlaylist(id, newName);
    await _loadPlaylists();
  }

  Future<void> reorderPlaylists(int oldIndex, int newIndex) async {
    await _playlistService.reorderPlaylists(oldIndex, newIndex);
    await _loadPlaylists();
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

  Future<void> removeSongFromLibrary(String songId) async {
    await _playlistService.removeSongFromAllPlaylists(songId);
    await _loadPlaylists();
  }

  Future<void> removeSongsFromLibrary(List<String> songIds) async {
    await _playlistService.removeSongsFromAllPlaylists(songIds);
    await _loadPlaylists();
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

  LyricsData _currentLyrics = LyricsData.empty();
  LyricsData get currentLyrics => _currentLyrics;
  bool _isFetchingLyrics = false;
  bool get isFetchingLyrics => _isFetchingLyrics;

  bool _isLoading = false;
  final List<String> _metadataLog = [];

  // Lyrics Synchronization Offset
  Duration _lyricsOffset = Duration.zero;
  Duration get lyricsOffset => _lyricsOffset;

  void setLyricsOffset(Duration offset) {
    _lyricsOffset = offset;
    notifyListeners();
  }

  // Track invalid songs
  final List<String> _invalidSongIds = [];
  List<String> get invalidSongIds => _invalidSongIds;

  bool get isLoading => _isLoading;
  bool _hasPerformedRestore = false;
  bool get hasPerformedRestore => _hasPerformedRestore;
  Timer? _playbackMonitor; // Robust backup for end-of-song detection
  Timer? _invalidDetectionTimer;

  Station? get currentStation => _currentStation;
  bool get isPlaying => _isPlaying;
  bool get isRecognizing => false;
  //   bool get isLoading => _isLoading; // duplicate removed
  double get volume => _volume;
  List<int> get favorites => _favorites;
  List<String> get metadataLog => _metadataLog;
  String _lastApiResponse = "No ACR response yet.";
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
  String? get currentSongId => _audioOnlySongId;

  bool _isShuffleMode = false;
  bool get isShuffleMode => _isShuffleMode;

  bool _isRepeatMode = true;
  bool get isRepeatMode => _isRepeatMode;

  bool _ignoringPause = false;

  // Shuffle Logic
  List<int> _shuffledIndices = [];

  List<SavedSong> get activeQueue {
    if (_currentPlayingPlaylistId == null) return [];

    Playlist playlist;
    if (_tempPlaylist != null &&
        _tempPlaylist!.id == _currentPlayingPlaylistId) {
      playlist = _tempPlaylist!;
    } else {
      playlist = playlists.firstWhere(
        (p) => p.id == _currentPlayingPlaylistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
    }

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

    Playlist playlist;
    if (_tempPlaylist != null &&
        _tempPlaylist!.id == _currentPlayingPlaylistId) {
      playlist = _tempPlaylist!;
    } else {
      playlist = playlists.firstWhere(
        (p) => p.id == _currentPlayingPlaylistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
    }

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

  Future<void> playAdHocPlaylist(Playlist playlist, String? startSongId) async {
    _tempPlaylist = playlist;
    _currentPlayingPlaylistId = playlist.id;

    if (playlist.songs.isEmpty) return;

    int startIndex = 0;
    if (startSongId != null) {
      final idx = playlist.songs.indexWhere((s) => s.id == startSongId);
      if (idx != -1) startIndex = idx;
    }

    SavedSong? songToPlay;
    // Find first valid song starting from requested index
    for (int i = startIndex; i < playlist.songs.length; i++) {
      final s = playlist.songs[i];
      if (s.isValid && !_invalidSongIds.contains(s.id)) {
        songToPlay = s;
        break;
      }
    }

    // Fallback: If no valid song found forward, or list empty
    if (songToPlay == null) {
      // Just try the requested one and let error handler deal with it
      // or try finding one from the beginning if we started mid-way?
      // Let's just try the startIndex one.
      if (startIndex < playlist.songs.length) {
        songToPlay = playlist.songs[startIndex];
      }
    }

    if (songToPlay != null) {
      await playPlaylistSong(songToPlay, playlist.id);
    }
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
    _invalidDetectionTimer?.cancel(); // CANCEL invalid detection timer
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
      List<Playlist> searchLists = [];
      if (playlistId != null) {
        if (_tempPlaylist != null && _tempPlaylist!.id == playlistId) {
          searchLists = [_tempPlaylist!];
        } else {
          searchLists = playlists.where((p) => p.id == playlistId).toList();
        }
      } else {
        searchLists = [...playlists];
        if (_tempPlaylist != null) searchLists.add(_tempPlaylist!);
      }

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
    // 2. NATIVE PLAYBACK (Anti-Standby Fix)
    // --------------------------------------------------------------------------------

    _isLoading = true;
    notifyListeners();

    try {
      // Race condition guard: Abort if song changed while fetching stream

      // Bypass blocking resolution in Provider - Let AudioHandler handle it (and use cache)
      // We pass the VideoId as the URI.
      await _audioHandler.playFromUri(Uri.parse(videoId), {
        'title': title,
        'artist': artist,
        'artUri': artwork,
        'album': album ?? "Playlist",
        'duration': null, // Will be updated by player
        'type': 'playlist_song',
        'playlistId': playlistId,
        'songId': songId,
        'videoId': videoId,
      });

      _audioOnlySongId = songId;
      _isPlaying = true;
      _isLoading = false;
      notifyListeners();

      // Clean up old controller if it exists
      if (_hiddenAudioController != null) {
        _hiddenAudioController!.removeListener(_youtubeListener);
        _hiddenAudioController!.dispose();
        _hiddenAudioController = null;
      }
      return; // Success!
    } catch (e) {
      debugPrint("Native YouTube playback failed, falling back: $e");
    }

    // --------------------------------------------------------------------------------
    // 3. FALLBACK: WEBVIEW (Legacy)
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
      }
    } else {
      // First launch loop
      _hiddenAudioController = YoutubePlayerController(
        initialVideoId: videoId,
        flags: const YoutubePlayerFlags(
          autoPlay: false,
          mute: false,
          enableCaption: false,
          hideControls: true,
          forceHD: false,
        ),
      );
      notifyListeners();

      // Increased delay: Ensure the Widget/WebView is fully integrated into the OS view hierarchy
      await Future.delayed(const Duration(milliseconds: 1500));

      // Retry loop for the first hand-shake
      int attempts = 0;
      while (attempts < 3) {
        _hiddenAudioController!.load(videoId);
        await Future.delayed(const Duration(milliseconds: 500));
        _hiddenAudioController!.play();

        // Check if it's moving or at least buffering
        await Future.delayed(const Duration(milliseconds: 1000));
        if (_hiddenAudioController!.value.isPlaying ||
            _hiddenAudioController!.value.playerState == PlayerState.playing ||
            _hiddenAudioController!.value.playerState ==
                PlayerState.buffering) {
          break;
        }
        attempts++;
      }
    }

    // --- RECOVERY TIMER ---
    // Background insurance: OS might try to pause the webview when screen turns off.
    _youtubeKeepAliveTimer?.cancel();
    _youtubeKeepAliveTimer = Timer.periodic(const Duration(seconds: 5), (
      timer,
    ) {
      if (_isPlaying && _hiddenAudioController != null) {
        final state = _hiddenAudioController!.value.playerState;
        if (state != PlayerState.playing &&
            state != PlayerState.buffering &&
            state != PlayerState.ended) {
          debugPrint("YouTube Keep-Alive: Forcing play...");
          _hiddenAudioController!.play();
        }
      } else if (!_isPlaying) {
        timer.cancel();
      }
    });

    // Ensure listener is attached (remove first to avoid duplicates)
    _hiddenAudioController!.removeListener(_youtubeListener);
    _hiddenAudioController!.addListener(_youtubeListener);

    _audioOnlySongId = songId;
    _isPlaying = true; // Ensure state is correct
    _isLoading = false;
    notifyListeners();

    // Start Monitor
    _startPlaybackMonitor();

    // Fetch lyrics for the song
    fetchLyrics();
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
                  if (_isOffline) {
                    // If offline, assume stall is due to network and just wait.
                    _lastMonitoredPositionTime =
                        null; // Reset timer to allow re-check later
                    return;
                  }

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

  void _retryAfterConnectionRestored() async {
    // 1. If we have a YouTube controller, try resume
    if (_hiddenAudioController != null) {
      if (_hiddenAudioController!.value.errorCode != 0) {
        _hiddenAudioController!.reload();
      } else {
        _hiddenAudioController!.play();
      }
    }

    // 2. Resume Native Playback (AudioHandler)
    if (_audioHandler.playbackState.value.processingState ==
            AudioProcessingState.error ||
        _audioHandler.playbackState.value.errorMessage ==
            "No Internet Connection") {
      _audioHandler.customAction('retryPlayback');
    }

    // 3. If we stalled during "Loading" (e.g. Resolution failed)
    if ((_isLoading || _errorMessage == "No Internet Connection") &&
        _currentPlayingPlaylistId != null &&
        _audioOnlySongId != null) {
      // Helper to find song
      SavedSong? targetSong;
      try {
        final p = playlists.firstWhere(
          (p) => p.id == _currentPlayingPlaylistId,
        );
        targetSong = p.songs.firstWhere((s) => s.id == _audioOnlySongId);
      } catch (_) {}

      if (targetSong != null) {
        LogService().log("Retrying playlist song: ${targetSong.title}");
        _isLoading = true;
        notifyListeners();
        playPlaylistSong(targetSong, _currentPlayingPlaylistId!);
      }
    }
  }

  void _youtubeListener() {
    if (_hiddenAudioController == null) return;

    final value = _hiddenAudioController!.value;
    final state = value.playerState;

    // 1. Explicit Error Check
    if (value.errorCode != 0) {
      if (_isOffline) {
        LogService().log(
          "Offline: Ignoring YouTube Error code ${value.errorCode}",
        );
        return;
      }
      LogService().log(
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
        if (diff.inSeconds > 5) {
          if (_isOffline) {
            LogService().log("Offline: Ignoring buffering stuck detected.");
            _lastProcessingTime = null;
            return;
          }
          LogService().log(
            "Playback Processing Timeout (>5s in $state). Marking invalid.",
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
                if (_isOffline) {
                  debugPrint("Offline: Ignoring zero duration.");
                  _zeroDurationStartTime = null;
                } else {
                  debugPrint(
                    "Song has had Zero Duration for >5s in Playing State. Marking invalid.",
                  );
                  _markCurrentSongAsInvalid();
                  playNext(false);
                  _zeroDurationStartTime = null;
                }
              }
            }
          } else {
            _zeroDurationStartTime = null;
          }
        } else {
          // Duration is valid
          _zeroDurationStartTime = null;
        }
      }
    }
    // 3. Sync Playing State
    if (state == PlayerState.playing || state == PlayerState.buffering) {
      if (!_isPlaying) {
        _isPlaying = true;
        notifyListeners();
      }
      // Clear loading if we are playing, buffering, or moving
      if (_isLoading ||
          (_hiddenAudioController!.value.position.inSeconds > 0)) {
        if (_isLoading) {
          _isLoading = false;
          notifyListeners();
        }
      }
    } else if (state == PlayerState.paused || state == PlayerState.cued) {
      // Treat 'cued' as effectively paused/stopped if it's not starting
      _zeroDurationStartTime = null;
      if (_isLoading) {
        _isLoading = false;
        notifyListeners();
      }
      if (_isPlaying) {
        _isPlaying = false;
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
    _youtubeKeepAliveTimer?.cancel();
    _youtubeKeepAliveTimer = null;
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

  void playStation(Station station) async {
    // If we're playing from a playlist (YouTube), stop it first
    if (_hiddenAudioController != null) {
      clearYoutubeAudio();
      _isShuffleMode = false;
    }

    // Ensure playlist mode is OFF so next/prev buttons work for Radio
    _currentPlayingPlaylistId = null;
    _audioOnlySongId = null;

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
        'user_initiated': true,
      });

      _isLoading = false;
      notifyListeners();
      // _addLog("Playing via Service");

      // Explicitly schedule recognition since playback state might not toggle
      // Explicitly schedule recognition for the new station
      // This is needed because if we switch stations while already playing,
      // the 'playing' state toggle listener won't fire.
      // _metadataTimer = Timer(const Duration(seconds: 5), _attemptRecognition); // FAZIO -- Intervallo ricerca musica via riconoscimento API

      // Fetch lyrics for the station (if names are already available)
      fetchLyrics();
    } catch (e) {
      _isLoading = false;
      // _addLog("Error: $e");
      notifyListeners();
    }
  }

  void togglePlay() {
    if (_hiddenAudioController != null) {
      _ignoringPause = true; // Guard against notification echo and state loop
      final state = _hiddenAudioController!.value.playerState;
      final bool currentlyPlaying =
          state == PlayerState.playing || state == PlayerState.buffering;

      if (currentlyPlaying) {
        _hiddenAudioController!.pause();
        _isPlaying = false;
        // Immediate sync to AudioHandler to avoid lag
        _audioHandler.customAction('updatePlaybackPosition', {
          'position': _hiddenAudioController!.value.position.inMilliseconds,
          'duration':
              _hiddenAudioController!.value.metaData.duration.inMilliseconds,
          'isPlaying': false,
        });
      } else {
        if (state == PlayerState.ended) {
          _hiddenAudioController!.seekTo(const Duration(seconds: 0));
        }
        _hiddenAudioController!.play();
        _isPlaying = true;
        // Immediate sync to AudioHandler
        _audioHandler.customAction('updatePlaybackPosition', {
          'position': _hiddenAudioController!.value.position.inMilliseconds,
          'duration':
              _hiddenAudioController!.value.metaData.duration.inMilliseconds,
          'isPlaying': true,
        });
      }
      notifyListeners();

      // Release guard after a short delay
      Future.delayed(const Duration(milliseconds: 600), () {
        _ignoringPause = false;
      });
      return;
    } else if (_currentPlayingPlaylistId != null) {
      // Native Playlist Mode
      if (_isPlaying) {
        pause();
      } else {
        resume();
      }
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
    if (_currentStation != null || _currentPlayingPlaylistId != null) {
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

  SavedSong? _getNextSongInPlaylist() {
    if (_currentPlayingPlaylistId == null) return null;

    Playlist playlist;
    if (_tempPlaylist != null &&
        _tempPlaylist!.id == _currentPlayingPlaylistId) {
      playlist = _tempPlaylist!;
    } else {
      playlist = playlists.firstWhere(
        (p) => p.id == _currentPlayingPlaylistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
    }
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
      // A song is valid if:
      // 1. It is not in the _invalidSongIds list (Legacy)
      // 2. Its .isValid flag is true
      // 3. Its duration is NOT zero (if known)
      if (!candidate.isValid || _invalidSongIds.contains(candidate.id)) {
        currentIndex = nextIndex;
        attempts++;
        continue;
      }
      return candidate;
    }

    return null; // All songs invalid or list empty
  }

  Future<void> _playNextInPlaylist({bool userInitiated = true}) async {
    final nextSong = _getNextSongInPlaylist();
    if (nextSong != null && _currentPlayingPlaylistId != null) {
      await playPlaylistSong(nextSong, _currentPlayingPlaylistId!);
    }
  }

  Future<void> _playPreviousInPlaylist() async {
    if (_currentPlayingPlaylistId == null || _audioOnlySongId == null) return;

    Playlist playlist;
    if (_tempPlaylist != null &&
        _tempPlaylist!.id == _currentPlayingPlaylistId) {
      playlist = _tempPlaylist!;
    } else {
      playlist = playlists.firstWhere(
        (p) => p.id == _currentPlayingPlaylistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
    }
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

  Future<void> playPlaylistSong(SavedSong song, String? playlistId) async {
    // Prevent playback of invalid songs
    if (!song.isValid || _invalidSongIds.contains(song.id)) {
      LogService().log("Skipping invalid song request: ${song.title}");
      _playNextInPlaylist();
      return;
    }
    // Optimistic UI update
    _currentTrack = song.title;
    _currentArtist = song.artist;
    _currentAlbum = song.album; // Optimistic Album
    _currentAlbumArt = song.artUri;
    _audioOnlySongId =
        song.id; // Also update ID so ID-based UI remains consistent

    String playlistName = "Playlist";
    if (playlistId != null) {
      try {
        final pl = playlists.firstWhere((p) => p.id == playlistId);
        playlistName = pl.name;
      } catch (_) {}
    }

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

    // Fetch lyrics for the playlist song
    fetchLyrics();

    _metadataTimer?.cancel(); // CANCEL recognition timer
    // _isLoading = true; // GAPLESS: Don't force loading state, let buffering event handle it
    _isPlaying = true; // Optimistically show pause icon
    notifyListeners();

    try {
      String? videoId;

      if (song.youtubeUrl != null) {
        videoId = YoutubePlayer.convertUrlToId(song.youtubeUrl!);
      }

      if (videoId == null) {
        final links = await resolveLinks(
          title: song.title,
          artist: song.artist,
          spotifyUrl: song.spotifyUrl,
          youtubeUrl: song.youtubeUrl,
        ).timeout(const Duration(seconds: 10));

        // Race condition guard after deep search
        if (_audioOnlySongId != song.id) return;

        final url = links['youtube'];
        if (url != null) {
          videoId = YoutubePlayer.convertUrlToId(url);
          // Fallback manual
          if (videoId == null && url.contains('v=')) {
            videoId = url.split('v=').last.split('&').first;
          }
        }
      }

      if (videoId != null) {
        // Clear loading after a maximum of 15 seconds regardless of state events
        final currentId = song.id;
        Future.delayed(const Duration(seconds: 15), () {
          if (_isLoading && _audioOnlySongId == currentId) {
            _isLoading = false;
            notifyListeners();
          }
        });

        // Race condition guard: If user clicked another song while resolving, abort
        if (_audioOnlySongId != song.id) {
          debugPrint(
            "playPlaylistSong: Song changed during resolution, aborting.",
          );
          return;
        }

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
        _isLoading = false;
        notifyListeners();

        // No Video ID found -> Invalid Song (Metadata issue)
        if (playlistId != null) {
          if (_isOffline) {
            LogService().log(
              "Offline: Cannot resolve video ID for ${song.title}. Waiting for connection...",
            );
            // We should probably show an error state or stop loading?
            _isLoading = false;
            // Resetting state effectively pauses/stops without erroring out to invalid
            notifyListeners();
            return;
          }

          LogService().log(
            "Marking song as invalid (No Video ID): ${song.title}",
          );
          await _playlistService.markSongAsInvalidGlobally(song.id);
          if (!_invalidSongIds.contains(song.id)) {
            _invalidSongIds.add(song.id);
            // Persist locally
            final prefs = await SharedPreferences.getInstance();
            await prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
          }

          // Also mark invalid in temp playlist if active
          if (_tempPlaylist != null) {
            final index = _tempPlaylist!.songs.indexWhere(
              (s) => s.id == song.id,
            );
            if (index != -1) {
              _tempPlaylist!.songs[index] = _tempPlaylist!.songs[index]
                  .copyWith(isValid: false);
            }
          }

          await Future.delayed(const Duration(seconds: 1));
          playNext(false);
        }
      }
    } catch (e) {
      _isLoading = false;
      notifyListeners();

      LogService().log("Error in playPlaylistSong: $e");

      // Check if error is network related
      final errStr = e.toString().toLowerCase();
      final isNetwork =
          errStr.contains('socket') ||
          errStr.contains('timeout') ||
          errStr.contains('handshake') ||
          errStr.contains('network') ||
          errStr.contains('lookup');

      if (!isNetwork && playlistId != null) {
        LogService().log("Marking song as invalid (Playback Error): $e");
        await _playlistService.markSongAsInvalidGlobally(song.id);
        if (!_invalidSongIds.contains(song.id)) {
          _invalidSongIds.add(song.id);
          // Persist locally
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
        }

        // Also mark invalid in temp playlist if active
        if (_tempPlaylist != null) {
          final index = _tempPlaylist!.songs.indexWhere((s) => s.id == song.id);
          if (index != -1) {
            _tempPlaylist!.songs[index] = _tempPlaylist!.songs[index].copyWith(
              isValid: false,
            );
          }
        }
      }

      if (playlistId != null) {
        await Future.delayed(const Duration(seconds: 1));
        playNext(false);
      }
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

  Future<void> fetchLyrics() async {
    if (_currentTrack == "Live Broadcast") {
      _currentLyrics = LyricsData.empty();
      _lyricsOffset = Duration.zero; // Reset offset
      notifyListeners();
      return;
    }

    _isFetchingLyrics = true;
    _currentLyrics = LyricsData.empty(); // Clear previous lyrics immediately
    _lyricsOffset = Duration.zero; // Reset offset
    notifyListeners();

    try {
      _currentLyrics = await _lyricsService.fetchLyrics(
        artist: _currentArtist,
        title: _currentTrack,
        album: _currentAlbum,
      );
    } catch (e) {
      _currentLyrics = LyricsData.empty();
    } finally {
      _isFetchingLyrics = false;
      notifyListeners();
    }
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

  Future<String?> _fetchItunesUrl(String query) async {
    try {
      final encodedOriginal = Uri.encodeComponent(query);
      final url = Uri.parse(
        'https://itunes.apple.com/search?term=$encodedOriginal&limit=1&media=music',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['resultCount'] > 0) {
          final result = data['results'][0];
          return result['trackViewUrl'] as String?;
        }
      }
    } catch (e) {
      debugPrint("iTunes Search Error: $e");
    }
    return null;
  }

  Future<void> reloadPlaylists() async {
    await _loadPlaylists();
  }

  Future<void> setCompactView(bool value) async {
    _isCompactView = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCompactView, value);
    notifyListeners();
  }

  Future<void> setManageGridView(bool value) async {
    _isManageGridView = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyManageGridView, value);
    notifyListeners();
  }

  Future<void> setManageGroupingMode(int value) async {
    _manageGroupingMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyManageGroupingMode, value);
    notifyListeners();
  }

  void _markCurrentSongAsInvalid() async {
    // Connectivity Check: Do NOT mark invalid if internet is down
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      LogService().log("Blocking 'Mark Invalid' - No Internet Connection");
      return;
    }

    if (_audioOnlySongId != null) {
      LogService().log("Marking Current Song Invalid: $_audioOnlySongId");
      if (!_invalidSongIds.contains(_audioOnlySongId!)) {
        _invalidSongIds.add(_audioOnlySongId!);
        LogService().log(
          "Added to invalidSongIds. Count: ${_invalidSongIds.length}",
        );

        // 1. Update In-Memory Playlists Immediately (Instant UI Feedback)
        bool memoryUpdated = false;
        for (var i = 0; i < _playlists.length; i++) {
          final p = _playlists[i];
          final index = p.songs.indexWhere((s) => s.id == _audioOnlySongId);
          if (index != -1) {
            final updatedSong = p.songs[index].copyWith(isValid: false);
            // We need to update the playlist in the list.
            // Since Playlist.songs is a List<SavedSong>, we can modify it if mutable,
            // or replace the Playlist object if immutable.
            // Assuming Playlist is immutable-ish but songs list is mutable?
            // Safer to replace the song in the list.
            p.songs[index] = updatedSong;
            memoryUpdated = true;
          }
        }
        if (memoryUpdated) {
          LogService().log("Updated _playlists in memory immediately.");
        }

        // 2. Notify UI immediately
        notifyListeners();

        // 3. Persist ID list
        SharedPreferences.getInstance().then((prefs) {
          prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
          LogService().log("Persisted invalidSongIds to Prefs");
        });

        // 4. Mark globally in DB (Async)
        _playlistService.markSongAsInvalidGlobally(_audioOnlySongId!).then((_) {
          LogService().log("Marked invalid globally via Service");
        });

        // 5. Update Temp Playlist
        if (_tempPlaylist != null) {
          final index = _tempPlaylist!.songs.indexWhere(
            (s) => s.id == _audioOnlySongId,
          );
          if (index != -1) {
            _tempPlaylist!.songs[index] = _tempPlaylist!.songs[index].copyWith(
              isValid: false,
            );
            LogService().log(
              "Updated _tempPlaylist in memory for index $index",
            );
          }
        }
      } else {
        LogService().log("Song ID $_audioOnlySongId already in invalidSongIds");
      }
    } else {
      LogService().log("Cannot mark invalid: _audioOnlySongId is null");
    }
  }

  Future<void> unmarkSongAsInvalid(String songId, {String? playlistId}) async {
    bool changed = false;
    if (_invalidSongIds.contains(songId)) {
      _invalidSongIds.remove(songId);
      changed = true;
      // Persist immediately
      SharedPreferences.getInstance().then((prefs) {
        prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
      });
    }

    // Always try to unmark globally, regardless of specific playlistId
    await _playlistService.unmarkSongAsInvalidGlobally(songId);
    await reloadPlaylists(); // Refresh local list

    // Also unmark in temp playlist if active
    if (_tempPlaylist != null) {
      final index = _tempPlaylist!.songs.indexWhere((s) => s.id == songId);
      if (index != -1) {
        _tempPlaylist!.songs[index] = _tempPlaylist!.songs[index].copyWith(
          isValid: true,
        );
      }
    }

    changed = true;

    if (changed) notifyListeners();
  }

  Future<void> _updateCurrentSongDuration(Duration duration) async {
    if (_currentPlayingPlaylistId == null || _audioOnlySongId == null) return;

    // Check if we need to update
    final playlist = playlists.firstWhere(
      (p) => p.id == _currentPlayingPlaylistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    final songIndex = playlist.songs.indexWhere(
      (s) => s.id == _audioOnlySongId,
    );

    if (songIndex != -1) {
      final song = playlist.songs[songIndex];
      // Only update if missing or zero
      if (song.duration == null || song.duration == Duration.zero) {
        // Double check duration is valid
        if (duration > Duration.zero) {
          LogService().log("Updating duration for ${song.title} to $duration");
          await _playlistService.updateSongDuration(
            _currentPlayingPlaylistId!,
            _audioOnlySongId!,
            duration,
          );
          // Auto-reload handled by listener
        } else {
          LogService().log("Failed to update duration for ${song.title}");
        }
      }
    }
  }

  // Spotify Auth methods
  Future<bool> spotifyHandleAuthCode(String code) async {
    final success = await _spotifyService.handleAuthCode(code);
    if (success) notifyListeners();
    return success;
  }

  Future<void> spotifyLogout() async {
    await _spotifyService.logout();
    notifyListeners();
  }

  Future<bool> importSpotifyPlaylist(
    String name,
    String spotifyId, {
    int? total,
  }) async {
    _isImportingSpotify = true;
    _spotifyImportProgress = 0;
    _spotifyImportName = name;
    notifyListeners();

    try {
      final tracks = await _spotifyService.getPlaylistTracks(
        spotifyId,
        total: total,
        onProgress: (p) {
          _spotifyImportProgress = p * 0.8;
          notifyListeners();
        },
      );

      if (tracks.isNotEmpty) {
        _spotifyImportProgress = 0.85;
        notifyListeners();

        final playlistId = "spotify_$spotifyId";
        final List<String> targetIds = [playlistId];
        final Map<String, String> targetNames = {playlistId: name};

        if (spotifyId == 'liked_songs') {
          targetIds.add('favorites');
          targetNames['favorites'] = 'Favorites';
        }

        await _playlistService.restoreSongsToMultiplePlaylists(
          targetIds,
          tracks,
          playlistNames: targetNames,
        );

        _spotifyImportProgress = 0.95;
        notifyListeners();

        await reloadPlaylists();

        _spotifyImportProgress = 1.0;
        notifyListeners();
        return true;
      }
      return false;
    } finally {
      _isImportingSpotify = false;
      notifyListeners();
    }
  }
}
