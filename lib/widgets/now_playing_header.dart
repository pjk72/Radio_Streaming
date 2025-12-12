import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../utils/icon_library.dart';

import '../providers/radio_provider.dart';
import '../screens/artist_details_screen.dart';

class NowPlayingHeader extends StatelessWidget {
  const NowPlayingHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final station = provider.currentStation;
    final String? imageUrl = station != null
        ? (provider.currentArtistImage ??
              provider.currentAlbumArt ??
              station.logo)
        : null;
    final bool hasEnrichedImage =
        (provider.currentArtistImage ?? provider.currentAlbumArt) != null;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 180),
      margin: const EdgeInsets.only(bottom: 32),
      decoration: BoxDecoration(
        color: const Color(0xFF2d3436).withValues(alpha: 0.3), // Darker glass
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
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
                    color: Colors.black.withValues(alpha: 0.4),
                    colorBlendMode: BlendMode.darken,
                  ),
                ),
              ),

            // 2. Right-Aligned Image with Fade (blends into background)
            if (imageUrl != null && hasEnrichedImage)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FractionallySizedBox(
                    widthFactor: 0.5, // Occupy right 50%
                    heightFactor: 1.0,
                    child: ShaderMask(
                      shaderCallback: (rect) {
                        return const LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          stops: [0.0, 0.3], // Fade in first 30% of the image
                          colors: [Colors.transparent, Colors.white],
                        ).createShader(rect);
                      },
                      blendMode: BlendMode.dstIn,
                      child: _buildImage(
                        imageUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                      ),
                    ),
                  ),
                ),
              ),

            // Gradient Overlay for readability
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
                          : const Color(
                              0xFF6c5ce7,
                            ).withValues(alpha: 0.2), // Default purplish tint
                      Colors.black.withValues(alpha: 0.3),
                    ],
                  ),
                ),
              ),
            ),

            // Content
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (station == null) ...[
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.radio,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          "Discover Radio",
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      "Tune in to the world's best stations.",
                      style: TextStyle(fontSize: 16, color: Colors.white70),
                    ),
                  ] else ...[
                    // External Links (Moved from PlayerBar)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Theme.of(
                                  context,
                                ).primaryColor.withValues(alpha: 0.4),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.play_arrow,
                                size: 14,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                "NOW PLAYING",
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.5,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // External Links (Top Right)
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Check if we have valid artist info to highlight
                    if (provider.currentArtist.isNotEmpty &&
                        provider.currentArtist != "Unknown Artist" &&
                        provider.currentTrack != "Live Broadcast") ...[
                      // ARTIST HIGHLIGHT MODE
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => ArtistDetailsScreen(
                                  artistName: provider.currentArtist,
                                  artistImage: provider.currentArtistImage,
                                  genre: station.genre,
                                ),
                              ),
                            );
                          },
                          child: Text(
                            provider.currentArtist.toUpperCase(),
                            style: TextStyle(
                              fontSize: 48,
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
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text.rich(
                        TextSpan(
                          text: provider.currentTrack,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w300,
                            color: Colors.white,
                          ),
                          children: [
                            if (provider.currentReleaseDate != null &&
                                provider.currentReleaseDate!.length >= 4)
                              TextSpan(
                                text:
                                    "   ${provider.currentReleaseDate!.substring(0, 4)}",
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.white38,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(Icons.radio, size: 14, color: Colors.white60),
                          const SizedBox(width: 8),
                          Text(
                            "ON ${station.name.toUpperCase()}",
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white60,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const Spacer(),
                          if (provider.currentSpotifyUrl != null) ...[
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
                            if (provider.currentYoutubeUrl != null) ...[
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
                      Text(
                        station.name,
                        style: const TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.0,
                          color: Colors.white,
                          height: 1.0,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          FaIcon(
                            IconLibrary.getIcon(station.icon),
                            size: 16,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            station.genre,
                            style: const TextStyle(
                              fontSize: 18,
                              color: Colors.white70,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
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
