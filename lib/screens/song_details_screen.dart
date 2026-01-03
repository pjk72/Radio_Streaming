import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:palette_generator/palette_generator.dart';
import '../providers/radio_provider.dart';
import '../models/playlist.dart';

import 'artist_details_screen.dart';
import 'album_details_screen.dart';
import '../services/lyrics_service.dart';

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
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  Orientation? _lastOrientation;

  @override
  void initState() {
    super.initState();
    _initVolume();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<RadioProvider>(
          context,
          listen: false,
        ).setObservingLyrics(true);
      }
    });
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
    try {
      Provider.of<RadioProvider>(
        context,
        listen: false,
      ).setObservingLyrics(false);
    } catch (_) {}

    _playbackTimer?.cancel();
    FlutterVolumeController.removeListener();
    _pageController?.dispose();
    _syncOverlayEntry?.remove();
    _syncOverlayEntry = null;
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
    final bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final Orientation currentOrientation = MediaQuery.of(context).orientation;

    // Reset sheet size when switching from landscape to portrait
    if (_lastOrientation == Orientation.landscape &&
        currentOrientation == Orientation.portrait) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_sheetController.isAttached) {
          _sheetController.animateTo(
            0.15, // matches the current dynamicSize for portrait
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
    _lastOrientation = currentOrientation;

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
            child: Container(color: Colors.black.withOpacity(0.6)),
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

          // 4. Lyrics "Tendina" (Draggable Pull-up Sheet)
          Positioned(
            left: 0,
            bottom: 0,
            top: 0, // Full height container so it can drag from bottom to top
            width: isLandscape
                ? MediaQuery.of(context).size.width * 0.5
                : MediaQuery.of(context).size.width,
            child: _buildDraggableLyrics(
              context,
              provider,
              visualizerColor,
              isLandscape: isLandscape,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDraggableLyrics(
    BuildContext context,
    RadioProvider provider,
    Color accentColor, {
    bool isLandscape = false,
  }) {
    // Calculate size to maintain same physical height as in portrait
    // Portrait: 15% of screen height
    // Landscape: (0.15 * screenWidth) / screenHeight
    final double screenHeight = MediaQuery.of(context).size.height;
    final double screenWidth = MediaQuery.of(context).size.width;
    final double portraitHeight = isLandscape ? screenWidth : screenHeight;

    double dynamicSize = 0.15; // Non tocco più questa parte
    if (isLandscape) {
      // Ridotto il moltiplicatore da 0.22 a 0.18 per abbassarla in landscape
      dynamicSize = (0.14 * portraitHeight / screenHeight).clamp(0.15, 0.5);
    }

    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: dynamicSize,
      minChildSize: dynamicSize,
      maxChildSize: 0.95,
      snap: true,
      snapSizes: [dynamicSize, 0.5, 0.95],
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
            child: Container(
              color: Colors.black.withOpacity(0.7),
              child: Stack(
                children: [
                  // Scrolling Lyrics Content
                  CustomScrollView(
                    controller: scrollController,
                    slivers: [
                      provider.currentLyrics.lines.isEmpty
                          ? SliverFillRemaining(
                              hasScrollBody: false,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  top: 0,
                                  left: 24,
                                  right: 24,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      provider.isFetchingLyrics
                                          ? Icons.sync_rounded
                                          : Icons.music_off_rounded,
                                      color: Colors.white30,
                                      size: 32,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      provider.isFetchingLyrics
                                          ? "Caricamento testi..."
                                          : "Nessun testo sincronizzato trovato",
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : SliverPadding(
                              padding: const EdgeInsets.only(
                                top:
                                    40, // Reduced from 45% screen height to fit under header
                                bottom: 40, // Reduced from 45% screen height
                                left: 24,
                                right: 24,
                              ),
                              sliver: _LyricsWidget(
                                lyrics: provider.currentLyrics,
                                accentColor: accentColor,
                                lyricsOffset: provider.lyricsOffset,
                              ),
                            ),
                    ],
                  ),

                  // Fixed Header (Handle + Title) - Always stays visible
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: GestureDetector(
                      onVerticalDragUpdate: (details) {
                        final currentSize = _sheetController.size;
                        final delta = details.primaryDelta ?? 0;
                        final newSize =
                            (currentSize -
                                    delta / MediaQuery.of(context).size.height)
                                .clamp(0.15, 0.95);
                        _sheetController.jumpTo(newSize);
                      },
                      child: Container(
                        padding: const EdgeInsets.only(
                          bottom: 0,
                        ), // Extra padding for easier grab
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black,
                              Colors.black.withOpacity(0.85),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.7, 1.0],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Drag Handle
                            Center(
                              child: Container(
                                margin: const EdgeInsets.only(
                                  top: 2,
                                  bottom: 0,
                                ),
                                width: 40,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: Colors.white24,
                                  borderRadius: BorderRadius.circular(2.5),
                                ),
                              ),
                            ),
                            // Title "Lyrics"
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 0,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.lyrics_rounded,
                                    color: accentColor.withOpacity(0.7),
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  const Text(
                                    "Lyrics",
                                    style: TextStyle(
                                      color: Colors.white30,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  if (provider.currentTrack != "Live Broadcast")
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            provider.currentTrack,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            provider.currentArtist,
                                            style: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 11,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (provider.isFetchingLyrics)
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  if (provider.currentLyrics.isSynced)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.tune_rounded,
                                        color: Colors.white54,
                                        size: 20,
                                      ),
                                      tooltip: 'Sync Lyrics',
                                      onPressed: () {
                                        _openSyncOverlay(context, provider);
                                      },
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Header (Close Button)
          _buildHeader(context, station.name, provider),

          //const SizedBox(height: 60), // More top space
          SizedBox(
            height: 300,
            child:
                provider.currentPlayingPlaylistId != null &&
                    provider.activeQueue.isNotEmpty
                ? _buildCarousel(context, provider, height: 320)
                : _buildAlbumArt(context, provider, mainImage, 320),
          ),
          const SizedBox(height: 24), // Space between art and info
          // Bottom Section: Info + Controls + Visualizer
          _buildBottomSection(
            context,
            provider,
            station,
            visualizerColor,
            bgImage,
          ),
        ],
      ),
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
    final double screenHeight = MediaQuery.of(context).size.height;
    final double artSize = (screenHeight * 0.45).clamp(140.0, 200.0);

    return Column(
      children: [
        _buildHeader(context, station.name, provider, isLandscape: true),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: Album Art
              Expanded(
                flex: 4,
                child: Container(
                  alignment: Alignment.topCenter,
                  padding: const EdgeInsets.only(
                    top: 10.0,
                    left: 16.0,
                    right: 16.0,
                  ),
                  child:
                      provider.currentPlayingPlaylistId != null &&
                          provider.activeQueue.isNotEmpty
                      ? _buildCarousel(context, provider, height: artSize)
                      : _buildAlbumArt(context, provider, mainImage, artSize),
                ),
              ),
              // Right: Info + Controls
              Expanded(
                flex: 6,
                child: _buildBottomSection(
                  context,
                  provider,
                  station,
                  visualizerColor,
                  bgImage,
                  isLandscape: true,
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
    RadioProvider provider, {
    bool isLandscape = false,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 16.0,
        vertical: isLandscape ? 0.0 : 8.0,
      ),
      child: Row(
        children: [
          Container(
            width: 110,
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(
                Icons.keyboard_arrow_down,
                color: Colors.white,
                size: 32,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Expanded(
            child: Text(
              stationName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          _buildVolumeControl(),
        ],
      ),
    );
  }

  Widget _buildVolumeControl() {
    return SizedBox(
      width: 110,
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.volume_down_rounded,
            color: Colors.white30,
            size: 16,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                activeTrackColor: Colors.white54,
                inactiveTrackColor: Colors.white10,
                thumbColor: Colors.white70,
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
                provider.currentAlbum != "Live Radio" &&
                (mainImage != null &&
                    mainImage != provider.currentStation?.logo)
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: () {
            if (provider.currentAlbum.isNotEmpty &&
                provider.currentAlbum != "Live Radio" &&
                (mainImage != null &&
                    mainImage != provider.currentStation?.logo)) {
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
                  color: Colors.black.withOpacity(0.3),
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
                          color: Colors.white.withOpacity(0.5),
                        ),
                      );
                    },
                  )
                : Center(
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 80,
                      color: Colors.white.withOpacity(0.5),
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
    // Check if album art is just station logo
    bool isDefaultLogo =
        (provider.currentAlbumArt ?? station.logo) == station.logo;

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        bottom: isLandscape ? 8 : 16,
        left: isLandscape ? MediaQuery.of(context).size.width * 0.14 : 0,
      ),
      physics: isLandscape
          ? const ClampingScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Info Section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.2, 0.0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: Column(
                key: ValueKey(
                  "${provider.currentTrack}|${provider.currentArtist}",
                ),
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
                            provider.currentArtist.isNotEmpty &&
                            !isDefaultLogo)
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    child: GestureDetector(
                      onTap:
                          (provider.currentTrack != "Live Broadcast" &&
                              provider.currentArtist.isNotEmpty &&
                              !isDefaultLogo)
                          ? () {
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
                          : null,

                      child: Text(
                        provider.currentArtist.isNotEmpty
                            ? provider.currentArtist
                            : "",
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 18,
                          decoration:
                              (provider.currentTrack != "Live Broadcast" &&
                                  provider.currentArtist.isNotEmpty &&
                                  !isDefaultLogo)
                              ? TextDecoration.underline
                              : null,
                          decorationColor: Colors.white54,
                        ),
                      ),
                    ),
                  ),
                  if (provider.currentAlbum.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      provider.currentAlbum,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          SizedBox(height: isLandscape ? 4 : 40),

          // Progress Bar (Youtube) - Above Controls
          if (provider.hiddenAudioController != null)
            _buildProgressBar(context, provider.hiddenAudioController!)
          else if (provider.currentPlayingPlaylistId != null)
            _buildNativeProgressBar(context, provider)
          else
            const SizedBox(height: 40), // Space for Radio info separation
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
                    icon: provider.isLoading
                        ? const SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(
                              color: Colors.black,
                              strokeWidth: 3,
                            ),
                          )
                        : Icon(
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

          SizedBox(height: isLandscape ? 95 : 50),
          // Visualizer (Bottom)
          AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            curve: Curves.fastOutSlowIn,
            height: isLandscape ? 40 : 60, // Shorter in landscape
            child: provider.isPlaying
                ? Opacity(
                    opacity:
                        (provider.hiddenAudioController != null ||
                            provider.currentPlayingPlaylistId != null)
                        ? 0.3
                        : 1.0,
                    child: _MusicVisualizer(
                      color: visualizerColor,
                      barCount: 60,
                      volume: _currentVolume,
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // Spacing for the curtain (initialChildSize is 0.15)
          SizedBox(height: MediaQuery.of(context).size.height * 0.15),
        ],
      ),
    );
  }

  Widget _buildNativeProgressBar(BuildContext context, RadioProvider provider) {
    // STANDARD LOGIC: Use AudioService.position for live position updates
    // This stream automatically extrapolates based on playback state and speed.
    return StreamBuilder<Duration>(
      stream: AudioService.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final duration =
            provider.audioHandler.mediaItem.value?.duration ?? Duration.zero;

        // Basic clamp to avoid errors if position > duration temporarily
        final maxVal = duration.inSeconds.toDouble() > 0
            ? duration.inSeconds.toDouble()
            : 1.0;
        final val = position.inSeconds.toDouble().clamp(0.0, maxVal);

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Row(
                children: [
                  Text(
                    _formatDuration(position),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ), // Visible thumb
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                        activeTrackColor: Colors.redAccent,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.redAccent,
                        overlayColor: Colors.redAccent.withOpacity(0.12),
                      ),
                      child: Slider(
                        value: val,
                        max: maxVal,
                        onChanged: (v) {
                          provider.audioHandler.seek(
                            Duration(seconds: v.toInt()),
                          );
                        },
                      ),
                    ),
                  ),
                  Text(
                    _formatDuration(duration),
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
      final oldId = _lastPlayingSongId;
      _lastPlayingSongId = provider.audioOnlySongId;

      if (currentIndex != -1 &&
          !_isNavigatingCarousel &&
          _pageController!.hasClients) {
        _isNavigatingCarousel = true;

        // Check if art is same as previous song to avoid visual slide
        bool isSameArt = false;
        if (oldId != null) {
          final oldIndex = songs.indexWhere((s) => s.id == oldId);
          if (oldIndex != -1 && oldIndex < songs.length) {
            final oldSong = songs[oldIndex];
            final newSong = songs[currentIndex];
            if (oldSong.artUri == newSong.artUri && oldSong.artUri != null) {
              isSameArt = true;
            }
          }
        }

        if (isSameArt) {
          _pageController!.jumpToPage(currentIndex);
          Future.delayed(const Duration(milliseconds: 50), () {
            if (mounted) _isNavigatingCarousel = false;
          });
        } else {
          _pageController!
              .animateToPage(
                currentIndex,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              )
              .then((_) {
                Future.delayed(const Duration(milliseconds: 100), () {
                  if (mounted) _isNavigatingCarousel = false;
                });
              });
        }
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
                    height: Curves.easeOut.transform(value) * height,
                    width: Curves.easeOut.transform(value) * height,
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
                      offset: const Offset(0, 20),
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

  OverlayEntry? _syncOverlayEntry;

  void _openSyncOverlay(BuildContext context, RadioProvider provider) {
    if (_syncOverlayEntry != null) return; // Already open

    _syncOverlayEntry = OverlayEntry(
      builder: (context) => _DraggableSyncOverlay(
        provider: provider,
        onClose: () {
          _syncOverlayEntry?.remove();
          _syncOverlayEntry = null;
        },
      ),
    );

    Overlay.of(context).insert(_syncOverlayEntry!);
  }
}

class _LyricsWidget extends StatefulWidget {
  final LyricsData lyrics;
  final Color accentColor;
  final Duration lyricsOffset;

  const _LyricsWidget({
    required this.lyrics,
    required this.accentColor,
    required this.lyricsOffset,
  });

  @override
  State<_LyricsWidget> createState() => _LyricsWidgetState();
}

class _LyricsWidgetState extends State<_LyricsWidget> {
  int _currentIndex = -1;
  final Map<int, GlobalKey> _lineKeys = {};
  double _lastViewportHeight = 0.0;

  void _scrollToIndex(int index) {
    // Force scroll even if index is same, to realign on resize
    _currentIndex = index;

    final key = _lineKeys[index];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        alignment: 0.5, // Center the text in the viewport
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: AudioService.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final effectivePosition = position - widget.lyricsOffset;

        int index = -1;
        for (int i = 0; i < widget.lyrics.lines.length; i++) {
          final lineTime = widget.lyrics.lines[i].time;
          // Check if current effective position is past this line's start
          if (effectivePosition >= lineTime) {
            index = i;
          } else {
            break;
          }
        }

        // Trigger scroll if index changed
        if (index != -1 && index != _currentIndex) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToIndex(index),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              // Re-center if viewport size changes (e.g. closing the sheet)
              if (_currentIndex != -1 &&
                  (constraints.viewportMainAxisExtent - _lastViewportHeight)
                          .abs() >
                      1.0) {
                _lastViewportHeight = constraints.viewportMainAxisExtent;
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _scrollToIndex(_currentIndex),
                );
              }
              _lastViewportHeight = constraints.viewportMainAxisExtent;

              return SliverList(
                delegate: SliverChildBuilderDelegate((context, i) {
                  final isSynced = widget.lyrics.isSynced == true;
                  final isCurrent = isSynced ? (i == index) : true;
                  final line = widget.lyrics.lines[i];

                  // Ensure key exists
                  _lineKeys[i] ??= GlobalKey();

                  return Padding(
                    key: _lineKeys[i],
                    padding: const EdgeInsets.symmetric(vertical: 12.0),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      style: TextStyle(
                        color: isCurrent ? Colors.white : Colors.white24,
                        fontSize: isSynced
                            ? (isCurrent ? 20 : 17)
                            : 22, // Larger font for non-synced lyrics
                        height: 1.4,
                        fontWeight: (isSynced && isCurrent) || !isSynced
                            ? FontWeight.bold
                            : FontWeight.normal,
                        shadows: isCurrent && isSynced
                            ? [
                                Shadow(
                                  color: widget.accentColor.withValues(
                                    alpha: 0.6,
                                  ),
                                  blurRadius: 12,
                                ),
                              ]
                            : null,
                      ),
                      child: Text(line.text, textAlign: TextAlign.center),
                    ),
                  );
                }, childCount: widget.lyrics.lines.length),
              );
            },
          ),
        );
      },
    );
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
        final double gap = totalWidth * 0.005;
        final double totalGap = gap * (widget.barCount - 1);
        final double barWidth = (totalWidth - totalGap) / widget.barCount;

        final Color accentColor = Color.lerp(widget.color, Colors.white, 0.15)!;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(widget.barCount, (index) {
            double heightFactor = _currentHeights[index];
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
                color: accentColor.withValues(
                  alpha: 0.6 + (heightFactor * 0.4),
                ),
                borderRadius: BorderRadius.circular(barWidth / 2),
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withOpacity(0.6),
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

class _DraggableSyncOverlay extends StatefulWidget {
  final RadioProvider provider;
  final VoidCallback onClose;

  const _DraggableSyncOverlay({required this.provider, required this.onClose});

  @override
  State<_DraggableSyncOverlay> createState() => _DraggableSyncOverlayState();
}

class _DraggableSyncOverlayState extends State<_DraggableSyncOverlay> {
  Offset _position = const Offset(20, 100);

  @override
  Widget build(BuildContext context) {
    final double currentOffsetSecs =
        widget.provider.lyricsOffset.inMilliseconds / 1000.0;

    void updateOffset(double newTime) {
      final clamped = newTime.clamp(-50.0, 50.0);
      widget.provider.setLyricsOffset(
        Duration(milliseconds: (clamped * 1000).toInt()),
      );
      setState(() {});
    }

    return Stack(
      children: [
        Positioned(
          left: _position.dx,
          top: _position.dy,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 300,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3), // Piu trasparente
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Draggable Header
                  GestureDetector(
                    onPanUpdate: (details) {
                      setState(() {
                        _position += details.delta;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Icon(
                            Icons.drag_indicator,
                            color: Colors.white38,
                            size: 20,
                          ),
                          const Text(
                            "Sync Lyrics",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          GestureDetector(
                            onTap: widget.onClose,
                            child: const Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          'Offset: ${currentOffsetSecs.toStringAsFixed(2)}s',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildSyncButton(
                              Icons.fast_rewind_rounded,
                              () => updateOffset(currentOffsetSecs - 1.0),
                              "-1s",
                            ),
                            _buildSyncButton(
                              Icons.remove_rounded,
                              () => updateOffset(currentOffsetSecs - 0.1),
                              "-0.1s",
                            ),
                            _buildSyncButton(
                              Icons.add_rounded,
                              () => updateOffset(currentOffsetSecs + 0.1),
                              "+0.1s",
                            ),
                            _buildSyncButton(
                              Icons.fast_forward_rounded,
                              () => updateOffset(currentOffsetSecs + 1.0),
                              "+1s",
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            overlayShape: SliderComponentShape.noOverlay,
                          ),
                          child: Slider(
                            value: currentOffsetSecs.clamp(-50.0, 50.0),
                            min: -50.0,
                            max: 50.0,
                            divisions: 200,
                            activeColor: Colors.white,
                            inactiveColor: Colors.white24,
                            onChanged: updateOffset,
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "-50s",
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                              ),
                            ),
                            const Text(
                              "+50s",
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () {
                            widget.provider.setLyricsOffset(Duration.zero);
                            setState(() {});
                          },
                          child: const Text(
                            "Reset",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSyncButton(IconData icon, VoidCallback onPressed, String label) {
    return Column(
      children: [
        IconButton(
          icon: Icon(icon, color: Colors.white70),
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }
}
