import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../data/station_data.dart';
import '../models/station.dart';
import '../models/saved_song.dart';
import 'playlist_service.dart';

class RadioAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  // StreamSubscription? _connectivitySubscription; // Removed unused field
  bool _isRetryPending = false;
  bool _expectingStop = false; // To distinguish between user stop and crash
  bool _isInitialBuffering = false; // To keep loading until actual audio data
  final PlaylistService _playlistService = PlaylistService();

  // Callbacks for external control (e.g. from Provider)
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

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    // Show only Favorites in Android Auto, matching the App's Home Screen
    final favStations = await _getOrderedFavorites();

    return favStations
        .map(
          (station) => MediaItem(
            id: station.url,
            album: "Radio Stream",
            title: station.name,
            artist: station.genre,
            artUri: station.logo != null ? Uri.parse(station.logo!) : null,
            playable: true,
            extras: {
              'url': station.url,
              'title': station.name,
              'artist': station.genre,
              'album': 'Live Radio',
              'artUri': station.logo,
            },
          ),
        )
        .toList();
  }

  Future<List<Station>> _getOrderedFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> favoriteIds =
        prefs.getStringList('favorite_station_ids') ?? [];

    if (favoriteIds.isEmpty) {
      // Fallback: If no favorites, show all stations (or empty list if strictly matching behavior)
      // User requested "matches the list on home screen". If home screen is empty, this should be too.
      // But to avoid "No Content" error loops in Auto, let's fallback to all if empty,
      // OR specifically for this user: they want "the list on home screen".
      // If home screen shows "No favorites yet", AA should probably show nothing or All?
      // Let's assume Fallback to All for usability if user has deleted all favorites.
      return stations;
    }

    // Map IDs to Stations ensuring correct order
    List<Station> ordered = [];
    for (String id in favoriteIds) {
      try {
        final station = stations.firstWhere((s) => s.id.toString() == id);
        ordered.add(station);
      } catch (_) {
        // Station ID not found (removed from data?)
      }
    }

    // If filtering resulted in 0 valid stations (rare), return all
    if (ordered.isEmpty) return stations;

    return ordered;
  }

  RadioAudioHandler() {
    _player.onPlayerStateChanged.listen(_broadcastState);

    // Auto-reconnect on stream finish (unexpected drop)
    _player.onPlayerComplete.listen((_) {
      if (!_expectingStop) {
        _handleConnectionError("Stream ended unexpectedly.");
      }
    });

    // Detect actual audio start
    _player.onPositionChanged.listen((_) {
      if (_isInitialBuffering) {
        _isInitialBuffering = false;
        _broadcastState(_player.state);
      }
    });

    // Listen to logs for errors (Audioplayers 6.x)
    // Listen to logs for errors (Audioplayers 6.x)
    // Commented out to prevent false positives stopping playback
    /*_player.onLog.listen((msg) {
      if (msg.contains("Error") || msg.contains("Exception")) {
        if (!_expectingStop) {
          _handleConnectionError("Playback error: $msg");
        }
      }
    });*/

    // Monitor network connectivity
    Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      // If we are supposed to be playing but experienced a network issue
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

    // Attempt to restart
    playbackState.add(
      playbackState.value.copyWith(
        errorMessage: null, // Clear error
        processingState: AudioProcessingState.buffering,
      ),
    );

    await playFromUri(Uri.parse(currentUrl), mediaItem.value?.extras);
  }

  @override
  Future<void> play() async {
    // REQUIREMENT 1: Clear buffer/cache by forcing a fresh load
    // Instead of _player.resume(), we restart the stream
    final currentItem = mediaItem.value;
    if (currentItem != null) {
      _expectingStop = false;
      await playFromUri(Uri.parse(currentItem.id), currentItem.extras);
    }
  }

  @override
  Future<void> pause() async {
    _expectingStop = true;
    await _player.pause();
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

  @override
  Future<void> stop() async {
    _expectingStop = true;
    _isRetryPending = false;
    await _player.stop();
    // Manually update state
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
    await super.stop();
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final station = stations.firstWhere(
      (s) => s.url == mediaId,
      orElse: () => stations[0],
    );

    await playFromUri(Uri.parse(station.url), {
      'title': station.name,
      'artist': station.genre,
      'album': 'Live Radio',
      'artUri': station.logo,
    });
  }

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) async {
    final url = uri.toString();
    _isRetryPending = false;
    _isCurrentSongSaved = false;
    _isInitialBuffering = true;

    // Lookup station for fallback metadata
    Station? station;
    try {
      station = stations.firstWhere((s) => s.url == url);
    } catch (_) {}

    final String title = extras?['title'] ?? station?.name ?? "Station";
    final String artist =
        extras?['artist'] ?? station?.genre ?? "Unknown Artist";
    final String? artUriStr = extras?['artUri'] ?? station?.logo;

    // Create MediaItem from extras or fallbacks
    final item = MediaItem(
      id: url,
      album: extras?['album'] ?? "Radio Stream",
      title: title,
      artist: artist,
      artUri: artUriStr != null ? Uri.parse(artUriStr) : null,
      extras: {'url': url},
    );

    mediaItem.add(item);

    // Signal buffering/loading
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.buffering,
        errorMessage: null,
      ),
    );

    try {
      _expectingStop = true; // Ignore events during reset
      await _player.stop(); // Clear previous
      _expectingStop = false; // Enable monitoring for new playback
      await _player.play(UrlSource(url));
    } catch (e) {
      _handleConnectionError("Failed to play: $e");
    }

    // Fallback: Clear buffering state after 5 seconds if no position update occurs
    Future.delayed(const Duration(seconds: 5), () {
      if (_isInitialBuffering) {
        _isInitialBuffering = false;
        _broadcastState(_player.state);
      }
    });

    // Force update
    if (_player.state == PlayerState.playing) {
      _broadcastState(PlayerState.playing);
    }
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
        String genre = "General";
        final url = item.extras?['url'];
        if (url != null) {
          try {
            final station = stations.firstWhere((s) => s.url == url);
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
    // Don't overwrite state if we are retrying or manually managing transition
    if (_isRetryPending || _expectingStop) {
      return;
    }

    final playing = state == PlayerState.playing;
    final int index = stations.indexWhere((s) => s.url == mediaItem.value?.id);

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
        androidCompactActionIndices: const [0, 1, 2, 3],
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
