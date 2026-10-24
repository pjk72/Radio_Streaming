import 'dart:convert';
import 'dart:ui';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'trending_details_screen.dart';
import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import 'package:provider/provider.dart';
import '../services/lyrics_service.dart';
import '../models/saved_song.dart';
import '../models/playlist.dart';
import '../utils/glass_utils.dart';

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

  /// Decodes HTML entities in [text]:
  /// - Named entities: &amp; &quot; &nbsp; &lt; &gt; &apos; (with or without ;)
  /// - Decimal numeric: &#NNN; or &#NNN  (semicolon optional — malformed HTML)
  /// - Hex numeric:     &#xHHH; or &#xHHH
  static String _decodeHtmlEntities(String text) {
    return text
        // Named entities (with semicolon)
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        // Named entities (without semicolon — malformed HTML)
        .replaceAll('&nbsp', ' ')
        .replaceAll('&amp', '&')
        .replaceAll('&quot', '"')
        // Hex numeric entities: &#xHHH; or &#xHHH (semicolon optional)
        .replaceAllMapped(
          RegExp(r'&#[xX]([0-9a-fA-F]+);?'),
          (m) {
            final code = int.tryParse(m[1]!, radix: 16);
            return code != null ? String.fromCharCode(code) : m[0]!;
          },
        )
        // Decimal numeric entities: &#NNN; or &#NNN (semicolon optional)
        .replaceAllMapped(
          RegExp(r'&#(\d+);?'),
          (m) {
            final code = int.tryParse(m[1]!);
            return code != null ? String.fromCharCode(code) : m[0]!;
          },
        );
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

      // Enrich top albums with release year
      await _enrichAlbumsWithYears(results.take(6).toList());

      return results;
    } catch (e) {
      developer.log("Error fetching discography: $e");
    }
    return [];
  }

  Future<void> _enrichAlbumsWithYears(List<Map<String, dynamic>> albums) async {
    if (albums.isEmpty) return;
    try {
      final batchYears = <String, String>{};
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(widget.artistName)}&entity=album&limit=50",
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final itunesResults = data['results'] as List? ?? [];
        for (final r in itunesResults) {
          final cName = r['collectionName'] as String?;
          final rDate = r['releaseDate'] as String?;
          if (cName != null && rDate != null && rDate.length >= 4) {
            final y = rDate.substring(0, 4);
            batchYears[_normalizeAlbum(cName)] = y;
            final cleaned = _cleanAlbumName(cName);
            if (cleaned.isNotEmpty) {
              batchYears[_normalizeAlbum(cleaned)] = y;
            }
          }
        }
      }

      final missingAlbums = <Map<String, dynamic>>[];
      for (final album in albums) {
        final name = album['name'] as String? ?? '';
        final norm = _normalizeAlbum(name);
        final normClean = _normalizeAlbum(_cleanAlbumName(name));
        String? year = batchYears[norm] ?? batchYears[normClean];

        if (year == null && normClean.isNotEmpty) {
          for (final entry in batchYears.entries) {
            if (entry.key.contains(normClean) || normClean.contains(entry.key)) {
              year = entry.value;
              break;
            }
          }
        }

        if (year != null && year.isNotEmpty) {
          album['year'] = year;
        } else {
          missingAlbums.add(album);
        }
      }

      if (missingAlbums.isNotEmpty) {
        await Future.wait(
          missingAlbums.map((album) async {
            final name = album['name'] as String? ?? '';
            final clean = _cleanAlbumName(name);
            final query = clean.isNotEmpty
                ? '${widget.artistName} $clean'
                : '${widget.artistName} $name';
            try {
              final qUri = Uri.parse(
                "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=album&limit=1",
              );
              final qResp =
                  await http.get(qUri).timeout(const Duration(seconds: 4));
              if (qResp.statusCode == 200) {
                final qData = jsonDecode(qResp.body);
                if (qData['resultCount'] > 0) {
                  final rDate = qData['results'][0]['releaseDate'] as String?;
                  if (rDate != null && rDate.length >= 4) {
                    album['year'] = rDate.substring(0, 4);
                  }
                }
              }
            } catch (_) {}
          }),
          eagerError: false,
        );
      }
    } catch (e) {
      developer.log("Error enriching albums with years: $e");
    }
  }

  static String _normalizeAlbum(String s) {
    return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _cleanAlbumName(String s) {
    return s.replaceAll(RegExp(r'\(.*?\)|\[.*?\]| - .*'), '').trim();
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

  Future<String?> _fetchWikipediaBioEn(String artistName) async {
    String? cleanExtract(Map<String, dynamic> data) {
      if (data['type'] == 'disambiguation') return null;
      final extract = data['extract'] as String?;
      if (extract == null || extract.trim().isEmpty) return null;
      return _decodeHtmlEntities(extract.trim());
    }

    Future<String?> trySummary(String title) async {
      try {
        final uri = Uri.parse(
          'https://en.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(title)}',
        );
        final response = await http.get(uri).timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final bio = cleanExtract(data);
          if (bio != null) return bio;
        }
      } catch (e) {
        developer.log("Error fetching Wikipedia summary for $title: $e");
      }
      return null;
    }

    // Try direct page
    String? bio = await trySummary(artistName);
    if (bio != null && bio.isNotEmpty) return bio;

    // Try with band/singer suffixes (prioritize band/singer)
    for (final suffix in const [
      ' (band)',
      ' (singer)',
      ' (musician)',
      ' (group)',
      ' (singer-songwriter)',
      ' (rock band)',
      ' (pop band)',
    ]) {
      bio = await trySummary('$artistName$suffix');
      if (bio != null && bio.isNotEmpty) return bio;
    }

    // Fallback to MediaWiki API (more robust)
    try {
      final uri = Uri.parse(
        'https://en.wikipedia.org/w/api.php?action=query&format=json&prop=extracts&exintro=1&explaintext=1&redirects=1&titles=${Uri.encodeComponent(artistName)}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final pages = data['query']?['pages'] as Map<String, dynamic>?;
        if (pages != null && pages.isNotEmpty) {
          for (final page in pages.values) {
            if (page is Map<String, dynamic>) {
              if (page.containsKey('missing')) continue;
              final extract = page['extract'] as String?;
              if (extract != null && extract.trim().isNotEmpty) {
                return _decodeHtmlEntities(extract.trim());
              }
            }
          }
        }
      }
    } catch (e) {
      developer.log("Error fetching Wikipedia extracts for $artistName: $e");
    }

    return null;
  }

  Future<String?> _fetchWikipediaFullBioEn(String artistName) async {
    Future<String?> tryFull(String title) async {
      // Try MediaWiki parse API for full page text
      try {
        final uri = Uri.parse(
          'https://en.wikipedia.org/w/api.php?action=parse&format=json&page=${Uri.encodeComponent(title)}&prop=text&disableeditsection=1&redirects=1',
        );
        final response = await http
            .get(
              uri,
              headers: {'User-Agent': 'RadioStreamingApp/1.0'},
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['error'] != null) throw Exception(data['error']);
          final textHtml = data['parse']?['text']?['*'] as String?;
          if (textHtml != null && textHtml.isNotEmpty) {
            String text = _decodeHtmlEntities(textHtml
                .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?<\/script>'), '')
                .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?<\/style>'), '')
                .replaceAll(RegExp(r'<table[^>]*>[\s\S]*?<\/table>'), '')
                .replaceAll(RegExp(r'<div class="infobox[^"]*"[^>]*>[\s\S]*?<\/div>'), '')
                .replaceAll(RegExp(r'<div id="toc"[^>]*>[\s\S]*?<\/div>'), '')
                .replaceAll(RegExp(r'<sup[^>]*>[\s\S]*?<\/sup>'), '')
                .replaceAll(RegExp(r'<[^>]+>'), ' '))
                .replaceAll(RegExp(r'\[\d+\]'), '')
                .replaceAll(RegExp(r'\$[0-9]+'), '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            if (text.length > 500) {
              // Remove common Wikipedia footer noise
              text = text
                  .replaceAll(RegExp(r'References.*$', caseSensitive: false), '')
                  .replaceAll(RegExp(r'External links.*$', caseSensitive: false), '')
                  .replaceAll(RegExp(r'See also.*$', caseSensitive: false), '')
                  .replaceAll(RegExp(r'Notes.*$', caseSensitive: false), '')
                  .trim();
              if (text.isNotEmpty) return text;
            }
          }
        }
      } catch (e) {
        developer.log("Error fetching Wikipedia parse for $title: $e");
      }

      // Try MediaWiki API for full extract
      try {
        final uri = Uri.parse(
          'https://en.wikipedia.org/w/api.php?action=query&format=json&prop=extracts&explaintext=1&exsectionformat=plain&exlimit=max&redirects=1&titles=${Uri.encodeComponent(title)}',
        );
        final response = await http.get(uri).timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final pages = data['query']?['pages'] as Map<String, dynamic>?;
          if (pages != null && pages.isNotEmpty) {
            for (final page in pages.values) {
              if (page is Map<String, dynamic>) {
                if (page.containsKey('missing')) continue;
                String? extract = page['extract'] as String?;
                if (extract != null && extract.trim().isNotEmpty) {
                  String text = _decodeHtmlEntities(extract)
                      .replaceAll(RegExp(r'\[\d+\]'), '')
                      .replaceAll(RegExp(r'\$[0-9]+'), '')
                      .replaceAll(RegExp(r'\s+'), ' ')
                      .trim();
                  if (text.length > 200) return text;
                }
              }
            }
          }
        }
      } catch (e) {
        developer.log("Error fetching Wikipedia full extract for $title: $e");
      }

      try {
        final uri = Uri.parse(
          'https://en.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(title)}',
        );
        final response = await http.get(uri).timeout(const Duration(seconds: 12));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          String? extract = data['extract'] as String?;
          if (extract != null && extract.trim().isNotEmpty) {
            String text = _decodeHtmlEntities(extract)
                .replaceAll(RegExp(r'\[\d+\]'), '')
                .replaceAll(RegExp(r'\$[0-9]+'), '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            if (text.isNotEmpty) return text;
          }
        }
      } catch (e) {
        developer.log("Error fetching Wikipedia summary for full $title: $e");
      }
      return null;
    }

    String? fullBio = await tryFull(artistName);
    if (fullBio != null && fullBio.isNotEmpty) return fullBio;

    for (final suffix in const [
      ' (band)',
      ' (singer)',
      ' (musician)',
      ' (group)',
      ' (singer-songwriter)',
      ' (Italian singer)',
      ' (rock band)',
      ' (pop band)',
    ]) {
      fullBio = await tryFull('$artistName$suffix');
      if (fullBio != null && fullBio.isNotEmpty) return fullBio;
    }

    return null;
  }

  Future<String?> _fetchWikipediaBirthInfo(String artistName) async {
    Future<String?> tryBirth(String title) async {
      try {
        final uri = Uri.parse(
          'https://en.wikipedia.org/w/api.php?action=parse&format=json&page=${Uri.encodeComponent(title)}&prop=text&disableeditsection=1&redirects=1',
        );
        final response = await http
            .get(
              uri,
              headers: {'User-Agent': 'RadioStreamingApp/1.0'},
            )
            .timeout(const Duration(seconds: 12));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['error'] != null) return null;
          final textHtml = data['parse']?['text']?['*'] as String?;
          if (textHtml == null || textHtml.isEmpty) return null;

          // Find infobox
          final infoboxMatch = RegExp(
            r'<table[^>]+class="[^"]*infobox[^"]*"[^>]*>[\s\S]*?</table>',
            caseSensitive: false,
          ).firstMatch(textHtml);
          if (infoboxMatch == null) return null;
          String infobox = infoboxMatch.group(0)!;

          // Extract birth date
          String? born;
          final bornMatch = RegExp(
            r'Born[^<]*</th>[\s\S]*?<td[^>]*>([\s\S]*?)</td>',
            caseSensitive: false,
          ).firstMatch(infobox);
          if (bornMatch != null) {
            String b = bornMatch.group(1)!;
            b = b
                .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ', ')
                .replaceAll(RegExp(r'<[^>]+>'), ' ')
                .replaceAll('&nbsp;', ' ')
                .replaceAll('&amp;', '&')
                .replaceAll(RegExp(r'\[\d+\]'), '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            if (b.isNotEmpty) born = b;
          }

          // If no Born row, try birth_date
          if (born == null || born.isEmpty) {
            final bdMatch = RegExp(
              r'birth_date[^<]*</th>[\s\S]*?<td[^>]*>([\s\S]*?)</td>',
              caseSensitive: false,
            ).firstMatch(infobox);
            if (bdMatch != null) {
              String b = bdMatch.group(1)!;
              b = b
                  .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ', ')
                  .replaceAll(RegExp(r'<[^>]+>'), ' ')
                  .replaceAll('&nbsp;', ' ')
                  .replaceAll('&amp;', '&')
                  .replaceAll(RegExp(r'\[\d+\]'), '')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim();
              if (b.isNotEmpty) born = b;
            }
          }

          if (born != null && born.isNotEmpty) {
            // Clean up common prefixes
            born = born.replaceAll(RegExp(r'^Born\s*:?\s*', caseSensitive: false), '');
            // Limit length
            if (born.length > 120) {
              // Take first two parts if comma separated
              final parts = born.split(',');
              if (parts.length >= 2) {
                born = '${parts[0].trim()}, ${parts[1].trim()}';
              } else {
                born = born.substring(0, 120).trim();
              }
            }
            return born;
          }
        }
      } catch (e) {
        developer.log("Error fetching Wikipedia birth info for $title: $e");
      }
      return null;
    }

    String? info = await tryBirth(artistName);
    if (info != null && info.isNotEmpty) return info;

    for (final suffix in const [
      ' (band)',
      ' (singer)',
      ' (musician)',
      ' (group)',
      ' (singer-songwriter)',
      ' (rock band)',
      ' (pop band)',
    ]) {
      info = await tryBirth('$artistName$suffix');
      if (info != null && info.isNotEmpty) return info;
    }

    return null;
  }

  Future<Map<String, dynamic>?> _fetchArtistInfo() async {
    Map<String, dynamic>? result;

    // 1. Try TheAudioDB for facts (genre/style/year) if available
    try {
      final uri = Uri.parse(
        "https://www.theaudiodb.com/api/v1/json/123/search.php?s=${Uri.encodeComponent(widget.artistName)}",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['artists'] != null && (data['artists'] as List).isNotEmpty) {
          result = Map<String, dynamic>.from(data['artists'][0]);
        }
      }
    } catch (e) {
      developer.log("Error fetching TheAudioDB info: $e");
    }

    // 2. Fallback to iTunes if AudioDB fails (just for genre)
    if (result == null) {
      try {
        final uri = Uri.parse(
          "https://itunes.apple.com/search?term=${Uri.encodeComponent(widget.artistName)}&entity=musicArtist&limit=1",
        );
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['resultCount'] > 0) {
            result = Map<String, dynamic>.from(data['results'][0]);
          }
        }
      } catch (e) {
        developer.log("Error fetching iTunes artist info: $e");
      }
    }

    // 3. Get biography from English Wikipedia (same UI)
    final wikiBio = await _fetchWikipediaBioEn(widget.artistName);
    if (wikiBio != null && wikiBio.isNotEmpty) {
      result ??= <String, dynamic>{};
      // Prefer English Wikipedia bio
      result['strBiographyEN'] = wikiBio;
      // Store full bio for popup
      final fullBio = await _fetchWikipediaFullBioEn(widget.artistName);
      if (fullBio != null && fullBio.isNotEmpty && fullBio.length > wikiBio.length) {
        result['strBiographyENFull'] = fullBio;
      } else if (fullBio != null && fullBio.isNotEmpty) {
        result['strBiographyENFull'] = fullBio;
      }
    }

    // 4. Get birth/origin info from Wikipedia infobox
    final birthInfo = await _fetchWikipediaBirthInfo(widget.artistName);
    if (birthInfo != null && birthInfo.isNotEmpty) {
      result ??= <String, dynamic>{};
      result['strBirthInfo'] = birthInfo;
    }

    return result;
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

  Future<void> _showFullBiographyDialog(
    BuildContext context, {
    String? imageUrl,
    String? introBio,
    String? cachedFullBio,
    String? birthInfo,
  }) async {
    String displayBio = cachedFullBio ?? introBio ?? '';
    try {
      final fetchedFull = await _fetchWikipediaFullBioEn(widget.artistName);
      if (fetchedFull != null && fetchedFull.isNotEmpty) {
        displayBio = fetchedFull;
      }
    } catch (e) {
      developer.log('Error loading full biography: $e');
    }

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (context) => _FullBiographyDialog(
        artistName: widget.artistName,
        imageUrl: imageUrl,
        bio: displayBio,
        birthInfo: birthInfo,
      ),
    );
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
                                  return const _ArtistInfoSkeleton();
                                }

                                final artistInfo = snapshot.data;

                                // Data extraction (handle AudioDB vs iTunes keys)
                                final rawBio =
                                    _decodeHtmlEntities(
                                      ((artistInfo?['strBiographyEN'] ??
                                              artistInfo?['strBiography'])
                                          as String?) ?? '');
                                final bio = rawBio.isEmpty ? null : rawBio;
                                final rawFullBio =
                                    _decodeHtmlEntities(
                                      ((artistInfo?['strBiographyENFull'] ??
                                              artistInfo?['strBiographyEN'] ??
                                              artistInfo?['strBiography'])
                                          as String?) ?? '');
                                final fullBio = rawFullBio.isEmpty ? null : rawFullBio;
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
                                              const SizedBox(height: 12),
                                              Align(
                                                alignment: Alignment.centerRight,
                                                child: TextButton.icon(
                                                  onPressed: () {
                                                    final birthInfo =
                                                        (artistInfo?['strBirthInfo'] as String?);
                                                    _showFullBiographyDialog(
                                                      context,
                                                      imageUrl: displayImage,
                                                      introBio: bio,
                                                      cachedFullBio: fullBio,
                                                      birthInfo: birthInfo,
                                                    );
                                                  },
                                                  icon: const Icon(
                                                    Icons.auto_stories_rounded,
                                                    color: Colors.white70,
                                                    size: 18,
                                                  ),
                                                  label: Text(
                                                    Provider.of<LanguageProvider>(
                                                      context,
                                                      listen: false,
                                                    ).translate(
                                                        'read_full_biography'),
                                                    style: const TextStyle(
                                                      color: Colors.white70,
                                                      fontSize: 13,
                                                    ),
                                                  ),
                                                  style: TextButton.styleFrom(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                            horizontal: 12,
                                                            vertical: 6),
                                                  ),
                                                ),
                                              ),
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
                                  child: _DiscographySkeleton(),
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
                                    final albumYear =
                                        album['year']?.toString() ?? "";

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
                                              albumYear,
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
          return const _SimilarArtistsSkeleton();
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
              return const _TopTracksSkeleton();
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

        final savedKeys = provider.allUniqueSongs
            .map(
              (s) =>
                  '${_normalize(s.title)}|${_normalize(s.artist)}'.toLowerCase(),
            )
            .toSet();
        final trackKey =
            '${_normalize(track.name)}|${_normalize(artistName)}'.toLowerCase();
        final isSaved = savedKeys.contains(trackKey);

        final langProvider = Provider.of<LanguageProvider>(
          context,
          listen: false,
        );

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
                    const SizedBox(width: 2),
                    // Add to playlist
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      iconSize: 22,
                      icon: Icon(
                        isSaved
                            ? Icons.playlist_add_check_rounded
                            : Icons.add_circle_outline,
                        color: isSaved
                            ? Theme.of(context).primaryColor
                            : Colors.white54,
                        size: 22,
                      ),
                      tooltip: isSaved
                          ? langProvider.translate('already_in_library')
                          : langProvider.translate('add_to_playlist'),
                      onPressed: () => _showAddSongDialog(context),
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

  static String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  SavedSong _buildSong() => SavedSong(
    id: _songId(),
    title: track.name,
    artist: artistName,
    album: track.albumName ?? '',
    dateAdded: DateTime.now(),
  );

  void _showAddSongDialog(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final song = _buildSong();
    final langProvider = Provider.of<LanguageProvider>(
      context,
      listen: false,
    );

    GlassUtils.showGlassDialog(
      context: context,
      builder: (dialogContext) {
        final playlists = provider.playlists;
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(
            langProvider.translate('add_to_playlist'),
            style: TextStyle(
              color: Theme.of(dialogContext).textTheme.titleLarge?.color,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    "${langProvider.translate('add_to_playlist')} '${song.title}' to:",
                    style: TextStyle(
                      color: Theme.of(
                        dialogContext,
                      ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: playlists.length + 1,
                    itemBuilder: (ctx, index) {
                      if (index == 0) {
                        return Material(
                          color: Colors.black.withValues(alpha: 0.001),
                          child: ListTile(
                            leading: const Icon(
                              Icons.add,
                              color: Colors.blueAccent,
                            ),
                            title: Text(
                              langProvider.translate('create_new_playlist'),
                              style: const TextStyle(color: Colors.blueAccent),
                            ),
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _createNewPlaylistAndAddSong(context);
                            },
                          ),
                        );
                      }
                      final p = playlists[index - 1];
                      return Material(
                        color: Colors.black.withValues(alpha: 0.001),
                        child: ListTile(
                          leading: const Icon(Icons.playlist_add_rounded),
                          title: Text(
                            p.name,
                            style: TextStyle(
                              color: Theme.of(
                                ctx,
                              ).textTheme.bodyLarge?.color,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _performAddSong(context, p.id);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _createNewPlaylistAndAddSong(BuildContext context) {
    final controller = TextEditingController();
    final song = _buildSong();
    final langProvider = Provider.of<LanguageProvider>(
      context,
      listen: false,
    );

    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(
          langProvider.translate('new_playlist'),
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
          decoration: InputDecoration(
            labelText: langProvider.translate('playlist_name'),
            labelStyle: TextStyle(
              color: Theme.of(
                context,
              ).textTheme.bodyLarge?.color?.withValues(alpha: 0.6),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).dividerColor),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).primaryColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(langProvider.translate('cancel')),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final name = controller.text;
                Navigator.pop(ctx);
                final provider = Provider.of<RadioProvider>(
                  context,
                  listen: false,
                );
                final songs = [song];
                final newPlaylist = await provider.createPlaylist(
                  name,
                  songs: songs,
                );
                provider.resolvePlaylistLinksInBackground(
                  newPlaylist.id,
                  songs,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        langProvider
                            .translate('song_added')
                            .replaceAll('{0}', song.title),
                      ),
                    ),
                  );
                }
              }
            },
            child: Text(
              langProvider.translate('create'),
              style: TextStyle(color: Theme.of(context).primaryColor),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _performAddSong(
    BuildContext context,
    String playlistId,
  ) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final song = _buildSong();
    await provider.addSongToPlaylist(playlistId, song);
    provider.resolvePlaylistLinksInBackground(playlistId, [song]);
    if (context.mounted) {
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            langProvider.translate('song_added').replaceAll('{0}', song.title),
          ),
        ),
      );
    }
  }

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

// ─── Skeleton / shimmer widgets ──────────────────────────────────────────────

/// A single shimmer box that pulses with opacity.
class _SkeletonBox extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;

  const _SkeletonBox({
    required this.width,
    required this.height,
    this.borderRadius = 8,
  });

  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.06, end: 0.18).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: _anim.value),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      ),
    );
  }
}

