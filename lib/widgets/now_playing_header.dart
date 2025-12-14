import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../utils/icon_library.dart';

import '../providers/radio_provider.dart';
import '../screens/artist_details_screen.dart';
import 'mini_visualizer.dart';
import 'pulsing_indicator.dart';

class NowPlayingHeader extends StatelessWidget {
  final double height;
  final double minHeight;
  final double maxHeight;
  final double topPadding;

  const NowPlayingHeader({
    super.key,
    required this.height,
    this.minHeight = 110,
    this.maxHeight = 200,
    this.topPadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    // Calculate scale factor (0.0 to 1.0)
    // t goes from 0.0 (at minHeight) to 1.0 (at maxHeight)
    // Adjust range to account for the fact that minHeight and maxHeight MIGHT include topPadding
    // But height passes the actual height.
    final double range = maxHeight - minHeight;
    final double t = range > 0
        ? ((height - minHeight) / range).clamp(0.0, 1.0)
        : 1.0;

    final provider = Provider.of<RadioProvider>(context);
    final station = provider.currentStation;
    final String? imageUrl = station != null
        ? (provider.currentArtistImage ??
              provider.currentAlbumArt ??
              station.logo)
        : null;
    final bool hasEnrichedImage =
        (provider.currentArtistImage ?? provider.currentAlbumArt) != null;

    final double titleSize = 18.0 + (18.0 * t); // 18 to 36
    final double trackSize = 12.0 + (8.0 * t); // 12 to 20
    final double stationSize = 18.0 + (18.0 * t); // 18 to 36

    // Animate border radius to 0 when nearing collapsed state
    final double borderRadius = 24.0 * t;

    // Interpolate top padding:
    // When t=1 (Expanded): padding is standard (16.0).
    // When t=0 (Collapsed): padding is standard + safeArea (16.0 + topPadding).
    // Adding extra buffer to be safe.
    final double dynamicTopPadding =
        (16.0 * t) + ((topPadding + 35.0) * (1.0 - t));

    return Stack(
      children: [
        MouseRegion(
          cursor:
              (station != null &&
                  provider.currentArtist.isNotEmpty &&
                  provider.currentArtist != "Unknown Artist" &&
                  provider.currentTrack != "Live Broadcast")
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: () {
              if (station != null &&
                  provider.currentArtist.isNotEmpty &&
                  provider.currentArtist != "Unknown Artist" &&
                  provider.currentTrack != "Live Broadcast") {
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
            },
            child: Container(
              width: double.infinity,
              height: height,
              margin: EdgeInsets.only(
                bottom: 24.0 * t,
                left: 20.0 * t,
                right: 20.0 * t,
              ),
              decoration: BoxDecoration(
                // Increase opacity when collapsed (t -> 0) to prevent background content mix
                // Increase opacity when collapsed (t -> 0) to prevent background content mix
                color: Theme.of(context).scaffoldBackgroundColor.withValues(
                  alpha: 0.3 + (0.65 * (1.0 - t)),
                ),
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(
                  color: Colors.white.withValues(
                    alpha: 0.1 * t,
                  ), // Fade border too
                ),
                boxShadow: [
                  if (t > 0.1) // Remove shadow when collapsed flat
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(borderRadius),
                child: Stack(
                  children: [
                    // 1. Blurred Background
                    if (imageUrl != null)
                      Positioned.fill(
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                          child: _buildImage(
                            imageUrl,
                            fit: BoxFit.cover,
                            color: Colors.black.withValues(
                              alpha: 0.4 + (0.4 * (1.0 - t)),
                            ), // Darker when collapsed
                            colorBlendMode: BlendMode.darken,
                          ),
                        ),
                      ),

                    // 2. Right-Aligned Image with Fade (blends into background)
                    // Resize logic: width factor reduces as t -> 0
                    if (imageUrl != null && hasEnrichedImage)
                      Positioned(
                        top:
                            topPadding *
                            (1.0 -
                                t), // Slide down to respect safe area when collapsed
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: FractionallySizedBox(
                            widthFactor: 0.75, // Even wider (75%)
                            heightFactor: 1.0,
                            child: ShaderMask(
                              shaderCallback: (rect) {
                                return const LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  stops: [0.0, 0.7], // Soft blend
                                  colors: [Colors.transparent, Colors.white],
                                ).createShader(rect);
                              },
                              blendMode: BlendMode.dstIn,
                              child: _buildImage(
                                imageUrl,
                                fit: BoxFit.cover,
                                alignment: Alignment.topCenter, // Focus on face
                              ),
                            ),
                          ),
                        ),
                      ),

                    // Gradient Overlay for readability
                    if (t > 0.1)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomLeft,
                              end: Alignment.topRight,
                              colors: [
                                station != null
                                    ? Color(
                                        int.parse(station.color),
                                      ).withValues(alpha: 0.4)
                                    : const Color(0xFF6c5ce7).withValues(
                                        alpha: 0.2,
                                      ), // Default purplish tint
                                Colors.black.withValues(alpha: 0.3),
                              ],
                            ),
                          ),
                        ),
                      ),

                    // Content
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: 24.0,
                          right: 24.0,
                          bottom: 2.0,
                          top: dynamicTopPadding,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: t < 0.3
                              ? MainAxisAlignment
                                    .start // Align to top when collapsed to ignore extra bottom space
                              : MainAxisAlignment.end,
                          children: [
                            if (station == null) ...[
                              // ... existing default view ...
                              const Spacer(),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.1,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.radio,
                                      color: Colors.white,
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Text(
                                    "Discover Radio",
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                  ),
                                ],
                              ),
                              if (t > 0.2) ...[
                                const SizedBox(height: 8),
                                const Text(
                                  "Tune in to the world's best stations.",
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
                            ] else ...[
                              // Check if we have valid artist info to highlight
                              if (provider.currentArtist.isNotEmpty &&
                                  provider.currentArtist != "Unknown Artist" &&
                                  provider.currentTrack !=
                                      "Live Broadcast") ...[
                                if (t > 0.3) const Spacer(),

                                // ARTIST HIGHLIGHT MODE
                                Text(
                                  provider.currentArtist.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: titleSize,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -1.0,
                                    color: Color(int.parse(station.color)),
                                    height: 1.0,
                                    shadows: const [
                                      Shadow(
                                        blurRadius: 15.0,
                                        color: Colors.black,
                                        offset: Offset(2, 2),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: (4.0 * t)),
                                Text.rich(
                                  TextSpan(
                                    text: provider.currentTrack,
                                    style: TextStyle(
                                      fontSize: trackSize,
                                      fontWeight: FontWeight.w300,
                                      color: Colors.white,
                                    ),
                                    children: [
                                      if (provider.currentReleaseDate != null &&
                                          provider.currentReleaseDate!.length >=
                                              4)
                                        TextSpan(
                                          text:
                                              "   ${provider.currentReleaseDate!.substring(0, 4)}",
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Colors.white38,
                                            fontWeight: FontWeight.normal,
                                          ),
                                        ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),

                                // Hide secondary info when very collapsed to save space
                                if (t > 0.3) ...[
                                  const Spacer(),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.radio,
                                        size: 12.0,
                                        color: Colors.white60,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        "ON ${station.name.toUpperCase()}",
                                        style: const TextStyle(
                                          fontSize: 12.0,
                                          color: Colors.white60,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1.0,
                                        ),
                                      ),
                                    ],
                                  ),
                                ] else ...[
                                  // When collapsed, just use a small spacer so content is centered vertically
                                  const SizedBox(height: 8),
                                ],

                                if (t >
                                    0.1) // Keep NOW PLAYING tag mostly visible but tighter layout
                                  SizedBox(height: 2.0 * t),

                                Row(
                                  children: [
                                    AnimatedOpacity(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      opacity: provider.isPlaying ? 1.0 : 0.0,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            provider.isRecognizing
                                                ? const Padding(
                                                    padding: EdgeInsets.only(
                                                      right: 4,
                                                    ),
                                                    child: PulsingIndicator(
                                                      color: Colors.white70,
                                                      size: 10,
                                                    ),
                                                  )
                                                : const Padding(
                                                    padding: EdgeInsets.only(
                                                      right: 4,
                                                    ),
                                                    child: MiniVisualizer(
                                                      color: Colors.white70,
                                                    ),
                                                  ),
                                            const Text(
                                              "NOW PLAYING",
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 0.5,
                                                color: Colors.white70,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    if (t > 0.5) // Hide icons when too small
                                      if (provider.currentSpotifyUrl !=
                                          null) ...[
                                        _HeaderIconButton(
                                          icon: FontAwesomeIcons.apple,
                                          color: Colors.white,
                                          url:
                                              "https://music.apple.com/us/search?term=${Uri.encodeComponent("${provider.currentTrack} ${provider.currentArtist}")}",
                                          tooltip: "Apple Music",
                                        ),
                                        const SizedBox(width: 12),
                                        _HeaderIconButton(
                                          icon: FontAwesomeIcons.spotify,
                                          color: Colors.white,
                                          url: provider.currentSpotifyUrl!,
                                          tooltip: "Spotify",
                                        ),
                                        if (provider.currentYoutubeUrl !=
                                            null) ...[
                                          const SizedBox(width: 12),
                                          _HeaderIconButton(
                                            icon: FontAwesomeIcons.youtube,
                                            color: Colors.white,
                                            url: provider.currentYoutubeUrl!,
                                            tooltip: "YouTube",
                                          ),
                                        ],
                                      ],
                                  ],
                                ),
                              ] else ...[
                                // STATION DEFAULT MODE
                                const Spacer(),
                                Text(
                                  station.name,
                                  style: TextStyle(
                                    fontSize: stationSize,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -1.0,
                                    color: Colors.white,
                                    height: 1.0,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                // Hide genre when very collapsed to save space or scale it down
                                if (t > 0.1) ...[
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      FaIcon(
                                        IconLibrary.getIcon(station.icon),
                                        size: trackSize, // Scale icon
                                        color: Colors.white70,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        station.genre,
                                        style: TextStyle(
                                          fontSize: trackSize, // Scale text
                                          color: Colors.white70,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ] else
                                  const SizedBox(height: 4),
                                SizedBox(height: 4.0 + (2.0 * t)),
                                AnimatedOpacity(
                                  duration: const Duration(milliseconds: 300),
                                  opacity: provider.isPlaying ? 1.0 : 0.0,
                                  child: Container(
                                    height:
                                        32, // Match height of icon row in artist mode roughly
                                    alignment: Alignment.centerLeft,
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.1,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              provider.isRecognizing
                                                  ? const Padding(
                                                      padding: EdgeInsets.only(
                                                        right: 4,
                                                      ),
                                                      child: PulsingIndicator(
                                                        color: Colors.white70,
                                                        size: 10,
                                                      ),
                                                    )
                                                  : const Padding(
                                                      padding: EdgeInsets.only(
                                                        right: 4,
                                                      ),
                                                      child: MiniVisualizer(
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                              const Text(
                                                "NOW PLAYING",
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                  letterSpacing: 0.5,
                                                  color: Colors.white70,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Upper Status Bar Gradient (Already exists, preserving it)
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: topPadding + 100.0,
          child: Opacity(
            // Fade in earlier and stay opaque longer
            opacity: ((0.8 - t) * 2).clamp(0.0, 1.0),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Theme.of(context).scaffoldBackgroundColor,
                      Theme.of(
                        context,
                      ).scaffoldBackgroundColor.withValues(alpha: 0.95),
                      Theme.of(
                        context,
                      ).scaffoldBackgroundColor.withValues(alpha: 0.0),
                    ],
                    stops: [
                      0.0,
                      // extend the solid part slightly below the status bar
                      topPadding > 0
                          ? ((topPadding + 10) / (topPadding + 100.0)).clamp(
                              0.0,
                              1.0,
                            )
                          : 0.3,
                      1.0,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // Bottom Gradient (Fade to Background) using the extra space
        if (t < 0.2)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 30,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color.fromARGB(
                        255,
                        30,
                        30,
                        62,
                      ).withValues(alpha: 0),
                      const Color.fromARGB(
                        255,
                        30,
                        30,
                        62,
                      ).withValues(alpha: 1),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildImage(
    String url, {
    BoxFit? fit,
    Color? color,
    BlendMode? colorBlendMode,
    Alignment? alignment,
  }) {
    if (url.startsWith('assets/')) {
      return Image.asset(
        url,
        fit: fit,
        color: color,
        colorBlendMode: colorBlendMode,
        alignment: alignment ?? Alignment.center,
      );
    } else {
      return Image.network(
        url,
        fit: fit,
        color: color,
        colorBlendMode: colorBlendMode,
        alignment: alignment ?? Alignment.center,
      );
    }
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String url;
  final String tooltip;

  const _HeaderIconButton({
    required this.icon,
    required this.color,
    required this.url,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: FaIcon(icon),
      color: Colors.white.withValues(alpha: 0.7),
      iconSize: 20,
      tooltip: tooltip,
      constraints: const BoxConstraints(),
      padding: EdgeInsets.zero,
      onPressed: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    );
  }
}

class NowPlayingHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double minHeight;
  final double maxHeight;
  final double topPadding;

  NowPlayingHeaderDelegate({
    this.minHeight = 100,
    this.maxHeight = 200,
    this.topPadding = 0.0,
  });

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Current width/height
    final double currentHeight = (maxHeight - shrinkOffset).clamp(
      minHeight,
      maxHeight,
    );

    return OverflowBox(
      minHeight: minHeight,
      maxHeight: maxHeight,
      child: Align(
        alignment: Alignment.topCenter,
        // Pass topPadding explicitly
        child: NowPlayingHeader(
          height: currentHeight,
          minHeight: minHeight,
          maxHeight: maxHeight,
          topPadding: topPadding,
        ),
      ),
    );
  }

  @override
  double get maxExtent => maxHeight;

  @override
  double get minExtent => minHeight;

  @override
  bool shouldRebuild(covariant NowPlayingHeaderDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxHeight ||
        minHeight != oldDelegate.minHeight ||
        topPadding != oldDelegate.topPadding;
  }
}
