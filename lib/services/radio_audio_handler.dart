// import 'dart:developer' as developer;
import 'package:http/http.dart' as http; // Added import
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:firebase_analytics/firebase_analytics.dart';

import '../models/station.dart';
import '../models/saved_song.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart' as model;
import 'log_service.dart';
import '../utils/genre_mapper.dart';
import 'acr_cloud_service.dart';
import 'song_link_service.dart';
import 'encryption_service.dart';

@pragma('vm:entry-point')
class RadioAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  List<Station> _stations = [];
  AudioPlayer _player = AudioPlayer();
  AudioPlayer _nextPlayer = AudioPlayer(); // For Gapless transitions
  String? _nextPlayerSourceUrl; // Track what's preloaded in _nextPlayer
  bool _hasTriggeredEarlyStart = false; // Prevent multiple early triggers
  bool _isSwapping = false; // Flag for seamless transition state

  // ... (existing helper methods if any)

  bool _isRetryPending = false;
  bool _internalRetry = false;
  bool _expectingStop = false;
  bool _isInitialBuffering = false;
  final PlaylistService _playlistService = PlaylistService();
  int _retryCount = 0;
  int _consecutiveErrorCount = 0; // Prevent infinite skip loops

  // Internal Playlist Queue State
  List<MediaItem> _playlistQueue = [];
  int _playlistIndex = -1;
  bool _isShuffleMode = false;
  static const int _maxRetries = 5;
  int _currentSessionId = 0;
  final double _volume = 1.0;
  Duration _currentPosition = Duration.zero;
  String? _currentPlayingPlaylistId;

  // Callbacks
  VoidCallback? onSkipNext;
  VoidCallback? onSkipPrevious;
  VoidCallback? onPreloadNext; // New callback

  // Preloading State
  bool _hasTriggeredPreload = false;
  String? _cachedNextSongUrl;
  Map<String, dynamic>? _cachedNextSongExtras;
  DateTime? _lastSkipRequestTime;

  // Recognition
  bool _isACRCloudEnabled = true;
  bool _isDevUser = false; // Strict Guard
  final ACRCloudService _acrCloudService = ACRCloudService();
  final SongLinkService _songLinkService = SongLinkService();
  Timer? _recognitionTimer;

  void _logAnalyticsEvent(String name, [Map<String, Object?>? parameters]) {
    Future.microtask(() async {
      try {
        final Map<String, Object>? cleanParameters = parameters != null
            ? Map<String, Object>.fromEntries(
                parameters.entries.where((e) => e.value != null).map((e) {
                  var val = e.value!;
                  if (val is bool) val = val ? 1 : 0;
                  if (val is! num && val is! String) val = val.toString();
                  if (val is String && val.length > 100) {
                    val = val.substring(0, 100);
                  }
                  return MapEntry(e.key, val);
                }),
              )
            : null;
        await FirebaseAnalytics.instance
            .logEvent(name: name, parameters: cleanParameters)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    });
  }

  void setACRCloudEnabled(bool value) {
    if (!_isDevUser && value == true) return;
    _isACRCloudEnabled = value;
    if (!_isACRCloudEnabled) {
      _stopRecognition();
    }
  }

  void setDevUser(bool value) {
    _isDevUser = value;
    if (!_isDevUser) {
      _isACRCloudEnabled = false; // Force OFF
      _stopRecognition();
      // Clear any pre-existing song metadata if not authorized
      _handleNoMatch();
    }
  }

  void _stopRecognition() {
    _recognitionTimer?.cancel();
    _acrCloudService.cancel();
  }

  // Skip context
  String _radioSkipContext = 'all'; // 'all' or 'favorites'
  Set<int> _favoriteStationIds = {};

  // Stuck Playback Monitoring
  Timer? _stuckCheckTimer;
  Duration _lastStuckCheckPosition = Duration.zero;
  int _stuckSecondsCount = 0;

  // StreamSubscriptions to manage listeners when replacing player
  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _playerCompleteSubscription;
  StreamSubscription? _playerPositionSubscription;
  StreamSubscription? _playerDurationSubscription;

  // Ensure we don't have multiple initializations happening at once
  bool _isInitializing = false;
  final Completer<void> _initCompleter = Completer<void>();
  Future<void> get _initializationComplete => _initCompleter.future;

  Future<void> _initializePlayer() async {
    if (_isInitializing) return;
    _isInitializing = true;

    // Ensure EncryptionService is ready (Critical for Background Isolate)
    await EncryptionService().init();

    try {
      // 2. Clear Source/Stop instead of full dispose for tracks
      try {
        await _player.stop();
        await _player.release();
      } catch (_) {}

      // 3. Configure (Use defaults to match Test Screen, add minimal config)

      // 3. Configure both players for gapless
      for (var p in [_player, _nextPlayer]) {
        try {
          await p.setReleaseMode(ReleaseMode.stop);
          await p.setAudioContext(
            AudioContext(
              android: const AudioContextAndroid(
                isSpeakerphoneOn: false,
                stayAwake: true,
                contentType: AndroidContentType.music,
                usageType: AndroidUsageType.media,
                audioFocus: AndroidAudioFocus.gain,
              ),
              iOS: AudioContextIOS(
                category: AVAudioSessionCategory.playback,
                options: const {},
              ),
            ),
          );
        } catch (_) {}
      }

      _setupPlayerListeners();
    } catch (e) {
      LogService().log('Error initializing player: $e');
    } finally {
      _isInitializing = false;
    }
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _currentPosition = position;
    _broadcastState(_player.state);
  }

  void _setupPlayerListeners() {
    _playerStateSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _playerPositionSubscription?.cancel();
    _playerDurationSubscription?.cancel();

    _playerStateSubscription = _player.onPlayerStateChanged.listen(
      _broadcastState,
      onError: (Object e) {
        // CRITICAL FIX: Ignore player state errors for local files
        final bool isLocal =
            mediaItem.value?.extras?['isLocal'] == true ||
            mediaItem.value?.extras?['isLocal'] == 'true' ||
            (mediaItem.value?.id.startsWith('/') ?? false) ||
            (mediaItem.value?.id.startsWith('file:') ?? false) ||
            ((mediaItem.value?.id.contains(':') ?? false) &&
                !(mediaItem.value?.id.startsWith('http') ?? false));

        if (isLocal) {
          LogService().log("Ignored player state error for local file: $e");
          return;
        }

        String es = e.toString();
        if (es.contains("-1005") || es.contains("what:1")) {
          LogService().log(
            "Critical Player Error Detected: $es. Triggering recovery...",
          );
          _handleConnectionError("Connection failed (Error -1005)");
        }
      },
    );

    _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
      if (_expectingStop) return;

      final currentPos = _currentPosition;
      final totalDuration = mediaItem.value?.duration;

      bool isGenuineCompletion = true;
      if (totalDuration != null && totalDuration > Duration.zero) {
        // If we finished more than 10 seconds early, it's likely a stream error, not a natural end
        if ((totalDuration - currentPos).inSeconds > 10) {
          isGenuineCompletion = false;
        }
      } else {
        // For radio or items without duration, completion is usually an unexpected end
        isGenuineCompletion = false;
      }

      if (isGenuineCompletion) {
        skipToNext(reason: "Song completed normally");
      } else {
        // CRITICAL FIX: For local files, premature end shouldn't always trigger network recovery/skip
        final bool isLocal =
            mediaItem.value?.extras?['isLocal'] == true ||
            mediaItem.value?.extras?['isLocal'] == 'true' ||
            (mediaItem.value?.id.startsWith('/') ?? false) ||
            (mediaItem.value?.id.startsWith('file:') ?? false);

        if (isLocal) {
          LogService().log(
            "Local file ended prematurely at ${currentPos.inSeconds}s. Retrying playback instead of error...",
          );
          // Try to just resume or replay without counting as a network error
          _retryPlayback();
        } else {
          LogService().log(
            "Stream ended prematurely at ${currentPos.inSeconds}s. Triggering recovery...",
          );
          _handleConnectionError("Stream ended unexpectedly.");
        }
      }
    }, onError: (Object e) {});

    _playerDurationSubscription = _player.onDurationChanged.listen((d) {
      final currentItem = mediaItem.value;
      if (currentItem != null &&
          currentItem.extras?['type'] == 'playlist_song' &&
          d > Duration.zero) {
        // Update duration for playlist songs so progress bar and preloading work
        if (currentItem.duration != d) {
          mediaItem.add(currentItem.copyWith(duration: d));
          _broadcastState(_player.state);
        }
      }
    });

    _playerPositionSubscription = _player.onPositionChanged.listen((pos) {
      _currentPosition = pos; // Track position

      // Fallback: If we see position moving, we are definitely NOT buffering anymore
      // BUT we don't clear _expectingStop here as it might be a stale event from a previous track
      if (_isInitialBuffering && pos > Duration.zero) {
        _isInitialBuffering = false;
        _broadcastState(_player.state);
        // Also ensure stuck monitor starts if not already
        _startStuckMonitor();
        return;
      }

      if (_isInitialBuffering && !_expectingStop) {
        _isInitialBuffering = false;
        _broadcastState(_player.state);
        // Start recognition if in Radio Mode
        if (playbackState.value.playing &&
            mediaItem.value?.extras?['type'] != 'playlist_song') {
          if (_recognitionTimer == null || !_recognitionTimer!.isActive) {
            // Delay recognition by 5 seconds to match Application Rules
            Timer(const Duration(seconds: 5), () {
              if (playbackState.value.playing &&
                  (_isDevUser || _isACRCloudEnabled) &&
                  mediaItem.value?.extras?['type'] != 'playlist_song') {
                LogService().log("Attempting Recognition...5");
                _attemptRecognition();
              }
            });
          }
        }
      } else {
        // Enforce Metadata Limits - If metadata says 2:30, stop at 2:30 even if file is longer
        final expectedDuration = mediaItem.value?.duration;
        if (expectedDuration != null) {
          // Trigger preloading 10 seconds before end
          if (expectedDuration - pos <= const Duration(seconds: 10) &&
              expectedDuration > Duration.zero) {
            if (!_hasTriggeredPreload &&
                mediaItem.value?.extras?['type'] == 'playlist_song') {
              _hasTriggeredPreload = true;
              if (onPreloadNext != null) onPreloadNext!();
            }
          }

          // Trigger early start 5 seconds before end
          if (expectedDuration - pos <= const Duration(seconds: 5) &&
              expectedDuration > Duration.zero) {
            if (!_hasTriggeredEarlyStart &&
                mediaItem.value?.extras?['type'] == 'playlist_song' &&
                _nextPlayerSourceUrl != null) {
              _hasTriggeredEarlyStart = true;
              skipToNext(reason: "Gapless transition (early start)");
              return;
            }
          }

          if (pos >= expectedDuration) {
            if (!_expectingStop) {
              skipToNext(reason: "Reached expected end of track");
            }
            return;
          }
        }

        final lastPos = playbackState.value.position;
        if ((pos - lastPos).abs().inSeconds >= 2) {
          _broadcastState(_player.state);
        }
      }
    }, onError: (Object e) {});

    // Global Error Monitoring
    _player.onLog.listen((log) {
      if (log.toLowerCase().contains("error") ||
          log.toLowerCase().contains("exception")) {
        final bool isLocal =
            mediaItem.value?.extras?['isLocal'] == true ||
            mediaItem.value?.extras?['isLocal'] == 'true';

        if (_isInitialBuffering &&
            !_expectingStop &&
            !isLocal &&
            (log.contains("403") ||
                log.contains("-1005") ||
                log.contains("1002"))) {
          skipToNext(reason: "Playback error detected in player logs: $log");
        }
      }
    }, onError: (Object e) {});
  }

  // Startup Lock to prevent Android 12 Foreground Service Exceptions
  bool _startupLock = true;

  RadioAudioHandler() {
    _stations = [];
    // Don't wait for future in constructor, but start it
    _initializePlayer();

    // Release lock after 1 second (reduced from 3s for better AA responsiveness)
    Future.delayed(const Duration(seconds: 1), () {
      _startupLock = false;
    });

    // Monitor network connectivity
    Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      final current = mediaItem.value;
      if (current == null) return;

      final extraLocal = current.extras?['isLocal'];
      final bool isLocal = extraLocal == true || extraLocal == 'true';
      final bool hasLocalPath = current.extras?['localPath'] != null;
      final bool isFileId =
          current.id.startsWith('/') || current.id.startsWith('file://');

      // 1. Local Playback: STRICTLY IGNORE Internet status
      if (isLocal || hasLocalPath || isFileId) return;

      final hasConnection = !results.contains(ConnectivityResult.none);

      if (!hasConnection) {
        // Internet Lost: Stop player to prevent buffering stale data
        if (playbackState.value.playing) {
          // If playlist song, pause to preserve position logic more naturally
          if (mediaItem.value?.extras?['type'] == 'playlist_song') {
            _player.pause();
          } else {
            _player.stop(); // Clear buffer for radio
          }

          _isRetryPending = true;
          // Show buffering/waiting state
          playbackState.add(
            playbackState.value.copyWith(
              errorMessage: "Waiting for connection...",
              processingState: AudioProcessingState.buffering,
            ),
          );
        }
      } else {
        // Internet Restored
        if (_isRetryPending) {
          _retryPlayback();
        }
      }
    });

    // Load persisted stations independent of UI
    _initializeBackgroundState();
  }

  Future<void> _initializeBackgroundState() async {
    LogService().log("RadioAudioHandler: Starting background state load...");
    try {
      await _loadSettings();
      await _quickRestore();
      await _loadStationsFromPrefs();
      await _loadQueue();
      LogService().log("RadioAudioHandler: Background state load complete.");
    } catch (e) {
      LogService().log("RadioAudioHandler: Error loading background state: $e");
    } finally {
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }

      // Heartbeat Timer: Fixes stuck UI progress in Release builds
      Timer.periodic(const Duration(seconds: 1), (timer) {
        if (playbackState.value.playing ||
            _expectingStop ||
            _isInitialBuffering) {
          _broadcastState();
        }
      });
    }
  }

  Future<void> _quickRestore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastId = prefs.getString('last_media_id');
      final lastTitle = prefs.getString('last_media_title');
      final lastArt = prefs.getString('last_media_art');
      final lastType = prefs.getString('last_media_type') ?? 'station';

      if (lastId != null && lastTitle != null && mediaItem.value == null) {
        final lastStationId = prefs.getInt('last_station_id');
        final lastIsLocal = prefs.getBool('last_media_is_local') ?? false;
        final item = MediaItem(
          id: lastId,
          title: lastTitle,
          artUri: (lastArt != null && lastArt.isNotEmpty)
              ? Uri.tryParse(lastArt)
              : null,
          extras: {
            'url': lastId,
            'type': lastType,
            'isLocal': lastIsLocal,
            if (lastStationId != null) 'stationId': lastStationId,
          },
        );
        mediaItem.add(item);
        // Broadcast stopped state with this item to satisfy AA immediately
        _broadcastState(PlayerState.stopped);
      }
    } catch (_) {}
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isACRCloudEnabled = prefs.getBool('enable_acrcloud') ?? false;
    final email = prefs.getString('user_email');
    _isDevUser =
        email == utf8.decode(base64.decode("b3JhemlvLmZhemlvQGdtYWlsLmNvbQ=="));
  }

  Future<void> _loadStationsFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 1. Load Stations
      final String? jsonStr = prefs.getString('saved_stations');
      List<Station> loaded = [];
      if (jsonStr != null) {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        loaded = decoded.map((e) => Station.fromJson(e)).toList();
      }

      if (loaded.isEmpty) return;

      // 2. Load Order
      // We ALWAYS respect custom order within categories now
      final List<String>? orderStr = prefs.getStringList('station_order');
      List<int> order = [];
      if (orderStr != null) {
        order = orderStr
            .map((e) => int.tryParse(e) ?? -1)
            .where((e) => e != -1)
            .toList();
      }
      // 3. Determine Category Ranks based on Custom Order
      // The category order should follow the order of stations in the Favorites list.
      // i.e. if the first station is "Pop", then "Pop" is the first category.
      final Map<String, int> categoryRank = {};
      int currentRank = 0;

      // Map station IDs to Station objects for O(1) lookup
      final Map<int, Station> stationMap = {for (var s in loaded) s.id: s};
      // Walk through the custom order to establish category priority
      for (var id in order) {
        final station = stationMap[id];
        if (station != null) {
          final cat = station.category;
          if (!categoryRank.containsKey(cat)) {
            categoryRank[cat] = currentRank++;
          }
        }
      }

      // 4. Multi-Level Sort: Category Rank -> Custom Order
      loaded.sort((a, b) {
        String catA = a.category;
        String catB = b.category;

        // Primary: Category Rank
        // If a category is not in the rank map (e.g. station not in custom order), append at end sorted alphabetically
        int rankA = categoryRank[catA] ?? 9999;
        int rankB = categoryRank[catB] ?? 9999;

        if (rankA != rankB) {
          return rankA.compareTo(rankB);
        }

        // Fallback for unranked categories: Sort Alphabetically
        if (rankA == 9999) {
          int alpha = catA.compareTo(catB);
          if (alpha != 0) return alpha;
        }

        // Secondary: Custom Order within Category
        int idxA = order.indexOf(a.id);
        int idxB = order.indexOf(b.id);

        // Handle missing from order list (append at end)
        if (idxA == -1) idxA = 9999;
        if (idxB == -1) idxB = 9999;

        return idxA.compareTo(idxB);
      });
      _stations = loaded;

      // Load Favorites for Skip Logic
      final List<String>? favStr = prefs.getStringList('favorites');
      if (favStr != null) {
        _favoriteStationIds = favStr
            .map((e) => int.tryParse(e) ?? -1)
            .where((e) => e != -1)
            .toSet();

        // Default to favorites context if favorites exist
        if (_favoriteStationIds.isNotEmpty) {
          _radioSkipContext = 'favorites';
        }
      }

      // Ensure images are loaded (Application Rule)
      _ensureStationImages();
    } catch (e) {
      // Fallback
    }
  }

  void _ensureStationImages() {
    bool changed = false;
    for (int i = 0; i < _stations.length; i++) {
      final s = _stations[i];
      if (s.logo == null || s.logo!.isEmpty) {
        final split = s.genre.split(RegExp(r'[|/,]'));
        if (split.isNotEmpty) {
          final firstGenre = split.first.trim();
          if (firstGenre.isNotEmpty) {
            final img = GenreMapper.getGenreImage(firstGenre);
            if (img != null) {
              _stations[i] = Station(
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

  Future<void> _saveStations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encoded = jsonEncode(
        _stations.map((s) => s.toJson()).toList(),
      );
      await prefs.setString('saved_stations', encoded);
    } catch (_) {}
  }

  Future<void> _loadQueue() async {
    // START: Filter logic for Android Auto (Matches Home Screen Favorites)
    var targetStations = _stations;
    if (_favoriteStationIds.isNotEmpty) {
      targetStations = _stations
          .where((s) => _favoriteStationIds.contains(s.id))
          .toList();
    }
    // Fallback if filtering resulted in empty list (paranoid check)
    if (targetStations.isEmpty) {
      targetStations = _stations;
    }
    // END: Filter logic
    final queueItems = targetStations
        .map(
          (s) => MediaItem(
            id: s.url,
            album: "Live Radio",
            title: s.name,
            artist: '',
            artUri: s.logo != null ? Uri.parse(s.logo!) : null,
            playable: true,
            extras: {'url': s.url, 'type': 'station', 'stationId': s.id},
          ),
        )
        .toList();
    queue.add(queueItems);
    // Ensure Android Auto sees the app as "Ready" immediately with valid content
    // We run this even if mediaItem is not null to refine quick-restored metadata
    if (queueItems.isNotEmpty) {
      MediaItem? startupItem;

      try {
        final prefs = await SharedPreferences.getInstance();
        final lastId = prefs.getString('last_media_id');
        final lastType = prefs.getString('last_media_type');
        if (lastId != null) {
          if (lastType == 'station' || lastType == null) {
            // Restore Station
            startupItem = queueItems.firstWhere(
              (item) => item.id == lastId,
              orElse: () => queueItems.first,
            );
          } else if (lastType == 'playlist_song') {
            // Restore Playlist Context
            final lastPlaylistId = prefs.getString('last_playlist_id');
            if (lastPlaylistId != null) {
              final playlists = await _playlistService.loadPlaylists();
              final playlist = playlists.firstWhere(
                (p) => p.id == lastPlaylistId,
                orElse: () => model.Playlist(
                  id: '',
                  name: '',
                  songs: [],
                  createdAt: DateTime.now(),
                ),
              );

              if (playlist.id == lastPlaylistId) {
                // Rebuild Queue logic (similar to playFromMediaId)
                _currentPlayingPlaylistId = playlist.id;
                _playlistQueue = playlist.songs
                    .map((ps) => _songToMediaItem(ps, playlist.id))
                    .toList();

                // Find specific song
                final songIndex = _playlistQueue.indexWhere(
                  (item) => item.id == lastId,
                );
                if (songIndex != -1) {
                  _playlistIndex = songIndex;
                  startupItem = _playlistQueue[songIndex];
                  queue.add(_playlistQueue); // Update system queue
                }
              }
            }
          }
        }
      } catch (_) {}

      // Fallback to first station if restoration failed
      if (startupItem == null && queueItems.isNotEmpty) {
        startupItem = queueItems.first;
      }

      if (startupItem != null) {
        mediaItem.add(startupItem);
      }
    }

    // Broadcast "Ready" state so AA shows controls immediately
    _broadcastState(PlayerState.stopped);
  }

  void _handleConnectionError(String message) {
    if (_expectingStop) return;

    playbackState.add(
      playbackState.value.copyWith(
        errorMessage: message,
        processingState:
            AudioProcessingState.buffering, // Show loading during retry
      ),
    );

    _isRetryPending = true;

    // Auto-retry logic
    _retryCount++;
    if (_retryCount > _maxRetries) {
      _isRetryPending = false;
      playbackState.add(
        playbackState.value.copyWith(
          errorMessage: "Unable to connect after multiple attempts.",
          processingState: AudioProcessingState.error,
          playing: false,
        ),
      );
      return;
    }

    Future.delayed(const Duration(seconds: 3), () {
      if (_isRetryPending) {
        _retryPlayback();
      }
    });
  }

  Future<void> _playYoutubeVideo(
    String videoId,
    SavedSong song,
    String playlistId, {
    Duration? startAt,
  }) async {
    // Session Management to allow cancellation
    final sessionId = DateTime.now().millisecondsSinceEpoch;
    _currentSessionId = sessionId;

    _expectingStop =
        true; // Block "Ready" state from stop() to keep UI in Buffering/Loading mode
    _isInitialBuffering = true;
    _currentPosition = Duration.zero;
    _broadcastState(PlayerState.stopped);

    // Safety watchdog: Clear loading state if stuck
    final watchdogId = sessionId;
    Future.delayed(const Duration(seconds: 15), () {
      if (_currentSessionId == watchdogId &&
          (_expectingStop || _isInitialBuffering)) {
        LogService().log(
          "Watchdog: Forcing clear of stuck loading state in _playYoutubeVideo",
        );
        _expectingStop = false;
        _isInitialBuffering = false;
        _broadcastState(); // Broadcast state to ensure UI updates
        _retryPlayback(); // Try to restart the song
      }
    });

    _stopRecognition(); // Stop ACRCloud if switching to a playlist song

    // Always reset flags
    _hasTriggeredPreload = false;
    _hasTriggeredEarlyStart = false;

    // LOCAL FILE CHECK
    // Fallback: If local path is null but videoId looks like a path
    String? effectiveLocalPath = song.localPath;
    if (effectiveLocalPath == null) {
      if (videoId.startsWith('/') ||
          (videoId.contains(':') && !videoId.startsWith('http'))) {
        effectiveLocalPath = videoId;
      }
    }

    if (effectiveLocalPath != null) {
      final extras = {
        'title': _getSongTitleWithIcons(song.title, effectiveLocalPath),
        'artist': song.artist,
        'album': song.album,
        'artUri': song.artUri,
        'localPath': effectiveLocalPath,
        'playlistId': playlistId,
        'songId': song.id,
        'type': 'playlist_song',
        'isLocal': true,
        'is_resolved': true,
        'user_initiated': true,
        'stableId': song.id,
        'startAt': startAt,
      };
      await _playYoutubeSong(effectiveLocalPath, extras);
      return;
    }

    // Check for preloaded stream FIRST
    if (_cachedNextSongExtras?['uniqueId'] == "${song.id}-$videoId" &&
        _cachedNextSongUrl != null) {
      final streamUrl = _cachedNextSongUrl!;

      final extras = {
        'title': song.title,
        'artist': song.artist,
        'album': song.album,
        'artUri': song.artUri,
        'youtubeUrl': song.youtubeUrl,
        'playlistId': playlistId,
        'songId': song.id,
        'videoId': videoId,
        'type': 'playlist_song',
        'is_resolved': true,
        'duration': _cachedNextSongExtras?['duration'],
        'user_initiated': true,

        'stableId': song.youtubeUrl ?? 'song_${song.id}',
        'startAt': startAt,
      };

      // DO WE HAVE A WARM PLAYER? (Gapless Swap)
      if (_nextPlayerSourceUrl == streamUrl) {
        await _swapPlayers(streamUrl, extras);
        return;
      }

      // Fallback: Clear cache and use normal flow if player wasn't warm
      _cachedNextSongUrl = null;
      _cachedNextSongExtras = null;
      await playFromUri(Uri.parse(streamUrl), extras);
      return;
    }

    // SLOW PATH: Not cached.

    // 1. Immediate UI Feedback (Before Stop)
    final String stableId = song.youtubeUrl ?? 'song_${song.id}';
    final placeholderItem = MediaItem(
      id: stableId,
      album: song.album,
      title: _getSongTitleWithIcons(song.title, song.localPath),
      artist: song.artist,
      artUri: _sanitizeArtUri(song.artUri, "${song.title} ${song.artist}"),
      extras: {
        'type': 'playlist_song',
        'playlistId': playlistId,
        'songId': song.id,
        'videoId': videoId,
        'stableId': stableId,
      },
    );
    mediaItem.add(placeholderItem);

    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.buffering,
        playing: true,
        errorMessage: null,
      ),
    );

    // 2. Stop previous playback (Async)
    try {
      await _player.stop();
    } catch (_) {}

    try {
      var yt = YoutubeExplode();

      // OPTIMIZATION: Check if session changed before network call
      if (_currentSessionId != sessionId) {
        yt.close();
        return;
      }

      var video = await yt.videos
          .get(videoId)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () =>
                throw TimeoutException("YouTube video info timed out"),
          );

      if (_currentSessionId != sessionId) {
        yt.close();
        return;
      }

      var manifest = await yt.videos.streamsClient
          .getManifest(videoId)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () =>
                throw TimeoutException("YouTube manifest timed out"),
          );
      var streamInfo = manifest.muxed.withHighestBitrate();
      yt.close();

      if (_currentSessionId != sessionId) return;

      final streamUrl = streamInfo.url.toString();

      final extras = {
        'title': song.title,
        'artist': song.artist,
        'album': song.album,
        'artUri': song.artUri,
        'youtubeUrl': song.youtubeUrl,
        'playlistId': playlistId,
        'songId': song.id,
        'videoId': videoId,
        'type': 'playlist_song',
        'is_resolved': true,
        'duration': video.duration?.inSeconds,
        'user_initiated': true,
        'stableId': stableId,
        'startAt': startAt,
      };

      if (_currentSessionId == sessionId) {
        await playFromUri(Uri.parse(streamUrl), extras);
        // Error count will be reset in playFromUri on success
      }
    } catch (e) {
      if (_currentSessionId != sessionId) return;

      final errorStr = e.toString();
      LogService().log(
        "YouTube Resolution Failure for ${song.title} ($videoId): $errorStr",
      );

      final bool isLocal =
          song.localPath != null || song.id.startsWith('local_');
      final connectivityResult = await Connectivity().checkConnectivity();
      final bool isNetwork = !connectivityResult.contains(
        ConnectivityResult.none,
      );

      _expectingStop = false;
      _isInitialBuffering = false;

      if (isLocal) {
        playbackState.add(
          playbackState.value.copyWith(
            errorMessage: "Local file error: $errorStr",
            processingState: AudioProcessingState.error,
          ),
        );
      } else if (isNetwork) {
        if (_consecutiveErrorCount < 3) {
          _consecutiveErrorCount++;

          // Categorize error for logging
          String category = "Unknown";
          if (errorStr.contains("TimeoutException"))
            category = "Timeout";
          else if (errorStr.contains("403"))
            category = "Forbidden (403)";
          else if (errorStr.contains("unavailable"))
            category = "Video Unavailable";
          else if (errorStr.contains("not found"))
            category = "Not Found";

          LogService().log(
            "Playback Error Category: $category. Error: $errorStr",
          );

          if (category != "Timeout" && category != "Unknown") {
            await _playlistService.markSongAsInvalidGlobally(song.id);
          }

          playbackState.add(
            playbackState.value.copyWith(
              errorMessage: "Playback Error ($category). Skipping...",
              processingState: AudioProcessingState.buffering,
            ),
          );

          Future.delayed(const Duration(seconds: 3), () {
            if (_currentSessionId == sessionId) {
              skipToNext(reason: "YouTube resolution failed: $category");
            }
          });
        } else {
          _consecutiveErrorCount = 0;
          playbackState.add(
            playbackState.value.copyWith(
              errorMessage: "Multiple failures. Stopped.",
              processingState: AudioProcessingState.error,
              playing: false,
            ),
          );
        }
      } else {
        playbackState.add(
          playbackState.value.copyWith(
            errorMessage: "No Internet Connection",
            processingState: AudioProcessingState.error,
            playing: false,
          ),
        );
      }
    }
  }

  Future<void> _retryPlayback() async {
    final currentUrl = mediaItem.value?.id;
    if (currentUrl == null) {
      return;
    }

    // Check connectivity first
    final extraLocal = mediaItem.value?.extras?['isLocal'];
    final bool isLocal = extraLocal == true || extraLocal == 'true';

    if (!isLocal) {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult.contains(ConnectivityResult.none)) {
        playbackState.add(
          playbackState.value.copyWith(
            errorMessage: "No Internet Connection",
            processingState: AudioProcessingState.error,
          ),
        );
        return; // Wait for connectivity change
      }
    }

    _isRetryPending = false;
    _internalRetry = true; // Flag to prevent reset of counter

    // Attempt to restart
    playbackState.add(
      playbackState.value.copyWith(
        errorMessage: null, // Clear error
        processingState: AudioProcessingState.buffering,
      ),
    );

    var extras = mediaItem.value?.extras;
    if (extras != null && extras['type'] == 'playlist_song') {
      // Create copy to add resume position
      extras = Map<String, dynamic>.from(extras);
      extras['startAt'] = _currentPosition;
      // CRITICAL: Force resolution because the ID in mediaItem is likely the stableId,
      // not the stream URL. We need _playYoutubeVideo to re-resolve it.
      extras['is_resolved'] = false;
    }

    await playFromUri(Uri.parse(currentUrl), extras);
    _internalRetry = false;
  }

  @override
  Future<void> pause() async {
    _isInitialBuffering = false;
    _expectingStop = false;
    try {
      // For playlist songs, use pause() to keep position. For radio, stop() to clear buffer.
      if (mediaItem.value?.extras?['type'] == 'playlist_song') {
        await _player.pause();
      } else {
        await _player.stop();
        _recognitionTimer?.cancel();
      }
    } catch (_) {}
    // Manually update state so UI knows we paused immediately
    _broadcastState(PlayerState.paused);
  }

  @override
  Future<void> stop() async {
    _stopRecognition();
    _isInitialBuffering = false;
    _expectingStop = false;
    try {
      await _player.stop();
      // await _player.release();
    } catch (_) {}
    _broadcastState(PlayerState.stopped);
    await super.stop();
  }

  @override
  Future<void> play() async {
    await _initializationComplete;
    _startupLock = false; // User Action unlocks
    // If paused, just resume without reloading
    if (_player.state == PlayerState.paused) {
      _expectingStop = false;
      await _player.resume();
      // State will be updated by listener, but we can force it for responsiveness
      _broadcastState(PlayerState.playing);

      // Restart Recognition Cycle if Radio Mode
      if (_isACRCloudEnabled &&
          mediaItem.value?.extras?['type'] != 'playlist_song') {
        LogService().log("Attempting Recognition...6");
        _attemptRecognition();
      }
      return;
    }

    final currentItem = mediaItem.value;
    if (currentItem != null) {
      _expectingStop = false;
      await playFromUri(Uri.parse(currentItem.id), currentItem.extras);
    }
  }

  @override
  Future<void> skipToNext({String? reason}) async {
    final now = DateTime.now();
    if (_lastSkipRequestTime != null &&
        now.difference(_lastSkipRequestTime!) <
            const Duration(milliseconds: 500)) {
      return;
    }
    _lastSkipRequestTime = now;

    LogService().log(
      "SkipToNext: ${reason ?? 'User initiated or manual skip'}. Current: ${mediaItem.value?.title ?? 'None'}",
    );

    _startupLock = false;

    // Optimistic: Signal buffering/loading immediately
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.buffering,
      ),
    );

    // 0. Safety Check: If current item is a STATION, force clear queue to ensure we use Radio Logic
    if (mediaItem.value?.extras?['type'] == 'station') {
      _playlistQueue.clear();
      _currentPlayingPlaylistId = null;
    }

    // 1. Check Internal Queue (Android Auto / Background Priority)
    if (_playlistQueue.isNotEmpty) {
      if (_playlistIndex < _playlistQueue.length - 1) {
        _playlistIndex++;
      } else {
        _playlistIndex = 0; // Loop
      }
      final item = _playlistQueue[_playlistIndex];
      await playFromMediaId(item.id, {'queue_ready': true});
      return;
    }

    // 2. Radio Skipping logic (prioritize internal list for consistency with AA display)
    if (_stations.isNotEmpty &&
        mediaItem.value?.extras?['type'] != 'playlist_song') {
      final current = mediaItem.value;
      if (current != null) {
        // Determine the list to skip through
        List<Station> skipList = _stations;
        if (_radioSkipContext == 'favorites' &&
            _favoriteStationIds.isNotEmpty) {
          skipList = _stations
              .where((s) => _favoriteStationIds.contains(s.id))
              .toList();
          // Fallback if current station is not in favorites but context is favorites
        }

        // Try to find index by Station ID (most reliable), then URL
        int index = -1;
        final currentStationId = current.extras?['stationId'];
        if (currentStationId != null) {
          index = skipList.indexWhere((s) => s.id == currentStationId);
        }

        if (index == -1) {
          index = skipList.indexWhere((s) => s.url == current.id);
        }

        if (index == -1 && current.extras?['url'] != null) {
          index = skipList.indexWhere((s) => s.url == current.extras!['url']);
        }

        if (index != -1) {
          int nextIndex = (index + 1) % skipList.length;
          final s = skipList[nextIndex];
          await playFromUri(Uri.parse(s.url), {
            'title': s.name,
            'artUri': s.logo,
            'type': 'station',
            'url': s.url,
            'stationId': s.id,
            'user_initiated': true,
          });
          return;
        }
      }
    }

    // 3. Fallback to Provider (Playlists / Other)
    if (onSkipNext != null) {
      onSkipNext!();
    } else {
      // Final fallback if everything else fails
      if (_stations.isNotEmpty) {
        final current = mediaItem.value;
        if (current == null) {
          await playFromUri(Uri.parse(_stations.first.url));
        } else {
          int index = _stations.indexWhere((s) => s.url == current.id);
          int nextIndex = (index + 1) % _stations.length;
          final s = _stations[nextIndex];
          await playFromUri(Uri.parse(s.url), {
            'title': s.name,
            'artUri': s.logo,
            'type': 'station',
            'user_initiated': true,
          });
        }
      }
    }
  }

  Future<void> preloadNextStream(String videoId, String songId) async {
    try {
      // Handle Local / Encrypted Files
      if (videoId.contains('/') ||
          videoId.contains('\\') ||
          videoId.contains('_secure') ||
          videoId.startsWith('file://')) {
        String filePath = videoId;
        try {
          if (filePath.startsWith('file://')) {
            filePath = Uri.parse(filePath).toFilePath();
          }
        } catch (_) {}

        final bool isEncrypted =
            filePath.contains('_secure') ||
            filePath.endsWith('.mst') ||
            filePath.contains('offline_music');

        if (isEncrypted) {
          final tempFile = await EncryptionService().decryptToTempFile(
            filePath,
          );
          await _nextPlayer.setSource(DeviceFileSource(tempFile.path));
        } else {
          await _nextPlayer.setSource(DeviceFileSource(filePath));
        }

        _cachedNextSongUrl = filePath;
        _cachedNextSongExtras = {
          'videoId': videoId,
          'songId': songId,
          'uniqueId': "$songId-$videoId",
        };
        _nextPlayerSourceUrl = filePath;
        await _nextPlayer.stop();
        return;
      }

      if (_cachedNextSongExtras?['uniqueId'] == "$songId-$videoId") return;

      var yt = YoutubeExplode();
      var video = await yt.videos.get(videoId);
      var manifest = await yt.videos.streamsClient.getManifest(videoId);
      var streamInfo = manifest.muxed.withHighestBitrate();
      yt.close();

      final streamUrl = streamInfo.url.toString();
      _cachedNextSongUrl = streamUrl;
      _cachedNextSongExtras = {
        'videoId': videoId,
        'songId': songId,
        'uniqueId': "$songId-$videoId",
        'duration': video.duration?.inSeconds,
      };

      // PRE-LOAD into the SECOND player for gapless swap
      _nextPlayerSourceUrl = streamUrl;
      await _nextPlayer.setSource(UrlSource(streamUrl));
      // Ensure it stays paused/stopped while buffering
      await _nextPlayer.stop();
    } catch (e) {
      // Ignore preloading errors; playback will resolve on demand if needed.
    }
  }

  @override
  Future<void> skipToPrevious({String? reason}) async {
    LogService().log(
      "SkipToPrevious: ${reason ?? 'User initiated'}. Current: ${mediaItem.value?.title ?? 'None'}",
    );
    _startupLock = false;

    // 0. Safety Check: If current item is a STATION, force clear queue to ensure we use Radio Logic
    if (mediaItem.value?.extras?['type'] == 'station') {
      _playlistQueue.clear();
      _currentPlayingPlaylistId = null;
    }

    // 1. Check Internal Queue
    if (_playlistQueue.isNotEmpty) {
      if (_playlistIndex > 0) {
        _playlistIndex--;
      } else {
        _playlistIndex = _playlistQueue.length - 1; // Loop
      }
      final item = _playlistQueue[_playlistIndex];
      await playFromMediaId(item.id, {'queue_ready': true});
      return;
    }

    // 2. Radio Skipping logic
    if (_stations.isNotEmpty &&
        mediaItem.value?.extras?['type'] != 'playlist_song') {
      final current = mediaItem.value;
      if (current != null) {
        // Determine the list to skip through
        List<Station> skipList = _stations;
        if (_radioSkipContext == 'favorites' &&
            _favoriteStationIds.isNotEmpty) {
          skipList = _stations
              .where((s) => _favoriteStationIds.contains(s.id))
              .toList();
        }

        int index = -1;
        final currentStationId = current.extras?['stationId'];
        if (currentStationId != null) {
          index = skipList.indexWhere((s) => s.id == currentStationId);
        }

        if (index == -1) {
          index = skipList.indexWhere((s) => s.url == current.id);
        }

        if (index == -1 && current.extras?['url'] != null) {
          index = skipList.indexWhere((s) => s.url == current.extras!['url']);
        }

        if (index != -1) {
          int prevIndex = index - 1;
          if (prevIndex < 0) prevIndex = skipList.length - 1;
          final s = skipList[prevIndex];
          await playFromUri(Uri.parse(s.url), {
            'title': s.name,
            'artUri': s.logo,
            'type': 'station',
            'url': s.url,
            'stationId': s.id,
            'user_initiated': true,
          });
          return;
        }
      }
    }

    // 3. Fallback
    if (onSkipPrevious != null) {
      onSkipPrevious!();
    } else {
      if (_stations.isNotEmpty) {
        final current = mediaItem.value;
        if (current != null) {
          int index = _stations.indexWhere((s) => s.url == current.id);
          int prevIndex = index - 1;
          if (prevIndex < 0) prevIndex = _stations.length - 1;
          final s = _stations[prevIndex];
          await playFromUri(Uri.parse(s.url), {
            'title': s.name,
            'artUri': s.logo,
            'type': 'station',
            'user_initiated': true,
          });
        }
      }
    }
  }

  Future<void> _swapPlayers(String url, Map<String, dynamic> extras) async {
    // 1. Prepare Metadata
    final String title = extras['title'] ?? "Song";
    final String artist = extras['artist'] ?? "Artist";
    final String album = extras['album'] ?? "Playlist";
    final String? artUri = extras['artUri'];

    MediaItem newItem = MediaItem(
      id: extras['stableId'] ?? url,
      album: album,
      title: title,
      artist: artist,
      duration: extras['duration'] != null
          ? Duration(seconds: extras['duration'])
          : null,
      artUri: artUri != null ? Uri.parse(artUri) : null,
      playable: true,
      extras: extras,
    );
    mediaItem.add(newItem);

    // 2. The Swap
    _isSwapping = true;
    _stopRecognition(); // Cancel recognition during swap

    _expectingStop = true; // Silence the dying player events

    // Switch references
    final oldPlayer = _player;
    _player = _nextPlayer;
    _nextPlayer = oldPlayer;
    _nextPlayerSourceUrl = null; // Clear warm flag

    // 3. Start the NEW main player
    await _player.resume();
    _setupPlayerListeners(); // Re-attach listeners to the new main
    _isSwapping = false;
    _expectingStop = false;

    _broadcastState(PlayerState.playing);

    // 4. Fade out and stop the OLD player (now in _nextPlayer)
    _fadeOutAndStop(_nextPlayer);

    // Clear cache
    _cachedNextSongUrl = null;
    _cachedNextSongExtras = null;
  }

  Future<void> _fadeOutAndStop(AudioPlayer player) async {
    try {
      // Short crossfade: 2 seconds
      for (double v = 1.0; v >= 0; v -= 0.2) {
        await player.setVolume(v);
        await Future.delayed(const Duration(milliseconds: 400));
      }
      await player.stop();
      await player.setVolume(1.0); // Reset volume for next time it becomes main
    } catch (_) {}
  }

  // --- RESTORED HELPER METHODS ---

  /// Helper to notify system about children changes (Android Auto)
  /// Note: This method was missing in BaseAudioHandler or removed in newer versions.
  /// We define it here to prevent compilation errors.
  /// If using audio_service 0.18+, this might need to be replaced with specific stream updates.
  void notifyChildrenChanged(dynamic subject) {
    // Implementation depends on specific audio_service version features.
    // For 0.18.x, invalidating the browsing cache might require re-broadcasting custom events or queue.
    // Currently acting as a stub to allow compilation.
  }

  void updateStations(List<Station> newStations) {
    _stations = List.from(newStations);
    _loadQueue();
    // Force AA Refresh
    notifyChildrenChanged({'android.service.media.extra.RECENT': null});
    notifyChildrenChanged('all_stations');
    notifyChildrenChanged('root');
  }

  Future<void> refreshPlaylists() async {
    // Expose this to allow UI to trigger AA refresh
    notifyChildrenChanged('playlists_root');
    // Also refresh specific playlists if possible, but root is usually enough to re-enter
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    _startupLock = false; // Action unlocks
    if (name == 'stopExternalPlayback') {
      playbackState.add(playbackState.value.copyWith(playing: false));
    } else if (name == 'startExternalPlayback') {
      // No-op, provider handles logic
    } else if (name == 'updatePlaybackPosition') {
      final position = extras?['position'];
      final duration = extras?['duration'];
      final isPlaying = extras?['isPlaying'] ?? false;
      if (position != null) {
        final old = playbackState.value;
        playbackState.add(
          PlaybackState(
            controls: old.controls,
            systemActions: old.systemActions,
            androidCompactActionIndices: old.androidCompactActionIndices,
            processingState: AudioProcessingState.ready,
            playing: isPlaying,
            updatePosition: Duration(milliseconds: position),
            bufferedPosition: duration != null
                ? Duration(milliseconds: duration)
                : Duration.zero,
            speed: 1.0,
            updateTime: DateTime.now(),
            queueIndex: old.queueIndex,
            errorMessage: null,
            repeatMode: old.repeatMode,
            shuffleMode: old.shuffleMode,
          ),
        );
        _isInitialBuffering =
            false; // If we're getting position updates, we're not buffering anymore
      }
    } else if (name == 'retryPlayback') {
      await _retryPlayback();
    } else if (name == 'setVolume') {
      final vol = extras?['volume'] as double?;
      if (vol != null) {
        try {
          await _player.setVolume(vol);
        } catch (_) {}
      }
    } else if (name == 'toggle_shuffle') {
      final newMode = _isShuffleMode
          ? AudioServiceShuffleMode.none
          : AudioServiceShuffleMode.all;
      await setShuffleMode(newMode);
    } else if (name == 'noop') {
      // Do nothing, just feedback
    } else if (name == 'setACRCloudEnabled') {
      final value = extras?['value'] as bool?;
      if (value != null) {
        _isACRCloudEnabled = value;
        if (!_isACRCloudEnabled) {
          _recognitionTimer?.cancel();
        } else {
          if (playbackState.value.playing &&
              mediaItem.value?.extras?['type'] != 'playlist_song') {
            LogService().log("Attempting Recognition...7");
            _attemptRecognition();
          }
        }
      }
    }
    return null;
  }

  Future<String> _resolveStreamUrl(
    String url, {
    bool isPlaylistSong = false,
  }) async {
    final lower = url.toLowerCase();

    // Explicit bypass for known direct streams
    if (isPlaylistSong ||
        lower.contains('googlevideo.com') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.mp4')) {
      return url;
    }

    final isPlaylist =
        lower.endsWith('.pls') ||
        lower.endsWith('.m3u') ||
        lower.contains('.pls?') ||
        lower.contains('.m3u?');
    // REMOVED .m3u8: HLS streams should typically be handled natively by the player.
    // Parsing them manually breaks streams with relative paths (Akamai/RTL etc).

    if (!isPlaylist) {
      return url;
    }

    final client = http.Client();
    try {
      final uri = Uri.parse(url);
      final request = http.Request('GET', uri)
        ..followRedirects = true
        ..headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36';

      final response = await client.send(request);

      // Safety: Only read body if Content-Type is text-like (playlist)
      // And limit download size to 100KB to prevent hanging on direct audio streams
      final cType = response.headers['content-type']?.toLowerCase() ?? '';
      final cLength =
          int.tryParse(response.headers['content-length'] ?? '0') ?? 0;

      if (cType.contains('audio') ||
          cType.contains('video') ||
          cType.contains('octet-stream') ||
          cLength > 102400) {
        // > 100KB
        return url;
      }

      final bodyBytes = await response.stream.toBytes().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException("Playlist download timed out"),
      );
      final body = String.fromCharCodes(bodyBytes);

      if (body.contains('[playlist]')) {
        final lines = body.split('\n');
        for (var line in lines) {
          if (line.toLowerCase().startsWith('file1=')) {
            return line.substring(6).trim();
          }
        }
      }

      final lines = body.split('\n');
      for (var line in lines) {
        line = line.trim();
        if (line.isNotEmpty && !line.startsWith('#')) {
          return line;
        }
      }

      return url;
    } catch (_) {
      return url;
    } finally {
      client.close();
    }
  }

  // --- AUDIO PLAYER CONTROLS ---

  // NEW: Dedicated playback method for YouTube/Playlist songs
  Future<void> _playYoutubeSong(String url, Map<String, dynamic> extras) async {
    final sessionId = DateTime.now().millisecondsSinceEpoch;
    _currentSessionId = sessionId;

    // Update UI immediately
    final String rawTitle = extras['title'] ?? "Song";
    final String title = _getSongTitleWithIcons(rawTitle, extras['localPath']);
    final String artist = extras['artist'] ?? "Artist";
    final String album = extras['album'] ?? "Playlist";
    final String? artUri = extras['artUri'];

    // Use sanitized URI helper to ensure AA compatibility
    final Uri? validArtUri = _sanitizeArtUri(artUri, "$title $artist");

    // INFER LOCALITY from URL if not provided
    // This handles manual playback of local files via playDirectAudio
    if (!extras.containsKey('isLocal')) {
      final String lowerUrl = url.toLowerCase();
      // Robust check for local files including Windows paths
      if (lowerUrl.startsWith('/') ||
          lowerUrl.startsWith('file://') ||
          (lowerUrl.contains(':') && !lowerUrl.startsWith('http'))) {
        extras['isLocal'] = true;
      }
    }

    // Set MediaItem
    MediaItem newItem = MediaItem(
      id: extras['stableId'] ?? url,
      album: album,
      title: title,
      artist: artist,
      duration: extras['duration'] != null
          ? Duration(seconds: extras['duration'])
          : null,
      artUri: validArtUri,
      playable: true,
      extras: extras,
    );
    mediaItem.add(newItem);

    // Force immediate transition to Loading state
    _expectingStop = true;
    _isInitialBuffering = true;
    _currentPosition = Duration.zero;
    _broadcastState(PlayerState.stopped);

    // Async Work
    Future.microtask(() async {
      if (_currentSessionId != sessionId) return;

      try {
        // OPTIMIZATION: Reuse player if healthy
        if (_player.state == PlayerState.disposed) {
          _player = AudioPlayer();
          _setupPlayerListeners();
          await _player.setPlaybackRate(1.0);

          // Configure Context (only needed on creation)
          await _player.setAudioContext(
            AudioContext(
              android: const AudioContextAndroid(
                isSpeakerphoneOn: false,
                stayAwake: true,
                contentType: AndroidContentType.music,
                usageType: AndroidUsageType.media,
                audioFocus: AndroidAudioFocus.gain,
              ),
              iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
            ),
          );
        }

        final extraLocal = extras['isLocal'];
        // FORCE RE-CHECK: If url looks like a path, treat as local
        final bool looksLikeLocal =
            url.startsWith('/') ||
            url.contains(':') && !url.startsWith('http') ||
            url.startsWith('file://');

        final bool isLocal =
            (extraLocal == true || extraLocal == 'true') || looksLikeLocal;

        // 4. Load Source & Play
        // CRITICAL: Always use ReleaseMode.stop for re-usable players.
        // ReleaseMode.release can dispose the player on Windows/Android when finished.
        await _player.setReleaseMode(ReleaseMode.stop);

        // Explicit Clean Stop before source change
        try {
          await _player.stop();
        } catch (_) {}

        if (isLocal) {
          // Stop any existing playback first to ensure clean state
          await _player.stop();

          LogService().log(
            "LOCAL PLAYBACK: Attempting to play local file. Raw URL: $url",
          );

          String filePath = url;
          // Clean up file URI if present
          if (url.startsWith('file://')) {
            try {
              filePath = Uri.parse(url).toFilePath();
            } catch (e) {
              LogService().log(
                "LOCAL PLAYBACK: Error converting URI to file path: $e",
              );
            }
          }

          LogService().log("LOCAL PLAYBACK: Resolved File Path: $filePath");

          final file = File(filePath);
          if (!await file.exists()) {
            // FALLBACK: Path might be URL encoded (e.g. %20 for spaces) but missing file:// scheme
            if (filePath.contains('%')) {
              try {
                final decodedPath = Uri.decodeFull(filePath);
                final decodedFile = File(decodedPath);
                if (await decodedFile.exists()) {
                  LogService().log(
                    "LOCAL PLAYBACK: Found file after decoding: $decodedPath",
                  );
                  filePath = decodedPath;
                  // file reference not needed to be updated here as we use filePath below,
                  // but for consistency/safety in future blocks:
                  // file = decodedFile; // file is final, can't update.
                }
              } catch (e) {
                LogService().log("LOCAL PLAYBACK: Error decoding path: $e");
              }
            }

            // Check again after potential update
            if (!await File(filePath).exists()) {
              LogService().log(
                "LOCAL PLAYBACK ERROR: File does not exist at path: $filePath",
              );
            }
          }

          // Ensure Release Mode is correct before setting source
          final bool isEncrypted =
              url.contains('_secure') ||
              url.endsWith('.mst') ||
              url.contains('offline_music');

          try {
            if (isEncrypted) {
              LogService().log("LOCAL PLAYBACK: Playing as Encrypted Source");

              // SIMPLIFICATION: Decrypt to temp file instead of streaming via HTTP loopback
              // This avoids network/binding issues on Android.
              try {
                LogService().log("LOCAL PLAYBACK: Decrypting to temp file...");
                final tempFile = await EncryptionService().decryptToTempFile(
                  filePath,
                );
                if (!await tempFile.exists() || await tempFile.length() == 0) {
                  throw Exception("Decrypted temp file is invalid or empty");
                }

                await _player.stop(); // Force stop to clear buffers
                LogService().log(
                  "LOCAL PLAYBACK: Set Source: ${tempFile.path}",
                );
                await _player.setSource(DeviceFileSource(tempFile.path));
              } catch (e) {
                LogService().log("LOCAL PLAYBACK ERROR: Decryption failed: $e");
                // Do NOT rethrow immediately if we want to try something else?
                // Actually, for encrypted files, if decryption fails, we CANNOT play the original.
                // So we MUST fail here.
                throw Exception("Failed to prepare encrypted file: $e");
              }
            } else {
              LogService().log(
                "LOCAL PLAYBACK: Setting DeviceFileSource: $filePath",
              );
              await _player.setSource(DeviceFileSource(filePath));
            }
          } catch (e) {
            LogService().log("LOCAL PLAYBACK ERROR: Source setup failed ($e).");

            // Only fallback to UrlSource if NOT encrypted, because UrlSource on encrypted file = strict fail = skip loop
            if (!isEncrypted) {
              LogService().log(
                "LOCAL PLAYBACK: Retrying as UrlSource (non-encrypted)...",
              );
              await _player.setSource(UrlSource(url));
            } else {
              // Re-throw for encrypted files so we don't try to play garbage
              rethrow;
            }
          }
        } else {
          await _player.setSource(UrlSource(url));
        }

        if (extras['startAt'] != null && extras['startAt'] is Duration) {
          try {
            await _player.seek(extras['startAt']);
          } catch (_) {}
        }

        LogService().log("LOCAL PLAYBACK: Resuming player...");
        await _player.resume();

        if (_currentSessionId == sessionId) {
          _expectingStop = false;
          _currentPosition = Duration.zero; // Reset for new song
          _consecutiveErrorCount = 0; // SUCCESS: Reset error counter
          _broadcastState(
            PlayerState.playing,
          ); // This ensures BOTH position and icon are updated

          // Safety Fallback: Clear initial buffering after 5 seconds if position doesn't move
          Future.delayed(const Duration(seconds: 5), () {
            if (_isInitialBuffering &&
                _currentSessionId == sessionId &&
                _player.state == PlayerState.playing) {
              _isInitialBuffering = false;
              _broadcastState();
            }
          });
        }
      } catch (e) {
        if (_currentSessionId == sessionId) {
          final errorStr = e.toString();
          LogService().log("Player Failure for ${extras['title']}: $errorStr");

          final extraLocal = extras['isLocal'];
          final bool isLocal = extraLocal == true || extraLocal == 'true';

          if (!isLocal && _consecutiveErrorCount < 3) {
            _consecutiveErrorCount++;

            String category = "Player Error";
            if (errorStr.contains("403"))
              category = "Link Expired (403)";
            else if (errorStr.contains("-1005"))
              category = "Network Socket Error (-1005)";

            LogService().log("Playback Failure Category: $category");

            if (category.contains("403")) {
              if (extras['playlistId'] != null && extras['songId'] != null) {
                _playlistService.markSongAsInvalid(
                  extras['playlistId'],
                  extras['songId'],
                );
              }
            }

            playbackState.add(
              playbackState.value.copyWith(
                errorMessage: "Player error ($category). Skipping...",
                processingState: AudioProcessingState.buffering,
              ),
            );

            Future.delayed(const Duration(seconds: 3), () {
              if (_currentSessionId == sessionId)
                skipToNext(reason: "Player failure: $category");
            });
          } else if (isLocal) {
            playbackState.add(
              playbackState.value.copyWith(
                errorMessage: "Local file error: $errorStr",
                processingState: AudioProcessingState.error,
                playing: false,
              ),
            );
          } else {
            _consecutiveErrorCount = 0;
            playbackState.add(
              playbackState.value.copyWith(
                errorMessage: "Multiple player errors. Stopped.",
                processingState: AudioProcessingState.error,
                playing: false,
              ),
            );
          }
        }
      }
    });
  }

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) async {
    // STARTUP PROTECTION:
    // If we are in the startup lock period (first 3s), block auto-play.
    // UNLESS it is explicitly flagged as user-initiated.
    if (_startupLock && extras?['user_initiated'] != true) {
      LogService().log("Blocked startup auto-play for: $uri");
      return;
    }

    // Unlock on valid play attempt
    _startupLock = false;

    // Dispatcher
    if (extras != null && extras['type'] == 'playlist_song') {
      _stopRecognition(); // Stop ACRCloud if switching from radio to playlist
      // If it's already resolved (has stream URL), play it directly
      if (extras['is_resolved'] == true) {
        _expectingStop = true; // Block events from old player
        await _playYoutubeSong(uri.toString(), extras);
      } else {
        // Otherwise, it's likely a video ID (from RadioProvider update), resolve it (checking cache)
        final bool isLocal =
            extras['isLocal'] == true ||
            extras['isLocal'] == 'true' ||
            extras['isLocal'] == 1;

        final song = SavedSong(
          id: extras['songId'] ?? 'unknown',
          title: extras['title'] ?? '',
          artist: extras['artist'] ?? '',
          album: extras['album'] ?? '',
          artUri: extras['artUri'],
          dateAdded: DateTime.now(),
          // Use URI as youtubeUrl normally, or localPath if local
          youtubeUrl: isLocal ? null : uri.toString(),
          localPath: isLocal ? (extras['videoId'] ?? uri.toString()) : null,
        );
        // Delegate to _playYoutubeVideo which handles caching and resolution
        await _playYoutubeVideo(
          uri.toString(),
          song,
          extras['playlistId'] ?? '',
          startAt: extras['startAt'] as Duration?,
        );
      }
      return;
    }

    // ORIGINAL RADIO LOGIC BELOW
    // 1. Force Stop & Clean State
    _expectingStop = true;
    _isRetryPending = false;
    if (!_internalRetry) {
      _retryCount = 0;
    }

    _isInitialBuffering = true; // Flag that we are starting new

    // RESET PLAYLIST STATE: Ensure we are in "Radio Mode"
    _playlistQueue.clear();
    queue.add([]); // Notify system that queue is empty
    _currentPlayingPlaylistId = null;
    _playlistIndex = -1;

    // Stop existing playback immediately
    try {
      await _player.stop();
    } catch (_) {}

    // 2. Update Metadata & State IMMEDIATELY
    final url = uri.toString();

    // Lookup station
    Station? station;
    try {
      station = _stations.firstWhere((s) => s.url == url);
    } catch (_) {}

    final String title = extras?['title'] ?? station?.name ?? "Station";
    final String artist = extras?['artist'] ?? "";
    final String album = extras?['album'] ?? "";
    final String? artUri = extras?['artUri'] ?? station?.logo;

    // Merge station info into extras to ensure stationId and url are always present
    final Map<String, dynamic> finalExtras = Map<String, dynamic>.from(
      extras ?? {},
    );
    finalExtras['url'] ??= url;
    if (station != null) {
      finalExtras['stationId'] ??= station.id;
      finalExtras['type'] ??= 'station';
    }

    MediaItem newItem = MediaItem(
      id: url,
      album: album,
      title: title,
      artist: artist,
      duration: finalExtras['duration'] != null
          ? Duration(seconds: finalExtras['duration'])
          : null,
      artUri: artUri != null ? Uri.parse(artUri) : null,
      playable: true,
      extras: finalExtras,
    );

    // Sanitize Art URI for Android Auto (Must be HTTPS or Content URI)
    if (newItem.artUri != null) {
      String artString = newItem.artUri.toString();
      bool changed = false;
      if (artString.startsWith('assets/') || !artString.startsWith('http')) {
        // Local asset often fails on AA. Generate a valid URL.
        final seed = station?.genre ?? title;
        final newArt = GenreMapper.getGenreImage(seed);
        if (newArt != null) {
          artString = newArt;
          changed = true;
        }
      } else if (artString.startsWith('http:')) {
        artString = artString.replaceFirst('http:', 'https:');
        changed = true;
      }

      if (changed) {
        newItem = newItem.copyWith(artUri: Uri.parse(artString));
      }
    }

    mediaItem.add(newItem);

    // Force immediate transition to Loading state via expectingStop + stopped state
    _expectingStop = true;
    _isInitialBuffering = true;
    _currentPosition = Duration.zero;
    _broadcastState(PlayerState.stopped);

    // 3. Defer all heavy player interactions (Stop, Resolve, SetSource, Play)
    // to a microtask with immediate return to UI.
    final sessionId = DateTime.now().millisecondsSinceEpoch;
    _currentSessionId = sessionId;

    // Safety watchdog: Clear loading state if stuck for more than 15 seconds
    Future.delayed(const Duration(seconds: 15), () {
      if (_currentSessionId == sessionId &&
          (_expectingStop || _isInitialBuffering)) {
        LogService().log(
          "Watchdog: Forcing clear of stuck loading state in playFromUri",
        );
        _expectingStop = false;
        _isInitialBuffering = false;
        _broadcastState();
      }
    });

    // Save Last Played State
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_media_id', url);
      await prefs.setString('last_media_title', title);
      await prefs.setString('last_media_art', artUri ?? '');

      final String typeVal = extras?['type'] ?? 'station';
      await prefs.setString('last_media_type', typeVal);
      await prefs.setBool('last_media_is_local', extras?['isLocal'] == true);

      if (typeVal == 'playlist_song') {
        final pId = extras?['playlistId'];
        if (pId != null) {
          await prefs.setString('last_playlist_id', pId);
        }
      }
    } catch (_) {}

    Future.microtask(() async {
      if (_currentSessionId != sessionId) return;

      try {
        // 1. Prepare Player (Reuse instead of Dispose)
        if (_player.state == PlayerState.disposed) {
          _player = AudioPlayer();
          _setupPlayerListeners();
        } else {
          try {
            await _player.stop();
          } catch (_) {}
        }

        // 2. Resolve URL
        final finalUrl = await _resolveStreamUrl(
          url,
          isPlaylistSong: extras?['type'] == 'playlist_song',
        ).timeout(const Duration(seconds: 4), onTimeout: () => url);

        if (_currentSessionId != sessionId) return;

        // 3. Configure & Play
        await _initializePlayer();

        if (extras?['type'] == 'playlist_song') {
          await _player.setReleaseMode(ReleaseMode.release);
        } else {
          await _player.setReleaseMode(ReleaseMode.stop);
        }

        String? mimeType;
        if (finalUrl.toLowerCase().contains(".m3u8")) {
          mimeType = "application/x-mpegURL";
        }

        await _player.setSource(UrlSource(finalUrl, mimeType: mimeType));
        await _player.setVolume(_volume);
        await _player.resume();

        _expectingStop = false;
        _consecutiveErrorCount = 0; // Reset on success
        _broadcastState(PlayerState.playing);

        // Clear initial buffering after success
        Future.delayed(const Duration(seconds: 1), () {
          if (_isInitialBuffering &&
              _currentSessionId == sessionId &&
              _player.state == PlayerState.playing) {
            _isInitialBuffering = false;
            _broadcastState();
          }
        });
      } catch (e) {
        if (_currentSessionId != sessionId) return;
        LogService().log("Error in optimized playFromUri: $e");
        _expectingStop = false;

        // Prevent machine-gun skipping
        if (_consecutiveErrorCount < 3) {
          _consecutiveErrorCount++;
          final hasDuration =
              mediaItem.value?.duration != null &&
              mediaItem.value!.duration! > Duration.zero;
          if (hasDuration) {
            Future.delayed(const Duration(seconds: 2), () {
              if (_currentSessionId == sessionId)
                skipToNext(reason: "Init error: $e");
            });
          } else {
            _handleConnectionError("Failed to play: $e");
          }
        } else {
          _consecutiveErrorCount = 0;
          playbackState.add(
            playbackState.value.copyWith(
              errorMessage: "Multiple playback errors. Stopped.",
              processingState: AudioProcessingState.error,
              playing: false,
            ),
          );
        }
      }
    });

    // 5. Watchdog for persistent hangs (Reduced to 10s for more reactivity)
    final currentId = url;
    Future.delayed(const Duration(seconds: 10), () {
      bool isPlaylistSong = extras?['type'] == 'playlist_song';
      if (_isInitialBuffering &&
          mediaItem.value?.id == currentId &&
          !_expectingStop &&
          !isPlaylistSong) {
        final hasDuration =
            mediaItem.value?.duration != null &&
            mediaItem.value!.duration! > Duration.zero;
        if (hasDuration) {
          skipToNext(reason: "Watchdog: Player stuck in buffering for >10s");
        }
      }
    });
  }

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    this.mediaItem.add(mediaItem);
    _broadcastState(_player.state);

    // Persist metadata updates for quick restore
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_media_id', mediaItem.id);
      await prefs.setString('last_media_title', mediaItem.title);
      await prefs.setString(
        'last_media_art',
        mediaItem.artUri?.toString() ?? '',
      );
      await prefs.setString(
        'last_media_type',
        mediaItem.extras?['type'] ?? 'station',
      );
      if (mediaItem.extras?['stationId'] != null) {
        await prefs.setInt('last_station_id', mediaItem.extras!['stationId']);
      }
    } catch (_) {}
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final wasShuffle = _isShuffleMode;
    _isShuffleMode = shuffleMode == AudioServiceShuffleMode.all;

    if (wasShuffle != _isShuffleMode && _currentPlayingPlaylistId != null) {
      // Reorganize Queue
      try {
        final playlists = await _playlistService.loadPlaylists();
        final playlist = playlists.firstWhere(
          (p) => p.id == _currentPlayingPlaylistId,
        );

        List<MediaItem> newQueue = playlist.songs.map((ps) {
          final String pId = ps.youtubeUrl ?? 'song_${ps.id}';
          // Consistently use context-aware IDs if that's what we are doing
          // But wait, the existing queue might have ctx_ IDs or bare IDs.
          // Let's standardise on ctx_ IDs for playlist playback.
          // CRITICAL FIX: If this is the CURRENTLY PLAYING song, we MUST use the ID
          // that is currently in mediaItem to avoid a "New Track" signal which resets the UI counter.

          String contextId = 'ctx_${playlist.id}_$pId';

          // Check if this matches current song
          final currentMediaItem = mediaItem.value;
          bool isMatch = false;

          if (currentMediaItem != null) {
            final currentExtras = currentMediaItem.extras;
            // Priority 1: Exact Song ID Match (if available in extras)
            if (currentExtras?['songId'] == ps.id) {
              isMatch = true;
            }
            // Priority 2: Youtube URL Match
            else if (ps.youtubeUrl != null &&
                ps.youtubeUrl == currentExtras?['youtubeUrl']) {
              isMatch = true;
            }
            // Priority 3: Stable ID / Fallback Match
            else {
              final currentStableId =
                  currentExtras?['stableId'] ??
                  currentExtras?['youtubeUrl'] ??
                  currentMediaItem.id;

              String cleanPId = pId.startsWith('song_')
                  ? pId.substring(5)
                  : pId;
              String cleanCurrent =
                  (currentStableId != null &&
                      currentStableId.startsWith('song_'))
                  ? currentStableId.substring(5)
                  : (currentStableId ?? '');

              if (cleanPId == cleanCurrent) {
                isMatch = true;
              }
            }
          }

          if (isMatch) {
            // MATCH! Use the EXISTING ID to keep UI seamless
            contextId = currentMediaItem!.id;
          }

          return MediaItem(
            id: contextId,
            title: ps.title,
            artist: ps.artist,
            album: ps.album,
            artUri: ps.artUri != null ? Uri.parse(ps.artUri!) : null,
            duration: ps.duration,
            extras: {
              'type': 'playlist_song',
              'playlistId': playlist.id,
              'songId': ps.id,
              'youtubeUrl': ps.youtubeUrl,
              'stableId': pId,
            },
          );
        }).toList();

        if (_isShuffleMode) {
          newQueue.shuffle();
        }

        // Maintain current song position
        final String? currentId = mediaItem.value?.id;
        if (currentId != null) {
          // Normalize IDs for comparison:
          // currentId might be 'ctx_...' or just a raw URL/ID depending on how it started
          // The newQueue items are definitely 'ctx_...'.
          // We need to match based on the underlying 'stableId' or 'youtubeUrl'.

          String currentStableId =
              mediaItem.value?.extras?['stableId'] ??
              mediaItem.value?.extras?['youtubeUrl'] ??
              currentId;

          if (currentStableId.startsWith('song_')) {
            currentStableId = currentStableId.substring(5);
          }

          final index = newQueue.indexWhere((item) {
            String itemStableId =
                item.extras?['stableId'] ?? item.extras?['youtubeUrl'] ?? '';

            if (itemStableId.startsWith('song_')) {
              itemStableId = itemStableId.substring(5);
            }

            // More robust match: Check explicit ID match first (handled by previous loop fix)
            // then check stableId match.
            if (item.id == currentId) {
              return true;
            }

            // Robust Extras Match
            if (mediaItem.value?.extras?['songId'] == item.extras?['songId'] &&
                item.extras?['songId'] != null) {
              return true;
            }

            return itemStableId == currentStableId;
          });

          if (index != -1) {
            _playlistIndex = index;
          } else {
            // If we really can't find it, using the OLD index is safer than resetting to 0
            // if the old index is valid for the new queue length.
            // This prevents "Always restart at 1" behavior if match fails.
            if (_playlistIndex >= newQueue.length) {
              _playlistIndex = 0;
            }
            LogService().log(
              "WARNING: Song match failed during shuffle swap. Keeping index $_playlistIndex",
            );
          }
        }

        _playlistQueue = newQueue;
        queue.add(_playlistQueue);
      } catch (_) {}
    }
    // Update position before broadcasting to ensure seek bar doesn't jump
    final pos = await _player.getCurrentPosition();
    if (pos != null) {
      _currentPosition = pos;
    }
    _broadcastState(_player.state);
  }

  static const _shuffleControl = MediaControl(
    androidIcon: 'drawable/ic_shuffle',
    label: 'Shuffle',
    action: MediaAction.custom,
    customAction: CustomMediaAction(name: 'toggle_shuffle'),
  );

  static const _sequentialControl = MediaControl(
    androidIcon: 'drawable/ic_repeat',
    label: 'Sequential',
    action: MediaAction.custom,
    customAction: CustomMediaAction(name: 'toggle_shuffle'),
  );

  // ... (existing helper methods if any)

  void _startStuckMonitor() {
    if (_stuckCheckTimer != null && _stuckCheckTimer!.isActive) return;

    _stuckSecondsCount = 0;
    _lastStuckCheckPosition = _currentPosition;

    // Only monitor if this is a playlist song
    if (mediaItem.value?.extras?['type'] != 'playlist_song') return;

    _stuckCheckTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      // Safety check: if not playing, stop.
      if (_player.state != PlayerState.playing) {
        _stopStuckMonitor();
        return;
      }

      // Double check it's still a playlist song
      if (mediaItem.value?.extras?['type'] != 'playlist_song') {
        _stopStuckMonitor();
        return;
      }

      // 1. Active Polling for Real Position
      // Background streams often throttle. We must ASK the player where it is.
      final Duration? realPos = await _player.getCurrentPosition();
      if (realPos == null) return;

      final currentPos = realPos;
      _currentPosition = realPos;

      // FORCE UI UPDATE: If stream is silent but we are moving, broadcast!
      final lastStatePos = playbackState.value.position;
      if ((currentPos - lastStatePos).abs().inSeconds >= 1) {
        _broadcastState(_player.state);
      }

      // 2. Stuck Detection Logic
      // If position hasn't moved significantly (< 100ms)
      if ((currentPos - _lastStuckCheckPosition).abs().inMilliseconds < 100) {
        // 3. Check Connectivity (Only if not local)
        // If it's a remote stream and we are offline, it's expected to be "stuck" (buffering).
        final extraLocal = mediaItem.value?.extras?['isLocal'];
        final bool isLocal = extraLocal == true || extraLocal == 'true';
        if (!isLocal) {
          final connectivity = await Connectivity().checkConnectivity();
          if (connectivity.contains(ConnectivityResult.none)) {
            _stuckSecondsCount = 0;
            return;
          }
        }
        _stuckSecondsCount++;
      } else {
        _stuckSecondsCount = 0;
        _lastStuckCheckPosition = currentPos;
      }

      debugPrint(_stuckSecondsCount.toString());
      if (_stuckSecondsCount >= 8) {
        LogService().log("Stuck playback detected (8s). Skipping to next.");
        _stuckSecondsCount = 0; // Reset to avoid multiple triggers

        // Ensure we hold the CPU awake while we trigger the skip
        WakelockPlus.enable();
        try {
          skipToNext(reason: "Stuck playback (8s motionless)");
          // Allow 5 seconds for the async chain to start
          await Future.delayed(const Duration(seconds: 5));
        } finally {
          WakelockPlus.disable();
        }
      }
    });
  }

  void _stopStuckMonitor() {
    _stuckCheckTimer?.cancel();
    _stuckCheckTimer = null;
    _stuckSecondsCount = 0;
  }

  void _broadcastState([PlayerState? forcedState]) {
    final state = forcedState ?? _player.state;
    // Monitor Stuck Playback
    if (state == PlayerState.playing) {
      _startStuckMonitor();
      // Keep _isInitialBuffering true until real playback is detected
      _expectingStop =
          false; // Safety: If we are playing, we are not expecting a stop anymore

      // Reset error counter on successful playback (not buffering)
      if (!_isInitialBuffering) {
        _consecutiveErrorCount = 0;
      }
    } else {
      _stopStuckMonitor();
    }

    // If we are pending a retry, don't clear notification
    if (_isRetryPending) {
      return;
    }

    // Determine if it is a playlist song
    final isPlaylistSong = mediaItem.value?.extras?['type'] == 'playlist_song';

    // Watchdog: If we stay in expectingStop for more than 10s, something is stuck.
    // Force clear it.
    if (_expectingStop && state != PlayerState.playing) {
      _stuckSecondsCount++;
      if (_stuckSecondsCount > 10) {
        LogService().log("Watchdog: Clearing stuck expectingStop state.");
        _expectingStop = false;
        _isInitialBuffering = false;
        _stuckSecondsCount = 0;

        if (mediaItem.value != null) {
          LogService().log(
            "Watchdog: Relaunching ${mediaItem.value!.title}...",
          );
          playFromUri(Uri.parse(mediaItem.value!.id), mediaItem.value!.extras);
        }
      }
    } else {
      _stuckSecondsCount = 0;
    }

    // Determine flags for the current broadcast
    // Critical for Android Auto: session must stay in a 'playing' state during transitions
    bool isBuffering = _isInitialBuffering;
    if (_expectingStop && state != PlayerState.playing) {
      isBuffering = true;
    }

    final playing =
        (state == PlayerState.playing || _expectingStop || _isInitialBuffering);
    final int index = _stations.indexWhere((s) => s.url == mediaItem.value?.id);

    // Determine strict processing state
    AudioProcessingState pState = AudioProcessingState.idle;
    if (state == PlayerState.playing) {
      pState = isBuffering
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready;
    } else if (state == PlayerState.paused || state == PlayerState.stopped) {
      // During transition (_expectingStop), we use BUFFERING to keep the spinner visible on AA
      if (_expectingStop) {
        pState = _isSwapping
            ? AudioProcessingState.ready
            : AudioProcessingState.buffering;
      } else if (isBuffering) {
        pState = AudioProcessingState.buffering;
      } else {
        pState = AudioProcessingState.ready;
      }
    } else if (state == PlayerState.completed) {
      pState = AudioProcessingState.completed;
    } else {
      pState = (isBuffering || _expectingStop)
          ? AudioProcessingState.buffering
          : AudioProcessingState.idle;
    }

    // Controls for transitioning or active state
    List<MediaControl> controls;
    if ((_expectingStop || isBuffering) && state != PlayerState.playing) {
      controls = [
        MediaControl.skipToPrevious,
        MediaControl.pause, // Show Pause icon to indicate user intent is 'Play'
        MediaControl.skipToNext,
      ];
    } else {
      controls = [
        MediaControl.skipToPrevious,
        if (state == PlayerState.playing)
          MediaControl.pause
        else
          MediaControl.play,
        MediaControl.skipToNext,
      ];
    }

    if (isPlaylistSong) {
      controls.add(_isShuffleMode ? _shuffleControl : _sequentialControl);
    }

    // System Actions
    final Set<MediaAction> actions = {
      MediaAction.skipToNext,
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.pause,
      MediaAction.stop,
    };
    if (isPlaylistSong) {
      actions.add(MediaAction.seek);
      actions.add(MediaAction.setShuffleMode);
    }

    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: actions,
        androidCompactActionIndices: const [0, 1, 2],
        processingState: pState,
        playing: playing,
        updatePosition: _currentPosition,
        bufferedPosition: Duration.zero,
        speed: 1.0,
        updateTime: DateTime.now(),
        queueIndex: isPlaylistSong ? _playlistIndex : (index >= 0 ? index : 0),
        errorMessage: null,
        shuffleMode: (_isShuffleMode && isPlaylistSong)
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    // Wait for initial data load to ensure favorites/queue are ready before AA asks
    await _initializationComplete;

    // 1. Root Level
    if (parentMediaId == 'root') {
      _logAnalyticsEvent('android_auto_usage', {
        'action': 'browse_root',
        'is_car': options?['android.service.media.extra.DEVICE_TYPE'] == 2,
        'recent': options?['android.service.media.extra.RECENT'],
      });
      // Auto-start logic for Android Auto (First Run only)
      if (!_hasTriggeredEarlyStart &&
          !playbackState.value.playing &&
          (_stations.isNotEmpty || mediaItem.value != null)) {
        _hasTriggeredEarlyStart = true; // Re-using flag or create new if needed
        // Defer play to avoid blocking getChildren
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!playbackState.value.playing) {
            play();
          }
        });
      }

      return [
        const MediaItem(
          id: 'favorites_radio',
          title: '❤️ Favorites',
          playable: false,
          extras: {'style': 'list_item'},
        ),
        const MediaItem(
          id: 'live_radio',
          title: 'All Stations',
          playable: false,
          extras: {'style': 'list_item'},
        ),
        const MediaItem(
          id: 'playlists_root',
          title: 'Playlists',
          playable: false,
        ),
        const MediaItem(
          id: 'downloads_root',
          title: '📥 Downloads',
          playable: false,
          extras: {'style': 'list_item'},
        ),
      ];
    }

    // 2. Favorites Radio List
    if (parentMediaId == 'favorites_radio') {
      await _loadStationsFromPrefs();
      final prefs = await SharedPreferences.getInstance();
      final favStr = prefs.getStringList('favorites') ?? [];
      final favIds = favStr
          .map((e) => int.tryParse(e) ?? -1)
          .where((e) => e != -1)
          .toSet();

      return _stations.where((s) => favIds.contains(s.id)).map((s) {
        final item = _stationToMediaItem(s);
        return item.copyWith(extras: {...?item.extras, 'origin': 'favorites'});
      }).toList();
    }

    // 2. Stations List
    if (parentMediaId == 'live_radio') {
      await _loadStationsFromPrefs(); // Force refresh to get latest order/favorites
      return _stations.map((s) {
        final item = _stationToMediaItem(s);
        return item.copyWith(extras: {...?item.extras, 'origin': 'all'});
      }).toList();
    }

    // 3. Playlists Folder
    if (parentMediaId == 'playlists_root') {
      final playlists = await _playlistService.loadPlaylists();
      final futures = playlists.map((p) async {
        String? baseImage = (p.id == 'favorites')
            ? GenreMapper.getGenreImage("Favorites")
            : GenreMapper.getGenreImage(p.name);

        Uri? artUri = baseImage != null ? Uri.tryParse(baseImage) : null;

        final isSpotify = p.id.startsWith('spotify_');
        final subTitle = isSpotify ? 'Spotify Playlist' : 'Playlist';

        return MediaItem(
          id: 'playlist_${p.id}',
          title: p.name,
          album: subTitle,
          playable: false,
          artUri: artUri,
          extras: {
            'android.media.metadata.DISPLAY_ICON_URI': artUri.toString(),
            'android.media.metadata.ART_URI': artUri.toString(),
            'android.media.metadata.ALBUM_ART_URI': artUri.toString(),
            if (isSpotify)
              'style':
                  'list_item', // Optional: Ensure it looks distinct if supported
          },
        );
      });

      return await Future.wait(futures);
    }

    // 4. Specific Playlist Content
    if (parentMediaId.startsWith('playlist_')) {
      final playlistId = parentMediaId.substring('playlist_'.length);
      final playlists = await _playlistService.loadPlaylists();
      try {
        final playlist = playlists.firstWhere((p) => p.id == playlistId);

        final List<MediaItem> songItems = playlist.songs.map((s) {
          final String mId = s.youtubeUrl ?? 'song_${s.id}';
          final String contextId = 'ctx_${playlist.id}_$mId';

          return _songToMediaItem(s, playlist.id, mediaIdOverride: contextId);
        }).toList();

        // Add Play All Item at the top
        if (songItems.isNotEmpty) {
          songItems.insert(
            0,
            MediaItem(
              id: 'play_all_${playlist.id}',
              title: 'Play All',
              playable: true,
              artUri: Uri.parse(
                "https://img.icons8.com/ios-filled/100/D32F2F/play--v1.png",
              ),
              extras: {'style': 'list_item'},
            ),
          );
        }

        return songItems;
      } catch (_) {}
    }

    // 5. Downloads List
    if (parentMediaId == 'downloads_root') {
      final result = await _playlistService.loadPlaylistsResult();
      final downloadedSongs = result.uniqueSongs
          .where((s) => s.localPath != null)
          .toList();

      final List<MediaItem> songItems = downloadedSongs.map((s) {
        final String mId = s.youtubeUrl ?? 'song_${s.id}';
        return _songToMediaItem(
          s,
          'downloads_root',
          mediaIdOverride: 'ctx_downloads_root_$mId',
        );
      }).toList();

      if (songItems.isNotEmpty) {
        songItems.insert(
          0,
          MediaItem(
            id: 'play_all_downloads_root',
            title: 'Play All Downloads',
            playable: true,
            artUri: Uri.parse(
              "https://img.icons8.com/ios-filled/100/D32F2F/play--v1.png",
            ),
            extras: {'style': 'list_item'},
          ),
        );
      }
      return songItems;
    }

    return [];
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    try {
      final station = _stations.firstWhere((s) => s.url == mediaId);
      return _stationToMediaItem(station);
    } catch (_) {}
    return null;
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    _logAnalyticsEvent('android_auto_usage', {
      'action': 'play_item',
      'mediaId': mediaId,
    });
    await _initializationComplete;
    // 1. Check Stations
    try {
      final s = _stations.firstWhere((s) => s.url == mediaId);

      // Update skip context based on where it was played from
      if (extras?['origin'] == 'favorites') {
        _radioSkipContext = 'favorites';
      } else if (extras?['origin'] == 'all') {
        _radioSkipContext = 'all';
      }

      await playFromUri(Uri.parse(s.url), {
        'type': 'station',
        'title': s.name,
        'artUri': s.logo,
        'user_initiated': true,
        'stationId': s.id,
      });
      return;
    } catch (_) {}

    // 2. Check Action Buttons (Play All / Shuffle)
    if (mediaId.startsWith('play_all_') || mediaId.startsWith('shuffle_all_')) {
      final isShuffle = mediaId.startsWith('shuffle_all_');
      final prefix = isShuffle ? 'shuffle_all_' : 'play_all_';
      final playlistId = mediaId.substring(prefix.length);

      if (playlistId == 'downloads_root') {
        final result = await _playlistService.loadPlaylistsResult();
        final downloadedSongs = result.uniqueSongs
            .where((s) => s.localPath != null)
            .toList();
        if (downloadedSongs.isEmpty) return;

        _currentPlayingPlaylistId = 'downloads_root';
        _isShuffleMode = true;
        _playlistQueue = downloadedSongs.map((s) {
          final String mId = s.youtubeUrl ?? 'song_${s.id}';
          return _songToMediaItem(
            s,
            'downloads_root',
            mediaIdOverride: 'ctx_downloads_root_$mId',
          );
        }).toList();

        if (_isShuffleMode) {
          _playlistQueue.shuffle();
        }

        if (_playlistQueue.isNotEmpty) {
          _playlistIndex = 0;
          queue.add(_playlistQueue);
          await playFromMediaId(_playlistQueue.first.id, {'queue_ready': true});
        }
        return;
      }

      final playlists = await _playlistService.loadPlaylists();
      try {
        final playlist = playlists.firstWhere((p) => p.id == playlistId);
        if (playlist.songs.isEmpty) return;

        // SET Current Playlist ID so toggleShuffle works later
        _currentPlayingPlaylistId = playlist.id;

        // Populate Internal Queue
        if (isShuffle || mediaId.startsWith('play_all_')) {
          _isShuffleMode =
              true; // Force shuffle for both 'Shuffle' and 'Play All' actions
        }

        _playlistQueue = playlist.songs
            .map((s) => _songToMediaItem(s, playlist.id))
            .toList();

        if (_isShuffleMode) {
          _playlistQueue.shuffle();
        }

        if (_playlistQueue.isNotEmpty) {
          _playlistIndex = 0;
          // Notify System Queue (Optional but good for AA)
          queue.add(_playlistQueue);

          // Play First Song
          final firstItem = _playlistQueue.first;
          await playFromMediaId(firstItem.id, {'queue_ready': true});
        }
      } catch (_) {}
      return;
    }

    // 3. Check Playlists (Individual Songs)
    final playlists = await _playlistService.loadPlaylists();

    // START: Context-Aware Resolution
    if (mediaId.startsWith('ctx_')) {
      try {
        if (mediaId.startsWith('ctx_downloads_root_')) {
          final realMediaId = mediaId.substring('ctx_downloads_root_'.length);
          final result = await _playlistService.loadPlaylistsResult();
          final downloadedSongs = result.uniqueSongs
              .where((s) => s.localPath != null)
              .toList();
          final song = downloadedSongs.firstWhere(
            (s) => (s.youtubeUrl ?? 'song_${s.id}') == realMediaId,
          );

          if (_currentPlayingPlaylistId != 'downloads_root') {
            _currentPlayingPlaylistId = 'downloads_root';
            _isShuffleMode = true;
            _playlistQueue = downloadedSongs.map((s) {
              final String mId = s.youtubeUrl ?? 'song_${s.id}';
              return _songToMediaItem(
                s,
                'downloads_root',
                mediaIdOverride: 'ctx_downloads_root_$mId',
              );
            }).toList();
            if (_isShuffleMode) _playlistQueue.shuffle();
            queue.add(_playlistQueue);
          }

          _playlistIndex = _playlistQueue.indexWhere(
            (item) => item.id == mediaId,
          );
          final String finalUrl = song.youtubeUrl ?? '';
          final String videoId = _extractVideoId(finalUrl) ?? '';
          await _playYoutubeVideo(videoId, song, 'downloads_root');
          return;
        }

        // Format: ctx_{playlistId}_{originalId}
        // Be careful with parsing if playlistId has underscores, but usually it's timestamp or "favorites".
        // Assuming playlistId matches first segment after ctx_.
        // Actually, we can just search for the playlist that matches.

        // ctx_favorites_https...
        // ctx_17123..._https...

        // Safer strategy: Iterate playlists and check if mediaId starts with ctx_{p.id}_
        for (var p in playlists) {
          final prefix = 'ctx_${p.id}_';
          if (mediaId.startsWith(prefix)) {
            final realMediaId = mediaId.substring(prefix.length);

            // Now find song in THIS playlist
            final song = p.songs.firstWhere(
              (s) {
                final String sId = s.youtubeUrl ?? 'song_${s.id}';
                return sId == realMediaId;
              },
              orElse: () => SavedSong(
                id: '',
                title: '',
                artist: '',
                album: '',
                dateAdded: DateTime.now(),
              ),
            );

            if (song.id.isNotEmpty) {
              // Determine Video ID / URL
              // ... (reuse logic)
              String videoId;
              String finalUrl;

              // Force Context
              final bool queueIsReady = extras?['queue_ready'] == true;
              if (!queueIsReady && _currentPlayingPlaylistId != p.id) {
                _currentPlayingPlaylistId = p.id;
                // Force Shuffle Mode by default on Android Auto context switch
                _isShuffleMode = true;

                _playlistQueue = p.songs.map((ps) {
                  final String pId = ps.youtubeUrl ?? 'song_${ps.id}';
                  return _songToMediaItem(
                    ps,
                    p.id,
                    mediaIdOverride: 'ctx_${p.id}_$pId',
                  );
                }).toList();

                if (_isShuffleMode) {
                  _playlistQueue.shuffle();
                }

                queue.add(_playlistQueue);
              }

              // Set Index
              _playlistIndex = _playlistQueue.indexWhere(
                (item) => item.id == mediaId,
              );

              // Resolve URL
              if (song.youtubeUrl == null) {
                // ... Search Logic ...
                final yt = YoutubeExplode();
                final query = "${song.artist} - ${song.title}";
                try {
                  final results = await yt.search.search(query);
                  if (results.isNotEmpty) {
                    final video = results.first;
                    finalUrl =
                        "https://www.youtube.com/watch?v=${video.id.value}";
                  } else {
                    yt.close();
                    return;
                  }
                } catch (_) {
                  yt.close();
                  return;
                }
                yt.close();
                videoId = _extractVideoId(finalUrl) ?? '';
              } else {
                finalUrl = song.youtubeUrl!;
                videoId = _extractVideoId(finalUrl) ?? '';
              }

              if (videoId.isNotEmpty) {
                await _playYoutubeVideo(
                  videoId,
                  song.copyWith(youtubeUrl: finalUrl),
                  p.id,
                );
                return;
              }
            }
          }
        }
      } catch (_) {}
    }
    // END: Context-Aware Resolution

    for (var p in playlists) {
      for (var s in p.songs) {
        final String mId = s.youtubeUrl ?? 'song_${s.id}';
        if (mId == mediaId) {
          String videoId;
          String finalUrl;

          // Standard Behavior: If user picks a song from a playlist, load context as Queue
          final bool queueIsReady = extras?['queue_ready'] == true;

          if (!queueIsReady && _currentPlayingPlaylistId != p.id) {
            // ... existing logic ...
            // We need to match the queue IDs to what we just defined in getChildren
            // If we use ctx_ IDs in getChildren, we should probably use them in queue too?
            // YES. If Android Auto sees ctx_ IDs, the queue must have ctx_ IDs for highlighting.

            _currentPlayingPlaylistId = p.id;
            // Respect existing Shuffle Mode
            // _isShuffleMode = false; // REMOVED

            _playlistQueue = p.songs.map((ps) {
              final String pId = ps.youtubeUrl ?? 'song_${ps.id}';
              return _songToMediaItem(
                ps,
                p.id,
                mediaIdOverride: 'ctx_${p.id}_$pId',
              );
            }).toList();

            if (_isShuffleMode) {
              _playlistQueue.shuffle();
            }

            queue.add(_playlistQueue);
          }

          // FIX: If we have a local path, we don't need to resolve YouTube URL, just play it!
          if (s.localPath != null) {
            finalUrl = s.youtubeUrl ?? "https://youtube.com/watch?v=local";
            videoId = s.localPath!; // Use path as unique ID for caching
          } else if (s.youtubeUrl == null) {
            // ... (resolution logic)
            try {
              final yt = YoutubeExplode();
              final query = "${s.artist} - ${s.title}";
              final results = await yt.search.search(query);
              if (results.isEmpty) {
                yt.close();
                return;
              }
              final video = results.first;
              videoId = video.id.value;
              finalUrl = "https://www.youtube.com/watch?v=$videoId";
              yt.close();
            } catch (_) {
              return;
            }
          } else {
            finalUrl = s.youtubeUrl!;
            videoId = _extractVideoId(finalUrl) ?? '';
            if (videoId.isEmpty) return;
          }

          // Update Index
          final idx = _playlistQueue.indexWhere((item) => item.id == mId);
          if (idx != -1) {
            _playlistIndex = idx;
          }

          await _playYoutubeVideo(
            videoId,
            s.copyWith(youtubeUrl: finalUrl),
            p.id,
          );
          return;
        }
      }
    }

    // Fallback
    if (mediaId.startsWith('http')) {
      await playFromUri(Uri.parse(mediaId), {'user_initiated': true});
    }
  }

  MediaItem _stationToMediaItem(Station s) {
    return MediaItem(
      id: s.url,
      album: "Live Radio",
      title: s.name,
      artist: s.genre,
      artUri: _sanitizeArtUri(s.logo, s.genre.isNotEmpty ? s.genre : s.name),
      playable: true,
      extras: {'url': s.url, 'type': 'station', 'stationId': s.id},
    );
  }

  MediaItem _songToMediaItem(
    SavedSong s,
    String playlistId, {
    String? mediaIdOverride,
  }) {
    final String stableId = s.youtubeUrl ?? 'song_${s.id}';
    final String mId = mediaIdOverride ?? stableId;

    return MediaItem(
      id: mId,
      title: _getSongTitleWithIcons(s.title, s.localPath),
      artist: s.artist,
      album: s.album,
      artUri: _sanitizeArtUri(s.artUri, "${s.title} ${s.artist}"),
      duration: s.duration,
      playable: true,
      extras: {
        'type': 'playlist_song',
        'playlistId': playlistId,
        'songId': s.id,
        'stableId': stableId,
        'youtubeUrl': s.youtubeUrl,
        'isLocal': s.localPath != null,
        'localPath': s.localPath,
        'android.media.metadata.extras.DOWNLOAD_STATUS': s.localPath != null
            ? 2
            : 0,
      },
    );
  }

  String _getSongTitleWithIcons(String title, String? localPath) {
    if (localPath == null) return title;
    // Avoid double icons
    if (title.startsWith("⬇️ ") || title.startsWith("📱 ")) return title;

    if (localPath.contains('_secure.') ||
        localPath.endsWith('.mst') ||
        localPath.contains('offline_music')) {
      return "⬇️ $title";
    } else {
      return "📱 $title";
    }
  }

  String? _extractVideoId(String url) {
    if (url.contains('v=')) return url.split('v=')[1].split('&')[0];
    if (url.contains('youtu.be/'))
      return url.split('youtu.be/')[1].split('?')[0];
    return null;
  }
  // --- RECOGNITION LOGIC ---

  Future<void> _attemptRecognition() async {
    // Strict Guard: Only Dev User allowed
    if (!_isDevUser) {
      // Ensure timer is killed if it somehow got here
      _recognitionTimer?.cancel();
      return;
    }

    if (!_isACRCloudEnabled) return;

    // Validations
    final currentItem = mediaItem.value;
    if (currentItem == null) return;
    if (currentItem.extras?['type'] == 'playlist_song')
      return; // Don't recognize playlist songs
    if (!playbackState.value.playing) return;

    final streamUrl = currentItem.id;

    LogService().log("ACRCloud: Starting recognition for $streamUrl");

    // Show indicator on Android Auto by updating artist field
    if (currentItem.id == streamUrl) {
      mediaItem.add(
        currentItem.copyWith(
          title: "${currentItem.title} 🔍",
          artist: "Identifying song...",
        ),
      );
    }

    final result = await _acrCloudService.identifyStream(streamUrl);

    if (result != null &&
        result['status']['code'] == 0 &&
        result['metadata'] != null) {
      final music = result['metadata']['music'];
      if (music != null && music.isNotEmpty) {
        final trackInfo = music[0];
        final title = trackInfo['title'];
        final artists = trackInfo['artists']?.map((a) => a['name']).join(', ');
        final album = trackInfo['album']?['name'];
        // final releaseDate = trackInfo['release_date'];

        LogService().log("ACRCloud: Match found: $title - $artists");

        // Lookup station to preserve radio identity on Android Auto
        Station? station;
        try {
          station = _stations.firstWhere((s) => s.url == streamUrl);
        } catch (_) {}
        final stationName = station?.name ?? "Radio";

        // Update MediaItem immediately with basic info
        final newMediaItem = currentItem.copyWith(
          title: title,
          artist: artists ?? "Unknown Artist",
          // Include station name in album field for context (Android Auto reference)
          album: (album != null && album.isNotEmpty)
              ? "$stationName • $album"
              : stationName,
          // Use station logo as temporary placeholder instead of null to prevent "logo disappearing"
          artUri: station?.logo != null ? Uri.parse(station!.logo!) : null,
        );
        mediaItem.add(newMediaItem);

        // Try to find artwork from ACRCloud
        String? acrArtwork;
        if (trackInfo['album'] != null && trackInfo['album']['cover'] != null) {
          acrArtwork = trackInfo['album']['cover'];
        }

        // Start Smart Link Resolution (Album Art Recovery)
        _resolveAndApplyMetadata(title, artists ?? "", acrArtwork);

        // Schedule Next Check
        int durationMs = trackInfo['duration_ms'] ?? 0;
        int offsetMs = trackInfo['play_offset_ms'] ?? 0;

        if (durationMs > 0 && offsetMs > 0) {
          int remainingMs = durationMs - offsetMs;
          int nextCheckDelay = remainingMs + 10000; // +10s buffer
          if (nextCheckDelay < 10000) nextCheckDelay = 10000;

          LogService().log(
            "ACRCloud: Next check in ${nextCheckDelay ~/ 1000}s",
          );

          _recognitionTimer?.cancel();
          LogService().log("Attempting Recognition...8");
          _recognitionTimer = Timer(
            Duration(milliseconds: nextCheckDelay),
            _attemptRecognition,
          );
        } else {
          _scheduleRetry(60);
        }
      } else {
        _handleNoMatch();
      }
    } else {
      _handleNoMatch();
    }
  }

  void _handleNoMatch() {
    // Reset to Station Info
    final currentUrl = mediaItem.value?.id;
    Station? station;
    try {
      station = _stations.firstWhere((s) => s.url == currentUrl);
    } catch (_) {}

    if (station != null) {
      final newItem = mediaItem.value?.copyWith(
        title: station.name,
        artist: station.genre,
        album: station.name,
        artUri: station.logo != null ? Uri.parse(station.logo!) : null,
      );
      if (newItem != null) mediaItem.add(newItem);
    }
    _scheduleRetry(45);
  }

  void _scheduleRetry(int seconds) {
    _recognitionTimer?.cancel();
    _recognitionTimer = Timer(Duration(seconds: seconds), _attemptRecognition);
    LogService().log("Attempting Recognition...9");
  }

  Future<void> _resolveAndApplyMetadata(
    String title,
    String artist,
    String? initialArt,
  ) async {
    // 1. Resolve Links to get Art
    String? finalArt = initialArt;

    // If we have initial art, update immediately
    if (finalArt != null) {
      final item = mediaItem.value;
      if (item != null) {
        mediaItem.add(item.copyWith(artUri: Uri.parse(finalArt)));
      }
    }

    try {
      // 2. Fetch iTunes/SongLink
      // Fallback logic
      String? sourceUrl;
      // Use iTunes search as base
      sourceUrl = await _fetchItunesUrl("$title $artist");

      if (sourceUrl != null) {
        final links = await _songLinkService.fetchLinks(
          url: sourceUrl,
          countryCode: 'US', // Default
        );

        if (links.containsKey('thumbnailUrl')) {
          finalArt = links['thumbnailUrl'];
        }

        // Update MediaItem with resolved art and links
        final item = mediaItem.value;
        if (item != null) {
          final newExtras = Map<String, dynamic>.from(item.extras ?? {});
          if (links.containsKey('spotify'))
            newExtras['spotifyUrl'] = links['spotify'];
          if (links.containsKey('youtube'))
            newExtras['youtubeUrl'] = links['youtube'];

          mediaItem.add(
            item.copyWith(
              artUri: finalArt != null ? Uri.parse(finalArt) : item.artUri,
              extras: newExtras,
            ),
          );
        }
      }
    } catch (e) {
      LogService().log("Error resolving metadata links: $e");
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
    } catch (_) {}
    return null;
  }

  Uri? _sanitizeArtUri(dynamic art, String fallback) {
    if (art == null || (art is String && art.isEmpty)) {
      final img = GenreMapper.getGenreImage(fallback);
      return img != null ? Uri.tryParse(img) : null;
    }
    if (art is Uri) return art;
    if (art is String) return Uri.tryParse(art);
    return null;
  }
}
