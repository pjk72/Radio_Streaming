import 'dart:math';
import '../models/saved_song.dart';
import '../services/music_metadata_service.dart';
import '../services/trending_service.dart';

class AIRecommendationService {
  final MusicMetadataService _metadataService = MusicMetadataService();
  final Random _random = Random();

  final List<String> _discoveryKeywords = [
    'Pop',
    'Rock',
    '80s',
    '90s',
    '70s',
    'Workout',
    'Chill',
    'Acoustic',
    'Hip Hop',
    'EDM',
    'Jazz',
    'R&B',
    'Classical',
    'Indie',
    'Alternative',
    'Country',
    'Reggae',
    'Blues',
    'Soul',
    'Funk',
    'Disco',
    'Metal',
    'Punk',
    'Techno',
    'House',
    'Trance',
    'Ambient',
    'Lofi',
    'Party',
    'Focus',
    'Sleep',
    'Romance',
    'Gaming',
    'Gym',
    'Running',
    'Latin',
    'K-Pop',
    'Afrobeat',
    'Reggaeton',
  ];

  Future<List<TrendingPlaylist>> generateDiscoverWeekly({
    required Map<String, int> phoneHistory,
    required Map<String, int> aaHistory,
    required Map<String, SavedSong> historyMetadata,
    int targetCount = 15, // Increased default as per RadioProvider
    String? countryName,
  }) async {
    final Map<String, int> combinedHistory = {};

    phoneHistory.forEach((id, count) {
      combinedHistory[id] = (combinedHistory[id] ?? 0) + count;
    });

    aaHistory.forEach((id, count) {
      combinedHistory[id] = (combinedHistory[id] ?? 0) + count;
    });

    final Set<String> usedGenres = {};
    if (countryName != null && countryName.isNotEmpty) {
      // We still keep country as a special "genre" for the first playlist
    }

    if (combinedHistory.isEmpty || historyMetadata.isEmpty) {
      final genericPlaylists = await _generateGenericDiscoverPlaylists(
        targetCount,
        {},
      );
      if (countryName != null && countryName.isNotEmpty) {
        final cp = await _generateCountryPlaylist(countryName);
        if (cp != null) genericPlaylists.insert(0, cp);
      }
      return genericPlaylists;
    }

    // NEW LOGIC: Detect Top Genres from history
    // 1. Get top unique songs from history
    final sortedHistory = combinedHistory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final int sampleLimit = 20;
    final List<String> topIds = sortedHistory
        .take(sampleLimit)
        .map((e) => e.key)
        .toList();

    final Map<String, int> genreWeights = {};
    final Map<String, String> songToGenre = {};
    final Map<String, String> artistToGenre = {};

    // 2. Fetch genres for top songs (Parallel)
    final List<Future<void>> genreFetches = [];
    for (var id in topIds) {
      final song = historyMetadata[id];
      if (song != null) {
        genreFetches.add(() async {
          try {
            // Use metadata service to find the actual genre
            final results = await _metadataService.searchSongs(
              query: "${song.title} ${song.artist}",
              limit: 1,
            );
            if (results.isNotEmpty) {
              final rawGenre = results.first.genre;
              final normalized = _normalizeGenre(rawGenre);
              songToGenre[id] = normalized;

              final weight = combinedHistory[id] ?? 1;
              genreWeights[normalized] =
                  (genreWeights[normalized] ?? 0) + weight;

              // Map artist too for broader heuristic
              final firstArtist = song.artist.split(',').first.trim();
              if (firstArtist.isNotEmpty) {
                artistToGenre[firstArtist] = normalized;
              }
            }
          } catch (_) {}
        }());
      }
    }
    await Future.wait(
      genreFetches,
    ).timeout(const Duration(seconds: 10), onTimeout: () => []);

    final sortedGenres = genreWeights.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final List<TrendingPlaylist> playlists = [];
    final Set<String> recommendedIds = combinedHistory.keys.toSet();

    // Add Country Playlist first if available
    if (countryName != null && countryName.isNotEmpty) {
      final cp = await _generateCountryPlaylist(countryName);
      if (cp != null) {
        playlists.add(cp);
        for (var t in cp.predefinedTracks ?? []) {
          recommendedIds.add(t['id']);
        }
      }
    }

    // 3. Generate playlists for Top Genres
    for (var genreEntry in sortedGenres) {
      if (playlists.length >= targetCount) break;

      final genre = genreEntry.key;
      if (usedGenres.contains(genre)) continue;
      usedGenres.add(genre);

      try {
        // Collect existing songs from history belonging to this genre
        final List<Map<String, dynamic>> historyTracks = [];
        combinedHistory.forEach((id, count) {
          final song = historyMetadata[id];
          if (song == null) return;

          bool matches = false;
          if (songToGenre[id] == genre) {
            matches = true;
          } else {
            // Check artist heuristic
            final firstArtist = song.artist.split(',').first.trim();
            if (artistToGenre[firstArtist] == genre) {
              matches = true;
            }
          }

          if (matches) {
            historyTracks.add({
              'title': song.title,
              'artist': song.artist,
              'album': song.album,
              'image': song.artUri ?? '',
              'id': song.id,
              'provider': 'AI',
              'fromHistory': true,
            });
          }
        });

        // Fetch new recommendations for this genre
        final results = await _metadataService.searchSongs(
          query: "Popular $genre",
          limit: 25,
        );

        final List<Map<String, dynamic>> discoveryTracks = [];
        final imageUrls = <String>[];
        final artistCounts = <String, int>{};

        // Populate imagery from history first to make it feel familiar
        for (var t in historyTracks) {
          if (t['image'] != null &&
              t['image'].isNotEmpty &&
              imageUrls.length < 4) {
            if (!imageUrls.contains(t['image'])) imageUrls.add(t['image']);
          }
        }

        for (var result in results) {
          if (!recommendedIds.contains(result.song.id)) {
            final trackArtist = result.song.artist;
            final count = artistCounts[trackArtist] ?? 0;
            if (count >= 2) continue; // Variation

            discoveryTracks.add({
              'title': result.song.title,
              'artist': trackArtist,
              'album': result.song.album,
              'image': result.song.artUri ?? '',
              'id': result.song.id,
              'provider': 'AI',
            });
            artistCounts[trackArtist] = count + 1;

            if (result.song.artUri != null && result.song.artUri!.isNotEmpty) {
              if (!imageUrls.contains(result.song.artUri) &&
                  imageUrls.length < 4) {
                imageUrls.add(result.song.artUri!);
              }
            }
          }
        }

        // Combine: History (top) + Discovery
        historyTracks.sort((a, b) {
          final countA = combinedHistory[a['id']] ?? 0;
          final countB = combinedHistory[b['id']] ?? 0;
          return countB.compareTo(countA);
        });

        final finalTracks = [...historyTracks.take(5), ...discoveryTracks];
        finalTracks.shuffle(_random);

        if (finalTracks.length >= 3) {
          playlists.add(
            TrendingPlaylist(
              id: "ai_playlist_genre_${genre.toLowerCase().replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}",
              title: "Mix $genre",
              provider: 'AI',
              imageUrls: imageUrls,
              trackCount: finalTracks.length,
              owner: "AI Discovery",
              predefinedTracks: finalTracks.take(20).toList(),
            ),
          );

          // Add recommended IDs to avoid duplicates in other playlists
          for (var t in finalTracks) {
            recommendedIds.add(t['id']);
          }
        }
      } catch (e) {
        // Skip this genre
      }
    }

    // Fallback to generic if we don't have enough
    if (playlists.length < targetCount) {
      final additional = await _generateGenericDiscoverPlaylists(
        targetCount - playlists.length,
        usedGenres,
      );
      playlists.addAll(additional);
    }

    // NOTE: We don't shuffle the entire list anymore to keep the most relevant (top genres) first
    // as it usually feels better for "Per Te".
    return playlists;
  }

