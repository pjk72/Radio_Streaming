import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/radio_provider.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../utils/icon_library.dart';
import 'package:url_launcher/url_launcher.dart';
import '../screens/song_details_screen.dart';
import '../screens/artist_details_screen.dart';

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
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 24 : 16),
      child: Row(
        children: [
          // Track Info
          Expanded(
            child: station != null
                ? Row(
                    children: [
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              PageRouteBuilder(
                                pageBuilder:
                                    (context, animation, secondaryAnimation) =>
                                        const SongDetailsScreen(),
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
                                        position: animation.drive(tween),
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
                                            (context, error, stackTrace) {
                                              return FaIcon(
                                                IconLibrary.getIcon(
                                                  station.icon,
                                                ),
                                                color: Color(
                                                  int.parse(station.color),
                                                ),
                                                size: 24,
                                              );
                                            },
                                      )
                                    : FaIcon(
                                        IconLibrary.getIcon(station.icon),
                                        color: Color(int.parse(station.color)),
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
                            : provider.currentTrack != "Live Broadcast" &&
                                  provider.currentTrack.isNotEmpty
                            ? Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          provider.currentTrack,
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).primaryColor,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        MouseRegion(
                                          cursor:
                                              provider.currentArtist.isNotEmpty
                                              ? SystemMouseCursors.click
                                              : SystemMouseCursors.basic,
                                          child: GestureDetector(
                                            onTap: () {
                                              if (provider
                                                  .currentArtist
                                                  .isNotEmpty) {
                                                Navigator.of(context).push(
                                                  MaterialPageRoute(
                                                    builder: (context) =>
                                                        ArtistDetailsScreen(
                                                          artistName: provider
                                                              .currentArtist,
                                                          artistImage: provider
                                                              .currentArtistImage,
                                                          genre: station.genre,
                                                        ),
                                                  ),
                                                );
                                              }
                                            },
                                            child: Text(
                                              provider.currentArtist.isNotEmpty
                                                  ? provider.currentArtist
                                                  : "Unknown Artist",
                                              style: TextStyle(
                                                color: Color(
                                                  int.parse(station.color),
                                                ),
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                        if (provider.currentAlbum.isNotEmpty)
                                          Text(
                                            provider.currentAlbum,
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.5,
                                              ),
                                              fontSize: 10,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onLongPress: () =>
                                        _showExternalLinks(context, provider),
                                    child: IconButton(
                                      onPressed: () async {
                                        if (context.mounted) {
                                          final playlistName = await provider
                                              .addToPlaylist(null);
                                          if (context.mounted &&
                                              playlistName != null) {
                                            _showSavedSnackBar(
                                              context,
                                              playlistName,
                                            );
                                          }
                                        }
                                      },
                                      icon: provider.isCurrentSongSaved
                                          ? const Icon(
                                              Icons.favorite_rounded,
                                              color: Colors.redAccent,
                                            )
                                          : const Icon(
                                              Icons.favorite_border_rounded,
                                              size: 24,
                                            ),
                                      color: provider.isCurrentSongSaved
                                          ? Colors.redAccent
                                          : Colors.white54,
                                      tooltip: provider.isCurrentSongSaved
                                          ? "Saved"
                                          : "Add to Favorites (Hold for options)",
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    station.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (isDesktop || station.name.length < 20)
                                    Text(
                                      station.genre,
                                      style: TextStyle(
                                        color: Colors.grey[400],
                                        fontSize: 12,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                      ),
                    ],
                  )
                : const Text(
                    "Select a station",
                    style: TextStyle(color: Colors.white70),
                  ),
          ),

          // Controls
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                      color: Theme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.4),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: IconButton(
                  icon: Icon(
                    provider.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  color: Colors.white,
                  iconSize: isDesktop ? 32 : 28,
                  onPressed: () => provider.togglePlay(),
                ),
              ),
              SizedBox(width: isDesktop ? 24 : 12),
              IconButton(
                icon: const Icon(Icons.skip_next_rounded),
                color: Colors.white,
                iconSize: isDesktop ? 32 : 28,
                onPressed: () => provider.playNext(),
              ),
            ],
          ),

          // Volume (Desktop only)
          if (isDesktop) ...[
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
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                        trackHeight: 2,
                      ),
                      child: Slider(
                        value: provider.volume,
                        onChanged: (val) => provider.setVolume(val),
                        activeColor: Theme.of(context).primaryColor,
                        inactiveColor: Colors.white12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showExternalLinks(BuildContext context, RadioProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF13131f),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: SingleChildScrollView(
            // Prevent overflow
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Options",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    fontFamily: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.fontFamily,
                  ),
                ),
                const SizedBox(height: 20),

                // Add to Playlist
                Material(
                  color: Theme.of(context).primaryColor,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () async {
                      final playlistName = await provider.addToPlaylist(null);
                      if (context.mounted) {
                        Navigator.pop(context);
                        if (playlistName != null) {
                          _showSavedSnackBar(context, playlistName);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Cannot save: No song identified yet.",
                              ),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(
                            Icons.playlist_add_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                          SizedBox(width: 12),
                          Text(
                            "Save to Playlist",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                Divider(color: Colors.white.withValues(alpha: 0.1)),
                const SizedBox(height: 10),

                Text(
                  "Open in...",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),

                // Spotify
                _buildServiceTile(
                  context,
                  "Spotify",
                  FontAwesomeIcons.spotify,
                  const Color(0xFF1DB954),
                  provider.currentSpotifyUrl,
                ),

                const SizedBox(height: 12),

                // YouTube
                _buildServiceTile(
                  context,
                  "YouTube",
                  FontAwesomeIcons.youtube,
                  const Color(0xFFFF0000),
                  provider.currentYoutubeUrl,
                ),

                const SizedBox(height: 12),

                // Apple Music (Search Fallback)
                _buildServiceTile(
                  context,
                  "Apple Music",
                  FontAwesomeIcons.apple,
                  Colors.white,
                  "https://music.apple.com/search?term=${Uri.encodeComponent("${provider.currentTrack} ${provider.currentArtist}")}",
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildServiceTile(
    BuildContext context,
    String name,
    IconData icon,
    Color color,
    String? url,
  ) {
    final bool isEnabled = url != null && url.isNotEmpty;
    return Opacity(
      opacity: isEnabled ? 1.0 : 0.5,
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: isEnabled
              ? () async {
                  try {
                    final uri = Uri.parse(url);
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Could not launch $name: $e")),
                      );
                    }
                  }
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              children: [
                FaIcon(icon, color: color, size: 28),
                const SizedBox(width: 16),
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.white24,
                  size: 16,
                ),
              ],
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
      return Image.asset(url, fit: fit, errorBuilder: errorBuilder);
    } else {
      return Image.network(url, fit: fit, errorBuilder: errorBuilder);
    }
  }

  void _showSavedSnackBar(BuildContext context, String playlistName) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1a4d2e), // Dark Green
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
        dismissDirection: DismissDirection.horizontal,
        elevation: 12,
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_rounded,
                color: Colors.greenAccent,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "SAVED",
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      color: Colors.greenAccent,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    playlistName.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
