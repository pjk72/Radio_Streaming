import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/station.dart';

import '../models/saved_song.dart';
import '../models/playlist.dart';
import '../services/playlist_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/radio_audio_handler.dart'; // Import for casting
import 'package:workmanager/workmanager.dart';
import '../services/background_tasks.dart';
import '../services/backup_service.dart';
import '../services/acr_cloud_service.dart';
import '../utils/genre_mapper.dart';
import '../services/song_link_service.dart';
import '../services/music_metadata_service.dart';
import '../services/log_service.dart';
import '../services/lyrics_service.dart';
import '../services/spotify_service.dart';
import '../services/entitlement_service.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt_explode;
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/upgrade_proposal.dart';
import '../services/local_playlist_service.dart';

// ...

class RadioProvider with ChangeNotifier {
  List<Station> stations = [];
  static const String _keySavedStations = 'saved_stations';
  Timer? _metadataTimer;

  // --- Song Duration Tracking (ACRCloud) ---
  Duration? _currentSongDuration;
  Duration? _initialSongOffset;
  DateTime? _songSyncTime;

  Duration? get currentSongDuration => _currentSongDuration;
  Duration get currentSongPosition {
    if (_songSyncTime == null || _initialSongOffset == null) {
      return Duration.zero;
    }
    final elapsed = DateTime.now().difference(_songSyncTime!);
    final pos = _initialSongOffset! + elapsed;
    // Don't go beyond duration if we have it
    if (_currentSongDuration != null && pos > _currentSongDuration!) {
      return _currentSongDuration!;
    }
    return pos;
  }

  static const String _keyStartOption =
      'start_option'; // 'none', 'last', 'specific'
  static const String _keyStartupStationId = 'startup_station_id';
  static const String _keyLastPlayedStationId = 'last_played_station_id';
  static const String _keyCompactView = 'compact_view';
  static const String _keyShuffleMode = 'shuffle_mode';
  static const String _keyInvalidSongIds = 'invalid_song_ids';
  static const String _keyManageGridView = 'manage_grid_view';
  static const String _keyManageGroupingMode = 'manage_grouping_mode';
  static const String _keyPlaylistCreatorFilter = 'playlist_creator_filter';
  static const String _keyFollowedArtists = 'followed_artists';
  static const String _keyFollowedAlbums = 'followed_albums';
  static const String _keyArtistImagesCache = 'artist_images_cache';

  final Set<String> _followedArtists = {};
  final Set<String> _followedAlbums = {};

  bool _currentSongIsSaved = false;
  bool get currentSongIsSaved => _currentSongIsSaved;

  bool _isImportingSpotify = false;
  double _spotifyImportProgress = 0;
  String? _spotifyImportName;
  bool _isRecognizing = false;

  bool _showGlobalBanner = true;

  bool get isImportingSpotify => _isImportingSpotify;
  double get spotifyImportProgress => _spotifyImportProgress;
  String? get spotifyImportName => _spotifyImportName;
  bool get isRecognizing => _isRecognizing;
  bool get showGlobalBanner => _showGlobalBanner;

  void setShowGlobalBanner(bool value) {
    if (_showGlobalBanner != value) {
      _showGlobalBanner = value;
      notifyListeners();
    }
  }

  List<String> get followedArtists => _followedArtists.toList();
  List<String> get followedAlbums => _followedAlbums.toList();

  bool isArtistFollowed(String artist) => _followedArtists.contains(artist);
  bool isAlbumFollowed(String album) => _followedAlbums.contains(album);

