import 'dart:convert';
import 'dart:ui';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'trending_details_screen.dart';
import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import 'package:provider/provider.dart';
import '../services/lyrics_service.dart';
import '../models/saved_song.dart';
import '../models/playlist.dart';

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

class _TopTrack {
  final String name;
  final int playCount;
  final String? albumName;

  const _TopTrack({
    required this.name,
    required this.playCount,
    this.albumName,
  });
}

class _ArtistDetailsScreenState extends State<ArtistDetailsScreen> {
  late Future<List<Map<String, dynamic>>> _discographyFuture;
  late Future<Map<String, dynamic>?> _artistInfoFuture;
  late Future<List<_SimilarArtist>> _similarArtistsFuture;
  late Future<List<_TopTrack>> _topTracksFuture;
  String? _fetchedArtistImage;
  String? _pickedArtistImage;
  String? _cachedArtistImage;

  @override
  void initState() {
    super.initState();
    // Prefer the latest cached (possibly user-overridden) image for this
    // artist over whatever image the previous screen handed us, so the most
    // recently loaded/picked profile photo shows immediately.
    _cachedArtistImage = Provider.of<RadioProvider>(
      context,
      listen: false,
    ).getArtistImageFor(widget.artistName);
    _discographyFuture = _fetchDiscography();
    _artistInfoFuture = _fetchArtistInfo();
    _similarArtistsFuture = _fetchSimilarArtists();
    _topTracksFuture = _fetchTopTracks();
    if (_cachedArtistImage == null && widget.artistImage == null) {
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
        "https://ws.audioscrobbler.com/2.0/"
        "?method=artist.gettopalbums"
        "&artist=${Uri.encodeComponent(widget.artistName)}"
        "&api_key=${RadioProvider.lastFmApiKey}"
        "&format=json&limit=20&autocorrect=1",
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body);
      if (data['error'] != null) return [];
      final albums = data['topalbums']?['album'] as List? ?? [];

      final results = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final entry in albums) {
        final map = entry as Map?;
        if (map == null) continue;
        final name = (map['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        final imageUrl = _pickAlbumImage(map['image'] as List?);
        final playcount = int.tryParse(map['playcount']?.toString() ?? '') ?? 0;
        final lowerName = name.toLowerCase();
        if (!seen.add(lowerName)) continue;
        results.add({
          'name': name,
          'playcount': playcount,
          'imageUrl': imageUrl ?? '',
        });
      }

      results.sort(
        (a, b) => (b['playcount'] as int).compareTo(a['playcount'] as int),
      );
      _warmAlbumImages(results);
      return results;
    } catch (e) {
      developer.log("Error fetching discography: $e");
    }
    return [];
  }

  // Download the album images in the background so the grid shows them
  // immediately (no visible placeholder) once the fetch completes.
  void _warmAlbumImages(List<Map<String, dynamic>> albums) {
    for (final album in albums) {
      final url = album['imageUrl']?.toString() ?? '';
      if (url.isEmpty || !mounted) continue;
      precacheImage(
        CachedNetworkImageProvider(url),
        context,
        onError: (_, _) {},
      );
    }
  }

