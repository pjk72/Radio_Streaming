import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';

import '../services/entitlement_service.dart';
import '../services/lyrics_service.dart';
import '../providers/language_provider.dart';
import '../providers/radio_provider.dart';
import '../widgets/lyrics_components.dart';

class LocalVideoPopup extends StatefulWidget {
  final VideoPlayerController controller;
  final File? tempFileToDeleteOnDispose;
  final String? songId;
  final String? songName;
  final String? artistName;
  final String? albumName;
  final String? artworkUrl;
  final String? genre;
  final String? releaseDate;

  const LocalVideoPopup({
    super.key,
    required this.controller,
    this.tempFileToDeleteOnDispose,
    this.songId,
    this.songName,
    this.artistName,
    this.albumName,
    this.artworkUrl,
    this.genre,
    this.releaseDate,
  });

  @override
  State<LocalVideoPopup> createState() => _LocalVideoPopupState();
}

class _LocalVideoPopupState extends State<LocalVideoPopup> {
  late VideoPlayerController _controller;
  bool _isAudioOnly = false;
  bool _isFullScreen = false;
  bool _isInPipMode = false;
  bool _showControls = true;
  Timer? _controlsTimer;

  // Statistics tracking
  Timer? _statsTimer;
  int _playbackSecondsAccumulated = 0;
  bool _statsRecorded = false;

  // Seeking state
  bool _isDraggingSlider = false;
  double _dragSliderValue = 0.0;

  // Lyrics state
  LyricsData? _lyrics;
  Duration _lyricsOffset = Duration.zero;
  bool _isTapToSyncActive = false;
  OverlayEntry? _lyricsOverlayEntry;

  static const platform = MethodChannel('com.antigravity.radio/pip');

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;

    // Start playback automatically
    _controller.play();

    // Listen to video changes
    _controller.addListener(_videoListener);

    // Setup auto-hide controls
    _startControlsTimer();

    // Start statistics tracking timer (records after 30s of real playback)
    _startStatsTimer();

    // Fetch lyrics if entitled
    final entitlements = Provider.of<EntitlementService>(
      context,
      listen: false,
    );
    if (entitlements.isFeatureEnabled('lyrics')) {
      _fetchLyrics();
    }

