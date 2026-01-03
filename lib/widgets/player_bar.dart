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

    return Container(
      height: 90,
      decoration: BoxDecoration(
        color: const Color(
          0xFF13131f,
        ).withValues(alpha: 0.95), // Slightly more opaque
        border: const Border(top: BorderSide(color: Colors.white12, width: 1)),
      ),
      padding: EdgeInsets
          .zero, // Remove padding from container to allow edge-to-edge progress bar
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
                                              const curve = Curves.easeOutQuart;
                                              var tween = Tween(
                                                begin: begin,
                                                end: end,
                                              ).chain(CurveTween(curve: curve));
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
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
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
                                                  int.parse(station.color),
                                                ),
                                                size: 24,
                                              ),
                                      ),
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
                                                          provider.currentTrack,
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Builder(
                                                    builder: (context) {
                                                      final bool isLinkEnabled =
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
                                                              : Colors.white70,
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
                                                  if (provider
                                                          .currentAlbum
                                                          .isNotEmpty &&
                                                      provider.currentAlbum !=
                                                          "Playlist") ...[
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      provider.currentAlbum,
                                                      style: TextStyle(
                                                        color: Colors.white
                                                            .withValues(
                                                              alpha: 0.5,
                                                            ),
                                                        fontSize: 11,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      )
                                    : const Text(
                                        "Select a station",
                                        style: TextStyle(color: Colors.white70),
                                      ),
                              ),
                            ],
                          )
                        : const Center(
                            child: Text(
                              "Select a station",
                              style: TextStyle(color: Colors.white70),
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
                                const Icon(
                                  Icons.volume_up_rounded,
                                  size: 20,
                                  color: Colors.grey,
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
                                      inactiveColor: Colors.white12,
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
      height: 24, // Increased height for touch targets
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
                style: const TextStyle(
                  color: Colors.white70,
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
                    activeTrackColor: Colors.redAccent,
                    inactiveTrackColor: Colors.white38, // Lighter
                    thumbColor: Colors.redAccent,
                    overlayColor: Colors.redAccent.withValues(alpha: 0.2),
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
                style: const TextStyle(
                  color: Colors.white70,
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
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Row(
            children: [
              Text(
                _formatDuration(
                  Duration(seconds: val.toInt()),
                ), // Display clamped
                style: const TextStyle(
                  color: Colors.white70,
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
                    activeTrackColor: Colors.redAccent,
                    inactiveTrackColor: Colors.white38,
                    thumbColor: Colors.redAccent,
                    overlayColor: Colors.redAccent.withValues(alpha: 0.2),
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
                style: const TextStyle(
                  color: Colors.white70,
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
              Icons.shuffle_rounded,
              color: provider.isShuffleMode ? Colors.redAccent : Colors.grey,
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
                : Colors.white54,
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
          color: Colors.white,
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
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.5,
                    ),
                  )
                : Icon(
                    provider.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
            color: Colors.white,
            iconSize: isDesktop ? 32 : 28,
            onPressed: () => provider.togglePlay(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.skip_next_rounded),
          color: Colors.white,
          iconSize: isDesktop ? 32 : 28,
          onPressed: () => provider.playNext(),
        ),
      ],
    );
  }
}
