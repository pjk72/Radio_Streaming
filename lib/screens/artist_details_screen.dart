import 'dart:convert';
import 'dart:ui';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'trending_details_screen.dart';
import '../providers/radio_provider.dart';
import 'package:provider/provider.dart';

class ArtistDetailsScreen extends StatefulWidget {
  final String artistName;
  final String? artistImage;
  final String? genre;
  final String? fallbackImage;

  const ArtistDetailsScreen({
    super.key,
    required this.artistName,
    this.artistImage,
    this.genre,
    this.fallbackImage,
  });

  @override
  State<ArtistDetailsScreen> createState() => _ArtistDetailsScreenState();
}

class _ArtistDetailsScreenState extends State<ArtistDetailsScreen> {
  late Future<List<Map<String, dynamic>>> _discographyFuture;
  late Future<Map<String, dynamic>?> _artistInfoFuture;
  String? _fetchedArtistImage;

  @override
  void initState() {
    super.initState();
    _discographyFuture = _fetchDiscography();
    _artistInfoFuture = _fetchArtistInfo();
    if (widget.artistImage == null) {
      _fetchArtistImage();
    }
  }

  Future<void> _fetchArtistImage() async {
    if (!mounted) return;
    try {
      final provider = Provider.of<RadioProvider>(context, listen: false);
      final picture = await provider.fetchArtistImage(widget.artistName);

      if (picture != null && mounted) {
        setState(() {
          _fetchedArtistImage = picture;
        });
      }
    } catch (e) {
      developer.log("Error fetching artist image: $e");
    }
  }

  Future<List<Map<String, dynamic>>> _fetchDiscography() async {
    try {
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(widget.artistName)}&entity=album&limit=50",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['results']);
      }
    } catch (e) {
      developer.log("Error fetching discography: $e");
    }
    return [];
  }

  Future<Map<String, dynamic>?> _fetchArtistInfo() async {
    // 1. Try TheAudioDB for rich bio/facts (using test key '2')
    try {
      final uri = Uri.parse(
        "https://www.theaudiodb.com/api/v1/json/2/search.php?s=${Uri.encodeComponent(widget.artistName)}",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['artists'] != null && (data['artists'] as List).isNotEmpty) {
          return data['artists'][0];
        }
      }
    } catch (e) {
      developer.log("Error fetching TheAudioDB info: $e");
    }

    // 2. Fallback to iTunes if AudioDB fails (just for genre)
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
      developer.log("Error fetching iTunes artist info: $e");
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final displayImage =
        widget.artistImage ?? _fetchedArtistImage ?? widget.fallbackImage;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Fixed Background Image
          if (displayImage != null)
            Image.network(
              displayImage,
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

          // 4. Draggable Panel (Lifted for Banner)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: DraggableScrollableSheet(
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
                                margin: const EdgeInsets.only(
                                  top: 12,
                                  bottom: 8,
                                ),
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

                          // Artist Info & Events Section
                          SliverToBoxAdapter(
                            child: FutureBuilder<Map<String, dynamic>?>(
                              future: _artistInfoFuture,
                              builder: (context, snapshot) {
                                if (snapshot.connectionState ==
                                    ConnectionState.waiting) {
                                  return const SizedBox(height: 100);
                                }

                                final artistInfo = snapshot.data;

                                // Data extraction (handle AudioDB vs iTunes keys)
                                final bio =
                                    artistInfo?['strBiographyEN'] as String?;
                                final style =
                                    artistInfo?['strStyle'] as String?;
                                final formed =
                                    artistInfo?['intFormedYear'] as String? ??
                                    artistInfo?['intBornYear'] as String?;
                                final genre =
                                    artistInfo?['strGenre'] ??
                                    artistInfo?['primaryGenreName'] ??
                                    widget.genre ??
                                    "Music";

                                // Find latest release logic (removed)

                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                  child: Column(
                                    children: [
                                      // 1. Facts Row (Style | Year | Genre)
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        alignment: WrapAlignment.center,
                                        children: [
                                          if (style != null) _buildBadge(style),
                                          if (formed != null)
                                            _buildBadge(
                                              "Est. $formed",
                                              icon: Icons.calendar_today,
                                            ),
                                          _buildBadge(
                                            genre.toString().toUpperCase(),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 24),

                                      // 2. Biography (Text inside page!)
                                      if (bio != null && bio.isNotEmpty) ...[
                                        Container(
                                          padding: const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.05,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                "Biography",
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.9),
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 18,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              ExternalBioText(bio: bio),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 24),
                                      ],
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

                              final allAlbums = snapshot.data!;

                              // 1. Dedup by name & Filter Singles (trackCount < 4)
                              final uniqueAlbums =
                                  <String, Map<String, dynamic>>{};
                              for (var album in allAlbums) {
                                final name = album['collectionName'] as String?;
                                final trackCount =
                                    album['trackCount'] as int? ?? 0;
                                final lowerName = name?.toLowerCase() ?? "";

                                // STRICT FILTER:
                                // 1. Exclude if fewer than 5 tracks (avoids Singles/EPs/Maxi-Singles)
                                // 2. Exclude explicitly named "Single" or "EP"
                                if (trackCount < 5) continue;
                                if (lowerName.contains(' - single') ||
                                    lowerName.contains(' (single)') ||
                                    lowerName.contains(' - ep') ||
                                    lowerName.contains(' (ep)')) {
                                  continue;
                                }

                                if (name != null) {
                                  // If we haven't seen this album name yet, add it.
                                  if (!uniqueAlbums.containsKey(name)) {
                                    uniqueAlbums[name] = album;
                                  }
                                }
                              }

                              // 2. Take top 12
                              final albums = uniqueAlbums.values
                                  .take(12)
                                  .toList();

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

                                    return MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  TrendingDetailsScreen(
                                                    albumName:
                                                        album['collectionName'] ??
                                                        "",
                                                    artistName:
                                                        widget.artistName,
                                                    artworkUrl: artworkUrl,
                                                    songName: null,
                                                  ),
                                            ),
                                          );
                                        },
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: Container(
                                                  color: Colors.grey[800],
                                                  width: double.infinity,
                                                  child: Image.network(
                                                    artworkUrl,
                                                    fit: BoxFit.cover,
                                                    errorBuilder:
                                                        (
                                                          context,
                                                          error,
                                                          stackTrace,
                                                        ) => const Icon(
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
                                            const SizedBox(height: 2),
                                            Text(
                                              "${album['releaseDate']?.substring(0, 4) ?? '-'} • ${album['primaryGenreName'] ?? 'Music'}",
                                              style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 11,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              "${album['trackCount'] ?? '?'} tracks",
                                              style: TextStyle(
                                                color: Colors.white.withValues(
                                                  alpha: 0.3,
                                                ),
                                                fontSize: 10,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }, childCount: albums.length),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ), // End Positioned Wrapper
        ],
      ),
    );
  }

  Widget _buildBadge(String text, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: Colors.white70),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class ExternalBioText extends StatefulWidget {
  final String bio;
  const ExternalBioText({super.key, required this.bio});

  @override
  State<ExternalBioText> createState() => _ExternalBioTextState();
}

class _ExternalBioTextState extends State<ExternalBioText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.bio,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            height: 1.5,
          ),
          maxLines: _expanded ? null : 4,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        ),
        if (widget.bio.length > 200)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _expanded = !_expanded;
                });
              },
              child: Text(
                _expanded ? "Show Less" : "Read More",
                style: const TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
