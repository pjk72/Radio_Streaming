import 'dart:ui';
// import 'dart:developer' as developer;
import 'package:http/http.dart' as http; // Added import
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../data/station_data.dart' as static_data;
import '../models/station.dart';
import '../models/saved_song.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart' as model;
import 'log_service.dart';
import '../utils/genre_mapper.dart';

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
    }, onError: (Object e) {});

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

    _playerPositionSubscription = _player.onPositionChanged.listen((pos) {
      _currentPosition = pos; // Track position

      if (_isInitialBuffering && !_expectingStop) {
        _isInitialBuffering = false;
        _broadcastState(_player.state);
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
              skipToNext();
              return;
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
    }, onError: (Object e) {});

    // Global Error Monitoring
    _player.onLog.listen((log) {
      if (log.toLowerCase().contains("error") ||
          log.toLowerCase().contains("exception")) {
        if (_isInitialBuffering &&
            !_expectingStop &&
            (log.contains("403") ||
                log.contains("-1005") ||
                log.contains("1002"))) {
          skipToNext();
        }
      }
    }, onError: (Object e) {});
  }

  // Startup Lock to prevent Android 12 Foreground Service Exceptions
  bool _startupLock = true;

  RadioAudioHandler() {
    _stations = List.from(static_data.stations);
    // Don't wait for future in constructor, but start it
    _initializePlayer();

    // Release lock after 3 seconds (enough for app to settle)
    Future.delayed(const Duration(seconds: 3), () {
      _startupLock = false;
    });

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

    // Load persisted stations independent of UI
    _loadStationsFromPrefs().then((_) => _loadQueue());
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

      // 2. Load Favorites

      // 3. Load Order & Sort
      final bool useCustomOrder = prefs.getBool('use_custom_order') ?? false;
      final List<String>? orderStr = prefs.getStringList('station_order');

      if (useCustomOrder && orderStr != null) {
        final order = orderStr
            .map((e) => int.tryParse(e) ?? -1)
            .where((e) => e != -1)
            .toList();
        final Map<int, Station> map = {for (var s in loaded) s.id: s};
        final List<Station> sorted = [];

        for (var id in order) {
          if (map.containsKey(id)) {
            sorted.add(map[id]!);
            map.remove(id);
          }
        }
        // Append remaining sorted-by-default
        sorted.addAll(map.values);
        _stations = sorted;
      } else {
        _stations = loaded;
      }
    } catch (e) {
      // Fallback
    }
  }

  Future<void> _loadQueue() async {
    // START: Filter logic for Android Auto (Matches Home Screen Favorites)
    final targetStations = _stations; // Use loaded sorted stations
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

    // Ensure Android Auto sees the app as "Ready" immediately with valid content
    if (queueItems.isNotEmpty && mediaItem.value == null) {
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
                _playlistQueue = playlist.songs.map((ps) {
                  final String pId = ps.youtubeUrl ?? 'song_${ps.id}';
                  return MediaItem(
                    id: pId,
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
      startupItem ??= queueItems.first;

      mediaItem.add(startupItem);
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
    String playlistId,
  ) async {
    // Always reset flags
    _hasTriggeredPreload = false;
    _hasTriggeredEarlyStart = false;

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
    // 1. Give Feedback
    await _player.stop();
    final String stableId = song.youtubeUrl ?? 'song_${song.id}';
    final placeholderItem = MediaItem(
      id: stableId,
      album: song.album,
      title: song.title,
      artist: song.artist,
      artUri: song.artUri != null ? Uri.parse(song.artUri!) : null,
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

    try {
      var yt = YoutubeExplode();
      var video = await yt.videos.get(videoId);
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
        'duration': video.duration?.inSeconds,
        'user_initiated': true,
        'stableId': stableId,
      };

      await playFromUri(Uri.parse(streamUrl), extras);
      playbackState.add(playbackState.value.copyWith(errorMessage: null));
    } catch (e) {
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage: "Error playing. Skipping...",
        ),
      );
      // Mark as invalid
      await _playlistService.markSongAsInvalid(playlistId, song.id);

      Future.delayed(const Duration(seconds: 5), () {
        skipToNext();
      });
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
    _startupLock = false; // User Action unlocks
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
    _startupLock = false;

    // 1. Check Internal Queue (Android Auto / Background Priority)
    if (_playlistQueue.isNotEmpty) {
      if (_playlistIndex < _playlistQueue.length - 1) {
        _playlistIndex++;
      } else {
        _playlistIndex = 0; // Loop
      }
      final item = _playlistQueue[_playlistIndex];
      // Use playFromMediaId to handle resolution
      await playFromMediaId(item.id);
      return;
    }

    // 2. Fallback to Provider / Radio
    if (onSkipNext != null) {
      onSkipNext!();
    } else {
      if (_stations.isNotEmpty) {
        final current = mediaItem.value;
        if (current == null) {
          await playFromUri(Uri.parse(_stations.first.url));
        } else {
          int index = _stations.indexWhere((s) => s.url == current.id);
          int nextIndex = (index + 1) % _stations.length;
          await playFromUri(Uri.parse(_stations[nextIndex].url));
        }
      }
    }
  }

  Future<void> preloadNextStream(String videoId, String songId) async {
    try {
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
  Future<void> skipToPrevious() async {
    _startupLock = false;

    // 1. Check Internal Queue
    if (_playlistQueue.isNotEmpty) {
      if (_playlistIndex > 0) {
        _playlistIndex--;
      } else {
        _playlistIndex = _playlistQueue.length - 1; // Loop
      }
      final item = _playlistQueue[_playlistIndex];
      await playFromMediaId(item.id);
      return;
    }

    // 2. Fallback
    if (onSkipPrevious != null) {
      onSkipPrevious!();
    } else {
      if (_stations.isNotEmpty) {
        final current = mediaItem.value;
        if (current != null) {
          int index = _stations.indexWhere((s) => s.url == current.id);
          int prevIndex = index - 1;
          if (prevIndex < 0) prevIndex = _stations.length - 1;
          await playFromUri(Uri.parse(_stations[prevIndex].url));
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
        if (_currentSessionId == sessionId) {
          LogService().log("Error playing YouTube song in handler: $e");
          Future.delayed(const Duration(seconds: 1), skipToNext);
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

    // Save Last Played State
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_media_id', url);

      final String type = extras?['type'] ?? 'station';
      await prefs.setString('last_media_type', type);

      if (type == 'playlist_song') {
        final pId = extras?['playlistId'];
        if (pId != null) {
          await prefs.setString('last_playlist_id', pId);
        }
      }
    } catch (_) {}

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

      // Hard Reset: Recreate player instance to clear binary buffers if it's a playlist song
      // OR if we've had repeated failures (retryCount > 0) to ensure fresh native state.
      if (extras?['type'] == 'playlist_song' || _retryCount > 0) {
        LogService().log(
          "Performing Hard Reset of AudioPlayer (Retry: $_retryCount)",
        );
        try {
          await _player.dispose();
        } catch (_) {}
        _player = AudioPlayer();
        _setupPlayerListeners(); // Re-attach listeners to new instance
        await Future.delayed(
          const Duration(milliseconds: 300),
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

        String? mimeType;
        if (finalUrl.toLowerCase().contains(".m3u8")) {
          mimeType = "application/x-mpegURL";
        }
        await _player.setSource(UrlSource(finalUrl, mimeType: mimeType));
        await _player.setVolume(_volume);

        await _player.resume();
        if (true) {
          _expectingStop = false;
          _broadcastState(PlayerState.playing);
        }
      } catch (e) {
        success = false;
        errorMessage = e.toString();
        LogService().log("Error in generic player init/resume: $e");
        _expectingStop = false;
      }

      if (!success) {
        if (errorMessage != null) {}
        final hasDuration =
            mediaItem.value?.duration != null &&
            mediaItem.value!.duration! > Duration.zero;

        if (hasDuration) {
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
          skipToNext();
        }
      }
    });
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    _startupLock = false; // Action unlocks
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
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    this.mediaItem.add(mediaItem);
    _isCurrentSongSaved = await _playlistService.isSongInFavorites(
      mediaItem.title,
      mediaItem.artist ?? '',
    );
    _broadcastState(_player.state);
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
          return MediaItem(
            id: pId,
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
        final currentId = mediaItem.value?.id;
        if (currentId != null) {
          final index = newQueue.indexWhere((item) => item.id == currentId);
          if (index != -1) {
            _playlistIndex = index;
            // Optionally move current song to top? No, just track index is fine.
          } else {
            // Reset if lost (shouldn't happen)
            _playlistIndex = 0;
          }
        }

        _playlistQueue = newQueue;
        queue.add(_playlistQueue);
      } catch (_) {}
    }
    _broadcastState(_player.state);
  }

  static const _shuffleControl = MediaControl(
    androidIcon: 'drawable/ic_repeat',
    label: 'Sequential',
    action: MediaAction.custom,
    customAction: CustomMediaAction(name: 'toggle_shuffle'),
  );

  static const _sequentialControl = MediaControl(
    androidIcon: 'drawable/ic_shuffle',
    label: 'Shuffle',
    action: MediaAction.custom,
    customAction: CustomMediaAction(name: 'toggle_shuffle'),
  );

  // ... (existing helper methods if any)

  void _broadcastState(PlayerState state) {
    // If we are pending a retry, don't clear notification
    if (_isRetryPending) {
      return;
    }

    // Determine if it is a playlist song
    final isPlaylistSong = mediaItem.value?.extras?['type'] == 'playlist_song';

    // CRITICAL: During station switch (_expectingStop), force "Buffering" or "Ready" state
    if (_expectingStop) {
      // Build controls for buffering state
      final List<MediaControl> bufferControls = [
        MediaControl.skipToPrevious,
        MediaControl.pause, // Show Pause (fake playing)
        MediaControl.skipToNext,
      ];
      // ADD SHUFFLE if it's a playlist
      if (isPlaylistSong) {
        bufferControls.add(
          _isShuffleMode ? _sequentialControl : _shuffleControl,
        );
      }

      playbackState.add(
        playbackState.value.copyWith(
          processingState: _isSwapping
              ? AudioProcessingState.ready
              : AudioProcessingState.buffering,
          playing: true,
          controls: bufferControls,
          queueIndex: isPlaylistSong ? _playlistIndex : null,
          shuffleMode: (_isShuffleMode && isPlaylistSong)
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none,
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
      pState = AudioProcessingState.ready;
    } else {
      pState = AudioProcessingState.idle;
    }

    // Build standard controls
    final List<MediaControl> standardControls = [
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
    ];

    // Custom Actions (Shuffle for Playlist, Like for Radio)
    if (isPlaylistSong) {
      standardControls.add(
        _isShuffleMode ? _sequentialControl : _shuffleControl,
      );
    } else {
      // Radio: Show Like/Liked button
      standardControls.add(
        _isCurrentSongSaved ? _addedControl : _addToPlaylistControl,
      );
    }

    // System Actions
    final Set<MediaAction> actions = {
      MediaAction.skipToNext,
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.pause,
      MediaAction.stop,
      MediaAction.seek,
      MediaAction.setShuffleMode,
    };
    if (isPlaylistSong) {
      actions.add(MediaAction.seek);
    }

    playbackState.add(
      playbackState.value.copyWith(
        controls: standardControls,
        systemActions: actions,
        androidCompactActionIndices: const [0, 1, 2],
        processingState: pState,
        playing: playing,
        updatePosition: _currentPosition,
        bufferedPosition: Duration.zero,
        speed: 1.0,
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
    // 1. Root Level
    if (parentMediaId == 'root') {
      // Auto-start logic for Android Auto (First Run only)
      if (!_hasTriggeredEarlyStart &&
          !playbackState.value.playing &&
          _stations.isNotEmpty) {
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
          id: 'live_radio',
          title: 'Live Radio',
          playable: false,
          extras: {'style': 'list_item'},
        ),
        const MediaItem(
          id: 'playlists_root',
          title: 'Playlists',
          playable: false,
        ),
      ];
    }

    // 2. Stations List
    // 2. Stations List
    if (parentMediaId == 'live_radio') {
      return _stations.map(_stationToMediaItem).toList();
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
          final String stableId = s.youtubeUrl ?? 'song_${s.id}';
          // Create Context-Aware ID to identify WHICH playlist this song click comes from
          final String contextId = 'ctx_${playlist.id}_$mId';

          return MediaItem(
            id: contextId,
            title: s.title,
            artist: s.artist,
            album: s.album,
            artUri: s.artUri != null ? Uri.parse(s.artUri!) : null,
            duration: s.duration,
            playable: true,
            extras: {
              'type': 'playlist_song',
              'playlistId': playlist.id,
              'songId': s.id,
              'stableId': stableId,
              'youtubeUrl': s.youtubeUrl,
            },
          );
        }).toList();

        // Standard Action Items
        final actionItems = [
          MediaItem(
            id: 'play_all_${playlist.id}',
            title: 'Play ${playlist.name}',
            album: 'Sequential',
            playable: true,
            extras: {'style': 'list_item'},
            artUri: Uri.parse("https://img.icons8.com/fluency/512/play.png"),
          ),
          MediaItem(
            id: 'shuffle_all_${playlist.id}',
            title: 'Shuffle ${playlist.name}',
            album: 'Random',
            playable: true,
            extras: {'style': 'list_item'},
            artUri: Uri.parse("https://img.icons8.com/fluency/512/shuffle.png"),
          ),
        ];

        return [...actionItems, ...songItems];
      } catch (_) {}
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
    // 1. Check Stations
    try {
      final s = _stations.firstWhere((s) => s.url == mediaId);
      await playFromUri(Uri.parse(s.url), {
        'type': 'station',
        'title': s.name,
        'user_initiated': true,
      });
      return;
    } catch (_) {}

    // 2. Check Action Buttons (Play All / Shuffle)
    if (mediaId.startsWith('play_all_') || mediaId.startsWith('shuffle_all_')) {
      final isShuffle = mediaId.startsWith('shuffle_all_');
      final prefix = isShuffle ? 'shuffle_all_' : 'play_all_';
      final playlistId = mediaId.substring(prefix.length);

      final playlists = await _playlistService.loadPlaylists();
      try {
        final playlist = playlists.firstWhere((p) => p.id == playlistId);
        if (playlist.songs.isEmpty) return;

        // Populate Internal Queue
        _isShuffleMode = isShuffle;
        _playlistQueue = playlist.songs.map((s) {
          final String mId = s.youtubeUrl ?? 'song_${s.id}';
          return MediaItem(
            id: mId,
            title: s.title,
            artist: s.artist,
            album: s.album,
            artUri: s.artUri != null ? Uri.parse(s.artUri!) : null,
            duration: s.duration,
            extras: {
              'type': 'playlist_song',
              'playlistId': playlist.id,
              'songId': s.id,
              'youtubeUrl': s.youtubeUrl,
            },
          );
        }).toList();

        if (_isShuffleMode) {
          _playlistQueue.shuffle();
        }

        if (_playlistQueue.isNotEmpty) {
          _playlistIndex = 0;
          // Notify System Queue (Optional but good for AA)
          queue.add(_playlistQueue);

          // Play First Song
          final firstItem = _playlistQueue.first;
          await playFromMediaId(firstItem.id);
        }
      } catch (_) {}
      return;
    }

    // 3. Check Playlists (Individual Songs)
    final playlists = await _playlistService.loadPlaylists();

    // START: Context-Aware Resolution
    if (mediaId.startsWith('ctx_')) {
      try {
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
              if (_currentPlayingPlaylistId != p.id || _isShuffleMode) {
                _currentPlayingPlaylistId = p.id;
                _isShuffleMode = false;
                _playlistQueue = p.songs.map((ps) {
                  final String pId = ps.youtubeUrl ?? 'song_${ps.id}';
                  return MediaItem(
                    id: 'ctx_${p.id}_$pId', // Keep consistent IDs in queue
                    title: ps.title,
                    artist: ps.artist,
                    album: ps.album,
                    artUri: ps.artUri != null ? Uri.parse(ps.artUri!) : null,
                    duration: ps.duration,
                    extras: {
                      'type': 'playlist_song',
                      'playlistId': p.id,
                      'songId': ps.id,
                      'youtubeUrl': ps.youtubeUrl,
                      'stableId': pId,
                    },
                  );
                }).toList();
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
          if (_currentPlayingPlaylistId != p.id || _isShuffleMode) {
            // ... existing logic ...
            // We need to match the queue IDs to what we just defined in getChildren
            // If we use ctx_ IDs in getChildren, we should probably use them in queue too?
            // YES. If Android Auto sees ctx_ IDs, the queue must have ctx_ IDs for highlighting.

            _currentPlayingPlaylistId = p.id;
            _isShuffleMode =
                false; // Force sequential when clicking specific song
            _playlistQueue = p.songs.map((ps) {
              final String pId = ps.youtubeUrl ?? 'song_${ps.id}';
              return MediaItem(
                id: 'ctx_${p.id}_$pId', // Update to use context ID!
                title: ps.title,
                artist: ps.artist,
                album: ps.album,
                artUri: ps.artUri != null ? Uri.parse(ps.artUri!) : null,
                duration: ps.duration,
                extras: {
                  'type': 'playlist_song',
                  'playlistId': p.id,
                  'songId': ps.id,
                  'youtubeUrl': ps.youtubeUrl,
                  'stableId': pId,
                },
              );
            }).toList();
            queue.add(_playlistQueue);
          }

          if (s.youtubeUrl == null) {
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
      artUri: s.logo != null ? Uri.parse(s.logo!) : null,
      playable: true,
      extras: {'url': s.url, 'type': 'station'},
    );
  }

  String? _extractVideoId(String url) {
    if (url.contains('v=')) return url.split('v=')[1].split('&')[0];
    if (url.contains('youtu.be/'))
      return url.split('youtu.be/')[1].split('?')[0];
    return null;
  }
}
