import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class TrendingPlaylist {
  final String id;
  final String title;
  final String provider; // YouTube, Audius, etc.
  final List<String> imageUrls; // For collage (4 items)
  final String? externalUrl;
  final int trackCount;
  final String? owner;
  final List<Map<String, dynamic>>? predefinedTracks;

  TrendingPlaylist({
    required this.id,
    required this.title,
    required this.provider,
    required this.imageUrls,
    this.externalUrl,
    this.trackCount = 0,
    this.owner,
    this.predefinedTracks,
  });
}

class TrendingService {
  final YoutubeExplode _yt = YoutubeExplode();

  // Basic cache to avoid hammering APIs
  final Map<String, List<TrendingPlaylist>> _cache = {};

  TrendingService();

  void dispose() {
    _yt.close();
  }

  Future<List<TrendingPlaylist>> searchTrending(
    String country,
    String year, {
    String? customQuery,
  }) async {
    final String query = customQuery ?? "Top 50 - $country";
    final cacheKey = query.toLowerCase();

    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    final results = await Future.wait([
      _searchYouTube(customQuery ?? "Top $country $year"),
      _searchAudius(customQuery ?? country),
      _searchDeezer(customQuery ?? "Top $country"),
    ]);

    final Set<String> seenImages = {};
    final finalResults = <TrendingPlaylist>[];

    for (var sublist in results) {
      int countForThisSource = 0;
      final int maxForSource = 10;

      for (var p in sublist) {
        if (p.trackCount <= 0) continue;

        final imageUrl = p.imageUrls.isNotEmpty ? p.imageUrls.first : null;
        if (imageUrl != null) {
          if (seenImages.contains(imageUrl)) continue;
        }

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



  Future<List<TrendingPlaylist>> _searchYouTube(String query) async {
    try {
      final searchList = await _yt.search.searchContent(
        query,
        filter: TypeFilters.playlist,
      );
      return searchList.take(25).map((result) {
        final p = result as SearchPlaylist;
        // YouTube provides thumbnails.
        return TrendingPlaylist(
          id: p.id.value,
          title: p.title,
          provider: 'YouTube',
          imageUrls: p.thumbnails.isNotEmpty
              ? [p.thumbnails.last.url.toString()]
              : [],
          externalUrl: 'https://www.youtube.com/playlist?list=${p.id.value}',
          trackCount: p.videoCount,
          owner: null, // SearchPlaylist doesn't expose channel name
        );
      }).toList();
    } catch (e) {
      print("Error searching YouTube: $e");
      return [];
    }
  }

  Future<List<TrendingPlaylist>> _searchAudius(String query) async {
    try {
      // Audius public API
      final url =
          "https://api.audius.co/v1/playlists/search?query=${Uri.encodeComponent(query)}&app_name=RadioStreamApp";
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final dataList = data['data'] as List?;
        if (dataList != null) {
          return dataList.take(25).map((item) {
            final artwork = item['artwork']; // Map of sizes
            String? imgUrl;
            if (artwork != null && artwork is Map) {
              imgUrl = artwork['1000x1000'] ?? artwork['480x480'];
            }

            final tCount =
                item['track_count'] ??
                (item['playlist_contents'] as List?)?.length ??
                1;

            return TrendingPlaylist(
              id: item['id'].toString(),
              title: item['playlist_name'],
              provider: 'AUDIUS',
              imageUrls: imgUrl != null ? [imgUrl] : [],
              trackCount: tCount,
              owner: item['user']?['name'],
            );
          }).toList();
        }
      }
    } catch (e) {
      print("Error searching Audius: $e");
    }
    return [];
  }

  Future<List<TrendingPlaylist>> _searchDeezer(String query) async {
    try {
      final url =
          "https://api.deezer.com/search/playlist?q=${Uri.encodeComponent(query)}&limit=25";
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final dataList = data['data'] as List?;
        if (dataList != null) {
          return dataList.map((item) {
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
      }
    } catch (e) {
      print("Error searching Deezer: $e");
    }
    return [];
  }

  Future<List<Map<String, String>>> getPlaylistTracks(
    TrendingPlaylist playlist,
  ) async {
    try {
      if (playlist.provider == 'AI' && playlist.predefinedTracks != null) {
        return playlist.predefinedTracks!
            .map((t) => t.map((k, v) => MapEntry(k, v.toString())))
            .toList();

      } else if (playlist.provider == 'YouTube') {
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
      } else if (playlist.provider == 'AUDIUS') {
        final url =
            "https://api.audius.co/v1/playlists/${playlist.id}/tracks?app_name=RadioStreamApp";
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final list = data['data'] as List?;
          if (list != null) {
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
      } else if (playlist.provider == 'DEEZER') {
        final url = "https://api.deezer.com/playlist/${playlist.id}/tracks";
        final response = await http.get(Uri.parse(url));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final dataList = data['data'] as List?;
          if (dataList != null) {
            return dataList.map((t) {
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
      }
    } catch (e) {
      print("Error fetching tracks for ${playlist.provider}: $e");
    }
    return [];
  }
}
