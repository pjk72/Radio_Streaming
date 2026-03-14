import '../models/saved_song.dart';
import 'music_metadata_service.dart';
import 'trending_service.dart';

class AIRecommendationService {
  final MusicMetadataService _metadataService = MusicMetadataService();

  /// Main entry point: Generates a list of tailored playlists
  Future<List<TrendingPlaylist>> generateDiscoverWeekly({
    required Map<String, int> phoneHistory,
    required Map<String, int> aaHistory,
    required Map<String, SavedSong> historyMetadata,
    List<SavedSong> favorites = const [],
    int targetCount = 25,
    String? countryCode,
    String? countryName,
  }) async {
    final Set<String> globalSeenIds = {};
    final List<TrendingPlaylist> playlists = [];

    // Combine history for easy access
    final List<SavedSong> userHistoryMetadata = historyMetadata.values.toList();
    
    // Sort history by play count (Total)
    final List<SavedSong> sortedHistory = List.from(userHistoryMetadata);
    sortedHistory.sort((a, b) {
      final countA = (phoneHistory[a.id] ?? 0) + (aaHistory[a.id] ?? 0);
      final countB = (phoneHistory[b.id] ?? 0) + (aaHistory[b.id] ?? 0);
      return countB.compareTo(countA);
    });

    // 0. PERSONAL MIXES (New Dynamic Sections)
    // 0.1 "Weekly Mix" (Mix Settimanale) - Most played
    if (sortedHistory.isNotEmpty) {
      final weeklyTracks =
          sortedHistory.take(20).map((s) => _mapToTrack(s, true)).toList();
      await _recoverMissingImages(weeklyTracks); // Recover missing images
      playlists.add(_assemblePlaylist(
        'Weekly Mix',
        weeklyTracks,
        owner: "Il tuo mix settimanale",
      ));
      for (var t in weeklyTracks) globalSeenIds.add(t['id']);
    }

    // 0.2 "Discovery Mix" (Scoperta) - Similar to top artists
    if (sortedHistory.isNotEmpty) {
      final topArtist = sortedHistory.first.artist.split(',').first.trim();
      final discovery = await _createDynamicPlaylist(
        title: 'Discovery Mix',
        query: topArtist,
        countryCode: countryCode,
        countryName: countryName,
        history: [], // Forcing new discovery
        globalSeenIds: globalSeenIds,
      );
      if (discovery != null) playlists.add(discovery);
    }

    // 1. GENRE MIXES & DECADES (Standard Sections)
    final sections = [
      {'title': 'Mix Pop', 'query': 'Pop', 'genre': 'Pop'},
      {'title': 'Mix Rock', 'query': 'Rock', 'genre': 'Rock'},
      {'title': 'Mix Dance', 'query': 'Dance', 'genre': 'Dance'},
      {'title': 'Mix Latin', 'query': 'Latin', 'genre': 'Latin'},
      {'title': 'Mix Chillout', 'query': 'Chillout', 'genre': 'Chillout'},
      {'title': 'Latest Hits', 'query': 'Latest Hits', 'period': 'Latest'},
      {'title': '90s Hits', 'query': '1990s', 'period': '1990s'},
      {'title': '80s Hits', 'query': '1980s', 'period': '1980s'},
      {'title': '70s Hits', 'query': '1970s', 'period': '1970s'},
      {'title': '60s Hits', 'query': '1960s', 'period': '1960s'},
    ];

    for (var sec in sections) {
      final p = await _createDynamicPlaylist(
        title: sec['title']!,
        query: sec['query']!,
        countryCode: countryCode,
        countryName: countryName,
        history: sortedHistory, // Pass sorted history to allow injection
        globalSeenIds: globalSeenIds,
        periodFilter: sec['period'],
        genreFilter: sec['genre'],
      );
      if (p != null) playlists.add(p);
    }

    return playlists;
  }

