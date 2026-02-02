import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../providers/radio_provider.dart';
import 'package:audio_service/audio_service.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../utils/icon_library.dart';

import '../screens/song_details_screen.dart';
import '../screens/artist_details_screen.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
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

    return Container(
      height: 72,
      decoration: BoxDecoration(
        color: cardColor.withValues(alpha: 0.50),
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
      ),
      padding: EdgeInsets.zero,
      child: Theme(
        data: playerTheme,
        child: Column(
          children: [
            // Top Section: Info + Controls + Volume
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isDesktop ? 24 : 16),
                child: Row(
                  children: [
                    // Track Info - Flexible width
                    Expanded(
                      flex: isDesktop ? 3 : 1,
                      child: station != null
                          ? Row(
                              mainAxisSize: MainAxisSize.min, // shrink wrap
                              children: [
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () {
                                      Navigator.of(context).push(
                                        PageRouteBuilder(
                                          pageBuilder:
                                              (
                                                context,
                                                animation,
                                                secondaryAnimation,
                                              ) => const SongDetailsScreen(),
                                          transitionsBuilder:
                                              (
                                                context,
                                                animation,
                                                secondaryAnimation,
                                                child,
                                              ) {
                                                const begin = Offset(0.0, 1.0);
                                                const end = Offset.zero;
                                                const curve =
                                                    Curves.easeOutQuart;
                                                var tween =
                                                    Tween(
                                                      begin: begin,
                                                      end: end,
                                                    ).chain(
                                                      CurveTween(curve: curve),
                                                    );
                                                return SlideTransition(
                                                  position: animation.drive(
                                                    tween,
                                                  ),
                                                  child: child,
                                                );
                                              },
                                        ),
                                      );
                                    },
                                    child: Hero(
                                      tag: 'player_image',
                                      child: Stack(
                                        children: [
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: Container(
                                              width: isDesktop ? 50 : 42,
                                              height: isDesktop ? 50 : 42,
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
                                                                station.icon,
                                                              ),
                                                              color: Color(
                                                                int.parse(
                                                                  station.color,
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
                                              provider.currentStation?.genre ==
                                                  "Local Device" ||
                                              provider.currentStation?.icon ==
                                                  "smartphone")
                                            Positioned(
                                              bottom: 2,
                                              right: 2,
                                              child: Container(
                                                padding: const EdgeInsets.all(
                                                  2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.8),
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
                                                            .check_circle_rounded
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
                                              Icons.signal_wifi_bad_rounded,
                                              color: Colors.redAccent,
                                              size: 20,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                provider.errorMessage!,
                                                style: const TextStyle(
                                                  color: Colors.redAccent,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        )
                                      : provider.currentTrack !=
                                                "Live Broadcast" &&
                                            provider.currentTrack.isNotEmpty
                                      ? Row(
                                          children: [
                                            Expanded(
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.translucent,
                                                child: Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Flexible(
                                                          child: Text(
                                                            provider
                                                                .currentTrack
                                                                .replaceFirst(
                                                                  "✅ ",
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
                                                              fontSize: 16,
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
                                                    const SizedBox(height: 4),
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
                                                              : "Unknown Artist",
                                                          style: TextStyle(
                                                            color: isLinkEnabled
                                                                ? Theme.of(
                                                                    context,
                                                                  ).primaryColor
                                                                : playerTheme
                                                                      .textTheme
                                                                      .bodySmall
                                                                      ?.color,
                                                            fontSize: 13,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
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
                                                                    builder: (context) => ArtistDetailsScreen(
                                                                      artistName:
                                                                          provider
                                                                              .currentArtist,
                                                                      artistImage:
                                                                          provider
                                                                              .currentArtistImage,
                                                                      genre: station
                                                                          .genre,
                                                                    ),
                                                                  ),
                                                                );
                                                              },
                                                              child: artistText,
                                                            ),
                                                          );
                                                        } else {
                                                          return artistText;
                                                        }
                                                      },
                                                    ),
                                                    Builder(
                                                      builder: (context) {
                                                        String albumText =
                                                            provider
                                                                .currentAlbum;
                                                        final stationName =
                                                            station.name;

                                                        if (stationName
                                                                .isNotEmpty &&
                                                            albumText.contains(
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
                                                          return Column(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                              const SizedBox(
                                                                height: 2,
                                                              ),
                                                              Text(
                                                                albumText,
                                                                style: TextStyle(
                                                                  color: playerTheme
                                                                      .textTheme
                                                                      .bodySmall
                                                                      ?.color
                                                                      ?.withValues(
                                                                        alpha:
                                                                            0.5,
                                                                      ),
                                                                  fontSize: 11,
                                                                ),
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                            ],
                                                          );
                                                        }
                                                        return const SizedBox.shrink();
                                                      },
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : Text(
                                          "Live Broadcast",
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
                                "Select a station",
                                style: TextStyle(
                                  color:
                                      playerTheme.textTheme.bodyMedium?.color,
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
                            child: _buildControls(context, provider, isDesktop),
                          )
                        : _buildControls(context, provider, isDesktop),

                    // Volume (Right Side) - Only show on Desktop
                    if (isDesktop)
                      Expanded(
                        flex: 2,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            const SizedBox(width: 32),
                            SizedBox(
                              width: 120,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.volume_up_rounded,
                                    size: 20,
                                    color: playerTheme.iconTheme.color
                                        ?.withValues(alpha: 0.5),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 0,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                              overlayRadius: 10,
                                            ),
                                        trackHeight: 2,
                                      ),
                                      child: Slider(
                                        value: provider.volume,
                                        onChanged: (val) =>
                                            provider.setVolume(val),
                                        activeColor: Theme.of(
                                          context,
                                        ).primaryColor,
                                        inactiveColor: Theme.of(
                                          context,
                                        ).dividerColor.withValues(alpha: 0.2),
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

            // Bottom Progress Bar (Full Width)
            if (provider.hiddenAudioController != null)
              _buildYoutubeProgressBar(context, provider.hiddenAudioController!)
            else if (provider.isRecognizing &&
                provider.currentPlayingPlaylistId == null)
              _buildRadioProgressBar(context, provider)
            else if (provider.currentPlayingPlaylistId != null)
              _buildNativeProgressBar(context, provider),
          ],
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

  Widget _buildYoutubeProgressBar(
    BuildContext context,
    YoutubePlayerController controller,
  ) {
    return Container(
      width: double.infinity,
      height: 18, // Reduced height
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      child: ValueListenableBuilder(
        valueListenable: controller,
        builder: (context, value, child) {
          final position = value.position.inSeconds.toDouble();
          final duration = value.metaData.duration.inSeconds.toDouble();
          final max = duration > 0 ? duration : 100.0;
          final val = position.clamp(0.0, max);

          return Row(
            children: [
              Text(
                _formatDuration(value.position),
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    trackShape: const RectangularSliderTrackShape(),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 0,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: Theme.of(context).primaryColor,
                    inactiveTrackColor: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.3), // Lighter
                    thumbColor: Theme.of(context).primaryColor,
                    overlayColor: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    value: val,
                    min: 0.0,
                    max: max,
                    onChanged: (v) {
                      controller.seekTo(Duration(seconds: v.toInt()));
                    },
                  ),
                ),
              ),
              Text(
                _formatDuration(value.metaData.duration),
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildNativeProgressBar(BuildContext context, RadioProvider provider) {
    // STANDARD LOGIC: Use AudioService.position for live position updates
    return StreamBuilder<Duration>(
      stream: AudioService.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final totalDuration =
            provider.audioHandler.mediaItem.value?.duration ?? Duration.zero;

        // Clamp values
        final positionSec = position.inSeconds.toDouble();
        final durationSec = totalDuration.inSeconds.toDouble();

        final max = durationSec > 0 ? durationSec : 1.0;
        final val = positionSec > max ? max : positionSec.clamp(0.0, max);

        return Container(
          width: double.infinity,
          height: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Row(
            children: [
              Text(
                _formatDuration(
                  Duration(seconds: val.toInt()),
                ), // Display clamped
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    trackShape: const RectangularSliderTrackShape(),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 0,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: Theme.of(context).primaryColor,
                    inactiveTrackColor: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.3),
                    thumbColor: Theme.of(context).primaryColor,
                    overlayColor: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    value: val,
                    min: 0.0,
                    max: max,
                    onChanged: (v) {
                      provider.audioHandler.seek(Duration(seconds: v.toInt()));
                    },
                  ),
                ),
              ),
              Text(
                _formatDuration(totalDuration),
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRadioProgressBar(BuildContext context, RadioProvider provider) {
    if (!provider.isRecognizing) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 0),
      alignment: Alignment.bottomCenter,
      child: const LinearProgressIndicator(
        minHeight: 1,
        backgroundColor: Colors.transparent,
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${duration.inHours}:$minutes:$seconds";
    }
    return "${duration.inMinutes}:$seconds";
  }

  Widget _buildControls(
    BuildContext context,
    RadioProvider provider,
    bool isDesktop,
  ) {
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
            tooltip: "Shuffle",
            onPressed: () => provider.toggleShuffle(),
          ),
          const SizedBox(width: 4),
        ],

        // Add to Genre Playlist Button (Radio Only)
        // Moved to the left of controls
        if (provider.currentPlayingPlaylistId == null &&
            provider.currentTrack.isNotEmpty &&
            provider.currentTrack != "Live Broadcast" &&
            provider.currentTrack != "Unknown Title" &&
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
                ? "Already saved"
                : "Add to Genre Playlist",
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
                            content: Text("Added to $genre Playlist"),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Could not identify song to save."),
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
        SizedBox(width: isDesktop ? 24 : 12),
        Container(
          width: isDesktop ? 50 : 42,
          height: isDesktop ? 50 : 42,
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.4),
                blurRadius: 10,
              ),
            ],
          ),
          child: IconButton(
            icon: provider.isLoading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Theme.of(context).colorScheme.onPrimary,
                      strokeWidth: 2.5,
                    ),
                  )
                : Icon(
                    provider.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
            color: Theme.of(context).colorScheme.onPrimary,
            iconSize: isDesktop ? 32 : 28,
            onPressed: () => provider.togglePlay(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.skip_next_rounded),
          color: Theme.of(context).iconTheme.color,
          iconSize: isDesktop ? 32 : 28,
          onPressed: () => provider.playNext(),
        ),
      ],
    );
  }
}