/// Skeleton for the Artist Info / Bio area.
class _ArtistInfoSkeleton extends StatelessWidget {
  const _ArtistInfoSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bio card skeleton
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                const _SkeletonBox(width: 100, height: 16, borderRadius: 6),
                const SizedBox(height: 12),
                // Text lines
                const _SkeletonBox(width: double.infinity, height: 12, borderRadius: 4),
                const SizedBox(height: 6),
                const _SkeletonBox(width: double.infinity, height: 12, borderRadius: 4),
                const SizedBox(height: 6),
                _SkeletonBox(width: MediaQuery.sizeOf(context).width * 0.5, height: 12, borderRadius: 4),
                const SizedBox(height: 14),
                // "Read full" button placeholder
                const Align(
                  alignment: Alignment.centerRight,
                  child: _SkeletonBox(width: 130, height: 30, borderRadius: 8),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // Badge row
          Wrap(
            spacing: 8,
            children: const [
              _SkeletonBox(width: 72, height: 28, borderRadius: 20),
              _SkeletonBox(width: 88, height: 28, borderRadius: 20),
              _SkeletonBox(width: 64, height: 28, borderRadius: 20),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Skeleton for the Similar Artists horizontal scroll row.
class _SimilarArtistsSkeleton extends StatelessWidget {
  const _SimilarArtistsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section title
        const _SkeletonBox(width: 160, height: 16, borderRadius: 6),
        const SizedBox(height: 12),
        SizedBox(
          height: 116,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 6,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (_, __) => Column(
              children: const [
                _SkeletonBox(width: 68, height: 68, borderRadius: 34), // circle
                SizedBox(height: 6),
                _SkeletonBox(width: 60, height: 11, borderRadius: 4),
                SizedBox(height: 4),
                _SkeletonBox(width: 44, height: 11, borderRadius: 4),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Skeleton for the Top Tracks list (5 rows).
class _TopTracksSkeleton extends StatelessWidget {
  const _TopTracksSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title row
        const _SkeletonBox(width: 120, height: 16, borderRadius: 6),
        const SizedBox(height: 12),
        // 5 track rows
        for (int i = 0; i < 5; i++) ...[
          Row(
            children: [
              // Rank number placeholder
              const _SkeletonBox(width: 20, height: 14, borderRadius: 4),
              const SizedBox(width: 12),
              // Album art
              const _SkeletonBox(width: 42, height: 42, borderRadius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    _SkeletonBox(width: double.infinity, height: 13, borderRadius: 4),
                    SizedBox(height: 5),
                    _SkeletonBox(width: 80, height: 11, borderRadius: 4),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

/// Skeleton for the Discography grid (2 rows × 3 columns).
class _DiscographySkeleton extends StatelessWidget {
  const _DiscographySkeleton();

  @override
  Widget build(BuildContext context) {
    const gap = 16.0;
    const cols = 3;
    final cardW = (MediaQuery.sizeOf(context).width - 32 - gap * (cols - 1)) / cols;
    final cardH = cardW / 0.75;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (int i = 0; i < 6; i++)
            SizedBox(
              width: cardW,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonBox(width: cardW, height: cardH * 0.78, borderRadius: 12),
                  const SizedBox(height: 8),
                  _SkeletonBox(width: cardW * 0.8, height: 13, borderRadius: 4),
                  const SizedBox(height: 5),
                  _SkeletonBox(width: cardW * 0.5, height: 11, borderRadius: 4),
                ],
              ),
            ),
        ],
      ),
    );
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
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _FullBiographyDialog extends StatefulWidget {
  final String artistName;
  final String? imageUrl;
  final String bio;
  final String? birthInfo;

  const _FullBiographyDialog({
    required this.artistName,
    required this.bio,
    this.imageUrl,
    this.birthInfo,
  });

  @override
  State<_FullBiographyDialog> createState() => _FullBiographyDialogState();
}

class _FullBiographyDialogState extends State<_FullBiographyDialog> {
  double _fontSize = 15;
  String? _translatedBio;
  bool _isTranslating = false;

  String get _displayBio => _translatedBio ?? widget.bio;

  Future<void> _translate() async {
    if (_translatedBio != null) {
      setState(() => _translatedBio = null);
      return;
    }
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    setState(() => _isTranslating = true);
    try {
      final translated = await LyricsService().translateText(
        widget.bio,
        langProvider.resolvedLanguageCode,
      );
      if (mounted) {
        setState(() {
          _translatedBio = translated;
          _isTranslating = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isTranslating = false);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _displayBio));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('bio_copied'),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _changeFont(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(12.0, 24.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    final screenHeight = MediaQuery.sizeOf(context).height * 0.85;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            constraints: BoxConstraints(maxHeight: screenHeight),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF2A1B3D).withValues(alpha: 0.98),
                  const Color(0xFF0D0D12).withValues(alpha: 0.98),
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Hero header with artist photo
                SizedBox(
                  height: 190,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
                        Positioned.fill(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ImageFiltered(
                                imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
                                child: CachedNetworkImage(
                                  imageUrl: widget.imageUrl!,
                                  fit: BoxFit.cover,
                                  alignment: Alignment.center,
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0D0D12).withValues(alpha: 0.6),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FractionallySizedBox(
                                  widthFactor: 0.7,
                                  heightFactor: 1.0,
                                  child: ShaderMask(
                                    shaderCallback: (rect) {
                                      return LinearGradient(
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                        stops: const [0.0, 0.12, 0.35, 0.65, 1.0],
                                        colors: [
                                          Colors.transparent,
                                          Colors.white.withValues(alpha: 0.08),
                                          Colors.white.withValues(alpha: 0.4),
                                          Colors.white,
                                          Colors.white,
                                        ],
                                      ).createShader(rect);
                                    },
                                    blendMode: BlendMode.dstIn,
                                    child: CachedNetworkImage(
                                      imageUrl: widget.imageUrl!,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.topCenter,
                                      errorWidget: (_, _, _) =>
                                          _buildHeaderPlaceholder(),
                                      placeholder: (_, _) =>
                                          _buildHeaderPlaceholder(),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Positioned.fill(
                          child: _buildHeaderPlaceholder(),
                        ),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.14, 0.28, 0.46, 0.72, 0.96],
                          ),
                        ),
                      ),
                      // Artist name anchored to the top of the header
                      Positioned(
                        left: 24,
                        right: 24,
                        top: 18,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: MediaQuery.of(context).size.width * 0.56,
                              child: Text(
                                widget.artistName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.w900,
                                  height: 0.95,
                                  letterSpacing: -1.2,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black,
                                      blurRadius: 20,
                                      offset: Offset(0, 4),
                                    ),
                                    Shadow(
                                      color: Colors.black87,
                                      blurRadius: 42,
                                      offset: Offset(0, 6),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (widget.birthInfo != null &&
                                widget.birthInfo!.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              SizedBox(
                                width: MediaQuery.of(context).size.width * 0.56,
                                child: Text(
                                  widget.birthInfo!.replaceAll(', ', '\n'),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    height: 1.4,
                                    shadows: const [
                                      Shadow(
                                        color: Colors.black,
                                        blurRadius: 12,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // Section label anchored to the bottom of the header
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom: 18,
                        child: Text(
                          langProvider.translate('biography'),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2.2,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IconButton(
                          onPressed: () => Navigator.pop(context),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(alpha: 0.4),
                          ),
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Toolbar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      _buildToolButton(
                        icon: Icons.text_decrease_rounded,
                        tooltip: 'A-',
                        onPressed: () => _changeFont(-1),
                      ),
                      const SizedBox(width: 4),
                      _buildToolButton(
                        icon: Icons.text_increase_rounded,
                        tooltip: 'A+',
                        onPressed: () => _changeFont(1),
                      ),
                      const Spacer(),
                      _isTranslating
                          ? const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white54,
                                ),
                              ),
                            )
                          : _buildToolButton(
                              icon: Icons.g_translate_rounded,
                              tooltip: langProvider.translate('translation'),
                              active: _translatedBio != null,
                              onPressed: _translate,
                            ),
                      const SizedBox(width: 4),
                      _buildToolButton(
                        icon: Icons.copy_rounded,
                        tooltip: langProvider.translate('copy'),
                        onPressed: _copy,
                      ),
                    ],
                  ),
                ),

                // Biography text
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_translatedBio != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).primaryColor.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              langProvider.translate('translation'),
                              style: TextStyle(
                                color: Theme.of(context).primaryColor,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                        Builder(
                          builder: (context) {
                            String normalized = _displayBio
                                .replaceAll('\r\n', '\n')
                                .replaceAll(RegExp(r'\n{3,}'), '\n\n')
                                .trim();

                            // Add line breaks after sentence-ending punctuation
                            normalized = normalized
                                .replaceAllMapped(
                                    RegExp(r'([.!?])\s+(?=[A-ZÀ-ÖØ-Þ])'),
                                    (m) => '${m[1]}\n\n')
                                .replaceAll(RegExp(r'\n{3,}'), '\n\n');

                            final paragraphs = normalized
                                .split(RegExp(r'\n\s*\n'))
                                .where((p) => p.trim().isNotEmpty)
                                .toList();

                            if (paragraphs.isEmpty) {
                              return SelectableText(
                                normalized.replaceAll(RegExp(r'\n+'), ' ').trim(),
                                textAlign: TextAlign.left,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.86),
                                  fontSize: _fontSize,
                                  height: 1.8,
                                  letterSpacing: 0.15,
                                  wordSpacing: 0.3,
                                ),
                              );
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final p in paragraphs)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 18),
                                    child: SelectableText(
                                      p.replaceAll(RegExp(r'\n+'), ' ').trim(),
                                      textAlign: TextAlign.left,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.86),
                                        fontSize: _fontSize,
                                        height: 1.8,
                                        letterSpacing: 0.15,
                                        wordSpacing: 0.3,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A2B52), Color(0xFF191325)],
        ),
      ),
      child: const Center(
        child: Icon(Icons.mic_rounded, size: 48, color: Colors.white24),
      ),
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool active = false,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: active
            ? Theme.of(context).primaryColor.withValues(alpha: 0.2)
            : Colors.white.withValues(alpha: 0.06),
        minimumSize: const Size(38, 38),
        padding: EdgeInsets.zero,
      ),
      icon: Icon(
        icon,
        size: 19,
        color: active ? Theme.of(context).primaryColor : Colors.white70,
      ),
    );
  }
}