  // Pick the largest image URL from Last.fm's [ {size, #text} ] array.
  static String? _pickAlbumImage(List? images) {
    if (images == null) return null;
    for (final img in images.reversed) {
      final map = img as Map?;
      final url = map?['#text'] as String? ?? '';
      if (url.isNotEmpty) return url;
    }
    return null;
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

  Future<List<_SimilarArtist>> _fetchSimilarArtists() async {
    // Last.fm returns the correct "similar" ARTIST NAMES, but its image URLs
    // currently resolve to a generic placeholder for almost every artist.
    // So we resolve each name through fetchArtistImage (Last.fm -> Deezer ->
    // TheAudioDB) which returns real profile photos.
    try {
      final uri = Uri.parse(
        "https://ws.audioscrobbler.com/2.0/"
        "?method=artist.getsimilar"
        "&artist=${Uri.encodeComponent(widget.artistName)}"
        "&api_key=${RadioProvider.lastFmApiKey}"
        "&format=json&limit=50&autocorrect=1",
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body);
      if (data['error'] != null) return [];
      final artists = data['similarartists']?['artist'] as List? ?? [];

      final selfName = widget.artistName.toLowerCase();
      final names = <String>[];
      for (final entry in artists) {
        final map = entry as Map?;
        final name = (map?['name'] as String? ?? '').trim();
        if (name.isEmpty || name.toLowerCase() == selfName) continue;
        names.add(name);
      }
      if (names.isEmpty) return [];

      if (!mounted) return [];
      final provider = Provider.of<RadioProvider>(context, listen: false);
      final resolved = await Future.wait(
        names.map((name) async {
          final imageUrl = await provider.fetchArtistImage(name);
          return _SimilarArtist(name: name, imageUrl: imageUrl ?? '');
        }),
        eagerError: false,
      );
      if (!mounted) return [];
      return resolved.where((a) => a.imageUrl.isNotEmpty).toList();
    } catch (e) {
      developer.log("Error fetching similar artists: $e");
    }
    return [];
  }

  Future<List<_TopTrack>> _fetchTopTracks() async {
    try {
      final uri = Uri.parse(
        "https://ws.audioscrobbler.com/2.0/"
        "?method=artist.gettoptracks"
        "&artist=${Uri.encodeComponent(widget.artistName)}"
        "&api_key=${RadioProvider.lastFmApiKey}"
        "&format=json&limit=50&autocorrect=1",
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body);
      if (data['error'] != null) return [];
      final tracks = data['toptracks']?['track'] as List? ?? [];

      final results = <_TopTrack>[];
      for (final entry in tracks) {
        final map = entry as Map?;
        if (map == null) continue;
        final name = (map['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        final playCount = int.tryParse(map['playcount']?.toString() ?? '') ?? 0;
        final albumName = (map['album'] as Map?)?['title'] as String?;
        results.add(
          _TopTrack(name: name, playCount: playCount, albumName: albumName),
        );
      }
      results.sort((a, b) => b.playCount.compareTo(a.playCount));
      return results.take(20).toList();
    } catch (e) {
      developer.log("Error fetching top tracks: $e");
    }
    return [];
  }

  // Scrape thumbnails from Bing Images for "<artist> musical artist profile photo".
  // No API key required (parses the HTML for direct image URLs).
  Future<List<String>> _fetchBingImages(String artistName) async {
    try {
      final query = Uri.encodeQueryComponent(
        '$artistName musical artist profile photo',
      );
      final uri = Uri.parse(
        'https://www.bing.com/images/search?q=$query&form=HDRSC2',
      );
      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/124.0.0.0 Safari/537.36',
              'Accept-Language': 'en-US,en;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        developer.log('Bing images status ${response.statusCode}');
        return [];
      }

      // Bing embeds results as m="{... \"murl\":\"<direct url>\" ...}"
      // with HTML-escaped quotes; unescape them so a plain regex works.
      final body = response.body
          .replaceAll('&quot;', '"')
          .replaceAll('&amp;', '&')
          .replaceAll('&#39;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');

      final urls = <String>[];
      final seen = <String>{};
      final regex = RegExp(r'"murl":"(.*?)"');
      for (final m in regex.allMatches(body)) {
        var url = m.group(1) ?? '';
        if (url.isEmpty || !url.startsWith('http')) continue;
        url = url.replaceAll(r'\/', '/');
        if (seen.add(url)) {
          urls.add(url);
        }
        if (urls.length >= 24) break;
      }
      return urls;
    } catch (e) {
      developer.log('Error fetching Bing images: $e');
    }
    return [];
  }

  Future<void> _openPhotoPicker() async {
    final urls = await _fetchBingImages(widget.artistName);
    if (!mounted) return;
    if (urls.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('no_photos_found'),
          ),
        ),
      );
      return;
    }

    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) =>
          _BingImagePickerSheet(artistName: widget.artistName, imageUrls: urls),
    );

    if (selected != null && mounted) {
      setState(() {
        _pickedArtistImage = selected;
        _cachedArtistImage = selected;
      });
      await Provider.of<RadioProvider>(
        context,
        listen: false,
      ).setArtistImageOverride(widget.artistName, selected);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('photo_saved'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Picked photo (manual override) > cached image for this artist > image
    // passed by the previous screen > fetched image > fallback
    final displayImage =
        _pickedArtistImage ??
        _cachedArtistImage ??
        widget.artistImage ??
        _fetchedArtistImage ??
        widget.fallbackImage;

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

          // 3b. Close Button (Fixed, returns directly to the app)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close_rounded),
              color: Colors.white,
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.2),
              ),
              onPressed: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
            ),
          ),

          // 3c. Photo Picker Button (Fixed, centered between the two)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 0,
            right: 0,
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.image_search_rounded),
                color: Colors.white,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.2),
                ),
                onPressed: _openPhotoPicker,
              ),
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
                                    (artistInfo?['strBiographyEN'] ??
                                            artistInfo?['strBiography'])
                                        as String?;
                                final style =
                                    artistInfo?['strStyle'] as String?;
                                final formed =
                                    artistInfo?['intFormedYear'] as String? ??
                                    artistInfo?['intBornYear'] as String?;
                                final genre =
                                    artistInfo?['strGenre'] ??
                                    artistInfo?['primaryGenreName'] ??
                                    widget.genre ??
                                    Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    ).translate('music');

                                // Find latest release logic (removed)

                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                  child: Column(
                                    children: [
                                      // 1. Biography (at the beginning)
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
                                                Provider.of<LanguageProvider>(
                                                  context,
                                                  listen: false,
                                                ).translate('biography'),
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

                                      // 2. Facts Row (Style | Year | Genre)
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        alignment: WrapAlignment.center,
                                        children: [
                                          if (style != null) _buildBadge(style),
                                          if (formed != null)
                                            _buildBadge(
                                              Provider.of<LanguageProvider>(
                                                    context,
                                                    listen: false,
                                                  )
                                                  .translate('est_year')
                                                  .replaceAll('{0}', formed),
                                              icon: Icons.calendar_today,
                                            ),
                                          _buildBadge(
                                            genre.toString().toUpperCase(),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),

                                      // 3. Similar Artists (Last.fm, clickable)
                                      _SimilarArtistsSection(
                                        similarFuture: _similarArtistsFuture,
                                        onSelected: (artist) {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  ArtistDetailsScreen(
                                                    artistName: artist.name,
                                                    artistImage:
                                                        artist.imageUrl,
                                                  ),
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 24),

                                      // 4. Top Tracks (Last.fm, playable)
                                      _TopTracksSection(
                                        topTracksFuture: _topTracksFuture,
                                        artistName: widget.artistName,
                                      ),
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
                                Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                ).translate('important_discography'),
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
                                return SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.all(32.0),
                                    child: Center(
                                      child: Text(
                                        Provider.of<LanguageProvider>(
                                          context,
                                          listen: false,
                                        ).translate('no_albums_found'),
                                        style: const TextStyle(
                                          color: Colors.white54,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }

                              final albums = snapshot.data!.take(6).toList();

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
                                    final albumName =
                                        album['name']?.toString() ?? "";
                                    final artworkUrl =
                                        album['imageUrl']?.toString() ?? "";

                                    return MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  TrendingDetailsScreen(
                                                    albumName: albumName,
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
                                                  child: artworkUrl.isEmpty
                                                      ? const Icon(
                                                          Icons.album,
                                                          color: Colors.white24,
                                                        )
                                                      : CachedNetworkImage(
                                                          imageUrl: artworkUrl,
                                                          fit: BoxFit.cover,
                                                          width:
                                                              double.infinity,
                                                          height:
                                                              double.infinity,
                                                          fadeInDuration:
                                                              Duration.zero,
                                                          placeholder: (_, _) =>
                                                              const SizedBox.expand(),
                                                          errorWidget:
                                                              (
                                                                _,
                                                                _,
                                                                _,
                                                              ) => const Icon(
                                                                Icons.album,
                                                                color: Colors
                                                                    .white24,
                                                              ),
                                                        ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              albumName.isEmpty
                                                  ? Provider.of<
                                                          LanguageProvider
                                                        >(
                                                          context,
                                                          listen: false,
                                                        )
                                                        .translate(
                                                          'unknown_album',
                                                        )
                                                  : albumName,
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
                                              '#${index + 1}',
                                              style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 11,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
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

class _SimilarArtist {
  final String name;
  final String imageUrl;

  const _SimilarArtist({required this.name, required this.imageUrl});
}

class _SimilarArtistsSection extends StatelessWidget {
  final Future<List<_SimilarArtist>> similarFuture;
  final ValueChanged<_SimilarArtist> onSelected;

  const _SimilarArtistsSection({
    required this.similarFuture,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_SimilarArtist>>(
      future: similarFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        final artists = snapshot.data ?? const <_SimilarArtist>[];
        if (artists.isEmpty) return const SizedBox.shrink();

        final screenWidth = MediaQuery.sizeOf(context).width - 48;
        final showsOverflow = artists.length * 90.0 > screenWidth;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('similar_artists'),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 116,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: artists.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 14),
                      itemBuilder: (context, index) {
                        final artist = artists[index];
                        return _SimilarArtistTile(
                          artist: artist,
                          onTap: () => onSelected(artist),
                        );
                      },
                    ),
                  ),
                  if (showsOverflow)
                    Positioned(
                      right: 0,
                      top: 0,
                      width: 44,
                      height: 68,
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.7),
                              ],
                            ),
                          ),
                          child: const Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: EdgeInsets.only(right: 2),
                              child: Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.white54,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SimilarArtistTile extends StatelessWidget {
  final _SimilarArtist artist;
  final VoidCallback onTap;

  const _SimilarArtistTile({required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.grey[800],
                border: Border.all(color: Colors.white12),
              ),
              clipBehavior: Clip.antiAlias,
              // Resolve from the provider cache so a photo override for this
              // artist updates the tile automatically (even on covered pages).
              child: Consumer<RadioProvider>(
                builder: (context, provider, _) {
                  final imageUrl =
                      provider.getArtistImageFor(artist.name) ??
                      artist.imageUrl;
                  return Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.mic, color: Colors.white24),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(
              artist.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopTracksSection extends StatefulWidget {
  final Future<List<_TopTrack>> topTracksFuture;
  final String artistName;

  const _TopTracksSection({
    required this.topTracksFuture,
    required this.artistName,
  });

  @override
  State<_TopTracksSection> createState() => _TopTracksSectionState();
}

class _TopTracksSectionState extends State<_TopTracksSection> {
  static const double _tileHeight = 58;
  static const int _visibleCount = 5;
  final ScrollController _scrollController = ScrollController();
  List<_TopTrack> _allTracks = [];
  bool _creating = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _saveTopPlaylist() {
    final playlistName = 'Top ${widget.artistName}';
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final alreadyExists = provider.playlists.any((p) => p.name == playlistName);

    if (_creating || _allTracks.isEmpty || alreadyExists) return;
    setState(() => _creating = true);

    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    final artistName = widget.artistName;

    final songs = _allTracks
        .map(
          (t) => SavedSong(
            id: 'toptrack_${artistName}_${t.name}'.hashCode.toString(),
            title: t.name,
            artist: artistName,
            album: t.albumName ?? '',
            dateAdded: DateTime.now(),
          ),
        )
        .toList();

    provider
        .createPlaylist(playlistName, songs: songs)
        .then((playlist) {
          provider.resolvePlaylistLinksInBackground(playlist.id, songs);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  langProvider
                      .translate('top_playlist_created')
                      .replaceAll('{0}', artistName)
                      .replaceAll('{1}', songs.length.toString()),
                ),
              ),
            );
          }
        })
        .whenComplete(() {
          if (mounted) setState(() => _creating = false);
        });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RadioProvider>(
      builder: (context, provider, _) {
        final playlistExists = provider.playlists.any(
          (p) => p.name == 'Top ${widget.artistName}',
        );

        return FutureBuilder<List<_TopTrack>>(
          future: widget.topTracksFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }

            final tracks = snapshot.data ?? const <_TopTrack>[];
            if (tracks.isEmpty) return const SizedBox.shrink();
            _allTracks = tracks;

            final hasMore = tracks.length > _visibleCount;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('top_tracks'),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: _creating
                          ? Padding(
                              padding: const EdgeInsets.all(6),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Theme.of(context).primaryColor,
                              ),
                            )
                          : playlistExists
                          ? Icon(
                              Icons.playlist_add_check_rounded,
                              color: Colors.white24,
                              size: 22,
                            )
                          : IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: _saveTopPlaylist,
                              icon: Icon(
                                Icons.playlist_add_rounded,
                                color: Theme.of(context).primaryColor,
                                size: 22,
                              ),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Fixed-height scrollable list: same space as 5 tracks, scrolls
                // past the 5th one to reveal the rest.
                SizedBox(
                  height: _tileHeight * _visibleCount,
                  child: Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: hasMore,
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.zero,
                      itemCount: tracks.length,
                      itemBuilder: (context, i) {
                        final track = tracks[i];
                        final playCountStr =
                            Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                )
                                .translate('playcount')
                                .replaceAll(
                                  '{0}',
                                  _formatPlayCount(track.playCount),
                                );

                        return _TopTrackTile(
                          track: track,
                          rank: i + 1,
                          playCountStr: playCountStr,
                          artistName: widget.artistName,
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static String _formatPlayCount(int count) {
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    }
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}K';
    }
    return count.toString();
  }
}

class _TopTrackTile extends StatelessWidget {
  final _TopTrack track;
  final int rank;
  final String playCountStr;
  final String artistName;

  const _TopTrackTile({
    required this.track,
    required this.rank,
    required this.playCountStr,
    required this.artistName,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<RadioProvider>(
      builder: (context, provider, _) {
        final songId = _songId();
        final isCurrent = provider.currentSongId == songId;
        final isCurrentPlaying = isCurrent && provider.isPlaying;
        final isLoading = isCurrent && provider.isLoading;

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: isLoading
                  ? null
                  : () {
                      if (isCurrentPlaying) {
                        provider.pause();
                      } else if (isCurrent) {
                        provider.resume();
                      } else {
                        _playTrack(context);
                      }
                    },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    // Rank
                    SizedBox(
                      width: 24,
                      child: Text(
                        '$rank',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Title + plays
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            playCountStr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Play / Pause / Loading indicator
                    if (isLoading)
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      )
                    else
                      Icon(
                        isCurrentPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                        color: Theme.of(context).primaryColor,
                        size: 30,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _songId() =>
      'toptrack_${artistName}_${track.name}'.hashCode.toString();

  void _playTrack(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final songId = _songId();

    final song = SavedSong(
      id: songId,
      title: track.name,
      artist: artistName,
      album: track.albumName ?? '',
      dateAdded: DateTime.now(),
    );

    final tempPlaylist = Playlist(
      id: 'artist_top_tracks_$artistName',
      name: 'Top Tracks - $artistName',
      songs: [song],
      createdAt: DateTime.now(),
    );

    provider.playAdHocPlaylist(tempPlaylist, song.id);
  }
}

class _BingImagePickerSheet extends StatelessWidget {
  final String artistName;
  final List<String> imageUrls;

  const _BingImagePickerSheet({
    required this.artistName,
    required this.imageUrls,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.8;
    return Container(
      height: maxHeight,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$artistName musical artist profile photo',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('choose_photo'),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                childAspectRatio: 1,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: imageUrls.length,
              itemBuilder: (context, index) {
                final url = imageUrls[index];
                return GestureDetector(
                  onTap: () => Navigator.pop(context, url),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey[800],
                        child: const Icon(
                          Icons.broken_image,
                          color: Colors.white24,
                        ),
                      ),
                    ),
                  ),
                );
              },
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
  String? _translatedBio;
  bool _isTranslating = false;

  @override
  Widget build(BuildContext context) {
    if (widget.bio.isEmpty) return const SizedBox.shrink();

    final bioToDisplay = _translatedBio ?? widget.bio;
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    final targetLang = langProvider.resolvedLanguageCode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                _translatedBio != null ? "Translation" : "Biography",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            if (widget.bio.isNotEmpty)
              _isTranslating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white54,
                      ),
                    )
                  : IconButton(
                      icon: Icon(
                        Icons.g_translate_rounded,
                        size: 18,
                        color: _translatedBio != null
                            ? Theme.of(context).primaryColor
                            : Colors.white54,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () async {
                        if (_translatedBio != null) {
                          setState(() => _translatedBio = null);
                          return;
                        }

                        setState(() => _isTranslating = true);
                        try {
                          final translated = await LyricsService()
                              .translateText(widget.bio, targetLang);
                          if (mounted) {
                            setState(() {
                              _translatedBio = translated;
                              _isTranslating = false;
                            });
                          }
                        } catch (e) {
                          if (mounted) {
                            setState(() => _isTranslating = false);
                          }
                        }
                      },
                    ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          bioToDisplay,
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
                _expanded
                    ? Provider.of<LanguageProvider>(
                        context,
                        listen: false,
                      ).translate('show_less')
                    : Provider.of<LanguageProvider>(
                        context,
                        listen: false,
                      ).translate('read_more'),
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