    platform.setMethodCallHandler((call) async {
      if (call.method == 'pipModeChanged') {
        if (mounted) {
          setState(() {
            _isInPipMode = call.arguments as bool;
          });
        }
      }
    });
  }

  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_controller.value.isPlaying) {
        _playbackSecondsAccumulated++;
      }
      if (_playbackSecondsAccumulated >= 30 && !_statsRecorded) {
        _statsRecorded = true;
        _statsTimer?.cancel();
        _recordStats();
      }
    });
  }

  void _recordStats() {
    final id = widget.songId ?? widget.songName ?? 'unknown_video';
    final title = widget.songName ?? id;
    final artist = widget.artistName ?? '';
    if (!mounted) return;
    Provider.of<RadioProvider>(context, listen: false).recordVideoSongPlay(
      songId: id,
      title: title,
      artist: artist,
      album: widget.albumName,
      artUri: widget.artworkUrl,
      genre: widget.genre,
      releaseDate: widget.releaseDate,
    );
  }

  void _videoListener() {
    if (mounted) {
      setState(() {});
    }
  }

  void _startControlsTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controller.value.isPlaying && !_isDraggingSlider) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _startControlsTimer();
    } else {
      _controlsTimer?.cancel();
    }
  }

  Future<void> _fetchLyrics({bool force = false}) async {
    if (widget.songName == null || widget.artistName == null) return;

    if (mounted) {
      setState(() {
        _lyrics = null;
      });
    }

    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;

    final lyrics = await LyricsService().fetchLyrics(
      title: widget.songName!,
      artist: widget.artistName!,
    );

    if (mounted) {
      setState(() {
        _lyrics = lyrics;
      });
    }
  }

  Stream<Duration> get _positionStream {
    return Stream.periodic(const Duration(milliseconds: 200)).map((_) {
      return _controller.value.position;
    });
  }

  void _toggleLyrics(BuildContext context) {
    if (_lyricsOverlayEntry != null) {
      _lyricsOverlayEntry!.remove();
      _lyricsOverlayEntry = null;
    } else {
      if (_lyrics == null) return;

      _lyricsOverlayEntry = OverlayEntry(
        builder: (context) {
          final lang = Provider.of<LanguageProvider>(context, listen: false);
          return Positioned.fill(
            child: Material(
              color: Colors.black.withValues(alpha: 0.6),
              child: Stack(
                children: [
                  LyricsWidget(
                    lyrics: _lyrics!,
                    accentColor: Colors.redAccent,
                    lyricsOffset: _lyricsOffset,
                    positionStream: _positionStream,
                    isTapToSyncActive: _isTapToSyncActive,
                    onSyncLine: (lineTime, lineText) {
                      final currentPos = _controller.value.position;
                      final newOffset = currentPos - lineTime;
                      setState(() {
                        _lyricsOffset = newOffset;
                      });
                      _lyricsOverlayEntry?.markNeedsBuild();
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          duration: const Duration(milliseconds: 1500),
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: Colors.black87,
                          content: Row(
                            children: [
                              const Icon(
                                Icons.check_circle_outline_rounded,
                                color: Colors.greenAccent,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  lang.translate('lyrics_synced_success'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    top: 40,
                    right: 20,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_lyrics!.isSynced)
                          IconButton(
                            icon: Icon(
                              _isTapToSyncActive
                                  ? Icons.touch_app_rounded
                                  : Icons.touch_app_outlined,
                              color: _isTapToSyncActive
                                  ? Colors.redAccent
                                  : Colors.white54,
                              size: 22,
                            ),
                            onPressed: () {
                              setState(() {
                                _isTapToSyncActive = !_isTapToSyncActive;
                              });
                              _lyricsOverlayEntry?.markNeedsBuild();
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.white54),
                          onPressed: () => _fetchLyrics(force: true),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54),
                          onPressed: () => _toggleLyrics(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
      Overlay.of(context).insert(_lyricsOverlayEntry!);
    }
    setState(() {});
  }

  void _toggleMode() {
    setState(() {
      _isAudioOnly = !_isAudioOnly;
    });
  }

  Future<void> _enterPip() async {
    try {
      await platform.invokeMethod('enterPip');
    } catch (e) {
      debugPrint("Failed to enter PiP: $e");
    }
  }

  void _seekRelative(int seconds) {
    final current = _controller.value.position;
    final total = _controller.value.duration;
    final target = current + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > total ? total : target);
    _controller.seekTo(clamped);
    _startControlsTimer();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return "${duration.inHours}:$minutes:$seconds";
    }
    return "$minutes:$seconds";
  }

  void _enterFullScreen() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setState(() {
      _isFullScreen = true;
    });
  }

  void _exitFullScreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    setState(() {
      _isFullScreen = false;
    });
    if (_lyricsOverlayEntry != null) _toggleLyrics(context);
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _controlsTimer?.cancel();
    _lyricsOverlayEntry?.remove();
    _controller.removeListener(_videoListener);
    _controller.pause();
    _controller.dispose();

    // Clean up temporary decrypted file if provided
    final tempFile = widget.tempFileToDeleteOnDispose;
    if (tempFile != null) {
      try {
        if (tempFile.existsSync()) {
          tempFile.delete().catchError((_) => tempFile);
        }
      } catch (_) {}
    }

    if (_isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entitlements = Provider.of<EntitlementService>(context);
    final canUseLyrics = entitlements.isFeatureEnabled('lyrics');
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    final isPlaying = _controller.value.isPlaying;
    final position = _controller.value.position;
    final duration = _controller.value.duration;

    final double sliderMax = duration.inMilliseconds.toDouble() > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final double sliderValue = _isDraggingSlider
        ? _dragSliderValue.clamp(0.0, sliderMax)
        : position.inMilliseconds.toDouble().clamp(0.0, sliderMax);

    // Video Player with Controls Overlay
    final videoWidget = GestureDetector(
      onTap: _toggleControls,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Raw Video
          Center(
            child: AspectRatio(
              aspectRatio: _controller.value.aspectRatio > 0
                  ? _controller.value.aspectRatio
                  : 16 / 9,
              child: VideoPlayer(_controller),
            ),
          ),

          // 2. Controls Overlay
          AnimatedOpacity(
            opacity: _showControls ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 250),
            child: Container(
              color: Colors.black38,
              child: Stack(
                children: [
                  // Top overlay: badges & quick actions
                  Positioned(
                    top: 8,
                    left: 12,
                    right: 12,
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.shade700.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.offline_pin_rounded,
                                color: Colors.white,
                                size: 14,
                              ),
                              SizedBox(width: 4),
                              Text(
                                "LOCAL",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        if (Platform.isAndroid)
                          IconButton(
                            icon: const Icon(
                              Icons.picture_in_picture_alt_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                            onPressed: _enterPip,
                            tooltip: "Picture-in-Picture",
                          ),
                        if (_isFullScreen) ...[
                          if (canUseLyrics && _lyrics != null)
                            IconButton(
                              icon: Icon(
                                Icons.lyrics,
                                color: _lyricsOverlayEntry != null
                                    ? Colors.redAccent
                                    : Colors.white,
                                size: 20,
                              ),
                              onPressed: () => _toggleLyrics(context),
                            ),
                          IconButton(
                            icon: const Icon(
                              Icons.fullscreen_exit_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                            onPressed: _exitFullScreen,
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Center Playback Buttons: -10s, Play/Pause, +10s
                  Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.replay_10_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                          onPressed: () => _seekRelative(-10),
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_circle_filled_rounded
                                : Icons.play_circle_filled_rounded,
                            color: Colors.redAccent,
                            size: 54,
                          ),
                          onPressed: () {
                            if (isPlaying) {
                              _controller.pause();
                            } else {
                              _controller.play();
                            }
                            _startControlsTimer();
                          },
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(
                            Icons.forward_10_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                          onPressed: () => _seekRelative(10),
                        ),
                      ],
                    ),
                  ),

                  // Bottom Bar: Scrubber Slider, Time, Fullscreen
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Progress Slider
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2.5,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                              activeTrackColor: Colors.redAccent,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.redAccent,
                            ),
                            child: Slider(
                              min: 0.0,
                              max: sliderMax,
                              value: sliderValue,
                              onChangeStart: (val) {
                                _isDraggingSlider = true;
                                _dragSliderValue = val;
                                _controlsTimer?.cancel();
                              },
                              onChanged: (val) {
                                setState(() {
                                  _dragSliderValue = val;
                                });
                              },
                              onChangeEnd: (val) {
                                _isDraggingSlider = false;
                                _controller.seekTo(
                                  Duration(milliseconds: val.toInt()),
                                );
                                _startControlsTimer();
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "${_formatDuration(position)} / ${_formatDuration(duration)}",
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (!_isFullScreen)
                                  IconButton(
                                    icon: const Icon(
                                      Icons.fullscreen_rounded,
                                      color: Colors.white70,
                                      size: 20,
                                    ),
                                    onPressed: _enterFullScreen,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    // If PiP is active, show only the player view
    if (_isInPipMode) {
      return videoWidget;
    }

    // Fullscreen Mode
    if (_isFullScreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              videoWidget,
              if (_isAudioOnly) _buildAudioOnlyView(),
            ],
          ),
        ),
      );
    }

    // Modal Dialog Mode (Matches YouTubePopup)
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background dismiss
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(color: Colors.black.withValues(alpha: 0.8)),
            ),
          ),

          // Dialog Container
          Container(
            width: MediaQuery.of(context).size.width * 0.9,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 10,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header with Title and Close Button
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 4.0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: Text(
                            widget.songName ?? "Video",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white70,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),

                // Video / Audio Player Area
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(0),
                  ),
                  child: SizedBox(
                    height: 220,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Layer 1: Video
                        videoWidget,

                        // Layer 2: Audio Only Overlay
                        if (_isAudioOnly) _buildAudioOnlyView(),
                      ],
                    ),
                  ),
                ),

                // Toggle Audio / Video Mode Button
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xFF252525),
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(16),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _toggleMode,
                        icon: Icon(
                          _isAudioOnly ? Icons.videocam : Icons.headphones,
                          color: Colors.white,
                        ),
                        label: Text(
                          _isAudioOnly
                              ? lang.translate('switch_to_video')
                              : lang.translate('switch_to_audio_only'),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioOnlyView() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.artworkUrl != null)
            Opacity(
              opacity: 0.3,
              child: CachedNetworkImage(
                imageUrl: widget.artworkUrl!,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => Container(color: Colors.grey[900]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                if (widget.artworkUrl != null)
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: widget.artworkUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => Container(
                          color: Colors.grey[850],
                          child: const Icon(
                            Icons.music_note,
                            color: Colors.white24,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.music_note,
                      size: 40,
                      color: Colors.white24,
                    ),
                  ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.songName ?? "Audio",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.artistName != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.artistName!,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (widget.albumName != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.albumName!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _controller.value.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                  ),
                  iconSize: 48,
                  color: Colors.redAccent,
                  onPressed: () {
                    if (_controller.value.isPlaying) {
                      _controller.pause();
                    } else {
                      _controller.play();
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
