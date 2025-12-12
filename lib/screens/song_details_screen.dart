import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/radio_provider.dart';

import 'artist_details_screen.dart';

class SongDetailsScreen extends StatelessWidget {
  const SongDetailsScreen({super.key});

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
              errorBuilder: (_, __, ___) => Container(color: Colors.black),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Header (Close Button)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 8.0,
                  ),
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
                          station.name,
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
                ),

                const Spacer(),

                // Album Art / Centerpiece
                Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Hero(
                    tag: 'player_image',
                    child: Container(
                      width: 280,
                      height: 280,
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

                const SizedBox(height: 32),

                // Info Section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    children: [
                      Text(
                        provider.currentTrack.isNotEmpty
                            ? provider.currentTrack
                            : "Live Broadcast",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
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
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 18,
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
                        const SizedBox(height: 4),
                        Text(
                          provider.currentAlbum,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // Actions (Spotify / YouTube)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (provider.currentSpotifyUrl != null) ...[
                      _ExternalLinkButton(
                        icon: FontAwesomeIcons.apple,
                        color: Colors.pinkAccent,
                        url:
                            "https://music.apple.com/us/search?term=${Uri.encodeComponent("${provider.currentTrack} ${provider.currentArtist}")}",
                        label: 'Music',
                      ),
                      const SizedBox(width: 24),
                    ],
                    if (provider.currentSpotifyUrl != null)
                      _ExternalLinkButton(
                        icon: FontAwesomeIcons.spotify,
                        color: Colors.green,
                        url: provider.currentSpotifyUrl!,
                        label: 'Spotify',
                      ),
                    if (provider.currentSpotifyUrl != null &&
                        provider.currentYoutubeUrl != null)
                      const SizedBox(width: 24),
                    if (provider.currentYoutubeUrl != null)
                      _ExternalLinkButton(
                        icon: FontAwesomeIcons.youtube,
                        color: Colors.red,
                        url: provider.currentYoutubeUrl!,
                        label: 'YouTube',
                      ),
                  ],
                ),

                const Spacer(flex: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExternalLinkButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String url;
  final String label;

  const _ExternalLinkButton({
    required this.icon,
    required this.color,
    required this.url,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IconButton(
          icon: FaIcon(icon),
          color: Colors.white.withValues(alpha: 0.9),
          iconSize: 20,
          style: IconButton.styleFrom(
            backgroundColor: color.withValues(alpha: 0.15),
            padding: const EdgeInsets.all(10),
            highlightColor: color.withValues(alpha: 0.3),
          ),
          onPressed: () => launchUrl(Uri.parse(url)),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }
}
