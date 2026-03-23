import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'log_service.dart';

class TrendingPlaylist {
  final String id;
  String title; // Not final, allowed to update during scrape
  String provider; // YouTube, AUDIUS, DEEZER, APPLEMUSIC, AI
  final List<String> imageUrls;
  final String? externalUrl;
  int trackCount; // Not final, can update after counting
  final String? owner;
  final String? categoryTitle;
  final List<Map<String, dynamic>>? predefinedTracks;

  TrendingPlaylist({
    required this.id,
    required this.title,
    required this.provider,
    required this.imageUrls,
    this.externalUrl,
    this.trackCount = -1,
    this.owner,
    this.categoryTitle,
    this.predefinedTracks,
  });
}

class TrendingService {
  final YoutubeExplode _yt = YoutubeExplode();

  final Map<String, List<TrendingPlaylist>> _cache = {};

  TrendingService();

  void dispose() {
    _yt.close();
  }

  Future<List<TrendingPlaylist>> searchTrending(
    String country,
    String year, {
    String? countryCode,
    String? customQuery,
  }) async {
    final String query = customQuery ?? "Top 50 - $country";
    final cacheKey = '${countryCode ?? country}_${query}'.toLowerCase();

    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    final results = await Future.wait([
      _searchAppleMusic(customQuery, countryCode ?? country),
      _searchYouTube(customQuery ?? "Top $country $year"),
      _searchAudius(customQuery ?? country),
      _searchDeezer(customQuery ?? "Top $country"),
    ]);

    final Set<String> seenImages = {};
    final finalResults = <TrendingPlaylist>[];

    for (var sublist in results) {
      int countForThisSource = 0;
      const int maxForSource = 100;

      for (var p in sublist) {
        // Allow playlists with tracks, predefined tracks, OR external URLs (for lazy-load)
        final hasTracks =
            p.trackCount > 0 ||
            (p.predefinedTracks != null && p.predefinedTracks!.isNotEmpty);
        final isLazyLoadable =
            p.externalUrl != null && p.externalUrl!.isNotEmpty;
        if (!hasTracks && !isLazyLoadable) continue;

        final imageUrl = p.imageUrls.isNotEmpty ? p.imageUrls.first : null;
        if (imageUrl != null && seenImages.contains(imageUrl)) continue;

        if (countForThisSource < maxForSource) {
          if (imageUrl != null) seenImages.add(imageUrl);
          finalResults.add(p);
          countForThisSource++;
        }
      }
    }

    _cache[cacheKey] = finalResults;
    return finalResults;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // APPLE MUSIC — public RSS API, no authentication required
  // https://rss.applemarketingtools.com/api/v2/{country}/music/{type}/N/songs.json
  // ─────────────────────────────────────────────────────────────────────────

  static const _appleCountryCodes = {
    'ALL': 'us',
    'IT': 'it',
    'US': 'us',
    'GB': 'gb',
    'DE': 'de',
    'FR': 'fr',
    'ES': 'es',
    'PT': 'pt',
    'NL': 'nl',
    'BE': 'be',
    'CH': 'ch',
    'AT': 'at',
    'SE': 'se',
    'NO': 'no',
    'DK': 'dk',
    'FI': 'fi',
    'PL': 'pl',
    'GR': 'gr',
    'TR': 'tr',
    'RU': 'ru',
    'JP': 'jp',
    'KR': 'kr',
    'CN': 'cn',
    'IN': 'in',
    'AU': 'au',
    'NZ': 'nz',
    'CA': 'ca',
    'MX': 'mx',
    'BR': 'br',
    'AR': 'ar',
    'ZA': 'za',
    'IE': 'ie',
    'MA': 'ma',
  };

  /// Chart types available from the Apple Music RSS API.
  static const appleChartTypes = [
    _AppleChartType(
      type: 'most-played',
      titleEn: 'Apple Music Playlists',
      titleKey: 'most_played_playlists',
      isPlaylist: true,
    ),
    _AppleChartType(
      type: 'most-played',
      titleEn: 'Most Played Songs',
      titleKey: 'top_songs',
    ),
    _AppleChartType(
      type: 'top-songs',
      titleEn: 'Top Songs',
      titleKey: 'top_songs',
    ),
  ];

  /// Fetches Apple Music chart playlists for [country].
  /// Returns one playlist per chart type (Most Played, Top Songs, etc.)
  Future<List<TrendingPlaylist>> _searchAppleMusic(
    String? customQuery,
    String country,
  ) async {
    final cc = (_appleCountryCodes[country] ?? 'us').toLowerCase();
    final playlists = <TrendingPlaylist>[];

    // Fetch multiple chart types in parallel
    // NOTE: Some charts return a SINGLE virtual playlist (built from songs),
    // while others (isPlaylist: true) return a LIST of real playlists.
    final futures = appleChartTypes.map((chart) async {
      if (chart.isPlaylist) {
        return await fetchApplePlaylists(cc, country, chart);
      } else {
        final p = await fetchAppleMusicChart(cc, country, chart);
        return p != null ? [p] : <TrendingPlaylist>[];
      }
    });

    final results = await Future.wait(futures);
    for (final list in results) {
      playlists.addAll(list);
    }

    return playlists;
  }

  /// Fetches real Apple Music playlists from the RSS feed.
  Future<List<TrendingPlaylist>> fetchApplePlaylists(
    String appleCC,
    String appCountry,
    _AppleChartType chart,
  ) async {
    const int limit = 100; // Fetch enough for 5 rows of 15 (75 total)
    final url = Uri.parse(
      'https://rss.marketingtools.apple.com/api/v2/$appleCC'
      '/music/${chart.type}/$limit/playlists.json',
    );

    try {
      final r = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 12));

      if (r.statusCode != 200) return [];

      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final feed = data['feed'] as Map<String, dynamic>? ?? {};
      final results = (feed['results'] as List?) ?? [];

      final List<TrendingPlaylist> playlists = [];
      for (int i = 0; i < results.length; i++) {
        final item = results[i];
        final title = item['name']?.toString() ?? 'Playlist';
        final id = item['id']?.toString() ?? '';
        final extUrl = item['url']?.toString() ?? '';
        final artUrl = (item['artworkUrl100']?.toString() ?? '')
            .replaceAll('100x100bb', '600x600bb')
            .replaceAll('100x100', '600x600');

        // Split into 3 categories (rows) based on index
        // Split into 6 categories (rows) of 15 based on index
        String category = 'most_played_playlists';
        if (i >= 15 && i < 30) category = 'top_playlists';
        if (i >= 30 && i < 45) category = 'recent_releases_playlists';
        if (i >= 45 && i < 60) category = 'hot_tracks_playlists';
        if (i >= 60 && i < 75) category = 'new_music_playlists';
        if (i >= 75) category = 'best_hits_playlists';

        playlists.add(
          TrendingPlaylist(
            id: id,
            title: title,
            provider: 'APPLEMUSIC',
            imageUrls: [artUrl],
            owner: item['artistName']?.toString() ?? 'Apple Music',
            externalUrl: extUrl,
            trackCount: -1,
            categoryTitle: category,
          ),
        );
      }
      return playlists;
    } catch (e) {
      return [];
    }
  }

  Future<TrendingPlaylist?> fetchAppleMusicChart(
    String appleCC,
    String appCountry,
    _AppleChartType chart,
  ) async {
    const int limit = 50;
    final url = Uri.parse(
      'https://rss.marketingtools.apple.com/api/v2/$appleCC'
      '/music/${chart.type}/$limit/songs.json',
    );

    try {
      var r = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 12));

      // Simple fallback to 'us' (global) if country-specific fails
      if (r.statusCode != 200 && appleCC != 'us') {
        final fallbackUrl = Uri.parse(
          'https://rss.applemarketingtools.com/api/v2/us'
          '/music/${chart.type}/$limit/songs.json',
        );
        r = await http
            .get(fallbackUrl, headers: {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 10));
      }

      if (r.statusCode != 200) return null;

      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final feed = data['feed'] as Map<String, dynamic>? ?? {};
      final results = (feed['results'] as List?) ?? [];

      if (results.isEmpty) return null;

      final tracks = results.map<Map<String, dynamic>>((song) {
        final artUrl = (song['artworkUrl100']?.toString() ?? '')
            .replaceAll('100x100bb', '300x300bb')
            .replaceAll('100x100', '300x300');
        return {
          'title': song['name']?.toString() ?? '',
          'artist': song['artistName']?.toString() ?? '',
          'album': song['collectionName']?.toString() ?? '',
          'image': artUrl,
          'id': song['id']?.toString() ?? '',
          'provider': 'Apple Music',
          'url': song['url']?.toString() ?? '',
        };
      }).toList();

      // Use first 4 song artworks for playlist collage
      final imageUrls = tracks
          .take(4)
          .map((t) => t['image'] as String)
          .where((u) => u.isNotEmpty)
          .toList();

      // Use feed title if available, otherwise build a clean fallback
      final feedTitle = (feed['title'] as String?) ?? '';
      final playlistTitle = feedTitle.isNotEmpty
          ? feedTitle
          : '${chart.titleEn} - ${appleCC.toUpperCase()}';

      return TrendingPlaylist(
        id: 'apple_chart_${chart.type}_$appleCC',
        title: playlistTitle,
        provider: 'APPLEMUSIC',
        imageUrls: imageUrls,
        trackCount: tracks.length,
        owner: 'Apple Music',
        externalUrl: 'https://music.apple.com/$appleCC/browse',
        categoryTitle: 'top_songs',
        predefinedTracks: tracks,
      );
    } catch (e) {
      return null;
    }
  }

  /// Scrapes an Apple Music playlist page for its tracks using
  /// the embedded `serialized-server-data` JSON blob.
  Future<List<Map<String, String>>> _scrapeApplePlaylist(
    String url, {
    TrendingPlaylist? originalPlaylist,
  }) async {
    try {
      LogService().log('Scraping Apple Music playlist: $url');
      final r = await http
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Language': 'it-IT,it;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 15));

      LogService().log(
        'Apple Music response: ${r.statusCode} (${r.body.length} bytes)',
      );
      if (r.statusCode != 200) return [];

      // Forced UTF-8 decoding to handle accents correctly
      final content = utf8.decode(r.bodyBytes, allowMalformed: true);

      // ── 1. Extract serialized-server-data ──────────────────────────────────
      String? jsonStr;
      // Use a more specific regex to find the script with the exact ID
      final ssdRegExp = RegExp(
        r'<script[^>]*id=["'
        ']?serialized-server-data["'
        ']?[^>]*>(.*?)</script>',
        dotAll: true,
        caseSensitive: false,
      );
      final ssdMatch = ssdRegExp.firstMatch(content);

      if (ssdMatch != null) {
        jsonStr = ssdMatch.group(1)?.trim();
        LogService().log(
          'SSD candidate found by ID, length: ${jsonStr?.length}',
        );
      } else {
        // Fallback to the flexible search if ID-based search fails
        int idIdx = content.indexOf('serialized-server-data');
        if (idIdx != -1) {
          final scriptStart = content.lastIndexOf('<script', idIdx);
          final scriptEnd = content.indexOf('</script>', idIdx);
          if (scriptStart != -1 && scriptEnd != -1) {
            final tagContent = content.substring(scriptStart, scriptEnd);
            final dataStart = tagContent.indexOf('>') + 1;
            jsonStr = tagContent.substring(dataStart).trim();
            LogService().log(
              'SSD candidate found by string search, length: ${jsonStr.length}',
            );
          }
        }
      }

      if (jsonStr != null && jsonStr.isNotEmpty && jsonStr.startsWith('{')) {
        try {
          final root = jsonDecode(jsonStr);

          // Robust navigation: root['data'] can be a List or Map
          Map? innerData;
          final d = root['data'];
          if (d is List && d.isNotEmpty) {
            // In some versions root['data'] is a List, and each item has its own 'data'
            innerData = d[0]['data'] as Map?;
          } else if (d is Map) {
            // Standard fallback
            innerData = (d['data'] ?? d) as Map?;
          }

          final sections = (innerData?['sections'] as List?) ?? [];
          LogService().log('SSD parsed: ${sections.length} sections found');

          // ── 1.5 Extract Playlist Metadata (Title & Track Count) ────────────
          for (final s in sections) {
            if (s is Map) {
              final itemKind = s['itemKind']?.toString() ?? '';
              if (itemKind == 'containerDetailHeaderLockup' ||
                  s['id']?.toString().contains('header') == true) {
                final hItems = s['items'] as List?;
                if (hItems != null && hItems.isNotEmpty) {
                  final header = hItems[0] as Map;
                  final tCount = header['trackCount'] as int? ?? 0;
                  final pTitle = header['title']?.toString();

                  if (originalPlaylist != null) {
                    if (pTitle != null) originalPlaylist.title = pTitle;
                    originalPlaylist.trackCount = tCount;
                    LogService().log(
                      'Updated Playlist Metadata: "${originalPlaylist.title}" | tracks: ${originalPlaylist.trackCount}',
                    );
                  }
                  break;
                }
              }
            }
          }

          List? trackItems;
          for (final s in sections) {
            if (s is Map) {
              final sType = s['type']?.toString() ?? '';
              final sId = s['id']?.toString() ?? '';
              if (sType == 'track-list-section' || sId.contains('track-list')) {
                trackItems = s['items'] as List?;
                if (trackItems != null && trackItems.isNotEmpty) {
                  LogService().log(
                    '  Successfully located tracks in section: $sId',
                  );
                  break;
                }
              }
            }
          }

          if (trackItems == null) {
            for (final s in sections) {
              if (s is Map) {
                final items = s['items'] as List?;
                if (items != null && items.length > 5) {
                  trackItems = items;
                  break;
                }
              }
            }
          }

          if (trackItems != null && trackItems.isNotEmpty) {
            // Updated: Fallback trackCount if the header metadata was not found
            if (originalPlaylist != null &&
                (originalPlaylist.trackCount == -1 ||
                    originalPlaylist.trackCount == 0)) {
              originalPlaylist.trackCount = trackItems.length;
              LogService().log(
                'Updated Playlist Metadata (Track List Fallback): '
                '"${originalPlaylist.title}" | tracks: ${originalPlaylist.trackCount}',
              );
            }
            return trackItems.map<Map<String, String>>((item) {
              final title = item['title']?.toString() ?? 'Unknown';

              // 1. Try subtitleLinks -> title (as suggested by USER)
              String? artist;
              final subLinks = item['subtitleLinks'] as List?;
              if (subLinks != null && subLinks.isNotEmpty) {
                artist = subLinks[0]['title']?.toString();
              }

              // 2. Fallback to artistName
              artist ??= item['artistName']?.toString();

              // 3. Last fallback
              artist ??= 'Various Artists';

              String artUrl = '';
              final artDict = item['artwork']?['dictionary'];
              if (artDict is Map) {
                artUrl = (artDict['url']?.toString() ?? '')
                    .replaceAll('{w}', '500')
                    .replaceAll('{h}', '500')
                    .replaceAll('{f}', 'jpg');
              }
              String songUrl = '';
              final paItems = item['playAction']?['items'] as List?;
              if (paItems != null && paItems.isNotEmpty) {
                songUrl =
                    paItems[0]['contentDescriptor']?['url']?.toString() ?? '';
              }
              return {
                'title': title,
                'artist': artist,
                'album': '',
                'image': artUrl,
                'id': songUrl.isNotEmpty
                    ? songUrl.split('/').last
                    : 'apple_${title.hashCode}',
                'provider': 'Apple Music',
                'url': songUrl,
              };
            }).toList();
          }
        } catch (e) {
          LogService().log('SSD Parse error: $e');
        }
      }

      // ── 2. Fallback: JSON-LD ───────────────────────────────────────────
      LogService().log('SSD failed or empty, trying JSON-LD strategy...');
      // Prioritize the specific ID mentioned by the user
      final ldRegExp = RegExp(
        r'<script[^>]*id=["'
        ']?schema:music-playlist["'
        ']?[^>]*>(.*?)</script>',
        dotAll: true,
        caseSensitive: false,
      );
      var ldMatches = ldRegExp.allMatches(content);

      if (ldMatches.isEmpty) {
        // Fallback to generic LD+JSON if the specific ID isn't found
        final genericLdRegExp = RegExp(
          r'<script[^>]*type=.?application/ld\+json.?[^>]*>(.*?)</script>',
          dotAll: true,
          caseSensitive: false,
        );
        ldMatches = genericLdRegExp.allMatches(content);
      }
      for (final m in ldMatches) {
        try {
          final data = jsonDecode(m.group(1)!.trim());
          final tracks = (data['track'] as List?) ?? [];
          if (tracks.isNotEmpty) {
            LogService().log(
              'Apple Music JSON-LD strategy success: ${tracks.length} tracks found',
            );
            return tracks.map<Map<String, String>>((t) {
              String artistName = 'Unknown Artist';
              final ba = t['byArtist'];
              if (ba is List && ba.isNotEmpty) {
                artistName = ba[0]['name']?.toString() ?? artistName;
              } else if (ba is Map) {
                artistName = ba['name']?.toString() ?? artistName;
              } else if (t['author'] != null) {
                artistName = t['author']['name']?.toString() ?? artistName;
              }

              return {
                'title': t['name']?.toString() ?? 'Unknown',
                'artist': artistName,
                'album': '',
                'image':
                    (t['audio']?['thumbnailUrl'] ?? t['thumbnailUrl'] ?? '')
                        .toString()
                        .replaceAll('100x100', '500x500'),
                'id':
                    t['url']?.toString().split('/').last ??
                    'apple_ld_${t['name'].hashCode}',
                'provider': 'Apple Music',
                'url': t['url']?.toString() ?? '',
              };
            }).toList();
          }
        } catch (e) {
          continue;
        }
      }

      LogService().log('All scraping strategies failed for $url');
      return [];
    } catch (e) {
      LogService().log('Scrape Apple Playlist error: $e');
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // YouTube
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<TrendingPlaylist>> _searchYouTube(String query) async {
    try {
      final searchList = await _yt.search.searchContent(
        query,
        filter: TypeFilters.playlist,
      );
      return searchList.take(25).map((result) {
        final p = result as SearchPlaylist;
        return TrendingPlaylist(
          id: p.id.value,
          title: p.title,
          provider: 'YouTube',
          imageUrls: p.thumbnails.isNotEmpty
              ? [p.thumbnails.last.url.toString()]
              : [],
          externalUrl: 'https://www.youtube.com/playlist?list=${p.id.value}',
          trackCount: p.videoCount,
        );
      }).toList();
    } catch (e) {
      LogService().log('YouTube search error: $e');
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Audius
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<TrendingPlaylist>> _searchAudius(String query) async {
    try {
      final url =
          'https://api.audius.co/v1/playlists/search'
          '?query=${Uri.encodeComponent(query)}&app_name=RadioStreamApp';
      final r = await http.get(Uri.parse(url));
      if (r.statusCode == 200) {
        final list = (jsonDecode(r.body)['data'] as List?) ?? [];
        return list.take(25).map((item) {
          final artwork = item['artwork'];
          String? img;
          if (artwork is Map) {
            img = artwork['1000x1000'] ?? artwork['480x480'];
          }
          final tCount =
              item['track_count'] ??
              (item['playlist_contents'] as List?)?.length ??
              1;
          return TrendingPlaylist(
            id: item['id'].toString(),
            title: item['playlist_name'],
            provider: 'AUDIUS',
            imageUrls: img != null ? [img] : [],
            trackCount: tCount,
            owner: item['user']?['name'],
          );
        }).toList();
      }
    } catch (e) {
      LogService().log('Audius error: $e');
    }
    return [];
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Deezer
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<TrendingPlaylist>> _searchDeezer(String query) async {
    try {
      final url =
          'https://api.deezer.com/search/playlist'
          '?q=${Uri.encodeComponent(query)}&limit=25';
      final r = await http.get(Uri.parse(url));
      if (r.statusCode == 200) {
        final list = (jsonDecode(r.body)['data'] as List?) ?? [];
        return list.map((item) {
          return TrendingPlaylist(
            id: item['id'].toString(),
            title: item['title'],
            provider: 'DEEZER',
            imageUrls: item['picture_medium'] != null
                ? [item['picture_medium']]
                : [],
            trackCount: item['nb_tracks'] ?? 0,
            owner: item['user']?['name'],
            externalUrl: item['link'],
          );
        }).toList();
      }
    } catch (e) {
      LogService().log('Deezer error: $e');
    }
    return [];
  }

  // ─────────────────────────────────────────────────────────────────────────

  // ─────────────────────────────────────────────────────────────────────────
  // getPlaylistTracks
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<Map<String, String>>> getPlaylistTracks(
    TrendingPlaylist playlist,
  ) async {
    try {
      // 1. Pre-fetched tracks (AI, Background Scraped Apple Music, etc.)
      if (playlist.predefinedTracks != null &&
          playlist.predefinedTracks!.isNotEmpty) {
        return playlist.predefinedTracks!
            .map((t) => t.map((k, v) => MapEntry(k, v.toString())))
            .toList();
      }

      // 2. Apple Music Handling
      if (playlist.provider == 'APPLEMUSIC') {
        LogService().log(
          '[PL-TRACKS] Apple Music request for: ${playlist.title} (ID: ${playlist.id})',
        );

        // Try scraping if URL exists
        if (playlist.externalUrl != null && playlist.externalUrl!.isNotEmpty) {
          final tracks = await _scrapeApplePlaylist(
            playlist.externalUrl!,
            originalPlaylist: playlist,
          );
          if (tracks.isNotEmpty) return tracks;
          LogService().log(
            '[PL-TRACKS] Scraper failed or empty for URL: ${playlist.externalUrl}',
          );
        }

        // Fallback for chart-based virtual playlists
        if (playlist.id.startsWith('apple_chart_')) {
          final parts = playlist.id.split('_');
          final appleCC = parts.length >= 4 ? parts.last : 'us';
          final chartType = parts.length >= 3 ? parts[2] : 'most-played';
          final chart = TrendingService.appleChartTypes.firstWhere(
            (c) => c.type == chartType && !c.isPlaylist,
            orElse: () => TrendingService.appleChartTypes.first,
          );
          final result = await fetchAppleMusicChart(
            appleCC,
            appleCC.toUpperCase(),
            chart,
          );
          if (result?.predefinedTracks != null) {
            return result!.predefinedTracks!
                .map((t) => t.map((k, v) => MapEntry(k, v.toString())))
                .toList();
          }
        }
        return [];
      }

      // 3. YouTube Handling
      if (playlist.provider == 'YouTube') {
        final videos = await _yt.playlists.getVideos(playlist.id).toList();
        return videos
            .map(
              (v) => {
                'title': v.title,
                'artist': v.author,
                'album': '',
                'image': v.thumbnails.highResUrl,
                'id': v.id.value,
                'provider': 'YouTube',
              },
            )
            .toList();
      }

      // 4. Audius Handling
      if (playlist.provider == 'AUDIUS') {
        final url =
            'https://api.audius.co/v1/playlists/${playlist.id}/tracks?app_name=RadioStreamApp';
        final r = await http.get(Uri.parse(url));
        if (r.statusCode == 200) {
          final list = (jsonDecode(r.body)['data'] as List?) ?? [];
          return list
              .map(
                (t) => {
                  'title': t['title'].toString(),
                  'artist': t['user']['name'].toString(),
                  'album': '',
                  'image': t['artwork']?['480x480']?.toString() ?? '',
                  'id': t['id'].toString(),
                  'provider': 'Audius',
                },
              )
              .toList();
        }
      }

      // 5. Deezer Handling
      if (playlist.provider == 'DEEZER') {
        final url = 'https://api.deezer.com/playlist/${playlist.id}/tracks';
        final r = await http.get(Uri.parse(url));
        if (r.statusCode == 200) {
          final list = (jsonDecode(r.body)['data'] as List?) ?? [];
          return list.map((t) {
            final artist = t['artist'];
            final album = t['album'];
            return {
              'title': t['title']?.toString() ?? 'Unknown',
              'artist': artist?['name']?.toString() ?? 'Unknown',
              'album': album?['title']?.toString() ?? '',
              'image': album?['cover_medium']?.toString() ?? '',
              'id': t['id'].toString(),
              'provider': 'Deezer',
              'preview': t['preview']?.toString() ?? '',
            };
          }).toList();
        }
      }
    } catch (e) {
      LogService().log('getPlaylistTracks ${playlist.provider} error: $e');
    }
    return [];
  }
}

/// Describes an Apple Music RSS chart endpoint.
class _AppleChartType {
  final String type;
  final String titleEn;
  final String titleKey;
  final bool isPlaylist;
  const _AppleChartType({
    required this.type,
    required this.titleEn,
    required this.titleKey,
    this.isPlaylist = false,
  });
}
