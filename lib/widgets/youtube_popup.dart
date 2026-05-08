import 'package:flutter/material.dart';
import 'dart:io';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/lyrics_service.dart';
import '../widgets/lyrics_components.dart';
import 'package:flutter/services.dart';
import '../services/entitlement_service.dart';
import '../providers/language_provider.dart';
import 'package:provider/provider.dart';

class YouTubePopup extends StatefulWidget {
  final String videoId;
  final bool initialAudioOnly;
  final String? songName;
  final String? artistName;
  final String? albumName;
  final String? artworkUrl;

  const YouTubePopup({
    super.key,
    required this.videoId,
    this.initialAudioOnly = false,
    this.songName,
    this.artistName,
    this.albumName,
    this.artworkUrl,
  });

  @override
  State<YouTubePopup> createState() => _YouTubePopupState();
}

class _YouTubePopupState extends State<YouTubePopup> {
  late YoutubePlayerController _videoController;
  bool _isAudioOnly = false;
  bool _isFullScreen = false;
  bool _isInPipMode = false;
  bool _isHD = false;

  // Lyrics State
  LyricsData? _lyrics;
  Duration _lyricsOffset = Duration.zero;
  OverlayEntry? _lyricsOverlayEntry;
  OverlayEntry? _syncOverlayEntry;