  String _normalizeGenre(String rawGenre) {
    final lower = rawGenre.toLowerCase();
    for (var keyword in _discoveryKeywords) {
      if (lower.contains(keyword.toLowerCase())) {
        return keyword;
      }
    }
    // Return capitalized first letter if not in list
    if (rawGenre.isEmpty) return "Pop";
    return rawGenre[0].toUpperCase() + rawGenre.substring(1).toLowerCase();
  }

  Future<List<TrendingPlaylist>> _generateGenericDiscoverPlaylists(
    int count,
    Set<String> usedKeywords,
  ) async {
    final List<TrendingPlaylist> playlists = [];

    for (int i = 0; i < count; i++) {
      final availableKeywords = _discoveryKeywords
          .where((k) => !usedKeywords.contains(k))
          .toList();
      if (availableKeywords.isEmpty) break;

      final keyword =
          availableKeywords[_random.nextInt(availableKeywords.length)];
      usedKeywords.add(keyword);

      try {
        final results = await _metadataService.searchSongs(
          query: 'Popular $keyword',
          limit: 15,
        );
        final uniqueValidTracks = <Map<String, dynamic>>[];
        final imageUrls = <String>[];
        final artistCounts = <String, int>{};

        for (var result in results) {
          final trackArtist = result.song.artist;
          final count = artistCounts[trackArtist] ?? 0;
          if (count >= 3) continue;

          uniqueValidTracks.add({
            'title': result.song.title,
            'artist': trackArtist,
            'album': result.song.album,
            'image': result.song.artUri ?? '',
            'id': result.song.id,
            'provider': 'AI',
          });
          artistCounts[trackArtist] = count + 1;

          if (result.song.artUri != null && result.song.artUri!.isNotEmpty) {
            if (!imageUrls.contains(result.song.artUri) &&
                imageUrls.length < 4) {
              imageUrls.add(result.song.artUri!);
            }
          }

          if (uniqueValidTracks.length >= 15) break;
        }

        if (uniqueValidTracks.isNotEmpty) {
          playlists.add(
            TrendingPlaylist(
              id: "ai_playlist_generic_${DateTime.now().millisecondsSinceEpoch}_$i",
              title: "Mix $keyword",
              provider: 'AI',
              imageUrls: imageUrls,
              trackCount: uniqueValidTracks.length,
              owner: "AI Discovery",
              predefinedTracks: uniqueValidTracks,
            ),
          );
        }
      } catch (e) {}
    }

    return playlists;
  }

