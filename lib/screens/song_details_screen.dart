import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:palette_generator/palette_generator.dart';
import '../providers/radio_provider.dart';
import '../models/playlist.dart';

import 'artist_details_screen.dart';
import 'album_details_screen.dart';

class SongDetailsScreen extends StatefulWidget {
  const SongDetailsScreen({super.key});

  @override
  State<SongDetailsScreen> createState() => _SongDetailsScreenState();
}

class _SongDetailsScreenState extends State<SongDetailsScreen> {
  double _currentVolume = 0.5;

  // Palette State
  String? _lastPaletteImage;
  Color? _extractedColor;

  PageController? _pageController;
  bool _isNavigatingCarousel = false;
  Timer? _playbackTimer;
  String? _lastPlayingSongId;
  String? _localLoadingId;
  final GlobalKey _carouselKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _initVolume();
  }

  Future<void> _initVolume() async {
    try {
      final vol = await FlutterVolumeController.getVolume();
      if (mounted) {
        setState(() {
          _currentVolume = vol ?? 0.5;
        });
      }
    } catch (_) {}

    FlutterVolumeController.addListener((volume) {
      if (mounted) {
        setState(() {
          _currentVolume = volume;
        });
      }
    });
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    FlutterVolumeController.removeListener();
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _updatePalette(String? imageUrl, Color fallback) async {
    if (imageUrl == _lastPaletteImage) return; // No change

    // reset if null
    if (imageUrl == null) {
      if (mounted) {
        setState(() {
          _lastPaletteImage = null;
          _extractedColor = fallback;
        });
      }
      return;
    }

    _lastPaletteImage = imageUrl;

    // Don't set state immediately to avoid build cycle if called from build (which we are doing carefully)
    // Actually we will trigger this from build but via a microtask or just knowing it's async

    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(imageUrl),
        maximumColorCount: 20,
      );

      if (mounted && _lastPaletteImage == imageUrl) {
        setState(() {
          // Try to find the liveliest color
          _extractedColor =
              palette.lightVibrantColor?.color ??
              palette.dominantColor?.color ??
              palette.vibrantColor?.color ??
              palette.lightMutedColor?.color ??
              fallback;
        });
      }
    } catch (_) {
      // On error fallback
      if (mounted && _lastPaletteImage == imageUrl) {
        setState(() {
          _extractedColor = fallback;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final station = provider.currentStation;

    if (station == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            "No station selected",
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    // Determine images
    final String? bgImage =
        provider.currentArtistImage ?? provider.currentAlbumArt ?? station.logo;
    final String? mainImage = provider.currentAlbumArt ?? station.logo;

    // Trigger Palette Update if needed
    final Color fallbackColor = Color(int.parse(station.color));
    if (bgImage != _lastPaletteImage) {
      // Schedule post-frame to avoid setState during build or just run async
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _updatePalette(bgImage, fallbackColor);
      });
    }

    // Effective Visualizer Color
    final Color visualizerColor = _extractedColor ?? fallbackColor;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Background Image
          if (bgImage != null)
            Image.network(
              bgImage,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Container(color: Color(int.parse(station.color))),
            )
          else
            Container(color: Color(int.parse(station.color))),

          // 2. Blur / Dark Overlay
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(color: Colors.black.withValues(alpha: 0.5)),
          ),

          // 3. Content
          SafeArea(
            child: OrientationBuilder(
              builder: (context, orientation) {
                if (orientation == Orientation.landscape) {
                  return _buildLandscapeLayout(
                    context,
                    provider,
                    station,
                    mainImage,
                    visualizerColor,
                    bgImage,
                  );
                }
                return _buildPortraitLayout(
                  context,
                  provider,
                  station,
                  mainImage,
                  visualizerColor,
                  bgImage,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout(
    BuildContext context,
    RadioProvider provider,
    dynamic station,
    String? mainImage,
    Color visualizerColor,
    String? bgImage,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Header (Close Button)
        _buildHeader(context, station.name, provider),

        // Album Art / Centerpiece
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 0.0),
          child: provider.currentPlayingPlaylistId != null
              ? _buildCarousel(context, provider)
              : _buildAlbumArt(context, provider, mainImage, 280),
        ),

        // Bottom Section: Info + Controls + Visualizer
        _buildBottomSection(
          context,
          provider,
          station,
          visualizerColor,
          bgImage,
        ),
      ],
    );
  }

  Widget _buildLandscapeLayout(
    BuildContext context,
    RadioProvider provider,
    dynamic station,
    String? mainImage,
    Color visualizerColor,
    String? bgImage,
  ) {
    return Column(
      children: [
        _buildHeader(context, station.name, provider),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Left: Album Art
              Expanded(
                flex: 4,
                child: Center(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: provider.currentPlayingPlaylistId != null
                          ? _buildCarousel(context, provider, height: 200)
                          : _buildAlbumArt(context, provider, mainImage, 200),
                    ),
                  ),
                ),
              ),
              // Right: Info + Controls
              Expanded(
                flex: 6,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _buildBottomSection(
                    context,
                    provider,
                    station,
                    visualizerColor,
                    bgImage,
                    isLandscape: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(
    BuildContext context,
    String stationName,
    RadioProvider provider,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white,
              size: 32,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),

          Expanded(
            child: Text(
              stationName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 48), // Balance the close button
        ],
      ),
    );
  }

  Widget _buildAlbumArt(
    BuildContext context,
    RadioProvider provider,
    String? mainImage,
    double size,
  ) {
    return Hero(
      tag: 'player_image',
      child: MouseRegion(
        cursor:
            provider.currentAlbum.isNotEmpty &&
                provider.currentAlbum != "Live Radio"
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: () {
            if (provider.currentAlbum.isNotEmpty &&
                provider.currentAlbum != "Live Radio") {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => AlbumDetailsScreen(
                    albumName: provider.currentAlbum,
                    artistName: provider.currentArtist,
                    artworkUrl: provider.currentAlbumArt,
                    songName: provider.currentTrack,
                  ),
                ),
              );
            }
          },
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: mainImage != null
                ? Image.network(
                    mainImage,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Center(
                        child: Icon(
                          Icons.music_note_rounded,
                          size: 80,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      );
                    },
                  )
                : Center(
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 80,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomSection(
    BuildContext context,
    RadioProvider provider,
    dynamic station,
    Color visualizerColor,
    String? bgImage, {
    bool isLandscape = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Info Section
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      provider.currentTrack.isNotEmpty
                          ? provider.currentTrack
                          : "Live Broadcast",
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              MouseRegion(
                cursor:
                    (provider.currentTrack != "Live Broadcast" &&
                        provider.currentArtist.isNotEmpty)
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                child: GestureDetector(
                  onTap: () {
                    if (provider.currentTrack != "Live Broadcast" &&
                        provider.currentArtist.isNotEmpty) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => ArtistDetailsScreen(
                            artistName: provider.currentArtist,
                            artistImage: bgImage,
                            genre: station.genre,
                          ),
                        ),
                      );
                    }
                  },
                  child: Text(
                    provider.currentArtist.isNotEmpty
                        ? provider.currentArtist
                        : station.genre,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 16,
                      decoration:
                          (provider.currentTrack != "Live Broadcast" &&
                              provider.currentArtist.isNotEmpty)
                          ? TextDecoration.underline
                          : null,
                      decorationColor: Colors.white54,
                    ),
                  ),
                ),
              ),
              if (provider.currentAlbum.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  provider.currentAlbum,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Progress Bar (Youtube) - Above Controls
        if (provider.hiddenAudioController != null)
          _buildProgressBar(context, provider.hiddenAudioController!),

        // Controls
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Shuffle (Left)
              if (provider.currentPlayingPlaylistId != null) ...[
                IconButton(
                  onPressed: () {
                    provider.toggleShuffle();
                    // Relayout and jump to start of list
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_pageController != null &&
                          _pageController!.hasClients) {
                        _pageController!.jumpToPage(0);
                        if (provider.activeQueue.isNotEmpty &&
                            provider.currentPlayingPlaylistId != null) {
                          provider.playPlaylistSong(
                            provider.activeQueue[0],
                            provider.currentPlayingPlaylistId!,
                          );
                        }
                      }
                    });
                  },
                  icon: Icon(
                    Icons.shuffle_rounded,
                    color: provider.isShuffleMode
                        ? const Color(0xFFE91E63)
                        : Colors.white24,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
              ],

              IconButton(
                onPressed: () => provider.playPrevious(),
                icon: const Icon(
                  Icons.skip_previous_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),
              const SizedBox(width: 24),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withOpacity(0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: IconButton(
                  onPressed: () => provider.togglePlay(),
                  icon: Icon(
                    provider.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.black,
                    size: 32,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              IconButton(
                onPressed: () => provider.playNext(),
                icon: const Icon(
                  Icons.skip_next_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Volume Slider (System Volume)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Row(
            children: [
              const Icon(
                Icons.volume_mute_rounded,
                color: Colors.white54,
                size: 20,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 0,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: _currentVolume.clamp(0.0, 1.0),
                    onChanged: (v) {
                      setState(() {
                        _currentVolume = v;
                      });
                      FlutterVolumeController.setVolume(v);
                    },
                  ),
                ),
              ),
              const Icon(
                Icons.volume_up_rounded,
                color: Colors.white54,
                size: 20,
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Visualizer (Bottom)
        if (provider.isPlaying)
          SizedBox(
            height: 100,
            child: Opacity(
              opacity: provider.hiddenAudioController != null ? 0.3 : 1.0,
              child: _MusicVisualizer(
                color: visualizerColor,
                barCount: 60,
                volume: _currentVolume,
              ),
            ),
          )
        else
          const SizedBox(height: 60),
      ],
    );
  }

  Widget _buildProgressBar(
    BuildContext context,
    YoutubePlayerController controller,
  ) {
    return ValueListenableBuilder<YoutubePlayerValue>(
      valueListenable: controller,
      builder: (context, value, child) {
        final position = value.position.inSeconds.toDouble();
        final duration = value.metaData.duration.inSeconds.toDouble();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Row(
                children: [
                  Text(
                    _formatDuration(value.position),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 0,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        value: position.clamp(
                          0.0,
                          duration > 0 ? duration : 1.0,
                        ),
                        max: duration > 0 ? duration : 1.0,
                        onChanged: (v) {
                          controller.seekTo(Duration(seconds: v.toInt()));
                        },
                      ),
                    ),
                  ),
                  Text(
                    _formatDuration(value.metaData.duration),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }

  Widget _buildCarousel(
    BuildContext context,
    RadioProvider provider, {
    double height = 320,
  }) {
    if (provider.currentPlayingPlaylistId == null) return const SizedBox();

    final playlist = provider.playlists.firstWhere(
      (p) => p.id == provider.currentPlayingPlaylistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );

    final songs = provider.activeQueue;
    if (songs.isEmpty) return const SizedBox();

    final currentIndex = songs.indexWhere(
      (s) => s.id == provider.audioOnlySongId,
    );

    // Sync PageController if external change happened (e.g. autoplay)
    if (_pageController == null) {
      _pageController = PageController(
        viewportFraction: 0.8,
        initialPage: currentIndex != -1 ? currentIndex : 0,
      );
      _lastPlayingSongId = provider.audioOnlySongId;
    } else if (provider.audioOnlySongId != _lastPlayingSongId) {
      _lastPlayingSongId = provider.audioOnlySongId;

      if (currentIndex != -1 &&
          !_isNavigatingCarousel &&
          _pageController!.hasClients) {
        _isNavigatingCarousel = true;
        _pageController!
            .animateToPage(
              currentIndex,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            )
            .then((_) {
              // Wait a bit to ensure onPageChanged callbacks have fired and been ignored
              Future.delayed(const Duration(milliseconds: 100), () {
                if (mounted) _isNavigatingCarousel = false;
              });
            });
      }
    }

    return SizedBox(
      height: height,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollStartNotification) {
            _playbackTimer?.cancel();
            if (notification.dragDetails != null) {
              _isNavigatingCarousel = false;
            }
          }

          if (notification is ScrollEndNotification && !_isNavigatingCarousel) {
            _playbackTimer?.cancel();
            _playbackTimer = Timer(const Duration(seconds: 2), () {
              if (!mounted) return;

              // Validate state again
              if (_pageController == null || !_pageController!.hasClients) {
                return;
              }

              // Snap back to current playing song if no interaction
              // Recalculate using fresh state to handle race conditions (e.g. tap during scroll)
              final currentQueue = provider.activeQueue;
              final realTargetIndex = currentQueue.indexWhere(
                (s) => s.id == provider.audioOnlySongId,
              );

              if (realTargetIndex != -1 && !_isNavigatingCarousel) {
                _isNavigatingCarousel = true;
                if (realTargetIndex < currentQueue.length) {
                  provider.previewSong(currentQueue[realTargetIndex]);
                }
                _pageController!
                    .animateToPage(
                      realTargetIndex,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    )
                    .then((_) {
                      if (mounted) _isNavigatingCarousel = false;
                    });
              }
            });
            return true;
          }
          return false;
        },
        child: PageView.builder(
          key: _carouselKey,
          controller: _pageController,
          itemCount: songs.length,
          onPageChanged: (index) {
            // Instant UI update
            if (!_isNavigatingCarousel) {
              provider.previewSong(songs[index]);
            }
          },
          itemBuilder: (context, index) {
            final song = songs[index];
            final isActive = index == currentIndex;

            // Scale effect
            return AnimatedBuilder(
              animation: _pageController!,
              builder: (context, child) {
                double value = 1.0;
                if (_pageController!.positions.length == 1 &&
                    _pageController!.position.haveDimensions) {
                  value = _pageController!.page! - index;
                  value = (1 - (value.abs() * 0.3)).clamp(0.0, 1.0);
                } else {
                  value = isActive ? 1.0 : 0.7;
                }
                return Center(
                  child: SizedBox(
                    height: Curves.easeOut.transform(value) * (height * 0.9),
                    width: Curves.easeOut.transform(value) * (height * 0.9),
                    child: child,
                  ),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: GestureDetector(
                  onTap: () {
                    _playbackTimer?.cancel();
                    if (provider.audioOnlySongId != song.id) {
                      setState(() {
                        _localLoadingId = song.id;
                      });
                      // Yield to allow UI update before processing
                      Future.delayed(const Duration(milliseconds: 50), () {
                        provider.playPlaylistSong(song, playlist.id).then((_) {
                          if (mounted) {
                            setState(() {
                              _localLoadingId = null;
                            });
                          }
                        });
                      });
                    }
                  },
                  onDoubleTap: () {
                    _playbackTimer?.cancel();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AlbumDetailsScreen(
                          albumName: song.album,
                          artistName: song.artist,
                          artworkUrl: song.artUri,
                          appleMusicUrl: song.appleMusicUrl,
                          songName: song.title,
                        ),
                      ),
                    );
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      song.artUri != null
                          ? Image.network(
                              song.artUri!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  Container(color: Colors.grey[900]),
                            )
                          : Container(
                              color: Colors.grey[900],
                              child: const Icon(
                                Icons.music_note_rounded,
                                color: Colors.white54,
                                size: 80,
                              ),
                            ),
                      if ((provider.isLoading &&
                              provider.audioOnlySongId == song.id) ||
                          _localLoadingId == song.id)
                        Container(
                          color: Colors.black54,
                          child: const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds <= 0) return "0:00";
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }
}

class _MusicVisualizer extends StatefulWidget {
  final Color color;
  final int barCount;
  final double volume;

  const _MusicVisualizer({
    required this.color,
    this.barCount = 30,
    this.volume = 1.0,
  });

  @override
  State<_MusicVisualizer> createState() => _MusicVisualizerState();
}

class _MusicVisualizerState extends State<_MusicVisualizer>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  late List<double> _currentHeights;
  late List<double> _targetHeights;
  final Random _random = Random();
  double _beatIntensity = 0.0;

  @override
  void initState() {
    super.initState();
    _currentHeights = List.filled(widget.barCount, 0.0);
    _targetHeights = List.filled(widget.barCount, 0.0);

    _ticker = createTicker((elapsed) {
      _updatePhysics();
    });
    _ticker.start();
  }

  void _updatePhysics() {
    if (_random.nextDouble() < 0.05) {
      _beatIntensity = 0.8 + _random.nextDouble() * 0.2;
    } else {
      _beatIntensity *= 0.95;
    }

    for (int i = 0; i < widget.barCount; i++) {
      double x = (i / widget.barCount) * 2 - 1;
      double spectrumBias = exp(-2 * x * x);
      double noise = _random.nextDouble();

      if (_random.nextDouble() < 0.15) {
        double beatComponent = (_beatIntensity * spectrumBias);
        double randomComponent = noise * 0.3 * spectrumBias;

        _targetHeights[i] = randomComponent + beatComponent;
        _targetHeights[i] = _targetHeights[i].clamp(0.05, 1.0);
      }

      if (_currentHeights[i] < _targetHeights[i]) {
        _currentHeights[i] += (_targetHeights[i] - _currentHeights[i]) * 0.15;
      } else {
        _currentHeights[i] -= 0.02;
      }
      _currentHeights[i] = _currentHeights[i].clamp(0.01, 1.0);
    }

    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double totalWidth = constraints.maxWidth;
        // With many bars, the gap needs to be very small or proportional
        final double gap = totalWidth * 0.005; // 0.5% gap
        final double totalGap = gap * (widget.barCount - 1);
        final double barWidth = (totalWidth - totalGap) / widget.barCount;

        // "Reflect the background color":
        // Use the original color almost directly, just with a tiny hint of white for brightness
        // so it pops against the dark background but stays true to the theme.
        final Color accentColor = Color.lerp(widget.color, Colors.white, 0.15)!;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(widget.barCount, (index) {
            double heightFactor = _currentHeights[index];

            // Scale height by volume (plus a small base so it's not totally invisible at low vol if desired, but user asked for "lower volume -> lower bars")
            // If volume is 0, bars should be flat.
            final double volumeScale = widget.volume.clamp(0.0, 1.0);

            return AnimatedContainer(
              duration: const Duration(milliseconds: 50),
              margin: EdgeInsets.only(
                right: index < widget.barCount - 1 ? gap : 0,
              ),
              width: barWidth,
              height: (constraints.maxHeight * heightFactor * volumeScale * 1.2)
                  .clamp(0.0, constraints.maxHeight),
              decoration: BoxDecoration(
                // Solid color that matches the background/station color strongly
                color: accentColor.withValues(
                  alpha: 0.6 + (heightFactor * 0.4),
                ),
                borderRadius: BorderRadius.circular(barWidth / 2),
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.8),
                    blurRadius: 8 * heightFactor * volumeScale,
                    spreadRadius: heightFactor * 1.5 * volumeScale,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
            );
          }),
        );
      },
    );
  }
}