  void _onUserStatusChanged() {
    final email = _backupService.currentUser?.email.toLowerCase();
    final isDevUser =
        email ==
        utf8
            .decode(base64.decode("b3JhemlvLmZhemlvQGdtYWlsLmNvbQ=="))
            .toLowerCase();

    SharedPreferences.getInstance().then((prefs) {
      if (email != null) {
        prefs.setString('user_email', email);
        // Force reset ONLY for authenticated non-dev users
        if (!isDevUser) {
          _isACRCloudEnabled = false;
          prefs.setBool(_keyEnableACRCloud, false);
          if (_audioHandler is RadioAudioHandler) {
            _audioHandler.setACRCloudEnabled(false);
          }
        }
      } else {
        prefs.remove('user_email');
      }
    });

    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.setDevUser(isDevUser);
      if (email != null && !isDevUser) {
        _audioHandler.setACRCloudEnabled(false);
      }
    }
    notifyListeners();
  }

  Future<void> _loadStations() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonStr = prefs.getString(_keySavedStations);

    final invalidIds = prefs.getStringList(_keyInvalidSongIds);
    if (invalidIds != null) {
      _invalidSongIds.clear();
      _invalidSongIds.addAll(invalidIds);
    }

    final savedArtists = prefs.getStringList(_keyFollowedArtists);
    if (savedArtists != null) {
      _followedArtists.clear();
      _followedArtists.addAll(savedArtists);
    }

    final savedAlbums = prefs.getStringList(_keyFollowedAlbums);
    if (savedAlbums != null) {
      _followedAlbums.clear();
      _followedAlbums.addAll(savedAlbums);
    }

    if (jsonStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        stations = decoded.map((e) => Station.fromJson(e)).toList();
        notifyListeners();
      } catch (e) {
        // Fallback if parse error
        stations = [];
        _saveStations(); // Reset corrupt data
      }
    } else {
      // First run: use default
      stations = [];
      _saveStations();
    }

    // --- APPLY SORTING LOGIC (Match RadioAudioHandler) ---
    // 1. Load Order locally to ensure synchronous sort
    final List<String>? orderStr = prefs.getStringList('station_order');
    List<int> order = [];
    if (orderStr != null) {
      order = orderStr
          .map((e) => int.tryParse(e) ?? -1)
          .where((e) => e != -1)
          .toList();
    }

    // 2. Determine Category Ranks
    final Map<String, int> categoryRank = {};
    int currentRank = 0;
    final Map<int, Station> stationMap = {for (var s in stations) s.id: s};

    for (var id in order) {
      final station = stationMap[id];
      if (station != null) {
        final cat = station.category;
        if (!categoryRank.containsKey(cat)) {
          categoryRank[cat] = currentRank++;
        }
      }
    }

    // 3. Multi-Level Sort
    stations.sort((a, b) {
      String catA = a.category;
      String catB = b.category;

      int rankA = categoryRank[catA] ?? 9999;
      int rankB = categoryRank[catB] ?? 9999;

      if (rankA != rankB) return rankA.compareTo(rankB);

      if (rankA == 9999) {
        int alpha = catA.compareTo(catB);
        if (alpha != 0) return alpha;
      }

      int idxA = order.indexOf(a.id);
      int idxB = order.indexOf(b.id);
      if (idxA == -1) idxA = 9999;
      if (idxB == -1) idxB = 9999;

      return idxA.compareTo(idxB);
    });
    // --- END SORTING ---

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

  bool _isPreloading = false;
  Future<void> _preloadNextSong() async {
    // Only preload if we are in playlist mode using native player
    if (_currentPlayingPlaylistId == null || _isPreloading) return;

    // Just find the next song
    final nextSong = _getNextSongInPlaylist();
    if (nextSong != null) {
      _isPreloading = true;
      try {
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
            await _audioHandler.preloadNextStream(videoId, nextSong.id);
          }
        }
      } finally {
        _isPreloading = false;
      }
    }
  }

  Future<void> addStation(Station s) async {
    stations.add(s);
    // Explicitly add to order list to ensure it exists for reordering immediately
    if (!_stationOrder.contains(s.id)) {
      _stationOrder.add(s.id);
      // We don't necessarily need to persist order immediately unless we want to be safe.
      // Saving stations already persists the station data.
      // But preserving order is good.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _keyStationOrder,
        _stationOrder.map((e) => e.toString()).toList(),
      );
    }
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

  // --- Auto-Skip Circuit Breaker ---
  int _autoSkipCount = 0;

  final AudioHandler _audioHandler;
  final EntitlementService _entitlementService;
  AudioHandler get audioHandler => _audioHandler;
  Timer? _youtubeKeepAliveTimer;
  final PlaylistService _playlistService = PlaylistService();
  final SongLinkService _songLinkService = SongLinkService();
  final MusicMetadataService _musicMetadataService = MusicMetadataService();
  final LyricsService _lyricsService = LyricsService();
  final SpotifyService _spotifyService = SpotifyService();
  SpotifyService get spotifyService => _spotifyService;
  final ACRCloudService _acrCloudService = ACRCloudService();
  final LocalPlaylistService _localPlaylistService = LocalPlaylistService();

  List<Playlist> _playlists = [];

  List<Playlist> get playlists => _playlists;

  List<SavedSong> _allUniqueSongs = [];
  List<SavedSong> get allUniqueSongs => _allUniqueSongs;

  /// Returns the total number of unique songs currently downloaded (including local media)
  int get totalDownloadedSongs {
    final Set<String> downloadedIds = {};
    for (var playlist in _playlists) {
      for (var song in playlist.songs) {
        if (song.isDownloaded) {
          downloadedIds.add(song.id);
        }
      }
    }
    return downloadedIds.length;
  }

  Playlist? _tempPlaylist;
  DateTime? _lastPlayNextTime;
  DateTime? _lastPlayPreviousTime;
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

  List<String> _playlistCreatorFilter = []; // Empty = Show All
  List<String> get playlistCreatorFilter => _playlistCreatorFilter;

  // Filtered Playlists Getter
  List<Playlist> get filteredPlaylists {
    final List<Playlist> baseList = playlists;
    if (_playlistCreatorFilter.isEmpty) return baseList;
    return baseList.where((p) {
      if (_playlistCreatorFilter.contains('all')) return true;

      // Determine creator type
      String type = p.creator;
      // Handle legacy/edge cases
      if (p.id.startsWith('spotify_'))
        type = 'spotify';
      else if (p.id == 'favorites')
        type = 'app';

      final canUseSpotify = _entitlementService.isFeatureEnabled(
        'spotify_integration',
      );
      if (type == 'spotify' && !canUseSpotify) return false;

      final canUseLocal = _entitlementService.isFeatureEnabled('local_library');
      if (type == 'local' && !canUseLocal) return false;

      return _playlistCreatorFilter.contains(type);
    }).toList();
  }

  Future<void> toggleFollowArtist(String artist) async {
    if (_followedArtists.contains(artist)) {
      _followedArtists.remove(artist);
    } else {
      _followedArtists.add(artist);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyFollowedArtists, _followedArtists.toList());
  }

  Future<void> toggleFollowAlbum(String album) async {
    if (_followedAlbums.contains(album)) {
      _followedAlbums.remove(album);
    } else {
      _followedAlbums.add(album);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyFollowedAlbums, _followedAlbums.toList());
  }

  Future<void> bulkToggleFavoriteSongs(
    List<SavedSong> songs,
    bool favorite,
  ) async {
    if (songs.isEmpty) return;

    if (favorite) {
      await addSongsToPlaylist('favorites', songs);
    } else {
      final ids = songs.map((s) => s.id).toList();
      await removeSongsFromPlaylist('favorites', ids);
    }
  }

  bool _isOffline = false; // Internal connectivity state

  RadioProvider(
    this._audioHandler,
    this._backupService,
    this._entitlementService,
  ) {
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

    _backupService.addListener(_onUserStatusChanged);
    _onUserStatusChanged(); // Initial sync

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

      // Sync Shuffle Mode from System/Notification
      // Only sync if we are in Playlist Mode.
      // AudioHandler forces shuffleMode=none for Radio, which would incorrectly wipe our preference if we didn't check.
      if (_currentPlayingPlaylistId != null || _hiddenAudioController != null) {
        final bool isShuffle = state.shuffleMode == AudioServiceShuffleMode.all;
        if (_isShuffleMode != isShuffle) {
          _isShuffleMode = isShuffle;
          if (_isShuffleMode && _currentPlayingPlaylistId != null) {
            _generateShuffleList();
          } else {
            _shuffledIndices.clear();
          }
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
          _metadataTimer?.cancel(); // Cancel any pending recognition
          notifyListeners();
        } else if (isReadyOrError && _isLoading) {
          _isLoading = false;
          if (state.processingState == AudioProcessingState.ready) {
            // STREAMING STARTED: Now we can start the 5 second countdown for lyrics
            if (_currentTrackStartTime == null) {
              _currentTrackStartTime = DateTime.now();
              fetchLyrics(); // Re-trigger search with the updated start time
            }
          }
          notifyListeners();

          // Wait for loading to finish before identifying song
          if (state.processingState == AudioProcessingState.ready &&
              _currentStation != null &&
              _currentPlayingPlaylistId == null) {
            _metadataTimer?.cancel();
            // Delay recognition by 2 seconds using Timer for cancellability
            _metadataTimer = Timer(const Duration(seconds: 5), () {
              // Ensure we are still playing the radio and not loading
              if (_isPlaying &&
                  !_isLoading &&
                  _currentPlayingPlaylistId == null) {
                // Double check if ACRCloud is enabled
                if (_isACRCloudEnabled &&
                    _entitlementService.isFeatureEnabled('song_recognition')) {
                  LogService().log("Attempting Recognition...1");
                  _attemptRecognition();
                }
              }
            });
          }
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

      // Sync Local Path if available in extras
      final String? itemLocalPath = item.extras?['localPath'];
      if (_currentLocalPath != itemLocalPath) {
        _currentLocalPath = itemLocalPath;
        metadataChanged = true;
      }

      if (metadataChanged) {
        // Only set start time if we are already in 'ready' state.
        // If we are buffering/loading, leave it null so playback listener can trigger it when ready.
        final processingState =
            _audioHandler.playbackState.value.processingState;
        if (processingState == AudioProcessingState.ready) {
          _currentTrackStartTime = DateTime.now();
        } else {
          _currentTrackStartTime = null;
        }

        // Trigger lyrics fetch and other updates
        fetchLyrics();
        checkIfCurrentSongIsSaved(); // Update save status for the new track
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

    // Load persisted data
    _loadStationOrder();
    _loadStartupSettings();
    _loadYouTubeSettings();
    _loadManageSettings();
    _loadPlaylistCreatorFilter();
    _loadArtistImagesCache();
    _loadStations();

    _loadPlaylists().then((_) {
      // Start background scan for local duplicates after data is ready
      Future.delayed(const Duration(seconds: 3), _scanForLocalUpgrades);
    });
  }

  // --- Upgrade Proposals (Duplicate Detection) ---
  List<UpgradeProposal> _upgradeProposals = [];
  List<UpgradeProposal> get upgradeProposals => _upgradeProposals;

  final OnAudioQuery _audioQuery = OnAudioQuery();

  Future<void> _scanForLocalUpgrades() async {
    LogService().log("Starting Scan for Local Upgrades...");
    if (kIsWeb) return;

    // Check permissions silently first
    if (Platform.isAndroid) {
      if (await Permission.audio.isGranted ||
          await Permission.storage.isGranted) {
        // Permission granted, proceed
      } else {
        // Just return, don't nag user on startup if they haven't granted yet.
        // Or strictly, we could try to request if we want to be aggressive,
        // but "background check" implies non-intrusive.
        // However, if the user *wants* this, they probably gave permission.
        // Let's check status.
        final status = await Permission.audio.status;
        if (!status.isGranted) return;
      }
    }

    try {
      final localSongs = await _audioQuery.querySongs(
        sortType: null,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );

      if (localSongs.isEmpty) return;

      // Normalize helper
      String normalize(String s) {
        return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
      }

      final List<UpgradeProposal> newProposals = [];
      final uniqueProposalIds =
          <String>{}; // prevent duplicates in proposal list

      for (var playlist in _playlists) {
        for (var song in playlist.songs) {
          // Skip if already local
          if (song.localPath != null || song.id.startsWith('local_')) continue;

          // Simple match
          final sTitle = normalize(song.title);
          final sArtist = normalize(song.artist);

          if (sTitle.isEmpty) continue;

          for (var local in localSongs) {
            final lTitle = normalize(local.title);
            final lArtist = normalize(local.artist ?? '');

            // Heuristic: Exact match of simplified strings
            // Check title match AND (artist match OR artist is unknown/empty in one side)
            // Stricter: Require artist match if artist exists
            bool artistMatch = false;
            if (sArtist.isNotEmpty && lArtist.isNotEmpty) {
              artistMatch =
                  sArtist.contains(lArtist) || lArtist.contains(sArtist);
            } else {
              // Permissive matching: If one side is missing artist info,
              // we allow a match based on title alone if it's an exact match.
              artistMatch = true;
            }

            if (artistMatch && (lTitle == sTitle || lTitle.contains(sTitle))) {
              if (uniqueProposalIds.add("${playlist.id}_${song.id}")) {
                newProposals.add(
                  UpgradeProposal(
                    playlistId: playlist.id,
                    songId: song.id,
                    songTitle: song.title,
                    songArtist: song.artist,
                    songAlbum: song.album,
                    localPath: local.data,
                    localId: local.id,
                  ),
                );
              }
              break; // Found a match for this song, move to next song
            }
          }
        }
      }

      if (newProposals.isNotEmpty) {
        _upgradeProposals = newProposals;
        notifyListeners();
        LogService().log(
          "Found ${newProposals.length} local upgrades available.",
        );
      }
    } catch (e) {
      LogService().log("Error scanning for local upgrades: $e");
    }
  }

  Future<void> applyUpgrades(List<UpgradeProposal> toApply) async {
    if (toApply.isEmpty) return;

    for (var proposal in toApply) {
      // Get playlist
      final index = _playlists.indexWhere((p) => p.id == proposal.playlistId);
      if (index == -1) continue;

      final songIndex = _playlists[index].songs.indexWhere(
        (s) => s.id == proposal.songId,
      );
      if (songIndex == -1) continue;

      // Update Song
      final original = _playlists[index].songs[songIndex];
      final updated = original.copyWith(
        localPath: proposal.localPath,
        // We keep the original metadata (Title/Artist) as source of truth if user liked it,
        // OR we could update it to match file.
        // User said "sostituendo la canzone online con quello offline".
        // keeping metadata is usually safer for UI consistency, but valid local path enables offline play.
        // We definitely set localPath.
        // We might want to set isValid=true if it was invalid.
        isValid: true,
      );

      _playlists[index].songs[songIndex] = updated;
    }

    await _playlistService.saveAll(_playlists);
    _upgradeProposals.clear();
    notifyListeners();
  }

  Future<void> _loadArtistImagesCache() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonStr = prefs.getString(_keyArtistImagesCache);
    if (jsonStr != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(jsonStr);
        decoded.forEach((key, value) {
          _artistImageCache[key] = value as String?;
        });
      } catch (e) {
        LogService().log("Error loading artist image cache: $e");
      }
    }
  }

  Future<void> _saveArtistImagesCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyArtistImagesCache, jsonEncode(_artistImageCache));
  }

  Future<void> _loadPlaylistCreatorFilter() async {
    final prefs = await SharedPreferences.getInstance();
    _playlistCreatorFilter =
        prefs.getStringList(_keyPlaylistCreatorFilter) ?? [];
    notifyListeners();
  }

  Future<void> togglePlaylistCreatorFilter(String type) async {
    if (_playlistCreatorFilter.contains(type)) {
      _playlistCreatorFilter.remove(type);
    } else {
      _playlistCreatorFilter.add(type);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyPlaylistCreatorFilter,
      _playlistCreatorFilter,
    );
    notifyListeners();
  }

  Future<void> clearPlaylistCreatorFilter() async {
    _playlistCreatorFilter.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPlaylistCreatorFilter);
    notifyListeners();
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

  bool _isSyncingDownloads = false;

  Future<void> _loadPlaylists() async {
    final result = await _playlistService.loadPlaylistsResult();
    _playlists = result.playlists;
    _allUniqueSongs = result.uniqueSongs;

    // Proactive Sync: Ensure all duplicates share download status
    if (!_isSyncingDownloads) {
      _isSyncingDownloads = true;
      try {
        await syncAllDownloadStatuses();
      } finally {
        _isSyncingDownloads = false;
      }
    }

    refreshAudioHandlerPlaylists(); // Force AA update
    checkIfCurrentSongIsSaved();
    notifyListeners();
  }

  Future<Playlist> createPlaylist(String name, {List<SavedSong>? songs}) async {
    final newPlaylist = await _playlistService.createPlaylist(
      name,
      songs: songs,
    );
    await _loadPlaylists(); // Refresh local list
    return newPlaylist;
  }

  Future<void> deletePlaylist(String id) async {
    // 1. Collect paths of downloaded songs in this playlist before deletion
    final playlist = _playlists.firstWhere(
      (p) => p.id == id,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    final List<String> potentialPathsToDelete = playlist.songs
        .where((s) => s.isDownloaded)
        .map((s) => s.localPath!)
        .toList();

    await _playlistService.deletePlaylist(id);
    await _loadPlaylists();

    if (potentialPathsToDelete.isNotEmpty) {
      await _cleanupUnreferencedFiles(potentialPathsToDelete);
    }
  }

  Future<String?> addToPlaylist(String? playlistId) async {
    if (_currentTrack == "Live Broadcast") return null;

    // Sanitize album name: remove station name etc.
    String cleanAlbum = _currentAlbum;
    final stationName = _currentStation?.name ?? "";
    if (stationName.isNotEmpty && cleanAlbum.contains(stationName)) {
      cleanAlbum = cleanAlbum
          .replaceAll(stationName, "")
          .replaceAll("•", "")
          .trim();
    }

    // Create Song Object
    final song = SavedSong(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: _currentTrack,
      artist: _currentArtist,
      album: cleanAlbum,
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
    if (playlistId.startsWith('local_')) return null;
    await _playlistService.addSongToPlaylist(playlistId, song);
    await _loadPlaylists();

    // Find name for return value
    final p = playlists.firstWhere(
      (p) => p.id == playlistId,
      orElse: () => playlists.first, // Fallback safe
    );
    return p.name;
  }

  Future<void> addSongToPlaylist(String playlistId, SavedSong song) async {
    if (playlistId.startsWith('local_')) return;
    await _playlistService.addSongToPlaylist(playlistId, song);
    await _loadPlaylists();
  }

  Future<void> updateSongInPlaylist(String playlistId, SavedSong song) async {
    await updateSongsInPlaylist(playlistId, [song]);
  }

  Future<void> updateSongsInPlaylist(
    String playlistId,
    List<SavedSong> songs,
  ) async {
    if (playlistId.startsWith('local_')) return;
    await _playlistService.updateSongsInPlaylist(playlistId, songs);
    await _loadPlaylists();
  }

  /// Normalizes a string for song matching by removing non-alphanumeric chars,
  /// extra whitespace, and common suffixes in brackets/parentheses.
  String _normalizeForMatching(String s) {
    String res = s.toLowerCase();
    // Remove content within parentheses/brackets (e.g. "(Official Video)", "[Remastered]")
    res = res.replaceAll(RegExp(r'\([^)]*\)'), '');
    res = res.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    // Remove all non-alphanumeric
    res = res.replaceAll(RegExp(r'[^\w\d]'), '');
    return res.trim();
  }

  Future<void> updateSongDownloadStatusGlobally(
    SavedSong downloadedSong,
  ) async {
    bool changed = false;

    final targetTitle = _normalizeForMatching(downloadedSong.title);
    final targetArtist = _normalizeForMatching(downloadedSong.artist);

    if (targetTitle.isEmpty) return;

    for (int i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      if (playlist.creator == 'local') continue;

      bool playlistChanged = false;
      final updatedSongsInPlaylist = List<SavedSong>.from(playlist.songs);
      for (int j = 0; j < updatedSongsInPlaylist.length; j++) {
        final song = updatedSongsInPlaylist[j];

        // Match by exact ID or normalized Title + Artist
        bool isMatch = song.id == downloadedSong.id;
        if (!isMatch) {
          isMatch =
              _normalizeForMatching(song.title) == targetTitle &&
              _normalizeForMatching(song.artist) == targetArtist;
        }

        if (isMatch) {
          if (song.localPath != downloadedSong.localPath) {
            LogService().log(
              "Sync: Found match for '${song.title}' in playlist '${playlist.name}'. Updating status.",
            );
            updatedSongsInPlaylist[j] = song.copyWith(
              localPath: downloadedSong.localPath,
              forceClearLocalPath: downloadedSong.localPath == null,
              youtubeUrl: downloadedSong.youtubeUrl?.isNotEmpty == true
                  ? downloadedSong.youtubeUrl
                  : song.youtubeUrl,
              isValid: downloadedSong.isValid,
            );
            playlistChanged = true;
          }
        }
      }
      if (playlistChanged) {
        _playlists[i] = playlist.copyWith(songs: updatedSongsInPlaylist);
        changed = true;
      }
    }

    if (changed) {
      await _playlistService.saveAll(_playlists);
      await _loadPlaylists(); // REFRESH ALL STATE (including unique songs)
    }
  }

  /// Scans the entire library and ensures all occurrences of the same song
  /// share the same localPath if at least one of them is downloaded.
  Future<void> syncAllDownloadStatuses() async {
    final Map<String, String> bestPaths = {}; // "artist|title" -> path

    String combinedKey(String a, String t) =>
        "${_normalizeForMatching(a)}|${_normalizeForMatching(t)}";

    // 1. Collect best paths
    for (var p in _playlists) {
      for (var s in p.songs) {
        if (s.localPath != null && s.localPath!.isNotEmpty) {
          final k = combinedKey(s.artist, s.title);
          if (k.length < 3) continue; // Skip very short/empty keys

          // Prefer app-managed paths (.mst / _secure)
          if (!bestPaths.containsKey(k) ||
              s.localPath!.endsWith('.mst') ||
              s.localPath!.contains('_secure')) {
            bestPaths[k] = s.localPath!;
          }
        }
      }
    }

    if (bestPaths.isEmpty) return;

    bool overallChanged = false;
    for (int i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      if (playlist.creator == 'local') continue;

      bool playlistChanged = false;
      final updatedSongs = List<SavedSong>.from(playlist.songs);
      for (int j = 0; j < updatedSongs.length; j++) {
        final s = updatedSongs[j];
        final k = combinedKey(s.artist, s.title);
        if (bestPaths.containsKey(k) && s.localPath != bestPaths[k]) {
          updatedSongs[j] = s.copyWith(localPath: bestPaths[k]);
          playlistChanged = true;
        }
      }

      if (playlistChanged) {
        _playlists[i] = playlist.copyWith(songs: updatedSongs);
        overallChanged = true;
      }
    }

    if (overallChanged) {
      await _playlistService.saveAll(_playlists);
      await _loadPlaylists();
    }
  }

  Future<void> addSongsToPlaylist(
    String playlistId,
    List<SavedSong> songs,
  ) async {
    if (playlistId.startsWith('local_')) return;
    await _playlistService.addSongsToPlaylist(playlistId, songs);
    await _loadPlaylists();
  }

  Future<void> resolvePlaylistLinksInBackground(
    String playlistId,
    List<SavedSong> songs,
  ) async {
    // Start almost immediately but don't block the UI
    Future.delayed(const Duration(milliseconds: 500), () async {
      final List<SavedSong> updatedSongs = [];

      for (var song in songs) {
        bool changed = false;
        SavedSong currentSong = song;

        // 1. Resolve Links (YouTube)
        if (currentSong.youtubeUrl == null || currentSong.youtubeUrl!.isEmpty) {
          try {
            // Minimal pause to stay relatively fast while avoiding harsh rate limits
            await Future.delayed(const Duration(milliseconds: 200));

            final links = await resolveLinks(
              title: currentSong.title,
              artist: currentSong.artist,
              spotifyUrl: currentSong.spotifyUrl,
            );

            if (links['youtube'] != null) {
              currentSong = currentSong.copyWith(youtubeUrl: links['youtube']);
              changed = true;
            }
          } catch (e) {
            debugPrint("Error resolving links for ${currentSong.title}: $e");
          }
        }

        // 2. Check and Correct Album Photos (Metadata)
        try {
          String cleanTitle = currentSong.title
              .replaceAll(RegExp(r'\.(mp3|m4a|wav|flac|ogg)$'), '')
              .trim();
          final metaResults = await _musicMetadataService.searchSongs(
            query: "$cleanTitle ${currentSong.artist}",
          );

          if (metaResults.isNotEmpty) {
            final bestMatch = metaResults.first.song;
            // Update artwork if available and different
            if (bestMatch.artUri != null &&
                bestMatch.artUri!.isNotEmpty &&
                bestMatch.artUri != currentSong.artUri) {
              currentSong = currentSong.copyWith(
                artUri: bestMatch.artUri,
                // Also update Album/ReleaseDate if missing or better
                album:
                    (currentSong.album.isEmpty ||
                        currentSong.album == 'Unknown Album')
                    ? bestMatch.album
                    : currentSong.album,
                releaseDate:
                    (currentSong.releaseDate == null ||
                        currentSong.releaseDate!.isEmpty)
                    ? bestMatch.releaseDate
                    : currentSong.releaseDate,
              );
              changed = true;
            }
          }
        } catch (e) {
          debugPrint("Error enriching metadata for ${currentSong.title}: $e");
        }

        if (changed) {
          updatedSongs.add(currentSong);
        }

        // Batch update every 5 songs to show progress but avoid constant disk I/O
        if (updatedSongs.length >= 5) {
          await updateSongsInPlaylist(playlistId, updatedSongs);
          updatedSongs.clear();
        }
      }

      // Final batch for remaining songs
      if (updatedSongs.isNotEmpty) {
        await updateSongsInPlaylist(playlistId, updatedSongs);
      }
    });
  }

  Future<void> renamePlaylist(String id, String newName) async {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index != -1 && _playlists[index].creator == 'local') return;

    await _playlistService.renamePlaylist(id, newName);
    await _loadPlaylists();
  }

  Future<void> copyPlaylist(String sourceId, String targetId) async {
    try {
      final source = _playlists.firstWhere((p) => p.id == sourceId);
      if (source.songs.isEmpty) return;

      await _playlistService.addSongsToPlaylist(targetId, source.songs);
      await _loadPlaylists();
    } catch (e) {
      debugPrint("Error copying playlist: $e");
    }
  }

  Future<void> updateSongPath(
    String playlistId,
    String songId,
    String newPath,
  ) async {
    try {
      final p = _playlists.firstWhere((p) => p.id == playlistId);
      final index = p.songs.indexWhere((s) => s.id == songId);
      if (index != -1) {
        final s = p.songs[index].copyWith(localPath: newPath);
        final updatedSongs = List<SavedSong>.from(p.songs);
        updatedSongs[index] = s;
        final updatedPlaylist = p.copyWith(songs: updatedSongs);

        await _playlistService.addPlaylist(updatedPlaylist);
        await _loadPlaylists();
      }
    } catch (e) {
      debugPrint("Error updating song path: $e");
    }
  }

  Future<String?> findSongOnDevice(
    String title,
    String artist, {
    String? filename,
  }) async {
    return await _localPlaylistService.findSongOnDevice(
      title,
      artist,
      filename: filename,
    );
  }

  Future<bool> tryFixLocalSongPath(String playlistId, SavedSong song) async {
    String? filename;
    if (song.localPath != null) {
      filename = song.localPath!.split(Platform.pathSeparator).last;
    }

    final newPath = await findSongOnDevice(
      song.title,
      song.artist,
      filename: filename,
    );
    if (newPath != null) {
      await updateSongPath(playlistId, song.id, newPath);
      return true;
    }
    return false;
  }

  Future<void> markSongAsInvalid(String playlistId, String songId) async {
    await _playlistService.markSongAsInvalid(playlistId, songId);
    if (!_invalidSongIds.contains(songId)) {
      _invalidSongIds.add(songId);
    }
    await _loadPlaylists();
  }

  Future<void> clearSongPath(String playlistId, String songId) async {
    try {
      final p = _playlists.firstWhere((p) => p.id == playlistId);
      final index = p.songs.indexWhere((s) => s.id == songId);
      if (index != -1) {
        // Clear path and ensure it's marked as valid (since it can play online)
        final s = p.songs[index].copyWith(
          forceClearLocalPath: true,
          isValid: true,
        );
        final updatedSongs = List<SavedSong>.from(p.songs);
        updatedSongs[index] = s;
        final updatedPlaylist = p.copyWith(songs: updatedSongs);

        await _playlistService.addPlaylist(updatedPlaylist);

        // Also unmark from global invalid list if it was there
        if (_invalidSongIds.contains(songId)) {
          await unmarkSongAsInvalid(songId, playlistId: playlistId);
        } else {
          await _loadPlaylists();
        }
      }
    } catch (e) {
      debugPrint("Error clearing song path: $e");
    }
  }

  Future<void> validateLocalSongsInPlaylist(String playlistId) async {
    try {
      final index = _playlists.indexWhere((p) => p.id == playlistId);
      if (index == -1) return;

      final p = _playlists[index];
      bool anyChanged = false;
      final List<SavedSong> currSongs = List.from(p.songs);
      final List<SavedSong> changedSongsToSync = [];
      final Set<String> revivedIds = {};
      final Set<String> invalidatedIds = {};

      for (int i = 0; i < currSongs.length; i++) {
        final s = currSongs[i];

        final isLocal =
            s.id.startsWith('local_') ||
            s.localPath != null ||
            p.creator == 'local';
        if (!isLocal) continue;

        bool needsCheck = false;
        if (s.isValid) {
          if (s.localPath != null) {
            final f = File(s.localPath!);
            // A valid song should be at least 100KB (header + some data)
            // MST files are encrypted, but should still have size
            if (!await f.exists() || (await f.length()) < 1024 * 50) {
              needsCheck = true;
            }
          } else if (p.creator == 'local' || s.id.startsWith('local_')) {
            needsCheck = true;
          }
        } else {
          // Even if marked invalid, we check if we can fix it
          needsCheck = true;
        }

        if (needsCheck) {
          final newPath = await _localPlaylistService.findSongOnDevice(
            s.title,
            s.artist,
          );

          if (newPath != null) {
            LogService().log("Found/Fixed local song: ${s.title} at $newPath");
            final updated = s.copyWith(localPath: newPath, isValid: true);
            currSongs[i] = updated;
            changedSongsToSync.add(updated);
            if (_invalidSongIds.contains(s.id)) revivedIds.add(s.id);
            anyChanged = true;
          } else {
            final bool canRevert =
                s.youtubeUrl != null ||
                s.spotifyUrl != null ||
                s.appleMusicUrl != null;

            if (canRevert) {
              if (s.localPath != null) {
                LogService().log(
                  "Downloaded song ${s.title} missing file, reverting to online.",
                );
                final updated = s.copyWith(
                  forceClearLocalPath: true,
                  isValid: true,
                );
                currSongs[i] = updated;
                changedSongsToSync.add(updated);
                if (_invalidSongIds.contains(s.id)) revivedIds.add(s.id);
                anyChanged = true;
              }
            } else {
              LogService().log(
                "Local song ${s.title} not found, marking invalid.",
              );
              final updated = s.copyWith(
                isValid: false,
                forceClearLocalPath: true,
              );
              currSongs[i] = updated;
              changedSongsToSync.add(updated);
              if (!_invalidSongIds.contains(s.id)) invalidatedIds.add(s.id);
              anyChanged = true;
            }
          }
        }
      }

      if (anyChanged) {
        _playlists[index] = p.copyWith(songs: currSongs);
        await _playlistService.saveAll(_playlists);

        // Sync changes to OTHER playlists and persist all
        for (var updatedSong in changedSongsToSync) {
          await _syncSongDownloadStatusInternal(updatedSong);
        }
        await _playlistService.saveAll(_playlists);

        if (revivedIds.isNotEmpty || invalidatedIds.isNotEmpty) {
          bool prefChanged = false;
          for (var id in revivedIds) {
            if (_invalidSongIds.remove(id)) prefChanged = true;
            await _playlistService.unmarkSongAsInvalidGlobally(id);
          }
          for (var id in invalidatedIds) {
            if (!_invalidSongIds.contains(id)) {
              _invalidSongIds.add(id);
              prefChanged = true;
            }
            await _playlistService.markSongAsInvalidGlobally(id);
          }

          if (prefChanged) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
          }
        }

        notifyListeners();
        LogService().log(
          "Validated playlist $playlistId: Consolidated changes saved and UI notified.",
        );
      }
    } catch (e) {
      LogService().log("Error validating local songs: $e");
    }
  }

  /// Internal sync that doesn't reload entire state from disk to avoid race conditions
  Future<void> _syncSongDownloadStatusInternal(SavedSong updatedSong) async {
    final targetTitle = _normalizeForMatching(updatedSong.title);
    final targetArtist = _normalizeForMatching(updatedSong.artist);

    for (int i = 0; i < _playlists.length; i++) {
      bool playlistChanged = false;
      final songs = List<SavedSong>.from(_playlists[i].songs);
      for (int j = 0; j < songs.length; j++) {
        if (songs[j].id == updatedSong.id ||
            (_normalizeForMatching(songs[j].title) == targetTitle &&
                _normalizeForMatching(songs[j].artist) == targetArtist)) {
          if (songs[j].localPath != updatedSong.localPath ||
              songs[j].isValid != updatedSong.isValid) {
            songs[j] = songs[j].copyWith(
              localPath: updatedSong.localPath,
              forceClearLocalPath: updatedSong.localPath == null,
              isValid: updatedSong.isValid,
              youtubeUrl: updatedSong.youtubeUrl ?? songs[j].youtubeUrl,
            );
            playlistChanged = true;
          }
        }
      }
      if (playlistChanged) {
        _playlists[i] = _playlists[i].copyWith(songs: songs);
      }
    }
  }

  Future<void> reorderPlaylists(int oldIndex, int newIndex) async {
    await _playlistService.reorderPlaylists(oldIndex, newIndex);
    await _loadPlaylists();
  }

  Future<void> removeFromPlaylist(String playlistId, String songId) async {
    if (playlistId.startsWith('local_')) return;

    // 1. Find the song to get its potential physical path
    final playlist = _playlists.firstWhere(
      (p) => p.id == playlistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    final song = playlist.songs.firstWhere(
      (s) => s.id == songId,
      orElse: () => SavedSong(
        id: '',
        title: '',
        artist: '',
        album: '',
        dateAdded: DateTime.now(),
      ),
    );
    final String? path = song.isDownloaded ? song.localPath : null;

    await _playlistService.removeSongFromPlaylist(playlistId, songId);
    await _loadPlaylists();

    if (path != null) {
      await _cleanupUnreferencedFiles([path]);
    }

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

  Future<void> copySong(
    String songId,
    String fromPayloadId,
    String toPayloadId,
  ) async {
    await _playlistService.copySong(songId, fromPayloadId, toPayloadId);
    await _loadPlaylists();
  }

  Future<void> copySongs(
    List<String> songIds,
    String fromPayloadId,
    String toPayloadId,
  ) async {
    await _playlistService.copySongs(songIds, fromPayloadId, toPayloadId);
    await _loadPlaylists();
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
    // 1. Get path before removal
    String? path;
    for (var p in _playlists) {
      final s = p.songs.firstWhere(
        (s) => s.id == songId,
        orElse: () => SavedSong(
          id: '',
          title: '',
          artist: '',
          album: '',
          dateAdded: DateTime.now(),
        ),
      );
      if (s.id.isNotEmpty && s.isDownloaded) {
        path = s.localPath;
        break;
      }
    }

    await _playlistService.removeSongFromAllPlaylists(songId);
    await _loadPlaylists();

    if (path != null) {
      await _cleanupUnreferencedFiles([path]);
    }
  }

  Future<void> removeSongsFromLibrary(List<String> songIds) async {
    // 1. Collect paths before removal
    final List<String> paths = [];
    final idSet = songIds.toSet();
    for (var p in _playlists) {
      for (var s in p.songs) {
        if (idSet.contains(s.id) && s.isDownloaded && s.localPath != null) {
          paths.add(s.localPath!);
        }
      }
    }

    await _playlistService.removeSongsFromAllPlaylists(songIds);
    await _loadPlaylists();

    if (paths.isNotEmpty) {
      await _cleanupUnreferencedFiles(paths);
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

  Future<void> addFoundSongsToGenre(List<SongSearchResult> results) async {
    if (results.isEmpty) return;

    await _playlistService.addSongsToGenrePlaylists(
      results.map((r) => (genre: r.genre, song: r.song)).toList(),
    );
    await _loadPlaylists();
  }

  Future<void> enrichPlaylistMetadata(String playlistId) async {
    final playlist = _playlists.firstWhere(
      (p) => p.id == playlistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    if (playlist.id.isEmpty) return;

    List<SavedSong> songsToProcess = playlist.songs
        .where((s) => s.artUri == null || s.artUri!.isEmpty)
        .toList();
    if (songsToProcess.isEmpty) return;

    bool anyChanged = false;
    List<SavedSong> updatedSongs = List.from(playlist.songs);

    // Process in small batches or with delays to avoid API throttling
    for (var song in songsToProcess) {
      try {
        // Clean query: remove file extensions or path info if present
        String cleanTitle = song.title
            .replaceAll(RegExp(r'\.(mp3|m4a|wav|flac|ogg)$'), '')
            .trim();
        final results = await searchMusic("$cleanTitle ${song.artist}");

        if (results.isNotEmpty) {
          // Find best match (simple check: title similarity)
          final match = results.first.song;
          int idx = updatedSongs.indexWhere((s) => s.id == song.id);
          if (idx != -1) {
            updatedSongs[idx] = updatedSongs[idx].copyWith(
              artUri: match.artUri,
              album:
                  (updatedSongs[idx].album == 'Unknown Album' ||
                      updatedSongs[idx].album.isEmpty)
                  ? match.album
                  : updatedSongs[idx].album,
              releaseDate:
                  (updatedSongs[idx].releaseDate == null ||
                      updatedSongs[idx].releaseDate!.isEmpty)
                  ? match.releaseDate
                  : updatedSongs[idx].releaseDate,
            );
            anyChanged = true;
          }
        }
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        LogService().log("Metadata Enrichment Error for ${song.title}: $e");
      }
    }

    if (anyChanged) {
      await _playlistService.saveAll(
        _playlists
            .map(
              (p) => p.id == playlistId ? p.copyWith(songs: updatedSongs) : p,
            )
            .toList(),
      );
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
  String? _currentAppleMusicUrl;
  String? _currentDeezerUrl;
  String? _currentTidalUrl;
  String? _currentAmazonMusicUrl;
  String? _currentNapsterUrl;

  String? _currentReleaseDate;
  String? _currentGenre;
  String? _currentLocalPath;

  LyricsData _currentLyrics = LyricsData.empty();
  LyricsData get currentLyrics => _currentLyrics;
  bool _isFetchingLyrics = false;
  bool get isFetchingLyrics => _isFetchingLyrics;
  DateTime? _currentTrackStartTime;

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
  String? get currentLocalPath => _currentLocalPath;

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
    await _audioHandler.setShuffleMode(
      _isShuffleMode
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
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

  Future<void> playDirectAudio(
    String streamUrl,
    String songId, {
    String? playlistId,
    String? overrideTitle,
    String? overrideArtist,
    String? overrideAlbum,
    String? overrideArtUri,
  }) async {
    LogService().log(
      "Playback: Starting Direct Stream: ${overrideTitle ?? 'Audio'} ($streamUrl)",
    );
    _invalidDetectionTimer?.cancel();
    _invalidDetectionTimer = null;

    _currentPlayingPlaylistId = playlistId;
    _audioOnlySongId = songId;

    String title = overrideTitle ?? "Audio";
    String artist = overrideArtist ?? "Direct Stream";
    String? artwork = overrideArtUri;
    String? album = overrideAlbum;

    _currentStation = Station(
      id: -998,
      name: playlistId ?? "Remote",
      genre: "Direct Stream",
      url: streamUrl,
      icon: "cloud_queue",
      color: "0xFF2196F3",
      logo: artwork,
      category: "Remote",
    );
    _currentTrack = title;
    _currentArtist = artist;
    _currentAlbum = album ?? "";
    _currentAlbumArt = artwork;
    _isPlaying = true;
    _isLoading = true;
    notifyListeners();

    try {
      await _audioHandler.playFromUri(Uri.parse(streamUrl), {
        'title': title,
        'artist': artist,
        'artUri': artwork,
        'album': album ?? "Remote",
        'type': 'playlist_song',
        'songId': songId,
        'playlistId': playlistId,
        'is_resolved': true,
        'user_initiated': true,
      });
    } catch (e) {
      LogService().log("Error in playDirectAudio: $e");
      _isLoading = false;
      notifyListeners();
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
    bool isLocal = false,
    bool isResolved = false,
  }) async {
    LogService().log(
      "Playback: Starting YouTube audio: ${overrideTitle ?? 'Audio'} (https://youtube.com/watch?v=$videoId)",
    );
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
      genre: isLocal ? "Local Device" : "My Playlist",
      url: isLocal ? videoId : "youtube://$videoId",
      icon: isLocal ? "smartphone" : "youtube",
      color: isLocal ? "0xFF4CAF50" : "0xFFFF0000",
      logo: artwork,
      category: "Playlist",
    );
    _currentTrack = title;
    _currentArtist = artist;
    _currentAlbum = album ?? ""; // Empty instead of "Playlist"
    _currentAlbumArt = artwork;
    _currentReleaseDate = releaseDate;
    _currentArtistImage = null;
    _currentLocalPath = isLocal ? videoId : null;
    _isPlaying = true; // Show 'Pause' icon
    // _isLoading = true; // Optional: Show loading state, but better to show song info

    _currentTrackStartTime = DateTime.now();
    checkIfCurrentSongIsSaved(); // Check if this song from the playlist is already saved somewhere
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
      Uri uri;
      if (isLocal) {
        uri = Uri.file(videoId);
      } else {
        uri = Uri.parse(videoId);
      }

      await _audioHandler.playFromUri(uri, {
        'title': title,
        'artist': artist,
        'artUri': artwork,
        'album': album ?? (isLocal ? "Local Device" : "Playlist"),
        'duration': null, // Will be updated by player
        'type': 'playlist_song',
        'playlistId': playlistId,
        'songId': songId,
        'videoId': videoId,
        'isLocal': isLocal,
        'is_resolved': isResolved || isLocal,
      });

      _audioOnlySongId = songId;
      _isPlaying = true;
      // _isLoading = false; // LET AUDIO HANDLER STATE CONTROL LOADING
      // notifyListeners();

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
                if (diff.inSeconds > 12) {
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
                      final bool isRemotePlaylist =
                          _currentPlayingPlaylistId != null &&
                          (_currentPlayingPlaylistId!.startsWith('trending_') ||
                              _currentPlayingPlaylistId!.startsWith(
                                'spotify_',
                              ));

                      if (isRemotePlaylist) {
                        debugPrint(
                          "Stallo Rilevato (>12s) - Playlist Remota: Skipping.",
                        );
                        _lastMonitoredPositionTime = null;
                        playNext(false);
                        return;
                      }

                      debugPrint(
                        "Stallo Rilevato (>12s) e Internet OK. Salto (no invalidazione).",
                      );
                      // _markCurrentSongAsInvalid(); // RIMOSSO to reduce skips/removals
                      playNext(false); // Passa alla successiva

                      _lastMonitoredPosition = null;
                      _lastMonitoredPositionTime = null;
                      return;
                    }
                  } else {
                    debugPrint(
                      "Stallo Rilevato (>12s) - Nessuna connessione Internet. Attendo...",
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

            if (remainingMs <= 200 && !_isLoading) {
              // Only intervene if practically finished to avoid dead air,
              // but don't force it 1s early which causes double-skips.
              _isLoading = true;
              notifyListeners();

              debugPrint(
                "PlaybackMonitor: Song finished (remaining: $remainingMs ms).",
              );
              playNext(false); // Changed to false (system initiated)
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

      checkIfCurrentSongIsSaved(); // Reset save status
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

      final bool isRemotePlaylist =
          _currentPlayingPlaylistId != null &&
          (_currentPlayingPlaylistId!.startsWith('trending_') ||
              _currentPlayingPlaylistId!.startsWith('spotify_'));

      if (isRemotePlaylist) {
        LogService().log(
          "YouTube Player Error: ${value.errorCode}. Remote Playlist: Skipping.",
        );
        playNext(false);
        return;
      }

      LogService().log(
        "YouTube Player Error: ${value.errorCode}. Marking song invalid.",
      );
      final idToInvalidate = _audioOnlySongId;
      playNext(false);
      _markCurrentSongAsInvalid(songId: idToInvalidate);
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
        if (diff.inSeconds > 12) {
          if (_isOffline) {
            LogService().log("Offline: Ignoring buffering stuck detected.");
            _lastProcessingTime = null;
            return;
          }

          final bool isRemotePlaylist =
              _currentPlayingPlaylistId != null &&
              (_currentPlayingPlaylistId!.startsWith('trending_') ||
                  _currentPlayingPlaylistId!.startsWith('spotify_'));

          if (isRemotePlaylist) {
            LogService().log(
              "Playback Processing Timeout (>12s). Playlist Remota: Ignoro controllo video.",
            );
            _lastProcessingTime = null;
            return;
          }

          LogService().log(
            "Playback Processing Timeout (>12s in $state). Skipping (no invalid).",
          );
          // final idToInvalidate = _audioOnlySongId;
          playNext(false);
          // _markCurrentSongAsInvalid(songId: idToInvalidate); // RIMOSSO
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

    if (_isLoading) {
      _isLoading = false;
      notifyListeners();
    }
    if (!_isPlaying) {
      _isPlaying = true;
      notifyListeners();
    }

    // RESET CIRCUIT BREAKER ON SUCCESSFUL PLAYBACK (> 5 seconds)
    if (_autoSkipCount > 0 &&
        state == PlayerState.playing &&
        value.position.inSeconds > 5) {
      LogService().log(
        "Playback successful (>5s). Resetting auto-skip counter.",
      );
      _autoSkipCount = 0;
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
            if (diff.inSeconds >= 12) {
              if (_isOffline) {
                debugPrint("Offline: Ignoring zero duration.");
                _zeroDurationStartTime = null;
              } else {
                debugPrint(
                  "Song has had Zero Duration for >12s in Playing State. Skipping.",
                );
                // final idToInvalidate = _audioOnlySongId;
                playNext(false);
                // _markCurrentSongAsInvalid(songId: idToInvalidate); // RIMOSSO
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

  static const String _keyEnableACRCloud = 'enable_acrcloud';
  bool _isACRCloudEnabled = false;
  bool get isACRCloudEnabled => _isACRCloudEnabled;

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
    LogService().log(
      "moveStation: Moving $stationId. After: $afterStationId, Before: $beforeStationId",
    );

    // Ensure order list is fully populated and CLEAN
    // We must check if the CONTENTS match, not just the length.
    // 1. Remove "Ghost" IDs (IDs in order list that no longer exist in stations)
    final Set<int> currentStationIds = stations.map((s) => s.id).toSet();
    final int removedCount = _stationOrder.length;
    _stationOrder.removeWhere((id) => !currentStationIds.contains(id));
    if (_stationOrder.length != removedCount) {
      LogService().log(
        "moveStation: Cleaned up ${removedCount - _stationOrder.length} ghost stations.",
      );
    }

    // 2. Add Missing IDs (IDs in stations but not in order list)
    final existingOrderIds = _stationOrder.toSet();
    final missing = stations
        .where((s) => !existingOrderIds.contains(s.id))
        .map((s) => s.id);

    if (missing.isNotEmpty) {
      LogService().log(
        "moveStation: Adding ${missing.length} missing stations to order...",
      );
      _stationOrder.addAll(missing);
    }

    // Auto-enable custom order
    if (!_useCustomOrder) {
      _useCustomOrder = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyUseCustomOrder, true);
    }

    final int currentIndex = _stationOrder.indexOf(stationId);
    if (currentIndex == -1) {
      LogService().log(
        "moveStation: Error - Station ID $stationId not found in order list.",
      );
      return;
    }

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
    _isACRCloudEnabled = prefs.getBool(_keyEnableACRCloud) ?? false;
    _isCompactView = prefs.getBool(_keyCompactView) ?? false;
    _isShuffleMode = prefs.getBool(_keyShuffleMode) ?? false;
    // Sync initial state to AudioHandler
    if (_isShuffleMode) {
      _audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
    } else {
      _audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
    }

    // Load invalid songs
    final invalidList = prefs.getStringList(_keyInvalidSongIds);
    if (invalidList != null) {
      _invalidSongIds.clear();
      _invalidSongIds.addAll(invalidList);
    }
    notifyListeners();
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
    LogService().log("Analytics Result: $station");
    LogService().log("Analytics Result: $station");

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

      // _isLoading = false; // Remove manual reset, let listener handle it for accuracy
      // notifyListeners();
      // _addLog("Playing via Service");

      // Recognition and Lyrics are now triggered by the playback state listener
      // once buffering is complete.
    } catch (e) {
      _isLoading = false;
      // _addLog("Error: $e");
      notifyListeners();
    }
  }

  void togglePlay() {
    LogService().log("Analytics Result: toggle_play");
    LogService().log("Analytics Result: toggle_play");

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
    _autoSkipCount = 0; // Reset on manual stop
    await _audioHandler.stop();
  }

  void resume() async {
    if (_currentStation != null || _currentPlayingPlaylistId != null) {
      await _audioHandler.play();
    }
  }

  // Helper to instantly kill current audio to prevent overlaps/ghosting
  // Async to ensure the platform channel actually stops playing before proceeding
  Future<void> stopPreviousStream() async {
    if (_hiddenAudioController != null) {
      _hiddenAudioController!.removeListener(_youtubeListener);
      _hiddenAudioController!.pause();
      // Give the native player a moment to process the pause
      await Future.delayed(const Duration(milliseconds: 100));
      _hiddenAudioController!.dispose();
      _hiddenAudioController = null;
    }
    // Also stop the background audio handler completely
    await _audioHandler.stop();

    _stopPlaybackMonitor();
    _isLoading = true;
    notifyListeners();
  }

  Future<void> playNext([bool userInitiated = true]) async {
    // 1. Interrupt immediately to stop music NOW
    if (userInitiated) {
      await stopPreviousStream();
    } else {
      // For auto-skip, the player is likely already ended/stopped,
      // but we still ensure cleanup to be safe.
      await stopPreviousStream();
    }

    // Debounce to ensure it only clicks once within a short window (1 second)
    final now = DateTime.now();
    if (_lastPlayNextTime != null &&
        now.difference(_lastPlayNextTime!) < const Duration(seconds: 1)) {
      // debugPrint("playNext: Ignored (Debounced)");
      return;
    }
    _lastPlayNextTime = now;

    if (userInitiated) {
      _autoSkipCount = 0; // Reset on user action
    } else {
      _autoSkipCount++;
      if (_autoSkipCount > 5) {
        LogService().log(
          "Circuit Breaker: Too many consecutive auto-skips ($_autoSkipCount). Stopping playback.",
        );
        stop();
        _errorMessage = "Unable to play songs"; // Optional: Inform UI
        notifyListeners();
        _autoSkipCount = 0;
        return;
      }
    }

    LogService().log(
      "playNext: Performing skip. userInitiated=$userInitiated. Current Track: $_currentTrack",
    );

    if (_hiddenAudioController != null || _currentPlayingPlaylistId != null) {
      _playNextInPlaylist(userInitiated: userInitiated);
    } else {
      playNextStationInFavorites();
    }
  }

  Future<void> playPrevious() async {
    // 1. Interrupt immediately
    await stopPreviousStream();

    final now = DateTime.now();
    if (_lastPlayPreviousTime != null &&
        now.difference(_lastPlayPreviousTime!) < const Duration(seconds: 1)) {
      return;
    }
    _lastPlayPreviousTime = now;

    LogService().log(
      "playPrevious: Performing skip. Current Track: $_currentTrack",
    );
    if (_hiddenAudioController != null || _currentPlayingPlaylistId != null) {
      _playPreviousInPlaylist();
    } else {
      playPreviousStationInFavorites();
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
    LogService().log(
      "Advancing to next song in playlist. userInitiated=$userInitiated",
    );
    final nextSong = _getNextSongInPlaylist();
    if (nextSong != null && _currentPlayingPlaylistId != null) {
      await playPlaylistSong(nextSong, _currentPlayingPlaylistId!);
    } else {
      LogService().log("No next song found in playlist or no active playlist.");
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
    // STOP PREVIOUS STREAM IMMEDIATELY
    // Re-use helper to be sure, although playNext/Prev already called it.
    // This covers case where playPlaylistSong is called directly (e.g. clicking item in list)
    await stopPreviousStream();

    LogService().log("Analytics Result: play_song");

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

    // RESET PLAYBACK IMMEDIATE (UI FEEDBACK)
    // Update MediaItem to new song with 0 duration to reset counters/bar
    _audioHandler.updateMediaItem(
      MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        artUri: song.artUri != null ? Uri.tryParse(song.artUri!) : null,
        duration: Duration.zero,
        extras: {
          'isLocal': song.localPath != null,
          'type': 'playlist_song',
          'songId': song.id,
          'playlistId': playlistId,
        },
      ),
    );
    // Reset position state if possible (though stream might lag slightly, this helps)
    // We invoke stop() which usually resets state in AudioService handlers
    // _audioHandler.stop(); // Redundant and potentially causes race with awaited stop() below

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

    // Lyrics fetch moved to after successful resolution
    _currentTrackStartTime = DateTime.now();

    _metadataTimer?.cancel(); // CANCEL recognition timer
    _isLoading = true; // User initiated: Force loading state immediately
    _isPlaying = true; // Optimistically show pause icon
    notifyListeners();

    try {
      // We manually manage state to show "Loading" while we resolved/stop
      _ignoringPause = true;
      _isLoading = true;
      _isPlaying = true; // Maintain "Playing" state in UI (Pause icon)
      notifyListeners();

      // REMOVED redundant await _audioHandler.stop() - handled by playFromUri/playYoutubeAudio
      // This avoids extra delay and race conditions with the 'stopped' event broadcast.

      // Delay resetting to ensure any pending events from the PREVIOUS player state are ignored
      Future.delayed(const Duration(milliseconds: 1000), () {
        _ignoringPause = false;
      });

      String? videoId;

      // 0. LOCAL FILE CHECK (Priority over stream)
      if (song.localPath != null) {
        final file = File(song.localPath!);
        if (await file.exists()) {
          await playYoutubeAudio(
            song.localPath!,
            song.id,
            playlistId: playlistId,
            overrideTitle: song.title,
            overrideArtist: song.artist,
            overrideAlbum: song.album,
            overrideArtUri: song.artUri,
            isLocal: true,
          );
          fetchLyrics(); // Fetch lyrics for local file
          return;
        } else {
          // File check failed
          if (_isOffline) {
            LogService().log(
              "Offline: Local file check failed for ${song.localPath}. Attempting to play anyway.",
            );
            // Try to play locally even if check failed (e.g. permission issue or flaky check)
            // This prevents clearing the path when we have no internet to Fallback anyway.
            await playYoutubeAudio(
              song.localPath!,
              song.id,
              playlistId: playlistId,
              overrideTitle: song.title,
              overrideArtist: song.artist,
              overrideAlbum: song.album,
              overrideArtUri: song.artUri,
              isLocal: true,
            );
            return;
          }

          LogService().log(
            "Local file not found: ${song.localPath}. Reverting to online.",
          );
          // Instead of invalidating, we clear the local path and let it fall through to online playback
          final updated = song.copyWith(forceClearLocalPath: true);

          // Sync this change so UI updates (removes download icon)
          await _syncSongDownloadStatusInternal(updated);
          await _playlistService.saveAll(_playlists);

          // Update local variable to proceed with online logic
          // ignore: parameter_assignments
          song = updated;
        }
      }

      // 1. Direct Stream Support (Audius, etc.)
      bool isDeezer = song.provider?.toLowerCase() == 'deezer';

      if (song.rawStreamUrl != null &&
          song.rawStreamUrl!.isNotEmpty &&
          !isDeezer) {
        LogService().log("Direct Link: Using rawStreamUrl for ${song.title}");
        await playYoutubeAudio(
          song.rawStreamUrl!,
          song.id,
          playlistId: playlistId,
          overrideTitle: song.title,
          overrideArtist: song.artist,
          overrideAlbum: song.album,
          overrideArtUri: song.artUri,
          isLocal: false,
          isResolved: true,
        );
        return;
      }

      if (song.youtubeUrl != null) {
        videoId = YoutubePlayer.convertUrlToId(song.youtubeUrl!);
        // If it was already a raw 11-char ID, use it directly
        if (videoId == null && song.youtubeUrl!.length == 11) {
          videoId = song.youtubeUrl;
        }
      }

      // Optimization for Remote Playlists:
      // If we don't have a videoId yet but the song ID itself looks like a YouTube ID
      // and it's from a trending or remote playlist, use it directly.
      if (videoId == null &&
          playlistId != null &&
          (playlistId.startsWith('trending_') ||
              playlistId.startsWith('spotify_'))) {
        if (song.id.length == 11) {
          videoId = song.id;
          LogService().log(
            "Remote Playlist: Using Song ID as direct YouTube ID: $videoId",
          );
        }
      }

      if (videoId == null) {
        Map<String, String> links = {};
        try {
          links = await resolveLinks(
            title: song.title,
            artist: song.artist,
            spotifyUrl: song.spotifyUrl,
            youtubeUrl: song.youtubeUrl,
          ).timeout(const Duration(seconds: 8));
        } catch (e) {
          LogService().log(
            "ResolveLinks failed or timed out: $e. Proceeding to fallback.",
          );
        }

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

      // 3. SEQUENTIAL SEARCH: YoutubeExplode
      // If we still don't have a videoId, try multiple search queries in sequence
      if (videoId == null) {
        final yt = yt_explode.YoutubeExplode();
        try {
          // Attempt 1: Artist + Title (Best for specific matches)
          LogService().log("Search Step 1: '${song.artist} ${song.title}'");
          var results = await yt.search.search("${song.artist} ${song.title}");

          // Attempt 2: Clean Title + Artist (Fallback)
          if (results.isEmpty) {
            final cleanTitle = song.title
                .replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '')
                .trim();
            LogService().log("Search Step 2: '$cleanTitle ${song.artist}'");
            results = await yt.search.search("$cleanTitle ${song.artist}");
          }

          // Attempt 3: Title only (if long enough)
          if (results.isEmpty && song.title.length > 5) {
            LogService().log("Search Step 3: '${song.title}'");
            results = await yt.search.search(song.title);
          }

          if (results.isNotEmpty && _audioOnlySongId == song.id) {
            videoId = results.first.id.value;
            LogService().log("Found ID via sequential search: $videoId");
          }
        } catch (e) {
          LogService().log("Sequential YouTube search error: $e");
        } finally {
          yt.close();
        }
      }

      // Fetch Lyrics immediately before playing via YouTube (after resolution)
      fetchLyrics();

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
            _isLoading = false;
            notifyListeners();
            return;
          }

          if (playlistId.startsWith('trending_')) {
            LogService().log(
              "Trending Playlist: Cannot resolve video ID for ${song.title}. Skipping without marking as invalid.",
            );
          } else {
            LogService().log(
              "No Video ID found for: ${song.title}. Skipping (not invalidating).",
            );
            // DON'T INVALIDATE GLOBALLY TO PREVENT EXCESSIVE REMOVALS
            // await _playlistService.markSongAsInvalidGlobally(song.id);
            /*
            if (!_invalidSongIds.contains(song.id)) {
              _invalidSongIds.add(song.id);
              // Persist locally
              final prefs = await SharedPreferences.getInstance();
              await prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
            }
            */
          }

          /*
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
          */

          await Future.delayed(const Duration(seconds: 1));
          playNext(false);
        }
      }
    } catch (e) {
      _isLoading = false;
      notifyListeners();

      LogService().log("Error in playPlaylistSong: $e");

      /*
      // Check if error is network related
      final errStr = e.toString().toLowerCase();
      final isNetwork =
          errStr.contains('socket') ||
          errStr.contains('timeout') ||
          errStr.contains('handshake') ||
          errStr.contains('network') ||
          errStr.contains('lookup');

      if (!isNetwork && playlistId != null && song.localPath == null) {
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
      */

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

  bool _isObservingLyrics = false;
  String? _lastLyricsSearch;

  void setObservingLyrics(bool isObserving) {
    _isObservingLyrics = isObserving;
  }

  Future<void> refreshLyrics() async {
    _lastLyricsSearch = null;
    await fetchLyrics(force: true);
  }

  Future<void> fetchLyrics({
    bool force = false,
    bool fromRecognition = false,
  }) async {
    // Only fetch if UI is observing or explicitly requested
    if (!_isObservingLyrics && !force) return;

    // Entitlement Check
    if (!_entitlementService.isFeatureEnabled('lyrics')) return;

    // Guard: Do not fetch if nothing is playing
    if (!_isPlaying &&
        _currentStation == null &&
        _currentPlayingPlaylistId == null)
      return;

    if (_currentTrack.isEmpty ||
        _currentTrack == "Live Broadcast" ||
        _currentArtist.isEmpty) {
      _currentLyrics = LyricsData.empty();
      _lastLyricsSearch = null;
      notifyListeners();
      return;
    }
    if (_currentTrack == "Live Broadcast" ||
        (_currentStation != null && _currentTrack == _currentStation!.name)) {
      _currentLyrics = LyricsData.empty();
      _lyricsOffset = Duration.zero; // Reset offset
      _lastLyricsSearch = null;
      notifyListeners();
      return;
    }

    final sanitizedArtist = _sanitizeArtistName(_currentArtist);
    final cleanArtist = LyricsService.cleanString(sanitizedArtist);
    final cleanTitle = LyricsService.cleanString(_currentTrack);
    final searchKey = "$cleanArtist|$cleanTitle";

    // 0. Streaming Check: Ensure we have started streaming
    // If _currentTrackStartTime is null, we are likely still buffering.
    // The playback listener will re-call fetchLyrics() once state hits 'ready'.
    if (_currentTrackStartTime == null && !force) {
      LogService().log("Lyrics Search: Waiting for streaming to start...");
      return;
    }

    // 0. Universal Wait Logic: Ensure at least 5 seconds from stream start
    final streamStartTime = _currentTrackStartTime ?? DateTime.now();
    final elapsedSinceStream = DateTime.now().difference(streamStartTime);
    if (!force && elapsedSinceStream < const Duration(seconds: 5)) {
      await Future.delayed(const Duration(seconds: 5) - elapsedSinceStream);
      // Re-check after wait: if song changed, abort this old call
      final verArtistNow = LyricsService.cleanString(
        _sanitizeArtistName(_currentArtist),
      );
      final verTitleNow = LyricsService.cleanString(_currentTrack);
      if ("$verArtistNow|$verTitleNow" != searchKey) return;
    }

    // 1. Auto-Clear Logic: Always clear if song changed
    if (force || _lastLyricsSearch != searchKey) {
      _currentLyrics = LyricsData.empty();
      _lyricsOffset = Duration.zero;
      notifyListeners();
    }

    // 2. Control Flow Logic
    final bool isRadio =
        _currentPlayingPlaylistId == null && _currentStation != null;
    if (!force) {
      if (isRadio) {
        if (!_isACRCloudEnabled) {
          _lastLyricsSearch = searchKey;
          _isFetchingLyrics = false;
          notifyListeners();
          return;
        }
        if (!fromRecognition) {
          _lastLyricsSearch = searchKey;
          _isFetchingLyrics = false;
          notifyListeners();
          return;
        }
      }
    }

    // 3. Initiate Search State
    _isFetchingLyrics = true;
    _lastLyricsSearch = searchKey;
    notifyListeners();

    // Re-verify if the song is still the same after wait (Final Check)
    // Re-verify if the song is still the same after wait
    final verArtist = LyricsService.cleanString(
      _sanitizeArtistName(_currentArtist),
    );
    final verTitle = LyricsService.cleanString(_currentTrack);
    final verKey = "$verArtist|$verTitle";
    if (verKey != searchKey || _lastLyricsSearch != searchKey) return;

    try {
      // LyricsService now handles all combinations (sanitized, raw, cleaned) internally
      final results = await _lyricsService.fetchLyrics(
        artist: _currentArtist,
        title: _currentTrack,
        isRadio: _currentPlayingPlaylistId == null,
      );

      // Only update if metadata hasn't changed while we were fetching
      if (_lastLyricsSearch == searchKey) {
        if (results.lines.isNotEmpty) {
          _currentLyrics = results;
        }
      }
    } catch (e) {
      _currentLyrics = LyricsData.empty();
      // Allow retry if failed
      _lastLyricsSearch = null;
    } finally {
      if (_lastLyricsSearch == searchKey) {
        _isFetchingLyrics = false;
        notifyListeners();
      }
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

  Future<String?> addCurrentSongToGenrePlaylist() async {
    if (_currentTrack.isEmpty || _currentStation == null) return null;

    final songId = "${_currentTrack}_${_currentArtist}";
    final genre = _currentGenre ?? "Mix";

    // Sanitize album name: remove station name etc.
    String cleanAlbum = _currentAlbum;
    final stationName = _currentStation?.name ?? "";
    if (stationName.isNotEmpty && cleanAlbum.contains(stationName)) {
      cleanAlbum = cleanAlbum
          .replaceAll(stationName, "")
          .replaceAll("•", "")
          .trim();
    }

    final song = SavedSong(
      id: songId,
      title: _currentTrack,
      artist: _currentArtist,
      album: cleanAlbum,
      artUri: _currentAlbumArt ?? _currentStation!.logo ?? "",
      duration: _currentSongDuration ?? Duration.zero,
      dateAdded: DateTime.now(),
      spotifyUrl: _currentSpotifyUrl,
      youtubeUrl: _currentYoutubeUrl,
      isValid: true,
    );

    // Optimistic Update
    _currentSongIsSaved = true;
    notifyListeners();

    try {
      // Use service to add to specific genre playlist
      await _playlistService.addToGenrePlaylist(genre, song);
    } catch (e) {
      // Revert if failed
      _currentSongIsSaved = false;
      notifyListeners();
      return null;
    }

    return genre;
  }

  Future<void> checkIfCurrentSongIsSaved() async {
    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") {
      _currentSongIsSaved = false;
    } else {
      _currentSongIsSaved = await _playlistService.isSongInFavorites(
        _currentTrack,
        _currentArtist,
      );
    }
    notifyListeners();
  }

  String _sanitizeArtistName(String artist) {
    // Stop at first occurrence of ( , & /
    // Regex split using [\(,&/]
    if (artist.isEmpty) return artist;
    return artist.split(RegExp(r'[\\(,&/]')).first.trim();
  }

  Future<void> fetchSmartLinks({bool keepExistingArtwork = false}) async {
    // If not playing, don't fetch anything to save resources
    if (!_isPlaying &&
        _currentPlayingPlaylistId == null &&
        (_hiddenAudioController == null ||
            !_hiddenAudioController!.value.isPlaying)) {
      // However, we must allow fetching if we are PAUSED but have content.
      // Easiest check: do we have a station or playlist active?
      // If we are completely stopped (no station, no playlist), return.
      if (_currentStation == null && _currentPlayingPlaylistId == null) return;
    }

    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") return;

    // Reset images to prevent showing previous song's art
    // respecting the flag
    if (!keepExistingArtwork) {
      _currentAlbumArt = _currentStation?.logo;
    }
    _currentArtistImage =
        null; // Always reset artist image for now? Or keep? stick to album art for now.

    // Check if song is already saved
    checkIfCurrentSongIsSaved();
    notifyListeners();

    final links = await resolveLinks(
      title: _currentTrack,
      artist: _currentArtist,
      spotifyUrl: _currentSpotifyUrl,
      youtubeUrl: _currentYoutubeUrl,
    );

    // Update State
    if (links.containsKey('thumbnailUrl')) {
      if (!keepExistingArtwork || _currentAlbumArt == null) {
        _currentAlbumArt = links['thumbnailUrl'];
      }
    }

    if (links.containsKey('spotify')) {
      _currentSpotifyUrl = links['spotify'];

      // Fetch Artist Image using Deezer (Requested Method)
      try {
        if (_currentArtist.isNotEmpty) {
          final query = _sanitizeArtistName(_currentArtist);
          final uri = Uri.parse(
            "https://api.deezer.com/search/artist?q=${Uri.encodeComponent(query)}&limit=1",
          );
          final response = await http.get(uri);
          if (response.statusCode == 200) {
            final json = jsonDecode(response.body);
            if (json['data'] != null && (json['data'] as List).isNotEmpty) {
              String? picture =
                  json['data'][0]['picture_xl'] ??
                  json['data'][0]['picture_big'] ??
                  json['data'][0]['picture_medium'];

              if (picture != null) {
                _currentArtistImage = picture;
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Error fetching artist image from Deezer: $e");
      }

      // Fallback or additional Spotify check could be here if needed, but user requested consistent method.
    }

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
          artist: (_currentGenre != null && _currentGenre!.isNotEmpty)
              ? "$_currentArtist"
              : _currentArtist,
          album: _currentAlbum.isNotEmpty
              ? ((_currentGenre != null && _currentGenre!.isNotEmpty)
                    ? "$_currentAlbum"
                    : _currentAlbum)
              : _currentGenre,
          genre: _currentGenre,
          artUri: _currentAlbumArt != null
              ? Uri.parse(_currentAlbumArt!)
              : (_currentStation?.logo != null
                    ? Uri.parse(_currentStation!.logo!)
                    : null),
          extras: {
            'url': _currentStation!.url,
            'stationId': _currentStation!.id,
            'type': 'station',
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

      // Update last backup timestamp to current time to prevent immediate automatic backup
      _lastBackupTs = DateTime.now().millisecondsSinceEpoch;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_backup_ts', _lastBackupTs);

      // Automatically set backup frequency to daily after first restore
      await setBackupFrequency('daily');

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
    notifyListeners();
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

  Future<void> setACRCloudEnabled(bool value) async {
    _isACRCloudEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnableACRCloud, value);
    notifyListeners();

    // Sync with AudioHandler
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.setACRCloudEnabled(value);
    }

    if (_isACRCloudEnabled &&
        _entitlementService.isFeatureEnabled('song_recognition')) {
      _metadataTimer?.cancel();
      LogService().log("Attempting Recognition...2");
      _attemptRecognition();
    } else {
      _metadataTimer?.cancel();
      _isRecognizing = false;
      notifyListeners();
    }
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

  void _markCurrentSongAsInvalid({String? songId}) async {
    final targetId = songId ?? _audioOnlySongId;
    bool isLocal = false;

    if (targetId != null) {
      for (var p in _playlists) {
        try {
          final s = p.songs.firstWhere((s) => s.id == targetId);
          if (s.localPath != null || s.id.startsWith('local_')) {
            isLocal = true;
            break;
          }
        } catch (_) {}
      }
    }

    // Trending Check: Do NOT mark invalid if from a remote trending playlist
    if (_currentPlayingPlaylistId?.startsWith('trending_') == true) {
      LogService().log(
        "Blocking 'Mark Invalid' - Song is from a trending playlist",
      );
      return;
    }

    // Connectivity Check: Do NOT mark invalid if internet is down (unless it is a local file)
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none) && !isLocal) {
      LogService().log("Blocking 'Mark Invalid' - No Internet Connection");
      return;
    }

    if (targetId != null) {
      LogService().log("Marking Song Invalid: $targetId");
      if (!_invalidSongIds.contains(targetId)) {
        _invalidSongIds.add(targetId);
        LogService().log(
          "Added to invalidSongIds. Count: ${_invalidSongIds.length}",
        );

        // 1. Update In-Memory Playlists Immediately (Instant UI Feedback)
        bool memoryUpdated = false;
        for (var i = 0; i < _playlists.length; i++) {
          final p = _playlists[i];
          final index = p.songs.indexWhere((s) => s.id == targetId);
          if (index != -1) {
            final updatedSong = p.songs[index].copyWith(
              isValid: false,
              forceClearLocalPath: true,
            );
            p.songs[index] = updatedSong;
            memoryUpdated = true;
          }
        }
        if (memoryUpdated) {
          LogService().log(
            "Updated _playlists in memory immediately and cleared localPath.",
          );
        }

        // 2. Notify UI immediately
        notifyListeners();

        // 3. Persist ID list
        final prefs = await SharedPreferences.getInstance();
        prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
        LogService().log("Persisted invalidSongIds to Prefs");

        // 4. Mark globally in DB (Async)
        await _playlistService.markSongAsInvalidGlobally(targetId);

        // Also sync localPath clearance globally
        try {
          final s = _allUniqueSongs.firstWhere((s) => s.id == targetId);
          await _syncSongDownloadStatusInternal(
            s.copyWith(
              localPath: null,
              forceClearLocalPath: true,
              isValid: false,
            ),
          );
          await _playlistService.saveAll(_playlists);
        } catch (_) {
          // Fallback if not in unique
          await _playlistService.saveAll(_playlists);
        }

        LogService().log(
          "Marked invalid globally via Service and cleared localPath.",
        );

        // 5. Update Temp Playlist
        if (_tempPlaylist != null) {
          final index = _tempPlaylist!.songs.indexWhere(
            (s) => s.id == targetId,
          );
          if (index != -1) {
            _tempPlaylist!.songs[index] = _tempPlaylist!.songs[index].copyWith(
              isValid: false,
              forceClearLocalPath: true,
            );
            LogService().log(
              "Updated _tempPlaylist in memory for index $index and cleared localPath",
            );
          }
        }
      } else {
        LogService().log("Song ID $targetId already in invalidSongIds");
      }
    } else {
      LogService().log("Cannot mark invalid: targetId is null");
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
    if (!_entitlementService.isFeatureEnabled('spotify_integration')) {
      return false;
    }
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

  Future<void> _attemptRecognition() async {
    // Entitlement Check: song_recognition
    if (!_entitlementService.isFeatureEnabled('song_recognition')) {
      _isRecognizing = false; // Ensure loading state is OFF
      return;
    }

    if (!_isACRCloudEnabled) return;

    // Strict Input Guard: Must be playing a station to recognize
    if (!_isPlaying ||
        _currentStation == null ||
        _currentPlayingPlaylistId != null)
      return;

    LogService().log(
      "ACRCloud: Starting recognition for ${_currentStation!.name}",
    );
    _lastApiResponse = "Identifying...";
    _isRecognizing = true; // Start loading state

    // Update AudioHandler to show identifying state on Android Auto
    _audioHandler.updateMediaItem(
      MediaItem(
        id: _currentStation!.url,
        title: "${_currentStation?.name ?? "Radio"} 🔍",
        artist: "Identifying song...",
        album: _currentStation?.name ?? "Radio",
        artUri: _currentStation?.logo != null
            ? Uri.tryParse(_currentStation!.logo!)
            : null,
        extras: {
          'url': _currentStation!.url,
          'stationId': _currentStation?.id,
          'type': 'station',
        },
      ),
    );
    notifyListeners();

    final result = await _acrCloudService.identifyStream(_currentStation!.url);
    _isRecognizing = false; // Stop loading state
    notifyListeners();

    if (result != null &&
        result['status']['code'] == 0 &&
        result['metadata'] != null) {
      final music = result['metadata']['music'];
      if (music != null && music.isNotEmpty) {
        final trackInfo = music[0];
        final title = trackInfo['title'];
        final artists = trackInfo['artists']?.map((a) => a['name']).join(', ');
        final album = trackInfo['album']?['name'];
        final releaseDate = trackInfo['release_date'];

        // Log raw response for debug
        _lastApiResponse = jsonEncode(result);

        // Update Metadata
        if (title != _currentTrack || artists != _currentArtist) {
          LogService().log("ACRCloud: Match found: $title - $artists");

          final stationName = _currentStation?.name ?? "Radio";
          _currentTrack = title;
          _currentArtist = artists ?? "Unknown Artist";
          // Include station name in album field for context
          _currentAlbum = (album != null && album.isNotEmpty)
              ? "$stationName • $album"
              : stationName;
          _currentReleaseDate = releaseDate;

          // Extract Genre
          String? genre;
          if (trackInfo['genres'] != null &&
              trackInfo['genres'] is List &&
              trackInfo['genres'].isNotEmpty) {
            genre = trackInfo['genres'][0]['name'];
          }
          _currentGenre = genre;

          // Reset artwork/state
          // Preserve station logo as placeholder instead of null
          _currentAlbumArt = _currentStation?.logo;
          _currentArtistImage = null;

          // Reset External Links
          _currentSpotifyUrl = null;
          _currentYoutubeUrl = null;
          _currentAppleMusicUrl = null;
          _currentDeezerUrl = null;
          _currentTidalUrl = null;
          _currentAmazonMusicUrl = null;
          _currentNapsterUrl = null;

          // --- Reset Duration Info ---
          _currentSongDuration = null;
          _initialSongOffset = null;
          _songSyncTime = null;

          // --- Set New Duration Info ---
          int durationMs = trackInfo['duration_ms'] ?? 0;
          int offsetMs = trackInfo['play_offset_ms'] ?? 0;
          if (durationMs > 0) {
            _currentSongDuration = Duration(milliseconds: durationMs);
            _initialSongOffset = Duration(milliseconds: offsetMs);
            _songSyncTime = DateTime.now();
          }

          checkIfCurrentSongIsSaved(); // Check if this new song is already saved

          // Try to find artwork in ACRCloud response
          String? acrArtwork;
          if (trackInfo['album'] != null &&
              trackInfo['album']['cover'] != null) {
            acrArtwork = trackInfo['album']['cover'];
          }

          if (acrArtwork != null) {
            _currentAlbumArt = acrArtwork;
          }

          notifyListeners();

          // Trigger fetchSmartLinks (which does SongLink search and updates artwork/links)
          await fetchSmartLinks(keepExistingArtwork: acrArtwork != null);
          fetchLyrics(fromRecognition: true);
        } else {
          LogService().log("ACRCloud: Same song detected.");
          _lastApiResponse = "Same song: $title";
          // Update offset for better accuracy even if same song
          int durationMs = trackInfo['duration_ms'] ?? 0;
          int offsetMs = trackInfo['play_offset_ms'] ?? 0;
          if (durationMs > 0) {
            _currentSongDuration = Duration(milliseconds: durationMs);
            _initialSongOffset = Duration(milliseconds: offsetMs);
            _songSyncTime = DateTime.now();
          }

          // Ensure genre is updated even if song is same (in case it wasn't caught before)
          String? genre;
          if (trackInfo['genres'] != null &&
              trackInfo['genres'] is List &&
              trackInfo['genres'].isNotEmpty) {
            genre = trackInfo['genres'][0]['name'];
          }
          if (genre != null) _currentGenre = genre;

          checkIfCurrentSongIsSaved();

          notifyListeners();
        }

        // --- INTELLIGENT SCHEDULING ---
        // Calculate when this song ends to schedule next check
        int durationMs = trackInfo['duration_ms'] ?? 0;
        int offsetMs = trackInfo['play_offset_ms'] ?? 0;

        if (durationMs > 0 && offsetMs > 0) {
          int remainingMs = durationMs - offsetMs;
          // Add a buffer of 10 seconds to ensure next song has started
          int nextCheckDelay = remainingMs + 10000;

          // Safety limits (e.g. if offset is wrong or song is effectively over)
          if (nextCheckDelay < 10000) nextCheckDelay = 10000;

          LogService().log(
            "ACRCloud: Next check in ${nextCheckDelay ~/ 1000}s (Song ends in ${remainingMs ~/ 1000}s)",
          );

          _metadataTimer?.cancel();
          LogService().log("Attempting Recognition...3");
          _metadataTimer = Timer(
            Duration(milliseconds: nextCheckDelay),
            _attemptRecognition,
          );
        } else {
          // Fallback if no duration info
          _scheduleRetry(60);
        }
      } else {
        _lastApiResponse = "No music found in stream sample.";
        _restoreDefaultRadioState();
        _scheduleRetry(45); // Retry sooner if just talk/ad
      }
    } else {
      _lastApiResponse = "Recognition failed or no match.";
      _restoreDefaultRadioState();
      _scheduleRetry(45); // Retry
    }
  }

  void _restoreDefaultRadioState() {
    // Reset to default station images as requested
    // "Force the default radio image"
    _currentAlbumArt = _currentStation?.logo;
    _currentArtistImage = null; // Will fallback to station logo in UI
    _currentTrack = _currentStation?.name ?? "Live Broadcast";
    _currentArtist = _currentStation?.genre ?? "";
    _currentLyrics = LyricsData.empty();

    // Also reset duration info as there is no specific song
    _currentSongDuration = null;
    _initialSongOffset = null;
    _songSyncTime = null;

    if (_currentStation != null) {
      // Explicitly update AudioHandler (Android Auto) with the Station Logo
      _audioHandler.updateMediaItem(
        MediaItem(
          id: _currentStation!.url,
          title: _currentTrack,
          artist: _currentArtist,
          album: _currentStation!.name,
          artUri: _currentStation!.logo != null
              ? Uri.tryParse(_currentStation!.logo!)
              : null,
          extras: {
            'url': _currentStation!.url,
            'stationId': _currentStation!.id,
            'type': 'station',
          },
        ),
      );
    }

    checkIfCurrentSongIsSaved();
    notifyListeners();
  }

  void _scheduleRetry(int seconds) {
    LogService().log("ACRCloud: Retrying in ${seconds}s");
    _metadataTimer?.cancel();
    LogService().log("Attempting Recognition...4");
    _metadataTimer = Timer(Duration(seconds: seconds), _attemptRecognition);
  }

  // --- Artist Image Caching ---
  final Map<String, String?> _artistImageCache = {};

  Future<String?> fetchArtistImage(String artistName) async {
    // 1. Normalize name for cache key
    final rawKey = artistName.trim().toLowerCase();

    // 2. Check Cache
    if (_artistImageCache.containsKey(rawKey)) {
      return _artistImageCache[rawKey];
    }

    // Helper: Returns URL (String), "NOT_FOUND" (String), or null (Error)
    Future<String?> searchDeezer(String query) async {
      if (query.isEmpty) return "NOT_FOUND";
      try {
        final uri = Uri.parse(
          "https://api.deezer.com/search/artist?q=${Uri.encodeComponent(query)}&limit=1",
        );
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final json = jsonDecode(response.body);
          if (json['data'] != null && (json['data'] as List).isNotEmpty) {
            return json['data'][0]['picture_xl'] ??
                json['data'][0]['picture_big'] ??
                json['data'][0]['picture_medium'];
          } else {
            return "NOT_FOUND";
          }
        } else {
          LogService().log(
            "Artist fetch failed ($query): ${response.statusCode}",
          );
        }
      } catch (e) {
        LogService().log("Error fetching artist '$query': $e");
      }
      return null; // Network or Server Error
    }

    // 3. Prepare Sanitized Name
    String searchName = artistName;
    searchName = searchName.split('•').first;
    searchName = searchName.split('(').first;
    searchName = searchName.split('[').first;
    searchName = searchName.split('{').first;

    final lowerName = searchName.toLowerCase();
    if (lowerName.contains(' feat')) {
      searchName = searchName.substring(0, lowerName.indexOf(' feat'));
    } else if (lowerName.contains(' ft.')) {
      searchName = searchName.substring(0, lowerName.indexOf(' ft.'));
    }

    searchName = searchName.split(' - ').first; // "Artist - Title" split
    searchName = searchName
        .split(RegExp(r'[,;&/|+\*\._]'))
        .first; // Special chars
    searchName = searchName.trim();

    // 4. Attempt 1: Sanitized Name
    String? result = await searchDeezer(searchName);

    // 5. Attempt 2: Raw Name (Fallback if Sanitized failed/empty, mimicking Artist Page)
    if ((result == "NOT_FOUND" || result == null) &&
        searchName != artistName.trim()) {
      // LogService().log("Sanitized search failed for '$searchName', trying raw: '$artistName'");
      final rawResult = await searchDeezer(artistName.trim());

      // If Raw found something, use it
      if (rawResult != null && rawResult != "NOT_FOUND") {
        result = rawResult;
      } else if (rawResult == "NOT_FOUND" && result == "NOT_FOUND") {
        // Both confirmed NOT FOUND
        result = "NOT_FOUND";
      }
      // If rawResult is null (Error), keep previous result (which might be NOT_FOUND or null)
    }

    // 6. Cache & Return
    if (result != null && result != "NOT_FOUND") {
      _artistImageCache[rawKey] = result;
      _saveArtistImagesCache(); // Persist
      return result;
    } else if (result == "NOT_FOUND") {
      _artistImageCache[rawKey] = null;
      _saveArtistImagesCache(); // Persist even if not found to avoid repeated searches
      return null;
    } else {
      // Error case: Do not cache, allow retry
      return null;
    }
  }

  Future<void> findMissingArtworks({String? playlistId}) async {
    final List<SavedSong> toProcess = [];
    if (playlistId != null) {
      try {
        final p = _playlists.firstWhere((p) => p.id == playlistId);
        for (var s in p.songs) {
          if (s.artUri == null ||
              s.artUri!.isEmpty ||
              s.artUri!.contains('placeholder') ||
              s.album == 'Unknown Album' ||
              s.album.isEmpty) {
            toProcess.add(s);
          }
        }
      } catch (_) {
        // If it's a temp playlist (artist/album view), we can't find it by ID in _playlists.
        // In this case, we'll just process all songs in the library that match the missing criteria.
        // This is safer than trying to pass a song list through multiple layers.
        for (var s in _allUniqueSongs) {
          if (s.artUri == null ||
              s.artUri!.isEmpty ||
              s.artUri!.contains('placeholder') ||
              s.album == 'Unknown Album' ||
              s.album.isEmpty) {
            toProcess.add(s);
          }
        }
      }
    } else {
      // Process all unique songs that are missing art
      for (var s in _allUniqueSongs) {
        if (s.artUri == null ||
            s.artUri!.isEmpty ||
            s.artUri!.contains('placeholder') ||
            s.album == 'Unknown Album' ||
            s.album.isEmpty) {
          toProcess.add(s);
        }
      }
    }

    if (toProcess.isEmpty) return;

    bool anyChanged = false;
    // Use a set to avoid processing same song twice
    final processIds = toProcess.map((s) => s.id).toSet();

    for (var songId in processIds) {
      final song = _allUniqueSongs.firstWhere(
        (s) => s.id == songId,
        orElse: () => toProcess.firstWhere((tp) => tp.id == songId),
      );

      try {
        final results = await _musicMetadataService.searchSongs(
          query: "${song.title} ${song.artist}",
          limit: 1,
        );

        if (results.isNotEmpty) {
          final match = results.first.song;
          if (match.artUri != null && match.artUri!.isNotEmpty) {
            // Update metadata in all playlists
            bool songChanged = false;
            for (int i = 0; i < _playlists.length; i++) {
              final playlist = _playlists[i];
              final songIndex = playlist.songs.indexWhere(
                (s) => s.id == songId,
              );
              if (songIndex != -1) {
                final updatedSongs = List<SavedSong>.from(playlist.songs);
                updatedSongs[songIndex] = updatedSongs[songIndex].copyWith(
                  artUri: match.artUri,
                  album:
                      (updatedSongs[songIndex].album == 'Unknown Album' ||
                          updatedSongs[songIndex].album.isEmpty)
                      ? match.album
                      : updatedSongs[songIndex].album,
                );
                _playlists[i] = playlist.copyWith(songs: updatedSongs);
                songChanged = true;
                anyChanged = true;
              }
            }
            if (songChanged) {
              // Update allUniqueSongs too
              final idx = _allUniqueSongs.indexWhere((s) => s.id == songId);
              if (idx != -1) {
                _allUniqueSongs[idx] = _allUniqueSongs[idx].copyWith(
                  artUri: match.artUri,
                  album:
                      (_allUniqueSongs[idx].album == 'Unknown Album' ||
                          _allUniqueSongs[idx].album.isEmpty)
                      ? match.album
                      : _allUniqueSongs[idx].album,
                );
              }
            }
          }
        }
      } catch (e) {
        LogService().log("Error finding artwork for ${song.title}: $e");
      }

      // Small delay to avoid rate limits
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (anyChanged) {
      await _playlistService.saveAll(_playlists);
      notifyListeners();
    }
  }

  Future<void> _deletePhysicalFile(String? path) async {
    if (path == null || path.isEmpty) return;

    final file = File(path);
    if (await file.exists()) {
      try {
        await file.delete();
        LogService().log("Deleted physical file: $path");
      } catch (e) {
        LogService().log("Error deleting physical file $path: $e");
      }
    }
  }

  Future<void> _cleanupUnreferencedFiles(List<String> pathsToCheck) async {
    if (pathsToCheck.isEmpty) return;

    // Build a set of all localPaths currently in use across all playlists
    final Set<String> activePaths = {};
    for (var p in _playlists) {
      for (var s in p.songs) {
        if (s.localPath != null && s.localPath!.isNotEmpty) {
          activePaths.add(s.localPath!);
        }
      }
    }

    for (var path in pathsToCheck.toSet()) {
      // Only delete if NOT in activePaths AND is a download (security check)
      final isDownload =
          path.toLowerCase().contains('_secure.') ||
          path.toLowerCase().endsWith('.mst') ||
          path.toLowerCase().contains('offline_music');

      if (isDownload && !activePaths.contains(path)) {
        await _deletePhysicalFile(path);
      }
    }
  }

  Future<void> enrichAllArtists() async {
    // Get all unique artists from all playlists
    final Set<String> artists = {};
    for (var playlist in _playlists) {
      for (var song in playlist.songs) {
        if (song.artist.isNotEmpty) {
          artists.add(song.artist);
        }
      }
    }

    if (artists.isEmpty) return;

    // Filter out those already professionally cached or explicitly marked NOT_FOUND
    final List<String> toFetch = artists.where((a) {
      final key = a.trim().toLowerCase();
      // We only fetch if NOT in cache. If it's in cache (even as null), we already tried.
      return !_artistImageCache.containsKey(key);
    }).toList();

    if (toFetch.isEmpty) return;

    // Process in batches with delays to avoid Deezer rate limits
    for (var artist in toFetch) {
      try {
        await fetchArtistImage(artist);
        // Small delay to be polite to the API
        await Future.delayed(const Duration(milliseconds: 250));
      } catch (e) {
        LogService().log("Error in bulk artist enrichment for $artist: $e");
      }
    }
  }

  // Allow external updates (e.g. from UI fetch)
  void setArtistImage(String? imageUrl) {
    if (_currentArtistImage != imageUrl) {
      _currentArtistImage = imageUrl;
      notifyListeners();
    }
  }
}