  /// Creates a single playlist by blending history and search results
  Future<TrendingPlaylist?> _createDynamicPlaylist({
    required String title,
    required String query,
    required List<SavedSong> history,
    required Set<String> globalSeenIds,
    String? countryCode,
    String? countryName,
    String? periodFilter,
    String? genreFilter,
  }) async {
    final List<Map<String, dynamic>> tracks = [];
    final Set<String> playlistSeenIds = {};
    final Set<String> artists = {};

    // 1. FILL FROM USER HISTORY (Natural Match)
    for (var s in history) {
      if (tracks.length >= 10) break; 
      if (globalSeenIds.contains(s.id)) continue;

      bool matches = false;
      // Period matching
      if (periodFilter != null && _isSongInPeriod(s, periodFilter)) {
        matches = true;
      } 
      // Genre matching (Attempt)
      else if (genreFilter != null) {
        // If we don't have genre info, we can't be 100% sure, 
        // but we can assume if the user listens to an artist a lot and we are in their mix, 
        // it's a good candidate if we don't have other filters.
        // For now, let's just use period as the primary hard filter for history.
      }
      // General match for Discovery/Query based mixes
      else if (title == 'Discovery Mix') {
        // We don't want history in discovery
      }
      else {
        // For generic genre mixes without period, we take some history items to make it feel "personal"
        // but we limit it.
        if (tracks.length < 5) matches = true;
      }

      if (matches) {
        tracks.add(_mapToTrack(s, true));
        playlistSeenIds.add(s.id);
        artists.add(s.artist.split(',').first.trim());
      }
    }

    // 2. FILL FROM SEARCH (Local then Global)
    final searchQueries = title == 'Discovery Mix' 
        ? ["Similar to $query", "$query radio", "More like $query"]
        : _generateSmartQueries(query, countryName, countryCode);

    for (var q in searchQueries) {
      if (tracks.length >= 25) break;

      final results = await _metadataService.searchSongs(
        query: q,
        limit: 40,
        countryCode: q.contains(countryName ?? '') ? countryCode : null,
      );

      for (var r in results) {
        final s = r.song;
        if (tracks.length >= 25) break;
        if (playlistSeenIds.contains(s.id) || globalSeenIds.contains(s.id))
          continue;

        // Filter by period if necessary
        if (periodFilter != null && !_isSongInPeriod(s, periodFilter)) continue;

        // Diversity check
        final artist = s.artist.split(',').first.trim();
        if (artists.contains(artist) && tracks.length < 15) continue;

        tracks.add(_mapToTrack(s, false));
        playlistSeenIds.add(s.id);
        artists.add(artist);
      }
    }

    if (tracks.length < 5) return null;
    
    await _recoverMissingImages(tracks); // Recover missing images

    globalSeenIds.addAll(playlistSeenIds);
    return _assemblePlaylist(title, tracks);
  }

  List<String> _generateSmartQueries(
    String base,
    String? country,
    String? code,
  ) {
    if (base == 'Latest Hits') {
      final List<String> q = ["Today Hits"];
      if (country != null) {
        q.insert(0, "$country Hits");
        q.insert(1, "Top $country");
      }
      return q;
    }

    if (base == 'Latin') {
      final year = DateTime.now().year;
      final prevYear = year - 1;
      return [
        "Top Latin $year",
        "Top Latin $prevYear",
        "Top Merengue Hits",
        "Top Salsa Hits",
        "Top Latin Pop",
      ];
    }

    final List<String> q = ["$base Hits"];
    if (country != null) {
      q.insert(0, "$base $country");
    }
    return q;
  }

  bool _isSongInPeriod(SavedSong song, String period) {
    final yearStr = song.releaseDate?.split('-').first ?? '0';
    final year = int.tryParse(yearStr) ?? 0;

    if (period == 'Latest') return year >= 2020;

    final pYear = int.tryParse(period.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    if (pYear > 0) return year >= pYear && year < pYear + 10;

    return true;
  }

  Map<String, dynamic> _mapToTrack(SavedSong s, bool fromHistory) => {
    'title': s.title,
    'artist': s.artist,
    'album': s.album,
    'image': s.artUri ?? '',
    'id': s.id,
    'provider': 'AI',
    'fromHistory': fromHistory,
    if (s.youtubeUrl != null) 'youtubeUrl': s.youtubeUrl,
  };

  TrendingPlaylist _assemblePlaylist(
    String title,
    List<Map<String, dynamic>> tracks, {
    String owner = "AI Discovery",
  }) {
    return TrendingPlaylist(
      id: "ai_${title.hashCode}_${DateTime.now().millisecond}",
      title: title,
      provider: 'AI',
      trackCount: tracks.length,
      owner: owner,
      predefinedTracks: tracks,
      imageUrls: tracks
          .map((t) => t['image'].toString())
          .where((i) => i.isNotEmpty)
          .take(4)
          .toList(),
    );
  }

  /// Proactively recovers missing images for a list of tracks
  Future<void> _recoverMissingImages(List<Map<String, dynamic>> tracks) async {
    final List<Future<void>> futures = [];
    // Limit recovery to first 15 tracks to keep it fast
    for (var i = 0; i < tracks.length && i < 15; i++) {
      final t = tracks[i];
      if (t['image'] == null || t['image'].toString().isEmpty) {
        futures.add(() async {
          try {
            final query = "${t['artist']} ${t['title']}";
            final results = await _metadataService.searchSongs(
              query: query,
              limit: 1,
            );
            if (results.isNotEmpty && results.first.song.artUri != null) {
              t['image'] = results.first.song.artUri;
            }
          } catch (_) {}
        }());
      }
    }

    if (futures.isNotEmpty) {
      // Don't wait more than 3 seconds for recovery
      await Future.wait(futures).timeout(
        const Duration(seconds: 3),
        onTimeout: () => [],
      );
    }
  }
}