  @override
  void initState() {
    super.initState();
    _initializeVideoPlayer();
    _isAudioOnly = widget.initialAudioOnly;

    // Check entitlement before fetching
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

  void _initializeVideoPlayer({bool forceHD = false}) {
    _videoController = YoutubePlayerController(
      initialVideoId: widget.videoId,
      flags: YoutubePlayerFlags(
        autoPlay: true,
        mute: false,
        enableCaption: false,
        hideControls: false,
        forceHD: forceHD,
      ),
    );
  }

  void _toggleHD() {
    final oldController = _videoController;
    final currentPosition = oldController.value.position;
    final isPlaying = oldController.value.isPlaying;

    setState(() {
      _isHD = !_isHD;

      // Update state and recreate controller with new flags
      _videoController = YoutubePlayerController(
        initialVideoId: widget.videoId,
        flags: YoutubePlayerFlags(
          autoPlay: isPlaying,
          mute: false,
          enableCaption: false,
          hideControls: false,
          forceHD: _isHD,
          startAt: currentPosition.inSeconds,
        ),
      );
    });

    // Quality change is handled by the controller recreation above with forceHD flag
    final quality = _isHD ? 'hd1080' : 'default';
    debugPrint('Switching quality to $quality');

    // Safe disposal of the old controller after the new one is active in the bridge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Small delay prevents potential race conditions with the bridge
      Future.delayed(const Duration(milliseconds: 200), () {
        oldController.dispose();
      });
    });
  }

  Future<void> _fetchLyrics({bool force = false}) async {
    if (widget.songName == null || widget.artistName == null) return;

    if (mounted) {
      setState(() {
        _lyrics = null; // Clear to show loading state
      });
    }

    // Wait 5 seconds before searching, as requested for playlists/external songs
    await Future.delayed(const Duration(seconds: 5));
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
    // Determine a reasonable update frequency (e.g., 200ms)
    return Stream.periodic(const Duration(milliseconds: 200)).map((_) {
      return _videoController.value.position;
    });
  }

  void _toggleLyrics(BuildContext context) {
    if (_lyricsOverlayEntry != null) {
      _lyricsOverlayEntry!.remove();
      _lyricsOverlayEntry = null;
      // Also close sync if lyrics close
      _syncOverlayEntry?.remove();
      _syncOverlayEntry = null;
    } else {
      if (_lyrics == null) return;

      _lyricsOverlayEntry = OverlayEntry(
        builder: (context) => Positioned.fill(
          child: Material(
            color: Colors.black.withValues(alpha: 0.6),
            child: Stack(
              children: [
                LyricsWidget(
                  lyrics: _lyrics!,
                  accentColor: Colors.redAccent,
                  lyricsOffset: _lyricsOffset,
                  positionStream: _positionStream,
                ),
                // Controls for Lyrics Overlay
                Positioned(
                  top: 40,
                  right: 20,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.tune, color: Colors.white54),
                        onPressed: () => _openSyncOverlay(context),
                        tooltip: Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('sync_lyrics'),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white54),
                        onPressed: () => _fetchLyrics(force: true),
                        tooltip: Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('retry_search'),
                      ),
                      if (_lyrics != null && _lyrics!.lines.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.copy, color: Colors.white54),
                          onPressed: () {
                            final text = _lyrics!.lines
                                .map((l) => l.text)
                                .join('\n');
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  Provider.of<LanguageProvider>(
                                    context,
                                    listen: false,
                                  ).translate('lyrics_copied'),
                                ),
                              ),
                            );
                          },
                          tooltip: Provider.of<LanguageProvider>(
                            context,
                            listen: false,
                          ).translate('copy_lyrics'),
                        ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => _toggleLyrics(context),
                        tooltip: Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('close_lyrics'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      Overlay.of(context).insert(_lyricsOverlayEntry!);
    }
    setState(() {});
  }

  void _openSyncOverlay(BuildContext context) {
    if (_syncOverlayEntry != null) return;

    _syncOverlayEntry = OverlayEntry(
      builder: (context) => DraggableSyncOverlay(
        currentOffset: _lyricsOffset,
        onOffsetChanged: (newOffset) {
          setState(() {
            _lyricsOffset = newOffset;
          });
          _lyricsOverlayEntry?.markNeedsBuild();
          _syncOverlayEntry?.markNeedsBuild();
        },
        onClose: () {
          _syncOverlayEntry?.remove();
          _syncOverlayEntry = null;
          setState(() {});
        },
      ),
    );
    Overlay.of(context).insert(_syncOverlayEntry!);
    setState(() {});
  }

  void _toggleMode() {
    setState(() {
      _isAudioOnly = !_isAudioOnly;
    });
  }

  @override
  void dispose() {
    _lyricsOverlayEntry?.remove();
    _syncOverlayEntry?.remove();
    _videoController.dispose();
    super.dispose();
  }

  static const platform = MethodChannel('com.antigravity.radio/pip');

  Future<void> _enterPip() async {
    try {
      await platform.invokeMethod('enterPip');
    } catch (e) {
      debugPrint("Failed to enter PiP: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('pip_error').replaceAll('{0}', e.toString()),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entitlements = Provider.of<EntitlementService>(context);
    final canUseLyrics = entitlements.isFeatureEnabled('lyrics');

    final player = YoutubePlayer(
      key: ValueKey(
        '${widget.videoId}_$_isHD',
      ), // Force recreation on HD toggle
      controller: _videoController,
      aspectRatio: _isFullScreen
          ? MediaQuery.of(context).size.aspectRatio
          : 16 / 9,
      showVideoProgressIndicator: true,
      progressIndicatorColor: Colors.redAccent,
      topActions: [
        // We need to include default back button behavior or at least a spacer
        const SizedBox(width: 8),
        const Spacer(),
        if (Platform.isAndroid)
          IconButton(
            icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white),
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
              ),
              onPressed: () => _toggleLyrics(context),
            ),
          if (_lyricsOverlayEntry != null)
            IconButton(
              icon: const Icon(Icons.tune, color: Colors.white),
              onPressed: () => _openSyncOverlay(context),
            ),
          IconButton(
            icon: Icon(
              _isHD ? Icons.hd : Icons.hd_outlined,
              color: _isHD ? Colors.redAccent : Colors.white,
            ),
            onPressed: _toggleHD,
            tooltip: _isHD ? "Disable HD" : "Enable HD",
          ),
        ],
      ],
      onEnded: (_) {},
    );

    return YoutubePlayerBuilder(
      onEnterFullScreen: () {
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
      },
      onExitFullScreen: () {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        setState(() {
          _isFullScreen = false;
        });
        // Remove lyrics when exiting fullscreen?
        // User asked for logic "when in full mode". It implies likely only for full mode.
        // We can keep them if open, but might look weird in dialog.
        // Let's remove them for safety to avoid overlay issues on dialog.
        if (_lyricsOverlayEntry != null) _toggleLyrics(context);
      },
      player: player,
      builder: (context, player) {
        if (_isInPipMode) return player;
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

              // Content Container
              Container(
                width: MediaQuery.of(context).size.width * 0.9,
                // Remove tight padding so header looks natural, or keep it consistent
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E), // Slightly lighter than black
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
                    // Header with Close Button
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 4.0,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Spacer or Title
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8.0),
                              child: Text(
                                widget.songName ?? "YouTube",
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
                            tooltip: Provider.of<LanguageProvider>(
                              context,
                              listen: false,
                            ).translate('close_lyrics'),
                          ),
                        ],
                      ),
                    ),

                    // Video/Audio Area
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(0), // Flat bottom for toggle
                      ),
                      child: SizedBox(
                        height: 220, // Slightly taller
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Layer 1: The Video Player (Managed by Builder)
                            player,

                            // Layer 2: Audio Only Overlay (Covers video)
                            if (_isAudioOnly)
                              Container(
                                color: Colors.black,
                                alignment: Alignment.center,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    // Background Blur Image
                                    if (widget.artworkUrl != null)
                                      Opacity(
                                        opacity: 0.3,
                                        child: CachedNetworkImage(
                                          imageUrl: widget.artworkUrl!,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, __, ___) =>
                                              Container(
                                                color: Colors.grey[900],
                                              ),
                                        ),
                                      ),

                                    // Content
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16.0,
                                      ),
                                      child: Row(
                                        children: [
                                          // Album Art
                                          if (widget.artworkUrl != null)
                                            Container(
                                              width: 80,
                                              height: 80,
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black
                                                        .withValues(alpha: 0.5),
                                                    blurRadius: 8,
                                                  ),
                                                ],
                                              ),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: CachedNetworkImage(
                                                  imageUrl: widget.artworkUrl!,
                                                  fit: BoxFit.cover,
                                                  errorWidget: (_, __, ___) =>
                                                      Container(
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
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: const Icon(
                                                Icons.music_note,
                                                size: 40,
                                                color: Colors.white24,
                                              ),
                                            ),

                                          const SizedBox(width: 16),

                                          // Text Info
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  widget.songName ??
                                                      "Audio Only",
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 16,
                                                  ),
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                if (widget.artistName !=
                                                    null) ...[
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    widget.artistName!,
                                                    style: const TextStyle(
                                                      color: Colors.white70,
                                                      fontSize: 14,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                                if (widget.albumName !=
                                                    null) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    widget.albumName!,
                                                    style: const TextStyle(
                                                      color: Colors.white38,
                                                      fontSize: 12,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),

                                          // Play/Pause Control
                                          ValueListenableBuilder<
                                            YoutubePlayerValue
                                          >(
                                            valueListenable: _videoController,
                                            builder: (context, value, child) {
                                              final isPlaying = value.isPlaying;
                                              return IconButton(
                                                icon: Icon(
                                                  isPlaying
                                                      ? Icons
                                                            .pause_circle_filled
                                                      : Icons
                                                            .play_circle_filled,
                                                ),
                                                iconSize: 48,
                                                color: Colors.redAccent,
                                                onPressed: () {
                                                  if (isPlaying) {
                                                    _videoController.pause();
                                                  } else {
                                                    _videoController.play();
                                                  }
                                                },
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // Toggle Button
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
                                  ? Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    ).translate('switch_to_video')
                                  : Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    ).translate('switch_to_audio_only'),
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
      },
    );
  }
}
