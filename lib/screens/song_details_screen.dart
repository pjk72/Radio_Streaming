import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:palette_generator/palette_generator.dart';
import '../providers/radio_provider.dart';
import '../models/playlist.dart';

import '../providers/language_provider.dart';
import 'trending_details_screen.dart';
import 'artist_details_screen.dart';
import '../services/lyrics_service.dart';
import '../services/entitlement_service.dart';

class SongDetailsScreen extends StatefulWidget {
  const SongDetailsScreen({super.key});

  @override
  State<SongDetailsScreen> createState() => _SongDetailsScreenState();
}

class _SongDetailsScreenState extends State<SongDetailsScreen>
    with TickerProviderStateMixin {
  double _currentVolume = 0.5;

  // Palette State
  String? _lastPaletteImage;
  Color? _extractedColor;
  late AnimationController _pulseController;

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
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
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
    _pulseController.dispose();
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
    final entitlements = Provider.of<EntitlementService>(context);
    final canUseLyrics = entitlements.isFeatureEnabled('lyrics');
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
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('no_station_selected'),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    // Determine images
    // During carousel preview, we prioritize the song art over the artist image for better visual feedback
    final String? bgImage = provider.currentAlbumArt ?? provider.currentArtistImage ?? station.logo;
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
              key: ValueKey(bgImage), // Force rebuild on image change
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Container(color: Color(int.parse(station.color))),
            )
          else
            Container(color: Color(int.parse(station.color))),

          // 2. Blur / Dark Overlay
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(color: Colors.black.withValues(alpha: 0.6)),
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

          if (canUseLyrics)
            Positioned(
              left: 0,
              bottom: 0, // Raise by banner height
              top: 0,
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
              color: Colors.black.withValues(alpha: 0.7),
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
                                          ? Provider.of<LanguageProvider>(
                                              context,
                                              listen: false,
                                            ).translate('loading_lyrics')
                                          : Provider.of<LanguageProvider>(
                                              context,
                                              listen: false,
                                            ).translate('no_lyrics_found'),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 16,
                                      ),
                                    ),
                                    if (!provider.isFetchingLyrics) ...[
                                      const SizedBox(height: 16),
                                      TextButton.icon(
                                        onPressed: () =>
                                            provider.fetchLyrics(force: true),
                                        icon: const Icon(
                                          Icons.refresh_rounded,
                                          color: Colors.white,
                                        ),
                                        label: Text(
                                          Provider.of<LanguageProvider>(
                                            context,
                                            listen: false,
                                          ).translate('retry_search'),
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                        style: TextButton.styleFrom(
                                          backgroundColor: Colors.white10,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 24,
                                            vertical: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
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
                              Colors.black.withValues(alpha: 0.85),
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
                                    color: accentColor.withValues(alpha: 0.7),
                                    size: 20,
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
                                            provider.currentTrack
                                                .replaceFirst("⬇️ ", "")
                                                .replaceFirst("📱 ", ""),
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
                                  if (provider.currentLyrics.lines.isNotEmpty)
                                    IconButton(
                                      icon: provider.isTranslatingLyrics
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white70,
                                              ),
                                            )
                                          : Icon(
                                              Icons.g_translate_rounded,
                                              color: provider.isLyricsTranslated
                                                  ? Theme.of(
                                                      context,
                                                    ).primaryColor
                                                  : Colors.white54,
                                              size: 20,
                                            ),
                                      tooltip: provider.isLyricsTranslated
                                          ? 'Show Original'
                                          : 'Translate (Live)',
                                      onPressed: provider.isTranslatingLyrics
                                          ? null
                                          : () {
                                              final langCode =
                                                  Provider.of<LanguageProvider>(
                                                    context,
                                                    listen: false,
                                                  ).resolvedLanguageCode;
                                              provider.toggleLyricsTranslation(
                                                langCode,
                                              );
                                            },
                                    ),
                                  if (provider.currentLyrics.isSynced)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.tune_rounded,
                                        color: Colors.white54,
                                        size: 20,
                                      ),
                                      tooltip: Provider.of<LanguageProvider>(
                                        context,
                                        listen: false,
                                      ).translate('sync_lyrics'),
                                      onPressed: () {
                                        _openSyncOverlay(context, provider);
                                      },
                                    ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.refresh_rounded,
                                      color: Colors.white54,
                                      size: 20,
                                    ),
                                    tooltip: Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    ).translate('retry_search'),
                                    onPressed: () {
                                      provider.fetchLyrics(force: true);
                                    },
                                  ),
                                  if (provider.currentLyrics.lines.isNotEmpty)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.copy_rounded,
                                        color: Colors.white54,
                                        size: 20,
                                      ),
                                      tooltip: Provider.of<LanguageProvider>(
                                        context,
                                        listen: false,
                                      ).translate('copy_lyrics'),
                                      onPressed: () {
                                        final text = provider
                                            .currentLyrics
                                            .lines
                                            .map((l) => l.text)
                                            .join('\n');
                                        Clipboard.setData(
                                          ClipboardData(text: text),
                                        );
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              Provider.of<LanguageProvider>(
                                                context,
                                                listen: false,
                                              ).translate('lyrics_copied'),
                                            ),
                                            duration: const Duration(
                                              seconds: 2,
                                            ),
                                          ),
                                        );
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
            height: 280,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior:
                  Clip.none, // Allow aura to overflow without pushing layout
              children: [
                Positioned(
                  child: SizedBox(
                    height: 380,
                    width: MediaQuery.of(context).size.width,
                    child: _StardustAura(
                      color: visualizerColor,
                      isPlaying: provider.isPlaying && !provider.isLoading,
                      volume: _currentVolume,
                    ),
                  ),
                ),
                provider.currentPlayingPlaylistId != null &&
                        provider.activeQueue.isNotEmpty
                    ? _buildCarousel(
                        context,
                        provider,
                        visualizerColor,
                        height: 230,
                      )
                    : _buildAlbumArt(
                        context,
                        provider,
                        visualizerColor,
                        mainImage,
                        230,
                      ),
              ],
            ),
          ),
          const SizedBox(
            height: 32,
          ), // Increased space to allow the shadow to breathe and move title away
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
    final double artSize = (screenHeight * 0.35).clamp(100.0, 160.0);

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
                  child: SizedBox(
                    height: artSize,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          child: SizedBox(
                            height: artSize * 2.5,
                            width: artSize * 2.5,
                            child: _StardustAura(
                              color: visualizerColor,
                              isPlaying:
                                  provider.isPlaying && !provider.isLoading,
                              volume: _currentVolume,
                            ),
                          ),
                        ),
                        provider.currentPlayingPlaylistId != null &&
                                provider.activeQueue.isNotEmpty
                            ? _buildCarousel(
                                context,
                                provider,
                                visualizerColor,
                                height: artSize,
                              )
                            : _buildAlbumArt(
                                context,
                                provider,
                                visualizerColor,
                                mainImage,
                                artSize,
                              ),
                      ],
                    ),
                  ),
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
          // Audio Effects Menu
          PopupMenuButton<double>(
            icon: Icon(
              Icons.graphic_eq_rounded,
              color: provider.currentSpeed != 1.0
                  ? Theme.of(context).primaryColor
                  : Colors.white70,
              size: 24,
            ),
            tooltip: 'Audio Effects',
            color: Colors.grey[900],
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onSelected: (speed) {
              provider.setAudioSpeed(speed);
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
              PopupMenuItem<double>(
                value: 0.85,
                child: Row(
                  children: [
                    Icon(
                      Icons.speed_rounded,
                      color: provider.currentSpeed == 0.85
                          ? Theme.of(context).primaryColor
                          : Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Slowed + Reverb',
                      style: TextStyle(
                        color: provider.currentSpeed == 0.85
                            ? Theme.of(context).primaryColor
                            : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<double>(
                value: 1.0,
                child: Row(
                  children: [
                    Icon(
                      Icons.play_circle_outline_rounded,
                      color: provider.currentSpeed == 1.0
                          ? Theme.of(context).primaryColor
                          : Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Normal',
                      style: TextStyle(
                        color: provider.currentSpeed == 1.0
                            ? Theme.of(context).primaryColor
                            : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<double>(
                value: 1.15,
                child: Row(
                  children: [
                    Icon(
                      Icons.fast_forward_rounded,
                      color: provider.currentSpeed == 1.15
                          ? Theme.of(context).primaryColor
                          : Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Sped Up (Nightcore)',
                      style: TextStyle(
                        color: provider.currentSpeed == 1.15
                            ? Theme.of(context).primaryColor
                            : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                activeTrackColor: Theme.of(
                  context,
                ).primaryColor.withValues(alpha: 0.8),
                inactiveTrackColor: Colors.white10,
                thumbColor: Theme.of(context).primaryColor,
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
    Color visualizerColor,
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
                  builder: (context) => TrendingDetailsScreen(
                    albumName: provider.currentAlbum,
                    artistName: provider.currentArtist,
                    artworkUrl: provider.currentAlbumArt,
                    songName: provider.currentTrack,
                  ),
                ),
              );
            }
          },
          child: AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    if (provider.isPlaying)
                      BoxShadow(
                        color: Theme.of(context).primaryColor.withOpacity(0.5),
                        blurRadius: 40,
                        spreadRadius: 5,
                        offset: Offset.zero,
                      ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: _ShadowedImage(
                  imageUrl: mainImage,
                  size: size,
                  visualizerColor: visualizerColor,
                  isPlaying: provider.isPlaying,
                  borderRadius: 12,
                ),
              );
            },
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

    final localPath = provider.currentLocalPath;
    final bool isOffline =
        localPath != null &&
        (localPath.contains('_secure.') ||
            localPath.endsWith('.mst') ||
            localPath.contains('offline_music'));

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        top: 10, // Added a bit of gap to ensure shadow visibility
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
                                    .replaceFirst("⬇️ ", "")
                                    .replaceFirst("📱 ", "")
                              : Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                ).translate('live_broadcast'),
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
                        (provider.currentArtist.isNotEmpty &&
                            (provider.currentPlayingPlaylistId != null ||
                                (provider.currentTrack !=
                                        Provider.of<LanguageProvider>(
                                          context,
                                          listen: false,
                                        ).translate('live_broadcast') &&
                                    !isDefaultLogo)))
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    child: GestureDetector(
                      onTap:
                          (provider.currentArtist.isNotEmpty &&
                              (provider.currentPlayingPlaylistId != null ||
                                  (provider.currentTrack !=
                                          Provider.of<LanguageProvider>(
                                            context,
                                            listen: false,
                                          ).translate('live_broadcast') &&
                                      !isDefaultLogo)))
                          ? () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => ArtistDetailsScreen(
                                    artistName: provider.currentArtist,
                                    artistImage: provider.currentArtistImage,
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
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 18,
                          decoration:
                              (provider.currentArtist.isNotEmpty &&
                                  (provider.currentPlayingPlaylistId != null ||
                                      (provider.currentTrack !=
                                              Provider.of<LanguageProvider>(
                                                context,
                                                listen: false,
                                              ).translate('live_broadcast') &&
                                          !isDefaultLogo)))
                              ? TextDecoration.underline
                              : null,
                          decorationColor: Colors.white54,
                        ),
                      ),
                    ),
                  ),
                  if (provider.currentAlbum.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Builder(
                      builder: (context) {
                        String albumText = provider.currentAlbum;
                        final stationName = station.name;

                        if (stationName.isNotEmpty &&
                            albumText.contains(stationName)) {
                          albumText = albumText
                              .replaceAll(stationName, "")
                              .replaceAll("•", "")
                              .trim();
                        }

                        if (albumText.isEmpty) return const SizedBox.shrink();

                        return Text(
                          albumText,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 14,
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),

          SizedBox(height: isLandscape ? 4 : 10),

          // Progress Bar (Youtube) - Above Controls
          if (provider.hiddenAudioController != null)
            _buildProgressBar(context, provider.hiddenAudioController!)
          else if (provider.isRecognizing ||
              provider.currentPlayingPlaylistId != null ||
              ((provider.currentStation != null ||
                      provider.audioHandler.mediaItem.value?.duration != null ||
                      provider
                              .audioHandler
                              .mediaItem
                              .value
                              ?.extras?['isRecognized'] ==
                          true) &&
                  provider.isACRCloudEnabled))
            provider.isRecognizing
                ? _buildIndeterminateProgressBar(
                    context,
                    provider,
                    isFast: true,
                  )
                : ((provider
                              .audioHandler
                              .mediaItem
                              .value
                              ?.extras?['hasExactOffset'] ??
                          true) &&
                      (provider
                                  .audioHandler
                                  .mediaItem
                                  .value
                                  ?.extras?['isRecognized'] ??
                              true) !=
                          false)
                ? _buildNativeProgressBar(context, provider)
                : provider.isPlaying
                ? _buildIndeterminateProgressBar(
                    context,
                    provider,
                    isFast: false,
                  )
                : const SizedBox(height: 20)
          else
            const SizedBox(height: 20), // Space for Radio info separation
          // Controls
          // Controls
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: SizedBox(
              height: 60,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 1. Left Action (Shuffle or Add)
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Builder(
                      builder: (context) {
                        // Shuffle (Playlist Mode)
                        if (provider.currentPlayingPlaylistId != null) {
                          return IconButton(
                            onPressed: () {
                              provider.toggleShuffle();
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (_pageController != null &&
                                    _pageController!.hasClients) {
                                  _pageController!.jumpToPage(0);
                                  if (provider.activeQueue.isNotEmpty &&
                                      provider.currentPlayingPlaylistId !=
                                          null) {
                                    provider.playPlaylistSong(
                                      provider.activeQueue[0],
                                      provider.currentPlayingPlaylistId!,
                                    );
                                  }
                                }
                              });
                            },
                            icon: Icon(
                              provider.isShuffleMode
                                  ? Icons.shuffle_rounded
                                  : Icons.repeat_rounded,
                              color: provider.isShuffleMode
                                  ? Theme.of(context).primaryColor
                                  : Colors.white24,
                              size: 24,
                            ),
                          );
                        }
                        // Add to Genre Playlist Button (Radio Only)
                        if (provider.currentPlayingPlaylistId == null &&
                            provider.currentTrack.isNotEmpty &&
                            provider.currentTrack != "Live Broadcast" &&
                            provider.currentTrack != "Unknown Title" &&
                            provider.currentAlbumArt !=
                                provider.currentStation?.logo) {
                          return IconButton(
                            icon: Icon(
                              provider.currentSongIsSaved
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                            ),
                            color: provider.currentSongIsSaved
                                ? Colors.redAccent
                                : Colors.white54,
                            iconSize: 28,
                            tooltip: provider.currentSongIsSaved
                                ? "Remove from Favorites"
                                : Provider.of<LanguageProvider>(
                                    context,
                                    listen: false,
                                  ).translate('add_to_genre_playlist'),
                            onPressed: () async {
                              final result = await provider
                                  .toggleCurrentSongFavorite();
                              if (context.mounted) {
                                if (result == true) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      behavior: SnackBarBehavior.floating,
                                      content: Row(
                                        children: [
                                          const Icon(
                                            Icons.favorite,
                                            color: Colors.white,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              Provider.of<LanguageProvider>(
                                                    context,
                                                    listen: false,
                                                  )
                                                  .translate(
                                                    'added_to_playlist',
                                                  )
                                                  .replaceAll(
                                                    '{0}',
                                                    'Favorites',
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                } else if (result == false) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      behavior: SnackBarBehavior.floating,
                                      content: Row(
                                        children: [
                                          const Icon(
                                            Icons.favorite_border,
                                            color: Colors.white,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                          const Expanded(
                                            child: Text(
                                              "Removed from Favorites",
                                            ),
                                          ),
                                        ],
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        Provider.of<LanguageProvider>(
                                          context,
                                          listen: false,
                                        ).translate('could_not_identify_song'),
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ),

                  // 2. Previous
                  IconButton(
                    onPressed: () => provider.playPrevious(),
                    icon: const Icon(
                      Icons.skip_previous_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),

                  // 3. Play/Pause (Center)
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.2),
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

                  // 4. Next
                  IconButton(
                    onPressed: () => provider.playNext(),
                    icon: const Icon(
                      Icons.skip_next_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),

                  // 5. Right Action (Device Indicator)
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: localPath != null
                        ? IconButton(
                            icon: Icon(
                              isOffline
                                  ? Icons.file_download_done_rounded
                                  : Icons.smartphone_rounded,
                              color: isOffline
                                  ? Colors.greenAccent.withValues(alpha: 0.8)
                                  : Colors.orangeAccent,
                              size: 24,
                            ),
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  behavior: SnackBarBehavior.floating,
                                  content: Row(
                                    children: [
                                      Icon(
                                        isOffline
                                            ? Icons.file_download_done_rounded
                                            : Icons.smartphone_rounded,
                                        color: isOffline
                                            ? Colors.greenAccent
                                            : Colors.orangeAccent,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        isOffline
                                            ? Provider.of<LanguageProvider>(
                                                context,
                                                listen: false,
                                              ).translate('song_saved_offline')
                                            : Provider.of<LanguageProvider>(
                                                context,
                                                listen: false,
                                              ).translate('song_on_device'),
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                  duration: const Duration(seconds: 3),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  margin: const EdgeInsets.all(20),
                                ),
                              );
                            },
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),

          SizedBox(height: isLandscape ? 95 : 30),

          // Spacing for the curtain (initialChildSize is 0.15)
          SizedBox(height: MediaQuery.of(context).size.height * 0.15),
        ],
      ),
    );
  }

  Widget _buildNativeProgressBar(BuildContext context, RadioProvider provider) {
    return StreamBuilder<MediaItem?>(
      stream: provider.audioHandler.mediaItem,
      builder: (context, mediaSnapshot) {
        return StreamBuilder<Duration>(
          stream: AudioService.position,
          builder: (context, snapshot) {
            final position = provider.isRecognizing
                ? Duration.zero
                : (snapshot.data ?? Duration.zero);
            final duration = mediaSnapshot.data?.duration ?? Duration.zero;

            final maxMs = duration.inMilliseconds.toDouble() > 0
                ? duration.inMilliseconds.toDouble()
                : 1000.0;
            final val = position.inMilliseconds.toDouble().clamp(0.0, maxMs);

            final isStation = provider.currentPlayingPlaylistId == null;
            final leftLabel = (isStation && duration > Duration.zero)
                ? "-${_formatDuration(duration - position > Duration.zero ? duration - position : Duration.zero)}"
                : _formatDuration(position);

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ), // Visible thumb
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                          activeTrackColor: Theme.of(context).primaryColor,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Theme.of(context).primaryColor,
                          overlayColor: Theme.of(
                            context,
                          ).primaryColor.withValues(alpha: 0.12),
                        ),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(end: val),
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.linear,
                          builder: (context, animatedVal, _) {
                            final secureValue = animatedVal.clamp(0.0, maxMs);
                            return Slider(
                              value: secureValue,
                              max: maxMs,
                              onChanged:
                                  provider.currentPlayingPlaylistId != null
                                  ? (v) {
                                      provider.audioHandler.seek(
                                        Duration(milliseconds: v.toInt()),
                                      );
                                    }
                                  : null,
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              leftLabel,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            isStation
                                ? const Icon(
                                    Icons.search_rounded,
                                    color: Colors.white70,
                                    size: 16,
                                  )
                                : Text(
                                    _formatDuration(duration),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildIndeterminateProgressBar(
    BuildContext context,
    RadioProvider provider, {
    bool isFast = false,
  }) {
    if (isFast) {
      return Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40.0),
            child: ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(2)),
              child: SizedBox(
                height: 4,
                child: _ScanningProgressBar(
                  speed: ScanningSpeed.fast,
                  height: 4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "--:--",
                  style: TextStyle(color: Colors.white30, fontSize: 12),
                ),
                Icon(Icons.sync_rounded, color: Colors.white30, size: 16),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      );
    }

    // Countdown Timer logic for Not Found / Sol 2 (isFast = false)
    final item = provider.audioHandler.mediaItem.value;
    final start = item?.extras?['countdown_start'] as int?;
    final durationMs = item?.extras?['ui_duration'] as int? ?? 45000;

    if (start != null) {
      return StreamBuilder<int>(
        stream: Stream.periodic(const Duration(milliseconds: 100), (i) => i),
        builder: (context, snapshot) {
          final elapsedMs = DateTime.now().millisecondsSinceEpoch - start;
          final progress = (elapsedMs / durationMs).clamp(0.0, 1.0);
          final currentDur = Duration(
            milliseconds: elapsedMs.clamp(0, durationMs),
          );
          final maxDur = Duration(milliseconds: durationMs);

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 0,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 0,
                            ),
                            activeTrackColor: Theme.of(context).primaryColor,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors
                                .transparent, // Disable thumb display since it's unseekable
                          ),
                          child: Slider(value: progress, onChanged: null),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(currentDur),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            _formatDuration(maxDur),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
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

    return const SizedBox(height: 20);
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
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 0,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                      activeTrackColor: Theme.of(context).primaryColor,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Theme.of(context).primaryColor,
                    ),
                    child: Slider(
                      value: position.clamp(0.0, duration > 0 ? duration : 1.0),
                      max: duration > 0 ? duration : 1.0,
                      onChanged: (v) {
                        controller.seekTo(Duration(seconds: v.toInt()));
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(value.position),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          _formatDuration(value.metaData.duration),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
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
    RadioProvider provider,
    Color visualizerColor, {
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
        viewportFraction:
            1.0, // Show only one photo at a time to clean up the sides
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
      height: 320,
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
              animation: Listenable.merge([_pageController!, _pulseController]),
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
                    height: 280, // Matching the parent height
                    width: MediaQuery.of(context).size.width,
                    child: Center(
                      child: SizedBox(
                        height: Curves.easeOut.transform(value) * 230,
                        width: Curves.easeOut.transform(value) * 230,
                        child: child,
                      ),
                    ),
                  ),
                );
              },
              child: _ShadowedImage(
                imageUrl: song.artUri,
                size: 230,
                visualizerColor: visualizerColor,
                isPlaying: provider.isPlaying,
                borderRadius: 26,
                isCarousel: true,
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
                      builder: (context) => TrendingDetailsScreen(
                        albumName: song.album,
                        artistName: song.artist,
                        artworkUrl: song.artUri,
                        appleMusicUrl: song.appleMusicUrl,
                        songName: song.title,
                      ),
                    ),
                  );
                },
                stackChildren: [
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

                  final parts = line.text.split('\n');

                  return Padding(
                    key: _lineKeys[i],
                    padding: const EdgeInsets.symmetric(vertical: 12.0),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      style: TextStyle(
                        color: isCurrent ? Colors.white : Colors.white54,
                        fontSize: isSynced
                            ? (isCurrent ? 20 : 17)
                            : 22, // Larger font for non-synced lyrics
                        height: 1.4,
                        fontWeight: (isSynced && isCurrent) || !isSynced
                            ? FontWeight.bold
                            : FontWeight.normal,
                        shadows: [
                          const Shadow(
                            color: Colors.black,
                            blurRadius: 10,
                            offset: Offset(0, 2),
                          ),
                          const Shadow(
                            color: Colors.black87,
                            blurRadius: 4,
                            offset: Offset(1, 1),
                          ),
                          if (isCurrent && isSynced)
                            Shadow(
                              color: widget.accentColor.withValues(alpha: 0.8),
                              blurRadius: 16,
                            ),
                        ],
                      ),
                      child: parts.length > 1
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(parts.first, textAlign: TextAlign.center),
                                const SizedBox(height: 6),
                                Text(
                                  parts.sublist(1).join('\n'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? Colors.white.withValues(alpha: 0.8)
                                        : Colors.white.withValues(alpha: 0.4),
                                    fontSize: isSynced
                                        ? (isCurrent ? 18 : 15)
                                        : 20,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            )
                          : Text(line.text, textAlign: TextAlign.center),
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

class _StardustAura extends StatefulWidget {
  final Color color;
  final bool isPlaying;
  final double volume;

  const _StardustAura({
    required this.color,
    required this.isPlaying,
    required this.volume,
  });

  @override
  State<_StardustAura> createState() => _StardustAuraState();
}

class _StardustAuraState extends State<_StardustAura>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  final List<_StardustParticle> _particles = [];
  final Random _random = Random();
  double _rotationAngle = 0.0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    // Initialize some particles
    for (int i = 0; i < 50; i++) {
      _particles.add(_createParticle(isInitial: true));
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    setState(() {
      _updatePhysics();
    });
  }

  _StardustParticle _createParticle({bool isInitial = false}) {
    final angle = _random.nextDouble() * pi * 2;
    return _StardustParticle(
      angle: angle,
      // Radius adjusted to hug the 230x230 square art (corners are at ~163px from center)
      radius: _random.nextDouble() * 0.3 + 0.55,
      size: _random.nextDouble() * 2.5 + 0.5,
      speed: _random.nextDouble() * 0.01 + 0.005,
      life: isInitial ? _random.nextDouble() : 1.0,
      opacity: _random.nextDouble() * 0.5 + 0.2,
      wobble: _random.nextDouble() * pi * 2,
    );
  }

  void _updatePhysics() {
    final activeMultiplier = widget.isPlaying ? 1.0 : 0.15;
    _rotationAngle += 0.003 * activeMultiplier;

    // Add new particles - Balanced count for 60fps performance
    final maxParticles = (100 + (widget.volume * 100)).toInt();
    if (_particles.length < maxParticles && _random.nextDouble() < 0.4) {
      _particles.add(_createParticle());
    }

    // Update existing
    for (int i = _particles.length - 1; i >= 0; i--) {
      final p = _particles[i];
      p.life -= 0.004; // Slightly faster fade for cleaner look
      p.angle += p.speed * activeMultiplier;
      p.wobble += 0.04;

      if (p.life <= 0) {
        _particles.removeAt(i);
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StardustPainter(
        particles: _particles,
        color: widget.color,
        rotationAngle: _rotationAngle,
        volume: widget.volume,
      ),
      size: Size.infinite,
    );
  }
}

class _StardustParticle {
  double angle;
  double radius;
  double size;
  double speed;
  double life;
  double opacity;
  double wobble;

  _StardustParticle({
    required this.angle,
    required this.radius,
    required this.size,
    required this.speed,
    required this.life,
    required this.opacity,
    required this.wobble,
  });
}

class _StardustPainter extends CustomPainter {
  final List<_StardustParticle> particles;
  final Color color;
  final double rotationAngle;
  final double volume;

  _StardustPainter({
    required this.particles,
    required this.color,
    required this.rotationAngle,
    required this.volume,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = min(size.width, size.height) * 0.8;

    // Removed ambient glow to prevent color mismatch with page background

    for (final p in particles) {
      final currentAngle = p.angle + rotationAngle;
      final orbitVariation = 1.0 + sin(p.wobble) * 0.12;
      final currentRadius = p.radius * maxRadius * orbitVariation;

      final offset = Offset(
        center.dx + cos(currentAngle) * currentRadius,
        center.dy +
            sin(currentAngle) *
                currentRadius, // Perfect circle for uniform distribution
      );

      final alpha = (p.opacity * p.life * (0.4 + volume * 0.6)).clamp(0.0, 1.0);

      // OPTIMIZED GLOW: Drawing two circles instead of using MaskFilter.blur
      // OPTIMIZED GLOW: Drawing two circles
      // 1. Soft Outer Glow - Reduced size to prevent "bar" effect
      canvas.drawCircle(
        offset,
        p.size * 1.8,
        Paint()..color = color.withOpacity(alpha * 0.25),
      );

      // 2. Main Particle
      canvas.drawCircle(
        offset,
        p.size,
        Paint()..color = color.withOpacity(alpha),
      );

      // 3. Brighter core
      if (p.life > 0.4) {
        canvas.drawCircle(
          offset,
          p.size * 0.4,
          Paint()..color = Colors.white.withOpacity(alpha * 0.8),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _ShadowedImage extends StatefulWidget {
  final String? imageUrl;
  final double size;
  final Color visualizerColor;
  final bool isPlaying;
  final double borderRadius;
  final bool isCarousel;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final List<Widget>? stackChildren;

  const _ShadowedImage({
    required this.imageUrl,
    required this.size,
    required this.visualizerColor,
    required this.isPlaying,
    required this.borderRadius,
    this.isCarousel = false,
    this.onTap,
    this.onDoubleTap,
    this.stackChildren,
  });

  @override
  State<_ShadowedImage> createState() => _ShadowedImageState();
}

class _ShadowedImageState extends State<_ShadowedImage>
    with SingleTickerProviderStateMixin {
  bool _isLoaded = false;
  late AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void didUpdateWidget(_ShadowedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageUrl != oldWidget.imageUrl) {
      _isLoaded = false;
      _fadeController.reset();
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showShadow = widget.isPlaying && _isLoaded;

    return AnimatedBuilder(
      animation: _fadeController,
      builder: (context, child) {
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            boxShadow: [
              if (showShadow)
                BoxShadow(
                  color: Theme.of(context)
                      .primaryColor
                      .withOpacity(0.8 * _fadeController.value),
                  blurRadius: widget.isCarousel
                      ? 8 * _fadeController.value
                      : 3 * _fadeController.value,
                  spreadRadius: widget.isCarousel
                      ? 5 * _fadeController.value
                      : 4 * _fadeController.value,
                  offset: Offset.zero,
                ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: GestureDetector(
            onTap: widget.onTap,
            onDoubleTap: widget.onDoubleTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.imageUrl != null && widget.imageUrl!.isNotEmpty
                    ? Image.network(
                        widget.imageUrl!,
                        key: ValueKey(widget.imageUrl),
                        fit: BoxFit.cover,
                        frameBuilder:
                            (context, child, frame, wasSynchronouslyLoaded) {
                          if (frame != null && !_isLoaded) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                setState(() {
                                  _isLoaded = true;
                                });
                                _fadeController.forward();
                              }
                            });
                          }
                          return child;
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return _buildPlaceholder();
                        },
                      )
                    : _buildPlaceholder(),
                if (widget.stackChildren != null) ...widget.stackChildren!,
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Icon(
        Icons.music_note_rounded,
        size: widget.isCarousel ? 40 : 80,
        color: Colors.white.withValues(alpha: 0.5),
      ),
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
                          Text(
                            Provider.of<LanguageProvider>(
                              context,
                              listen: false,
                            ).translate('sync_lyrics'),
                            style: const TextStyle(
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
                          Provider.of<LanguageProvider>(context, listen: false)
                              .translate('offset_secs')
                              .replaceAll(
                                '{0}',
                                currentOffsetSecs.toStringAsFixed(2),
                              ),
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
                          child: Text(
                            Provider.of<LanguageProvider>(
                              context,
                              listen: false,
                            ).translate('reset'),
                            style: const TextStyle(
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

enum ScanningSpeed { fast, slow }

class _ScanningProgressBar extends StatefulWidget {
  final ScanningSpeed speed;
  final double height;

  const _ScanningProgressBar({required this.speed, this.height = 2});

  @override
  _ScanningProgressBarState createState() => _ScanningProgressBarState();
}

class _ScanningProgressBarState extends State<_ScanningProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    final duration = widget.speed == ScanningSpeed.fast
        ? const Duration(milliseconds: 1000)
        : const Duration(milliseconds: 12000);

    _controller = AnimationController(vsync: this, duration: duration)
      ..repeat(reverse: true);

    _animation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void didUpdateWidget(_ScanningProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speed != widget.speed) {
      final newDuration = widget.speed == ScanningSpeed.fast
          ? const Duration(milliseconds: 1000)
          : const Duration(milliseconds: 12000);
      _controller.duration = newDuration;
      if (_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).primaryColor;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Stack(
          children: [
            Container(color: color.withValues(alpha: 0.05)),
            Align(
              alignment: Alignment(_animation.value * 2 - 1, 0),
              child: Container(
                width: 80,
                height: widget.height,
                decoration: BoxDecoration(
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
