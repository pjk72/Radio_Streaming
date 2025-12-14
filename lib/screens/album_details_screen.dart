import 'dart:convert';
import 'dart:ui';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class AlbumDetailsScreen extends StatefulWidget {
  final String albumName;
  final String artistName;
  final String? artworkUrl;

  const AlbumDetailsScreen({
    super.key,
    required this.albumName,
    required this.artistName,
    this.artworkUrl,
  });

  @override
  State<AlbumDetailsScreen> createState() => _AlbumDetailsScreenState();
}

class _AlbumDetailsScreenState extends State<AlbumDetailsScreen> {
  late Future<Map<String, dynamic>?> _albumInfoFuture;

  @override
  void initState() {
    super.initState();
    _albumInfoFuture = _fetchAlbumInfo();
    // We can't fetch tracks until we have album ID from album info,
    // or we can try to chain them.
    // Let's chain them in _fetchTracks if possible, or wait.
    // Actually, I can do both.
  }

  Future<Map<String, dynamic>?> _fetchAlbumInfo() async {
    try {
      final query = "${widget.albumName} ${widget.artistName}";
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=album&limit=1",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['resultCount'] > 0) {
          return data['results'][0];
        }
      }
    } catch (e) {
      developer.log("Error fetching album info: $e");
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _fetchTracks(int collectionId) async {
    try {
      // Add limit=200 to ensure we get all tracks for large albums/compilations
      final uri = Uri.parse(
        "https://itunes.apple.com/lookup?id=$collectionId&entity=song&limit=200",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // The first result is the collection itself, the rest are songs
        final results = List<Map<String, dynamic>>.from(data['results']);

        var tracks = results
            .where((item) => item['wrapperType'] == 'track')
            .toList();

        // Sort by Disc Number then Track Number
        tracks.sort((a, b) {
          int discA = a['discNumber'] ?? 1;
          int discB = b['discNumber'] ?? 1;
          if (discA != discB) return discA.compareTo(discB);

          int trackA = a['trackNumber'] ?? 0;
          int trackB = b['trackNumber'] ?? 0;
          return trackA.compareTo(trackB);
        });

        return tracks;
      }
    } catch (e) {
      developer.log("Error fetching tracks: $e");
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _albumInfoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final albumData = snapshot.data;

          // Fallback image if API fails
          final String displayImage =
              albumData?['artworkUrl100']?.replaceAll(
                '100x100bb',
                '600x600bb',
              ) ??
              widget.artworkUrl ??
              "";

          final String displayName =
              albumData?['collectionName'] ?? widget.albumName;
          final String displayArtist =
              albumData?['artistName'] ?? widget.artistName;
          final String? genre = albumData?['primaryGenreName'];
          final String? copyright = albumData?['copyright'];

          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. Background Image
              if (displayImage.isNotEmpty)
                Image.network(
                  displayImage,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Container(color: Colors.grey[900]),
                )
              else
                Container(color: Colors.grey[900]),

              // 2. Dark Overlay
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.6),
                      Colors.black.withValues(alpha: 0.9),
                      Colors.black,
                    ],
                  ),
                ),
              ),

              // 4. Content
              CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: MediaQuery.of(context).padding.top + 60,
                        left: 24,
                        right: 24,
                        bottom: 24,
                      ),
                      child: Column(
                        children: [
                          // Album Art Shadowed
                          Container(
                            width: 200,
                            height: 200,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 30,
                                  offset: const Offset(0, 15),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: displayImage.isNotEmpty
                                ? Image.network(displayImage, fit: BoxFit.cover)
                                : const Center(
                                    child: Icon(
                                      Icons.album,
                                      size: 80,
                                      color: Colors.white54,
                                    ),
                                  ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            displayName,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            displayArtist,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 18,
                            ),
                          ),
                          if (genre != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              genre,
                              style: TextStyle(
                                color: Theme.of(context).primaryColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          if (albumData != null &&
                              albumData['collectionViewUrl'] != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (albumData['collectionViewUrl'] !=
                                      null) ...[
                                    _SocialButton(
                                      icon: FontAwesomeIcons.apple,
                                      color: Colors.pinkAccent,
                                      url: albumData['collectionViewUrl'],
                                      label: "Apple Music",
                                    ),
                                    const SizedBox(width: 16),
                                  ],
                                  _SocialButton(
                                    icon: FontAwesomeIcons.spotify,
                                    color: Colors.green,
                                    url:
                                        "https://open.spotify.com/search/${Uri.encodeComponent("$displayName $displayArtist")}",
                                    label: "Spotify",
                                  ),
                                  const SizedBox(width: 16),
                                  _SocialButton(
                                    icon: FontAwesomeIcons.youtube,
                                    color: Colors.red,
                                    url:
                                        "https://www.youtube.com/results?search_query=${Uri.encodeComponent("$displayName $displayArtist")}",
                                    label: "YouTube",
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                  // Tracks List
                  if (albumData != null)
                    FutureBuilder<List<Map<String, dynamic>>>(
                      future: _fetchTracks(albumData['collectionId']),
                      builder: (context, trackSnap) {
                        if (trackSnap.connectionState ==
                            ConnectionState.waiting) {
                          return const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          );
                        }

                        final tracks = trackSnap.data ?? [];
                        if (tracks.isEmpty) {
                          return const SliverToBoxAdapter(
                            child: Center(
                              child: Text(
                                "No tracks available",
                                style: TextStyle(color: Colors.white54),
                              ),
                            ),
                          );
                        }

                        return SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final track = tracks[index];
                            return ListTile(
                              leading: Text(
                                "${track['trackNumber'] ?? index + 1}",
                                style: const TextStyle(color: Colors.white54),
                              ),
                              title: Text(
                                track['trackName'] ?? "Unknown Track",
                                style: const TextStyle(color: Colors.white),
                              ),
                              trailing: track['trackTimeMillis'] != null
                                  ? Text(
                                      _formatDuration(track['trackTimeMillis']),
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 12,
                                      ),
                                    )
                                  : null,
                              onTap: () {
                                if (track['trackViewUrl'] != null) {
                                  launchUrl(Uri.parse(track['trackViewUrl']));
                                } else if (track['previewUrl'] != null) {
                                  launchUrl(Uri.parse(track['previewUrl']));
                                }
                              },
                            );
                          }, childCount: tracks.length),
                        );
                      },
                    )
                  else
                    const SliverToBoxAdapter(child: SizedBox.shrink()),

                  // Copyright / Footer
                  if (copyright != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Text(
                          copyright,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white30,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),

                  // Bottom Padding
                  const SliverPadding(padding: EdgeInsets.only(bottom: 50)),
                ],
              ),

              // 3. Back Button (Moved to top of stack Z-order)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  color: Colors.white,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.2),
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatDuration(int millis) {
    final duration = Duration(milliseconds: millis);
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }
}

class _SocialButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String url;
  final String label;

  const _SocialButton({
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
          color: Colors.white,
          iconSize: 24,
          style: IconButton.styleFrom(
            backgroundColor: color.withValues(alpha: 0.2),
            padding: const EdgeInsets.all(12),
            highlightColor: color.withValues(alpha: 0.5),
          ),
          onPressed: () => launchUrl(Uri.parse(url)),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 10),
        ),
      ],
    );
  }
}
