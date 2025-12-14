import 'dart:ui';
// import 'dart:developer' as developer;
import 'package:http/http.dart' as http; // Added import
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../data/station_data.dart' as static_data;
import '../models/station.dart';
import '../models/saved_song.dart';
import 'playlist_service.dart';

class RadioAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  List<Station> _stations = [];
  AudioPlayer _player = AudioPlayer(); // Non-final to allow recreation

  // ... (existing helper methods if any)

  bool _isRetryPending = false;
  bool _expectingStop = false;
  bool _isInitialBuffering = false;
  final PlaylistService _playlistService = PlaylistService();
  int _retryCount = 0;
  static const int _maxRetries = 5;
  bool _internalRetry = false;
  final double _volume = 1.0;

  // Callbacks
  VoidCallback? onSkipNext;
  VoidCallback? onSkipPrevious;

  static const _addToPlaylistControl = MediaControl(
    androidIcon: 'drawable/ic_favorite_border',
    label: 'Like',
    action: MediaAction.custom,
    customAction: const CustomMediaAction(name: 'add_to_playlist'),
  );

  static const _addedControl = MediaControl(
    androidIcon: 'drawable/ic_favorite',
    label: 'Liked',
    action: MediaAction.custom,
    customAction: const CustomMediaAction(name: 'noop'),
  );

  bool _isCurrentSongSaved = false;

  // StreamSubscriptions to manage listeners when replacing player
  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _playerCompleteSubscription;
  StreamSubscription? _playerPositionSubscription;

  // Ensure we don't have multiple initializations happening at once
  bool _isInitializing = false;

  Future<void> _initializePlayer() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      // 1. Dispose old player if exists
      // We must await this to ensure native resources are freed
      try {
        await _playerStateSubscription?.cancel();
        await _playerCompleteSubscription?.cancel();
        await _playerPositionSubscription?.cancel();

        // Critical: Release native resources before releasing the Dart object
        await _player.release();
        await _player.dispose();
      } catch (_) {
        // Ignore disposal errors, object might be dead already
      }

      // 2. Create New Instance
      _player = AudioPlayer();

      // 3. Configure (Use defaults to match Test Screen, add minimal config)
      try {
        await _player.setReleaseMode(ReleaseMode.stop);
        // Set context again just in case, similar to fresh start
        await _player.setAudioContext(
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

      // 4. Attach Listeners
      _playerStateSubscription = _player.onPlayerStateChanged.listen(
        _broadcastState,
      );

      _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
        if (!_expectingStop) {
          _handleConnectionError("Stream ended unexpectedly.");
        }
      });

      _playerPositionSubscription = _player.onPositionChanged.listen((_) {
        // Debounce actual playing state from buffering
        if (_isInitialBuffering && !_expectingStop) {
          _isInitialBuffering = false;
          _broadcastState(_player.state);
        }
      });
    } finally {
      _isInitializing = false;
    }
  }

  // Legacy init - forwards to safe init
  Future<void> _initPlayer() async {
    await _initializePlayer();
  }

  RadioAudioHandler() {
    _stations = List.from(static_data.stations);
    // Don't wait for future in constructor, but start it
    _initializePlayer();

    // Monitor network connectivity
    Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      final hasConnection = !results.contains(ConnectivityResult.none);
      if (hasConnection && _isRetryPending) {
        _retryPlayback();
      }
    });

    _loadQueue();
  }

  Future<void> _loadQueue() async {
    // START: Filter logic for Android Auto (Matches Home Screen Favorites)
    final targetStations = await _getOrderedFavorites();
    // END: Filter logic

    final queueItems = targetStations
        .map(
          (s) => MediaItem(
            id: s.url,
            album: "Live Radio",
            title: s.name,
            artist: s.genre,
            artUri: s.logo != null ? Uri.parse(s.logo!) : null,
            playable: true,
            extras: {'url': s.url},
          ),
        )
        .toList();
    queue.add(queueItems);
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

  Future<void> _retryPlayback() async {
    final currentUrl = mediaItem.value?.id;
    if (currentUrl == null) {
      return;
    }

    // Check connectivity first
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

    _isRetryPending = false;
    _internalRetry = true; // Flag to prevent reset of counter

    // Attempt to restart
    playbackState.add(
      playbackState.value.copyWith(
        errorMessage: null, // Clear error
        processingState: AudioProcessingState.buffering,
      ),
    );

    await playFromUri(Uri.parse(currentUrl), mediaItem.value?.extras);
    _internalRetry = false;
  }

  @override
  Future<void> pause() async {
    _expectingStop = true;
    try {
      await _player.pause().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // Manually update state so UI knows we paused
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  @override
  Future<void> skipToNext() async {
    onSkipNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    onSkipPrevious?.call();
  }

  // --- RESTORED HELPER METHODS ---

  void updateStations(List<Station> newStations) {
    _stations = List.from(newStations);
    _loadQueue();
  }

  Future<List<Station>> _getOrderedFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> favoriteIds =
        prefs.getStringList('favorite_station_ids') ?? [];

    if (favoriteIds.isEmpty) return _stations;

    List<Station> ordered = [];
    for (String id in favoriteIds) {
      try {
        final station = _stations.firstWhere((s) => s.id.toString() == id);
        ordered.add(station);
      } catch (_) {}
    }

    if (ordered.isEmpty) return _stations;
    return ordered;
  }

  Future<String> _resolveStreamUrl(String url) async {
    final lower = url.toLowerCase();
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
      final bodyBytes = await response.stream
          .toBytes(); // Simplify for brevity/safety
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

  @override
  Future<void> play() async {
    await _initializePlayer(); // Ensure fresh
    final currentItem = mediaItem.value;
    if (currentItem != null) {
      _expectingStop = false;
      await playFromUri(Uri.parse(currentItem.id), currentItem.extras);
    }
  }

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) async {
    // 1. Set Switch Flag
    _expectingStop = true; // CRITICAL: keep notification alive

    // 2. Update Metadata & State IMMEDIATELY (Before resolving/init)
    final url = uri.toString();
    _isRetryPending = false;
    _isCurrentSongSaved = false;
    _isInitialBuffering = true;
    _internalRetry = false; // Reset

    // Lookup station
    Station? station;
    try {
      station = _stations.firstWhere((s) => s.url == url);
    } catch (_) {}

    final String title = extras?['title'] ?? station?.name ?? "Station";
    final String artist =
        extras?['artist'] ?? station?.genre ?? "Unknown Artist";
    final String? artUriStr = extras?['artUri'] ?? station?.logo;

    final item = MediaItem(
      id: url,
      album: extras?['album'] ?? "Radio Stream",
      title: title,
      artist: artist,
      artUri: artUriStr != null ? Uri.parse(artUriStr) : null,
      extras: {'url': url},
    );

    mediaItem.add(item);

    // Force Buffering/Playing state so Service stays alive
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.buffering,
        playing: true,
        errorMessage: null,
      ),
    );

    // 3. RECREATE PLAYER (Now safe to do, UI shows new station buffering)
    await _initializePlayer();

    // 4. Defer Reset of Flag until we are actually ready to play/fail
    // _expectingStop = false; // MOVED INSIDE MICROTASK

    Future.microtask(() async {
      // Re-check if we are still the intended station (prevent race conditions)
      if (mediaItem.value?.id != url) return;

      bool success = true;
      String? errorMessage;

      try {
        String finalUrl = url;
        try {
          finalUrl = await _resolveStreamUrl(
            url,
          ).timeout(const Duration(seconds: 4), onTimeout: () => url);
        } catch (_) {}

        // Re-check again before acting on player
        if (mediaItem.value?.id != url) return;

        // EXACT MATCH to EditStationScreen implementation:
        // 1. Set Source
        // 2. Set Volume
        // 3. Resume
        await _player.setSourceUrl(finalUrl);
        await _player.setVolume(_volume);

        // Resume with timeout check
        await _player.resume().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            success = false;
            errorMessage = "Player handshake timed out";
          },
        );

        if (success) {
          _expectingStop = false; // Ready to show real state
          _broadcastState(PlayerState.playing); // Force playing state
        } else {
          _expectingStop = false; // Failed, allow error state to show
        }
      } catch (e) {
        _expectingStop = false;
        success = false;
        errorMessage = e.toString();
      }

      if (!success) {
        if (errorMessage != null) {
          _handleConnectionError("Failed to play: $errorMessage");
        }
      }
    });

    Future.delayed(const Duration(seconds: 5), () {
      if (_isInitialBuffering && !_expectingStop) {
        _isInitialBuffering = false;
        // Query actual state slightly later
        _broadcastState(_player.state);
      }
    });
  }

  @override
  Future<void> customAction(
    String name, [
    Map<String, dynamic>? arguments,
  ]) async {
    if (name == 'setVolume') {
      final vol = arguments?['volume'] as double?;
      if (vol != null) {
        await _player.setVolume(vol);
      }
    } else if (name == 'add_to_playlist') {
      final item = mediaItem.value;
      if (item != null) {
        final song = SavedSong(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: item.title,
          artist: item.artist ?? 'Unknown',
          album: item.album ?? 'Radio',
          artUri: item.artUri?.toString(),
          spotifyUrl: item.extras?['spotifyUrl'],
          youtubeUrl: item.extras?['youtubeUrl'],
          dateAdded: DateTime.now(),
        );

        // Lookup station genre
        String genre = "Mix";
        final url = item.extras?['url'];
        if (url != null) {
          try {
            final station = _stations.firstWhere((s) => s.url == url);
            // Take first genre if multiple (e.g. "Pop | Rock" -> "Pop")
            genre = station.genre.split('|').first.trim();
            // Clean slashes too just in case
            genre = genre.split('/').first.trim();
          } catch (_) {}
        }

        await _playlistService.addToGenrePlaylist(genre, song);
        _isCurrentSongSaved = true;
        _broadcastState(_player.state);
      }
    }
  }

  @override
  Future<void> updateMediaItem(MediaItem item) async {
    mediaItem.add(item);
    _isCurrentSongSaved = await _playlistService.isSongInFavorites(
      item.title,
      item.artist ?? '',
    );
    _broadcastState(_player.state);
  }

  void _broadcastState(PlayerState state) {
    // If we are pending a retry, don't clear notification
    if (_isRetryPending) {
      return;
    }

    // CRITICAL: During station switch (_expectingStop), force "Buffering" state
    // instead of Idle/Stopped. This usually keeps the Notification ALIVE
    // because "Buffering" is considered an active playback state by Android.
    if (_expectingStop) {
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.buffering,
          playing:
              true, // Keep "Play" active logic so notification stays expanded
          controls: [
            MediaControl.skipToPrevious,
            MediaControl.pause, // Show Pause (fake playing)
            MediaControl.skipToNext,
            _isCurrentSongSaved ? _addedControl : _addToPlaylistControl,
          ],
        ),
      );
      return;
    }

    final playing = state == PlayerState.playing;
    final int index = _stations.indexWhere((s) => s.url == mediaItem.value?.id);

    // Determine strict processing state: Buffering if logic says so, otherwise map player state
    AudioProcessingState pState = AudioProcessingState.idle;
    if (state == PlayerState.playing) {
      if (_isInitialBuffering) {
        pState = AudioProcessingState.buffering;
      } else {
        pState = AudioProcessingState.ready;
      }
    } else if (state == PlayerState.paused) {
      pState = AudioProcessingState.ready;
    } else if (state == PlayerState.stopped) {
      // Only map to true Idle if we really mean it (e.g. error or hard stop).
      // If we are just transitioning, this line is usually protected by _expectingStop above.
      pState = AudioProcessingState.idle;
    } else {
      pState = AudioProcessingState.idle;
    }

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          _isCurrentSongSaved ? _addedControl : _addToPlaylistControl,
        ],
        systemActions: const {
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: pState,
        playing: playing,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
        queueIndex: index >= 0 ? index : 0,
        errorMessage: null, // Clear error on valid state change
      ),
    );
  }
}
