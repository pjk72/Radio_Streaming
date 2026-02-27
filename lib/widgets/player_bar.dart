import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import 'package:audio_service/audio_service.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../utils/icon_library.dart';

import '../screens/song_details_screen.dart';
import '../screens/artist_details_screen.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  void _openSongDetails(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const SongDetailsScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          const curve = Curves.easeOutQuart;
          var tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final langProvider = Provider.of<LanguageProvider>(context);
    final station = provider.currentStation;
    final bool isDesktop = MediaQuery.of(context).size.width > 600;

    // Calculate contrast for the player bar background (cardColor)
    final cardColor = Theme.of(context).cardColor;
    final contrastColor = cardColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

    // Local theme for content inside PlayerBar
    final playerTheme = Theme.of(context).copyWith(
      iconTheme: Theme.of(context).iconTheme.copyWith(color: contrastColor),
      textTheme: Theme.of(
        context,
      ).textTheme.apply(bodyColor: contrastColor, displayColor: contrastColor),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (details) {
        // Swipe UP detection: velocity is negative
        if (details.primaryVelocity != null &&
            details.primaryVelocity! < -300) {
          _openSongDetails(context);
        }
      },
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: isDesktop ? 80 : 72,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  cardColor.withValues(alpha: 0.4),
                  cardColor.withValues(alpha: 0.6),
                ],
              ),
              border: Border(
                top: BorderSide(
                  color: contrastColor.withValues(alpha: 0.1),
                  width: 0.5,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 20,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Theme(
              data: playerTheme,
              child: Stack(
                children: [
                  // Main Section: Info + Controls + Volume
                  Align(
                    alignment: Alignment.center,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: isDesktop ? 24 : 16,
                      ),
                      child: Row(
                        children: [
                          // Track Info - Flexible width
                          Expanded(
                            flex: isDesktop ? 3 : 1,
                            child: station != null
                                ? Row(
                                    mainAxisSize:
                                        MainAxisSize.min, // shrink wrap
                                    children: [
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          onTap: () =>
                                              _openSongDetails(context),
                                          child: Hero(
                                            tag: 'player_image',
                                            child: Stack(
                                              children: [
                                                ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: Container(
                                                    width: isDesktop ? 44 : 36,
                                                    height: isDesktop ? 44 : 36,
                                                    color: Colors.black,
                                                    alignment: Alignment.center,
                                                    child:
                                                        (provider.currentAlbumArt ??
                                                                station.logo) !=
                                                            null
                                                        ? _buildImage(
                                                            provider.currentAlbumArt ??
                                                                station.logo!,
                                                            fit: BoxFit.cover,
                                                            errorBuilder:
                                                                (
                                                                  context,
                                                                  error,
                                                                  stackTrace,
                                                                ) {
                                                                  return FaIcon(
                                                                    IconLibrary.getIcon(
                                                                      station
                                                                          .icon,
                                                                    ),
                                                                    color: Color(
                                                                      int.parse(
                                                                        station
                                                                            .color,
                                                                      ),
                                                                    ),
                                                                    size: 24,
                                                                  );
                                                                },
                                                          )
                                                        : FaIcon(
                                                            IconLibrary.getIcon(
                                                              station.icon,
                                                            ),
                                                            color: Color(
                                                              int.parse(
                                                                station.color,
                                                              ),
                                                            ),
                                                            size: 24,
                                                          ),
                                                  ),
                                                ),
                                                if (provider.currentLocalPath !=
                                                        null ||
                                                    provider
                                                            .currentStation
                                                            ?.genre ==
                                                        "Local Device" ||
                                                    provider
                                                            .currentStation
                                                            ?.icon ==
                                                        "smartphone")
                                                  Positioned(
                                                    bottom: 2,
                                                    right: 2,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            2,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black
                                                            .withValues(
                                                              alpha: 0.8,
                                                            ),
                                                        shape: BoxShape.circle,
                                                        border: Border.all(
                                                          color: Colors.white24,
                                                          width: 0.5,
                                                        ),
                                                      ),
                                                      child: Icon(
                                                        (provider.currentLocalPath !=
                                                                    null &&
                                                                (provider
                                                                        .currentLocalPath!
                                                                        .contains(
                                                                          '_secure.',
                                                                        ) ||
                                                                    provider
                                                                        .currentLocalPath!
                                                                        .contains(
                                                                          '.mst',
                                                                        ) ||
                                                                    provider
                                                                        .currentLocalPath!
                                                                        .contains(
                                                                          'offline_music',
                                                                        )))
                                                            ? Icons
                                                                  .file_download_done_rounded
                                                            : Icons
                                                                  .smartphone_rounded,
                                                        size: 12,
                                                        color:
                                                            (provider.currentLocalPath !=
                                                                    null &&
                                                                (provider
                                                                        .currentLocalPath!
                                                                        .contains(
                                                                          '_secure.',
                                                                        ) ||
                                                                    provider
                                                                        .currentLocalPath!
                                                                        .contains(
                                                                          '.mst',
                                                                        ) ||
                                                                    provider
                                                                        .currentLocalPath!
                                                                        .contains(
                                                                          'offline_music',
                                                                        )))
                                                            ? Colors.greenAccent
                                                            : Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: provider.errorMessage != null
                                            ? Row(
                                                children: [
                                                  Icon(
                                                    Icons
                                                        .signal_wifi_bad_rounded,
                                                    color: Colors.redAccent,
                                                    size: 20,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      provider.errorMessage!,
                                                      style: const TextStyle(
                                                        color: Colors.redAccent,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 14,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ],
                                              )
                                            : provider.currentTrack !=
                                                      langProvider.translate(
                                                        'live_broadcast',
                                                      ) &&
                                                  provider
                                                      .currentTrack
                                                      .isNotEmpty
                                            ? Row(
                                                children: [
                                                  Expanded(
                                                    child: MouseRegion(
                                                      cursor: SystemMouseCursors
                                                          .click,
                                                      child: GestureDetector(
                                                        behavior:
                                                            HitTestBehavior
                                                                .translucent,
                                                        onTap: () =>
                                                            _openSongDetails(
                                                              context,
                                                            ),
                                                        child: Column(
                                                          mainAxisAlignment:
                                                              MainAxisAlignment
                                                                  .center,
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Row(
                                                              children: [
                                                                Flexible(
                                                                  child: Text(
                                                                    provider
                                                                        .currentTrack
                                                                        .replaceFirst(
                                                                          "⬇️ ",
                                                                          "",
                                                                        )
                                                                        .replaceFirst(
                                                                          "📱 ",
                                                                          "",
                                                                        ),
                                                                    style: TextStyle(
                                                                      color: playerTheme
                                                                          .textTheme
                                                                          .titleMedium
                                                                          ?.color,
                                                                      fontSize:
                                                                          16,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w700,
                                                                    ),
                                                                    maxLines: 1,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                            const SizedBox(
                                                              height: 4,
                                                            ),
                                                            Builder(
                                                              builder: (context) {
                                                                final bool
                                                                isLinkEnabled =
                                                                    provider
                                                                        .currentArtist
                                                                        .isNotEmpty &&
                                                                    provider.currentAlbumArt !=
                                                                        null &&
                                                                    provider.currentAlbumArt !=
                                                                        provider
                                                                            .currentStation
                                                                            ?.logo;

                                                                final Widget
                                                                artistText = Text(
                                                                  provider
                                                                          .currentArtist
                                                                          .isNotEmpty
                                                                      ? provider
                                                                            .currentArtist
                                                                      : langProvider.translate(
                                                                          'unknown_artist',
                                                                        ),
                                                                  style: TextStyle(
                                                                    color:
                                                                        isLinkEnabled
                                                                        ? Theme.of(
                                                                            context,
                                                                          ).primaryColor
                                                                        : playerTheme
                                                                              .textTheme
                                                                              .bodySmall
                                                                              ?.color,
                                                                    fontSize:
                                                                        13,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w600,
                                                                  ),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                );

                                                                if (isLinkEnabled) {
                                                                  return MouseRegion(
                                                                    cursor:
                                                                        SystemMouseCursors
                                                                            .click,
                                                                    child: GestureDetector(
                                                                      onTap: () {
                                                                        Navigator.of(
                                                                          context,
                                                                        ).push(
                                                                          MaterialPageRoute(
                                                                            builder:
                                                                                (
                                                                                  context,
                                                                                ) => ArtistDetailsScreen(
                                                                                  artistName: provider.currentArtist,
                                                                                  artistImage: provider.currentArtistImage,
                                                                                  genre: station.genre,
                                                                                ),
                                                                          ),
                                                                        );
                                                                      },
                                                                      child:
                                                                          artistText,
                                                                    ),
                                                                  );
                                                                } else {
                                                                  return artistText;
                                                                }
                                                              },
                                                            ),
                                                            Builder(
                                                              builder: (context) {
                                                                String
                                                                albumText = provider
                                                                    .currentAlbum;
                                                                final stationName =
                                                                    station
                                                                        .name;

                                                                if (stationName
                                                                        .isNotEmpty &&
                                                                    albumText
                                                                        .contains(
                                                                          stationName,
                                                                        )) {
                                                                  albumText = albumText
                                                                      .replaceAll(
                                                                        stationName,
                                                                        "",
                                                                      )
                                                                      .replaceAll(
                                                                        "•",
                                                                        "",
                                                                      )
                                                                      .trim();
                                                                }

                                                                if (albumText
                                                                        .isNotEmpty &&
                                                                    albumText !=
                                                                        "Playlist") {
                                                                  return Padding(
                                                                    padding:
                                                                        const EdgeInsets.only(
                                                                          top:
                                                                              1,
                                                                        ),
                                                                    child: Text(
                                                                      albumText,
                                                                      style: TextStyle(
                                                                        color: playerTheme
                                                                            .textTheme
                                                                            .bodySmall
                                                                            ?.color
                                                                            ?.withValues(
                                                                              alpha: 0.4,
                                                                            ),
                                                                        fontSize:
                                                                            10,
                                                                        letterSpacing:
                                                                            0.3,
                                                                      ),
                                                                      maxLines:
                                                                          1,
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                    ),
                                                                  );
                                                                }
                                                                return const SizedBox.shrink();
                                                              },
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              )
                                            : Text(
                                                langProvider.translate(
                                                  'live_broadcast',
                                                ),
                                                style: TextStyle(
                                                  color: playerTheme
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.color,
                                                  fontSize: isDesktop ? 16 : 14,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                      ),
                                    ],
                                  )
                                : Center(
                                    child: Text(
                                      langProvider.translate(
                                        'select_a_station',
                                      ),
                                      style: TextStyle(
                                        color: playerTheme
                                            .textTheme
                                            .bodyMedium
                                            ?.color,
                                      ),
                                    ),
                                  ),
                          ),

                          // Spacer to ensure separation if needed, or rely on MainAxisAlignment.spaceBetween
                          if (!isDesktop) const SizedBox(width: 8),

                          // Center Controls (Play, Prev, Next, Shuffle) - Fixed size on Mobile
                          isDesktop
                              ? Expanded(
                                  flex: 2,
                                  child: _buildControls(
                                    context,
                                    provider,
                                    isDesktop,
                                  ),
                                )
                              : _buildControls(context, provider, isDesktop),

                          // Volume (Right Side) - Only show on Desktop
                          if (isDesktop)
                            Expanded(
                              flex: 1,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  const SizedBox(width: 12),
                                  SizedBox(
                                    width: 100,
                                    child: Row(
                                      children: [
                                        Icon(
                                          provider.volume == 0
                                              ? Icons.volume_off_rounded
                                              : provider.volume < 0.5
                                              ? Icons.volume_down_rounded
                                              : Icons.volume_up_rounded,
                                          size: 18,
                                          color: playerTheme.iconTheme.color
                                              ?.withValues(alpha: 0.4),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              thumbShape:
                                                  const RoundSliderThumbShape(
                                                    enabledThumbRadius: 5,
                                                  ),
                                              overlayShape:
                                                  const RoundSliderOverlayShape(
                                                    overlayRadius: 10,
                                                  ),
                                              trackHeight: 3,
                                              activeTrackColor: Theme.of(
                                                context,
                                              ).primaryColor,
                                              inactiveTrackColor:
                                                  Theme.of(context).dividerColor
                                                      .withValues(alpha: 0.1),
                                              thumbColor: Theme.of(
                                                context,
                                              ).primaryColor,
                                            ),
                                            child: Slider(
                                              value: provider.volume,
                                              onChanged: (val) =>
                                                  provider.setVolume(val),
                                            ),
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
                    ),
                  ),

                  // Slim Modern Progress Bar at the very top
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _buildSlimProgressBar(context, provider),
                  ),

                  if (!isDesktop)
                    Positioned(
                      top: 7, // Below progress bar (2px) + small gap
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          width: 24,
                          height: 3,
                          decoration: BoxDecoration(
                            color: contrastColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(1.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(
    String url, {
    BoxFit? fit,
    ImageErrorWidgetBuilder? errorBuilder,
  }) {
    if (url.startsWith('assets/')) {
      return Image.asset(
        url,
        fit: fit,
        errorBuilder: errorBuilder,
        gaplessPlayback: true,
      );
    } else {
      return CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        errorWidget: errorBuilder != null
            ? (context, url, error) =>
                  errorBuilder(context, error, StackTrace.current)
            : null,
        memCacheWidth: 150, // Optimize memory for small thumbnail
        maxWidthDiskCache: 150, // Optimize disk storage
        fadeInDuration: const Duration(milliseconds: 300), // Smooth transition
      );
    }
  }

  Widget _buildControls(
    BuildContext context,
    RadioProvider provider,
    bool isDesktop,
  ) {
    final langProvider = Provider.of<LanguageProvider>(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Shuffle Button (Left of Controls)
        if (provider.currentPlayingPlaylistId != null) ...[
          IconButton(
            icon: Icon(
              provider.isShuffleMode
                  ? Icons.shuffle_rounded
                  : Icons.repeat_rounded,
              color: provider.isShuffleMode
                  ? Theme.of(context).primaryColor
                  : Theme.of(context).iconTheme.color?.withValues(alpha: 0.5),
            ),
            iconSize: 20,
            tooltip: langProvider.translate('shuffle'),
            onPressed: () => provider.toggleShuffle(),
          ),
          const SizedBox(width: 4),
        ],

        // Add to Genre Playlist Button (Radio Only)
        // Moved to the left of controls
        if (provider.currentSongDuration != null &&
            provider.currentPlayingPlaylistId == null &&
            provider.currentTrack.isNotEmpty &&
            provider.currentTrack != langProvider.translate('live_broadcast') &&
            provider.currentTrack != langProvider.translate('unknown_title') &&
            provider.currentAlbumArt != provider.currentStation?.logo) ...[
          IconButton(
            icon: Icon(
              provider.currentSongIsSaved
                  ? Icons.check_circle
                  : Icons.add_circle_outline,
            ),
            color: provider.currentSongIsSaved
                ? Colors.greenAccent
                : Theme.of(context).iconTheme.color?.withValues(alpha: 0.5),
            iconSize: 20,
            tooltip: provider.currentSongIsSaved
                ? langProvider.translate('already_saved')
                : langProvider.translate('add_to_genre_playlist'),
            onPressed: provider.currentSongIsSaved
                ? null // Disable if already saved
                : () async {
                    final genre = await provider
                        .addCurrentSongToGenrePlaylist();
                    if (context.mounted) {
                      if (genre != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            backgroundColor: const Color(
                              0xFF1a4d2e,
                            ), // Dark Green
                            content: Text(
                              langProvider
                                  .translate('added_to_playlist')
                                  .replaceAll('{0}', genre),
                            ),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              langProvider.translate('could_not_identify_song'),
                            ),
                          ),
                        );
                      }
                    }
                  },
          ),
          const SizedBox(width: 8),
        ],

        IconButton(
          icon: const Icon(Icons.skip_previous_rounded),
          color: Theme.of(context).iconTheme.color,
          iconSize: isDesktop ? 32 : 28,
          onPressed: () => provider.playPrevious(),
        ),
        SizedBox(width: isDesktop ? 24 : 4),
        Container(
          width: isDesktop ? 48 : 40,
          height: isDesktop ? 48 : 40,
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.4),
                blurRadius: 15,
                spreadRadius: 1,
              ),
            ],
          ),
          child: IconButton(
            icon: provider.isLoading
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      color: Theme.of(context).colorScheme.onPrimary,
                      strokeWidth: 3,
                    ),
                  )
                : Icon(
                    provider.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
            color: Theme.of(context).colorScheme.onPrimary,
            iconSize: isDesktop ? 30 : 26,
            onPressed: () => provider.togglePlay(),
          ),
        ),
        SizedBox(width: isDesktop ? 24 : 4),
        IconButton(
          icon: const Icon(Icons.skip_next_rounded),
          color: Theme.of(context).iconTheme.color,
          iconSize: isDesktop ? 32 : 28,
          onPressed: () => provider.playNext(),
        ),
      ],
    );
  }

  Widget _buildSlimProgressBar(BuildContext context, RadioProvider provider) {
    final accentColor = Theme.of(context).primaryColor;

    if (provider.hiddenAudioController != null) {
      return ValueListenableBuilder(
        valueListenable: provider.hiddenAudioController!,
        builder: (context, value, child) {
          final position = value.position.inSeconds.toDouble();
          final duration = value.metaData.duration.inSeconds.toDouble();
          final max = duration > 0 ? duration : 100.0;
          final progress = (position / max).clamp(0.0, 1.0);

          return _progressBarLine(
            context,
            progress,
            accentColor,
            onSeek: (p) => provider.hiddenAudioController!.seekTo(
              Duration(seconds: (p * max).toInt()),
            ),
          );
        },
      );
    } else if (provider.currentPlayingPlaylistId != null) {
      return StreamBuilder<Duration>(
        stream: AudioService.position,
        builder: (context, snapshot) {
          final position = snapshot.data ?? Duration.zero;
          final totalDuration =
              provider.audioHandler.mediaItem.value?.duration ??
              const Duration(seconds: 1);
          final maxSec = totalDuration.inSeconds > 0
              ? totalDuration.inSeconds
              : 1;
          final progress = (position.inSeconds / maxSec).clamp(0.0, 1.0);

          return _progressBarLine(
            context,
            progress,
            accentColor,
            onSeek: (p) => provider.audioHandler.seek(
              Duration(seconds: (p * maxSec).toInt()),
            ),
          );
        },
      );
    } else if (provider.isRecognizing) {
      return SizedBox(
        height: 2,
        child: LinearProgressIndicator(
          backgroundColor: Colors.transparent,
          valueColor: AlwaysStoppedAnimation<Color>(
            accentColor.withValues(alpha: 0.5),
          ),
          minHeight: 2,
        ),
      );
    }
    return const SizedBox(height: 2);
  }

  Widget _progressBarLine(
    BuildContext context,
    double progress,
    Color color, {
    ValueChanged<double>? onSeek,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: onSeek != null
              ? (details) {
                  final box = context.findRenderObject() as RenderBox;
                  final localPos = box.globalToLocal(details.globalPosition);
                  final p = (localPos.dx / box.size.width).clamp(0.0, 1.0);
                  onSeek(p);
                }
              : null,
          onTapDown: onSeek != null
              ? (details) {
                  final box = context.findRenderObject() as RenderBox;
                  final p = (details.localPosition.dx / box.size.width).clamp(
                    0.0,
                    1.0,
                  );
                  onSeek(p);
                }
              : null,
          child: Container(
            width: double.infinity,
            height: 6, // Smaller hit area to avoid overlapping content
            color: Colors.transparent,
            alignment: Alignment.topCenter,
            child: Container(
              width: double.infinity,
              height: 2,
              color: Theme.of(context).dividerColor.withValues(alpha: 0.05),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: constraints.maxWidth * progress,
                  height: 2,
                  decoration: BoxDecoration(
                    color: color,
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.5),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
