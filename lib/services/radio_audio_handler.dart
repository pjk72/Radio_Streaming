import 'dart:ui';
// import 'dart:developer' as developer;
import 'package:http/http.dart' as http; // Added import
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
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
import 'log_service.dart';

class RadioAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  List<Station> _stations = [];
  AudioPlayer _player = AudioPlayer();

  // ... (existing helper methods if any)

  bool _isRetryPending = false;
  bool _internalRetry = false;
  bool _expectingStop = false;
  bool _isInitialBuffering = false;
  final PlaylistService _playlistService = PlaylistService();
  int _retryCount = 0;
  static const int _maxRetries = 5;
  int _currentSessionId = 0;
  final double _volume = 1.0;
  Duration _currentPosition = Duration.zero;

  // Callbacks
  VoidCallback? onSkipNext;
  VoidCallback? onSkipPrevious;
  VoidCallback? onPreloadNext; // New callback

  // Preloading State
  bool _hasTriggeredPreload = false;
  String? _cachedNextSongUrl;
  Map<String, dynamic>? _cachedNextSongExtras;

  static const _addToPlaylistControl = MediaControl(
    androidIcon: 'drawable/ic_favorite_border',
    label: 'Like',
    action: MediaAction.custom,
    customAction: CustomMediaAction(name: 'add_to_playlist'),
  );

  static const _addedControl = MediaControl(
    androidIcon: 'drawable/ic_favorite',
    label: 'Liked',
    action: MediaAction.custom,
    customAction: CustomMediaAction(name: 'noop'),
  );

  bool _isCurrentSongSaved = false;

  // StreamSubscriptions to manage listeners when replacing player
  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _playerCompleteSubscription;
  StreamSubscription? _playerPositionSubscription;
  StreamSubscription? _playerDurationSubscription;

  // Ensure we don't have multiple initializations happening at once
  bool _isInitializing = false;

  Future<void> _initializePlayer() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      // 2. Clear Source/Stop instead of full dispose for tracks
      try {
        await _player.stop();
        await _player.release();
      } catch (_) {}

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

      _setupPlayerListeners();
    } catch (e) {
      LogService().log("Player initialization error: $e");
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
        LogService().log("Player State Error: $e");
        String es = e.toString();
        if (es.contains("-1005") || es.contains("what:1")) {
          // Common connection/media error - try to swallow if transient
        }
      },
    );

    _playerCompleteSubscription = _player.onPlayerComplete.listen(
      (_) {
        if (!_expectingStop) {
          final hasDuration =
              mediaItem.value?.duration != null &&
              mediaItem.value!.duration! > Duration.zero;

          if (hasDuration) {
            skipToNext();
          } else {
            _handleConnectionError("Stream ended unexpectedly.");
          }
        }
      },
      onError: (Object e) {
        LogService().log("Player Complete Error: $e");
      },
    );

    _playerDurationSubscription = _player.onDurationChanged.listen((d) {
      final currentItem = mediaItem.value;
      if (currentItem != null &&
          currentItem.extras?['type'] == 'playlist_song' &&
          d > Duration.zero) {
        // Update duration for playlist songs so progress bar and preloading work
        if (currentItem.duration != d) {
          mediaItem.add(currentItem.copyWith(duration: d));
        }
      }
    });

    _playerPositionSubscription = _player.onPositionChanged.listen(
      (pos) {
        _currentPosition = pos; // Track position

        if (_isInitialBuffering && !_expectingStop) {
          _isInitialBuffering = false;
          _broadcastState(_player.state);
        } else {
          // Enforce Metadata Limits - If metadata says 2:30, stop at 2:30 even if file is longer
          final expectedDuration = mediaItem.value?.duration;
          if (expectedDuration != null) {
            // Trigger preloading 10 seconds before end (increased from 5s)
            if (expectedDuration - pos <= const Duration(seconds: 10) &&
                expectedDuration > Duration.zero) {
              if (!_hasTriggeredPreload &&
                  mediaItem.value?.extras?['type'] == 'playlist_song') {
                _hasTriggeredPreload = true;
                LogService().log(
                  "Triggering Preload (Time Remaining: ${expectedDuration - pos})",
                );
                if (onPreloadNext != null) onPreloadNext!();
              }
            }

            if (pos >= expectedDuration) {
              if (!_expectingStop) skipToNext();
              return;
            }
          }

          final lastPos = playbackState.value.position;
          if ((pos - lastPos).abs().inSeconds >= 2) {
            _broadcastState(_player.state);
          }
        }
      },
      onError: (Object e) {
        LogService().log("Player Position Error: $e");
      },
    );

    // Global Error Monitoring
    _player.onLog.listen(
      (log) {
        if (log.toLowerCase().contains("error") ||
            log.toLowerCase().contains("exception")) {
          LogService().log("Native Player Log: $log");
          if (_isInitialBuffering &&
              !_expectingStop &&
              (log.contains("403") ||
                  log.contains("-1005") ||
                  log.contains("1002"))) {
            LogService().log(
              "Detected chronic playback error in logs, skipping...",
            );
            skipToNext();
          }
        }
      },
      onError: (Object e) {
        LogService().log("Player Log Error: $e");
      },
    );
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

      if (!hasConnection) {
        // Internet Lost: Stop player to prevent buffering stale data
        if (playbackState.value.playing) {
          _player.stop(); // Clear buffer
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

  Future<void> _playYoutubeVideo(
    String videoId,
    SavedSong song,
    String playlistId,
  ) async {
    // Always reset preload flag
    _hasTriggeredPreload = false;

    // Debug Cache State
    LogService().log("Checking Cache for: ${song.id}-$videoId");
    if (_cachedNextSongExtras != null) {
      LogService().log("Cache content: ${_cachedNextSongExtras?['uniqueId']}");
    } else {
      LogService().log("Cache is empty");
    }

    // Check for preloaded stream FIRST
    if (_cachedNextSongExtras?['uniqueId'] == "${song.id}-$videoId" &&
        _cachedNextSongUrl != null) {
      LogService().log("Using preloaded stream for: $videoId");
      final streamUrl = _cachedNextSongUrl!;
      _cachedNextSongUrl = null;
      _cachedNextSongExtras = null;

      // FAST PATH: Go directly to playback without stopping/buffering UI
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
      };
      await playFromUri(Uri.parse(streamUrl), extras);
      return;
    }

    // SLOW PATH: Not cached.
    // 1. Give Feedback
    await _player.stop();

    final placeholderItem = MediaItem(
      id: "api_resolve_${song.id}",
      album: song.album,
      title: song.title,
      artist: song.artist,
      artUri: song.artUri != null ? Uri.parse(song.artUri!) : null,
      extras: {
        'type': 'playlist_song',
        'playlistId': playlistId,
        'songId': song.id,
        'videoId': videoId,
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

    try {
      LogService().log("Cache miss for $videoId. Resolving...");
      var yt = YoutubeExplode();
      var manifest = await yt.videos.streamsClient.getManifest(videoId);
      var streamInfo = manifest.muxed.withHighestBitrate();
      yt.close();

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
      };

      await playFromUri(Uri.parse(streamUrl), extras);
      playbackState.add(playbackState.value.copyWith(errorMessage: null));
    } catch (e) {
      LogService().log("Error playing YouTube video: $e");
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage: "Could not play song. Tap to skip.",
        ),
      );
    }
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
  @override
  Future<void> pause() async {
    try {
      // For playlist songs, use pause() to keep position. For radio, stop() to clear buffer.
      if (mediaItem.value?.extras?['type'] == 'playlist_song') {
        await _player.pause();
      } else {
        await _player.stop();
      }
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
  Future<void> play() async {
    // If paused, just resume without reloading
    if (_player.state == PlayerState.paused) {
      _expectingStop = false;
      await _player.resume();
      // State will be updated by listener, but we can force it for responsiveness
      playbackState.add(
        playbackState.value.copyWith(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      return;
    }

    final currentItem = mediaItem.value;
    if (currentItem != null) {
      _expectingStop = false;
      await playFromUri(Uri.parse(currentItem.id), currentItem.extras);
    }
  }

  @override
  Future<void> skipToNext() async {
    if (onSkipNext != null) {
      onSkipNext!();
    } else {
      final stations = await _getOrderedFavorites();
      if (stations.isNotEmpty) {
        final current = mediaItem.value;
        if (current == null) {
          await playFromUri(Uri.parse(stations.first.url));
        } else {
          int index = stations.indexWhere((s) => s.url == current.id);
          int nextIndex = (index + 1) % stations.length;
          await playFromUri(Uri.parse(stations[nextIndex].url));
        }
      }
    }
  }

  Future<void> preloadNextStream(String videoId, String songId) async {
    try {
      if (_cachedNextSongExtras?['uniqueId'] == "$songId-$videoId") return;

      LogService().log("Preloading next song: $videoId (ID: $songId)");
      var yt = YoutubeExplode();
      var manifest = await yt.videos.streamsClient.getManifest(videoId);
      var streamInfo = manifest.muxed.withHighestBitrate();
      yt.close();

      _cachedNextSongUrl = streamInfo.url.toString();
      _cachedNextSongExtras = {
        'videoId': videoId,
        'songId': songId,
        'uniqueId': "$songId-$videoId",
      };
      LogService().log("Preload success. URL cached for $videoId");
    } catch (e) {
      LogService().log("Preload failed: $e");
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (onSkipPrevious != null) {
      onSkipPrevious!();
    } else {
      final stations = await _getOrderedFavorites();
      if (stations.isNotEmpty) {
        final current = mediaItem.value;
        if (current != null) {
          int index = stations.indexWhere((s) => s.url == current.id);
          int prevIndex = index - 1;
          if (prevIndex < 0) prevIndex = stations.length - 1;
          await playFromUri(Uri.parse(stations[prevIndex].url));
        }
      }
    }
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
      // If server returns audio/mpeg for a PLS url (weird but possible), we shouldn't download it all.
      final cType = response.headers['content-type']?.toLowerCase() ?? '';
      if (cType.contains('audio') ||
          cType.contains('video') ||
          cType.contains('octet-stream')) {
        // Direct stream masquerading as playlist?
        return url;
      }

      final bodyBytes = await response.stream.toBytes();
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
    final String title = extras['title'] ?? "Song";
    final String artist = extras['artist'] ?? "Artist";
    final String album = extras['album'] ?? "Playlist";
    final String? artUri = extras['artUri'];

    // Set MediaItem
    MediaItem newItem = MediaItem(
      id: url,
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
    _isCurrentSongSaved = await _playlistService.isSongInFavorites(
      title,
      artist,
    );

    /* GAPLESS: Don't force buffering state initially
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.buffering,
        playing: true,
        errorMessage: null,
      ),
    );
    */

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
        } else {
          // If playing, just stop to clear buffers or directly set source?
          // setSourceUrl usually handles it.
          // await _player.stop(); // GAPLESS ATTEMPT: Don't explicit stop
        }

        // 4. Load Source & Play
        // Ensure Release Mode is correct
        if (_player.releaseMode != ReleaseMode.release) {
          await _player.setReleaseMode(ReleaseMode.release);
        }

        await _player.setSource(UrlSource(url));
        await _player.resume();

        if (_currentSessionId == sessionId) {
          _expectingStop = false;
          _broadcastState(PlayerState.playing);
        }
      } catch (e) {
        LogService().log("Youtube Playback Error: $e");
        if (_currentSessionId == sessionId) {
          Future.delayed(const Duration(seconds: 1), skipToNext);
        }
      }
    });
  }

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) async {
    // Dispatcher
    if (extras != null && extras['type'] == 'playlist_song') {
      // If it's already resolved (has stream URL), play it directly
      if (extras['is_resolved'] == true) {
        _expectingStop = true; // Block events from old player
        await _playYoutubeSong(uri.toString(), extras);
      } else {
        // Otherwise, it's likely a video ID (from RadioProvider update), resolve it (checking cache)
        final song = SavedSong(
          id: extras['songId'] ?? 'unknown',
          title: extras['title'] ?? '',
          artist: extras['artist'] ?? '',
          album: extras['album'] ?? '',
          artUri: extras['artUri'],
          dateAdded: DateTime.now(),
          youtubeUrl: uri.toString(), // Using URI as ID container
        );
        // Delegate to _playYoutubeVideo which handles caching and resolution
        await _playYoutubeVideo(
          uri.toString(),
          song,
          extras['playlistId'] ?? '',
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
    _isCurrentSongSaved = false;
    _isInitialBuffering = true; // Flag that we are starting new

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
    final String artist = extras?['artist'] ?? station?.genre ?? "Live Radio";
    final String album = extras?['album'] ?? station?.category ?? "Live Radio";
    final String? artUri = extras?['artUri'] ?? station?.logo;

    MediaItem newItem = MediaItem(
      id: url,
      album: album,
      title: title,
      artist: artist,
      duration: extras?['duration'] != null
          ? Duration(seconds: extras!['duration'])
          : null,
      artUri: artUri != null ? Uri.parse(artUri) : null,
      playable: true,
      extras: extras ?? {'url': url},
    );

    mediaItem.add(newItem);
    _isCurrentSongSaved = await _playlistService.isSongInFavorites(
      title,
      artist,
    );

    // Force Buffering/Playing state so Service stays alive
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.buffering,
        playing: true,
        errorMessage: null,
      ),
    );

    // 3. Defer all heavy player interactions (Stop, Resolve, SetSource, Play)
    // to a microtask with immediate return to UI.
    final sessionId = DateTime.now().millisecondsSinceEpoch;
    _currentSessionId = sessionId;

    Future.microtask(() async {
      if (_currentSessionId != sessionId) return;

      // Stop previous instance - fire and forget
      try {
        await _player.stop();
        // If we encountered a fatal error recently or switching types, explicit dispose/create might help clean native buffers
        // But for speed we just stop.
        // Logic: specific 1005 errors usually need a fresh player.
      } catch (_) {}

      // Hard Reset: Recreate player instance to clear binary buffers if it's a playlist song (prone to issues)
      if (extras?['type'] == 'playlist_song') {
        // Full recreation is necessary for persistent -1005 errors
        try {
          await _player.dispose();
        } catch (_) {}
        _player = AudioPlayer();
        _setupPlayerListeners(); // Re-attach listeners to new instance
        await Future.delayed(
          const Duration(milliseconds: 200),
        ); // Give it a moment to stabilize
      } else {
        await _player.release();
      }

      bool success = true;
      String? errorMessage;

      String finalUrl = url;
      // Resolve playlists if needed (non-blocking)
      try {
        finalUrl = await _resolveStreamUrl(
          url,
          isPlaylistSong: extras?['type'] == 'playlist_song',
        ).timeout(const Duration(seconds: 3), onTimeout: () => url);
      } catch (_) {}

      // Re-check session barrier after I/O wait
      if (_currentSessionId != sessionId) return;

      // 4. Init & Play
      try {
        _expectingStop = false; // Ready to receive events
        await _initializePlayer();

        if (extras?['type'] == 'playlist_song') {
          await _player.setReleaseMode(
            ReleaseMode.release,
          ); // Allow seamless transitions
          _expectingStop = false;
        } else {
          // Radio
          await _player.setReleaseMode(ReleaseMode.stop);
        }

        await _player.setSource(UrlSource(finalUrl));
        await _player.setVolume(_volume);

        await _player.resume();
        if (true) {
          _expectingStop = false;
          _broadcastState(PlayerState.playing);
        }
      } catch (e) {
        success = false;
        errorMessage = e.toString();
        _expectingStop = false;
      }

      if (!success) {
        if (errorMessage != null) {
          LogService().log("Playback failed: $errorMessage");
        }

        final hasDuration =
            mediaItem.value?.duration != null &&
            mediaItem.value!.duration! > Duration.zero;

        if (hasDuration) {
          LogService().log("Song playback failed, skipping to next...");
          skipToNext();
        } else {
          _handleConnectionError(
            "Failed to play: ${errorMessage ?? 'Unknown error'}",
          );
        }
      }
    });

    // 5. Watchdog for persistent hangs (like 403 silent failure)
    final currentId = url;
    Future.delayed(const Duration(seconds: 15), () {
      // Check if it's a playlist song to allow more time or different handling
      bool isPlaylistSong = extras?['type'] == 'playlist_song';

      if (_isInitialBuffering &&
          mediaItem.value?.id == currentId &&
          !_expectingStop &&
          !isPlaylistSong) {
        final hasDuration =
            mediaItem.value?.duration != null &&
            mediaItem.value!.duration! > Duration.zero;
        if (hasDuration) {
          LogService().log(
            "Watchdog: Song stuck in buffering too long, skipping...",
          );
          skipToNext();
        }
      }
    });
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'setVolume') {
      final vol = extras?['volume'] as double?;
      if (vol != null) {
        try {
          await _player.setVolume(vol);
        } catch (_) {}
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
            genre = station.genre.split('|').first.trim();
            genre = genre.split('/').first.trim();
          } catch (_) {}
        }

        await _playlistService.addToGenrePlaylist(genre, song);
        _isCurrentSongSaved = true;
        _broadcastState(_player.state);
      }
    } else if (name == 'startExternalPlayback') {
      // 1. Stop internal radio player
      try {
        await _player.stop();
      } catch (_) {}

      _expectingStop = false;

      // 2. Update Metadata for External Audio
      final title = extras?['title'] ?? "External Audio";
      final artist = extras?['artist'] ?? "YouTube";
      final artUri = extras?['artUri'];

      final item = MediaItem(
        id: "external_audio",
        album: "YouTube Audio",
        title: title,
        artist: artist,
        artUri: artUri != null ? Uri.parse(artUri) : null,
        playable: true,
      );
      mediaItem.add(item);

      // 3. Force Playing State to keep Service Alive
      // Use controls that make sense: Pause (to stop), Stop.
      // Added Skip controls as requested
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.ready,
          playing: true,
          controls: [
            MediaControl.skipToPrevious,
            MediaControl.pause, // Allows user to pause using system controls
            MediaControl.skipToNext,
            MediaControl.stop,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
            MediaAction.skipToNext,
            MediaAction.skipToPrevious,
          },
          errorMessage: null,
        ),
      );
    } else if (name == 'stopExternalPlayback') {
      // Just update state to stopped/paused
      playbackState.add(
        playbackState.value.copyWith(
          playing: false,
          processingState: AudioProcessingState.ready,
        ),
      );
    } else if (name == 'updatePlaybackPosition') {
      // Update progressive icon / progress bar
      if (extras != null) {
        final int posMs = extras['position'] ?? 0;
        final int durMs = extras['duration'] ?? 0;
        final bool isPlaying = extras['isPlaying'] ?? false;

        playbackState.add(
          playbackState.value.copyWith(
            playing: isPlaying,
            updatePosition: Duration(milliseconds: posMs),
            bufferedPosition: Duration(milliseconds: posMs),
            processingState: AudioProcessingState.ready,
          ),
        );

        // Update Metadata Duration if needed
        if (mediaItem.value != null && durMs > 0) {
          final currentDuration =
              mediaItem.value!.duration?.inMilliseconds ?? 0;
          if (currentDuration != durMs) {
            mediaItem.add(
              mediaItem.value!.copyWith(
                duration: Duration(milliseconds: durMs),
              ),
            );
          }
        }
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
      // Map Stopped to Ready so the UI shows "Play" button and allows resuming
      pState = AudioProcessingState.ready;
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
        updatePosition: _currentPosition,
        bufferedPosition: Duration.zero,
        speed: 1.0, // Force 1.0 speed
        queueIndex: index >= 0 ? index : 0,
        errorMessage: null, // Clear error on valid state change
      ),
    );
  }

  // --- ANDROID AUTO BROWSING ---

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentMediaId == 'root') {
      // 'root'
      return [
        const MediaItem(
          id: 'favorites',
          title: 'Favorites',
          playable: false, // Folder
        ),
        const MediaItem(
          id: 'all_stations',
          title: 'All Stations',
          playable: false, // Folder
        ),
        const MediaItem(
          id: 'playlists_root',
          title: 'Playlists',
          playable: false, // Folder
        ),
      ];
    }

    if (parentMediaId == 'favorites') {
      final favorites = await _getOrderedFavorites();
      return favorites.map(_stationToMediaItem).toList();
    }

    if (parentMediaId == 'all_stations') {
      return _stations.map(_stationToMediaItem).toList();
    }

    if (parentMediaId == 'playlists_root') {
      final playlists = await _playlistService.loadPlaylists();
      return playlists
          .map(
            (p) => MediaItem(
              id: 'playlist_${p.id}',
              title: p.name,
              album: 'Playlists',
              playable: false, // Folder
            ),
          )
          .toList();
    }

    if (parentMediaId.startsWith('playlist_')) {
      final playlistId = parentMediaId.substring('playlist_'.length);
      final playlists = await _playlistService.loadPlaylists();
      try {
        final playlist = playlists.firstWhere((p) => p.id == playlistId);
        final List<MediaItem> children = [];

        // Add Play All & Shuffle virtual items
        children.add(
          MediaItem(
            id: 'playlist_play_all_${playlist.id}',
            title: '▶ Play All',
            album: playlist.name,
            playable: true,
            extras: {'type': 'playlist_cmd', 'cmd': 'play_all'},
          ),
        );
        children.add(
          MediaItem(
            id: 'playlist_shuffle_${playlist.id}',
            title: '🔀 Shuffle',
            album: playlist.name,
            playable: true,
            extras: {'type': 'playlist_cmd', 'cmd': 'shuffle'},
          ),
        );

        // Add actual songs
        children.addAll(
          playlist.songs.map((s) {
            final String uniqueId = 'playlist_song_${playlist.id}_${s.id}';
            return MediaItem(
              id: uniqueId,
              title: s.title,
              artist: s.artist,
              album: s.album,
              artUri: s.artUri != null ? Uri.tryParse(s.artUri!) : null,
              playable: true,
              extras: {
                'url': s.youtubeUrl,
                'playlistId': playlist.id,
                'songId': s.id,
                'videoId': _extractVideoId(s.youtubeUrl),
              },
            );
          }),
        );
        return children;
      } catch (_) {}
    }

    return [];
  }

  String? _extractVideoId(String? url) {
    if (url == null) return null;
    try {
      if (url.contains("v=")) {
        return url.split("v=")[1].split("&")[0];
      } else if (url.contains("youtu.be/")) {
        return url.split("youtu.be/")[1].split("?")[0];
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    // 1. Handle Commands (Play All / Shuffle)
    if (mediaId.startsWith('playlist_play_all_') ||
        mediaId.startsWith('playlist_shuffle_')) {
      final bool isShuffle = mediaId.contains('_shuffle_');
      final playlistId = mediaId.split('_').last;

      mediaItem.add(
        MediaItem(
          id: "playlist_cmd_intent",
          title: isShuffle ? "Shuffling Playlist..." : "Starting Playlist...",
          artist: "System",
          extras: {
            'type': 'playlist_cmd',
            'playlistId': playlistId,
            'cmd': isShuffle ? 'shuffle' : 'play_all',
          },
        ),
      );
      return;
    }

    // 2. Handle Individual Songs
    if (mediaId.startsWith('playlist_song_')) {
      // It's a playlist song.
      // We need to fetch the item details to pass correct info
      // Since we don't have the item here easily without re-parsing,
      // check if it was preloaded or we have to browse for it.
      // Better approach: Parse ID

      // Format: playlist_song_[playlistId]_[songId]
      // Warning: IDs might contain underscores.
      // Robust Way: Store map? No.
      // Re-fetch playlist.

      // Let's assume we can re-fetch quickly.
      try {
        // Find playlist ID... this is tricky with underscores.
        // Let's use getChildren logic/search.
        // Shortcut: If we just clicked it, it might typically come with extras if provided by UI,
        // but from AA root, it calls playFromMediaId(id).

        final playlists = await _playlistService.loadPlaylists();
        for (var p in playlists) {
          if (mediaId.startsWith('playlist_song_${p.id}_')) {
            final songId = mediaId.substring('playlist_song_${p.id}_'.length);
            final song = p.songs.firstWhere(
              (s) => s.id == songId,
              orElse: () => SavedSong(
                id: '',
                title: '',
                artist: '',
                album: '',
                dateAdded: DateTime.now(),
              ),
            );

            if (song.id.isNotEmpty) {
              // Determine VideoID
              final videoId = _extractVideoId(song.youtubeUrl);

              if (videoId != null) {
                _playYoutubeVideo(videoId, song, p.id);
                return;
              }
            }
          }
        }
      } catch (_) {}
      return;
    }

    // Default Station logic
    await super.playFromMediaId(mediaId, extras);
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    // Helper to find item in currently known lists
    // This is optional but good for robust implementations
    try {
      return _stations
          .map(_stationToMediaItem)
          .firstWhere((item) => item.id == mediaId);
    } catch (_) {
      return null;
    }
  }

  MediaItem _stationToMediaItem(Station s) {
    return MediaItem(
      id: s.url,
      album: "Live Radio",
      title: s.name,
      artist: s.genre,
      artUri: s.logo != null ? Uri.parse(s.logo!) : null,
      playable: true,
      extras: {'url': s.url},
    );
  }
}