  Future<TrendingPlaylist?> _generateCountryPlaylist(String countryName) async {
    try {
      final results = await _metadataService.searchSongs(
        query: 'Top Hits $countryName',
        limit: 15,
      );
      final uniqueValidTracks = <Map<String, dynamic>>[];
      final imageUrls = <String>[];
      final artistCounts = <String, int>{};

      for (var result in results) {
        final trackArtist = result.song.artist;
        final count = artistCounts[trackArtist] ?? 0;
        if (count >= 3) continue;

        uniqueValidTracks.add({
          'title': result.song.title,
          'artist': trackArtist,
          'album': result.song.album,
          'image': result.song.artUri ?? '',
          'id': result.song.id,
          'provider': 'AI',
        });
        artistCounts[trackArtist] = count + 1;

        if (result.song.artUri != null && result.song.artUri!.isNotEmpty) {
          if (!imageUrls.contains(result.song.artUri) && imageUrls.length < 4) {
            imageUrls.add(result.song.artUri!);
          }
        }
        if (uniqueValidTracks.length >= 15) break;
      }

      if (uniqueValidTracks.isNotEmpty) {
        return TrendingPlaylist(
          id: "ai_playlist_country_${DateTime.now().millisecondsSinceEpoch}",
          title: "Mix $countryName",
          provider: 'AI',
          imageUrls: imageUrls,
          trackCount: uniqueValidTracks.length,
          owner: "AI Discovery",
          predefinedTracks: uniqueValidTracks,
        );
      }
    } catch (e) {}
    return null;
  }
}
