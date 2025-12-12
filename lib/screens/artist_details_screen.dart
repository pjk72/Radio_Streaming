import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class ArtistDetailsScreen extends StatefulWidget {
  final String artistName;
  final String? artistImage;
  final String? genre;

  const ArtistDetailsScreen({
    super.key,
    required this.artistName,
    this.artistImage,
    this.genre,
  });

  @override
  State<ArtistDetailsScreen> createState() => _ArtistDetailsScreenState();
}

class _ArtistDetailsScreenState extends State<ArtistDetailsScreen> {
  late Future<List<Map<String, dynamic>>> _discographyFuture;
  late Future<Map<String, dynamic>?> _artistInfoFuture;

  @override
  void initState() {
    super.initState();
    _discographyFuture = _fetchDiscography();
    _artistInfoFuture = _fetchArtistInfo();
  }

  Future<List<Map<String, dynamic>>> _fetchDiscography() async {
    try {
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(widget.artistName)}&entity=album&limit=10",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['results']);
      }
    } catch (e) {
      debugPrint("Error fetching discography: $e");
    }
    return [];
  }

  Future<Map<String, dynamic>?> _fetchArtistInfo() async {
    try {
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(widget.artistName)}&entity=musicArtist&limit=1",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['resultCount'] > 0) {
          return data['results'][0];
        }
      }
    } catch (e) {
      debugPrint("Error fetching artist info: $e");
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Fixed Background Image
          if (widget.artistImage != null)
            Image.network(
              widget.artistImage!,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            )
          else
            Container(
              color: Colors.grey[900],
              child: const Center(
                child: Icon(Icons.mic, size: 64, color: Colors.white24),
              ),
            ),

          // 2. Fixed Gradient Overlay (for readability)
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.3),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.8),
                ],
              ),
            ),
          ),

          // 3. Back Button (Fixed)
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

          // 4. Draggable Panel
          DraggableScrollableSheet(
            initialChildSize: 0.55,
            minChildSize: 0.3,
            maxChildSize: 0.95,
            snap: true,
            snapSizes: const [0.3, 0.55, 0.95],
            builder: (context, scrollController) {
              return ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(32),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.6),
                    child: CustomScrollView(
                      controller: scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        // Handle
                        SliverToBoxAdapter(
                          child: Center(
                            child: Container(
                              margin: const EdgeInsets.only(top: 12, bottom: 8),
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white30,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),

                        // Artist Name
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            child: Text(
                              widget.artistName,
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                shadows: [
                                  Shadow(
                                    color: Colors.black54,
                                    blurRadius: 10,
                                    offset: Offset(0, 4),
                                  ),
                                ],
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),

                        // Artist Info Section
                        SliverToBoxAdapter(
                          child: FutureBuilder<Map<String, dynamic>?>(
                            future: _artistInfoFuture,
                            builder: (context, snapshot) {
                              if (!snapshot.hasData) {
                                return const SizedBox.shrink();
                              }
                              final data = snapshot.data!;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      data['primaryGenreName'] ??
                                          widget.genre ??
                                          "Artist",
                                      style: TextStyle(
                                        color: Theme.of(context).primaryColor,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    // Social Buttons Row
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (data['artistLinkUrl'] != null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 16.0,
                                            ),
                                            child: _SocialButton(
                                              icon: FontAwesomeIcons.apple,
                                              color: Colors.pinkAccent,
                                              url: data['artistLinkUrl'],
                                              label: 'Music',
                                            ),
                                          ),
                                        _SocialButton(
                                          icon: FontAwesomeIcons.spotify,
                                          color: Colors.green,
                                          url:
                                              "https://open.spotify.com/search/${Uri.encodeComponent(widget.artistName)}",
                                          label: 'Spotify',
                                        ),
                                        const SizedBox(width: 16),
                                        _SocialButton(
                                          icon: FontAwesomeIcons.youtube,
                                          color: Colors.red,
                                          url:
                                              "https://www.youtube.com/results?search_query=${Uri.encodeComponent(widget.artistName)}",
                                          label: 'YouTube',
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 32),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),

                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24.0,
                              vertical: 8.0,
                            ),
                            child: Text(
                              "Important Discography",
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.9),
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),

                        // Discography Grid
                        FutureBuilder<List<Map<String, dynamic>>>(
                          future: _discographyFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.all(32),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                              );
                            }

                            if (!snapshot.hasData || snapshot.data!.isEmpty) {
                              return const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.all(32.0),
                                  child: Center(
                                    child: Text(
                                      "No albums found.",
                                      style: TextStyle(color: Colors.white54),
                                    ),
                                  ),
                                ),
                              );
                            }

                            final albums = snapshot.data!;

                            return SliverPadding(
                              padding: const EdgeInsets.all(16.0),
                              sliver: SliverGrid(
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 200,
                                      childAspectRatio: 0.75,
                                      crossAxisSpacing: 16,
                                      mainAxisSpacing: 16,
                                    ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final album = albums[index];
                                  final artworkUrl =
                                      album['artworkUrl100']?.replaceAll(
                                        '100x100bb',
                                        '400x400bb',
                                      ) ??
                                      "";

                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          child: Container(
                                            color: Colors.grey[800],
                                            width: double.infinity,
                                            child: Image.network(
                                              artworkUrl,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                    Icons.album,
                                                    color: Colors.white24,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        album['collectionName'] ??
                                            "Unknown Album",
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        album['releaseDate']?.substring(0, 4) ??
                                            "",
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  );
                                }, childCount: albums.length),
                              ),
                            );
                          },
                        ),

                        const SliverPadding(
                          padding: EdgeInsets.only(bottom: 50),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
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
          iconSize: 28,
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
