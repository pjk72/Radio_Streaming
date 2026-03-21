import 'dart:math';
import '../models/saved_song.dart';
import 'music_metadata_service.dart';
import 'trending_service.dart';
import '../l10n/app_translations.dart';

class AIRecommendationService {
  final MusicMetadataService _metadataService = MusicMetadataService();

  /// Main entry point: Generates a list of tailored playlists
  /// Generates a list of tailored playlists (Backward compatibility)
  Future<List<TrendingPlaylist>> generateDiscoverWeekly({
    required Map<String, int> phoneHistory,
    required Map<String, int> aaHistory,
    required Map<String, SavedSong> historyMetadata,
    List<dynamic> weeklyLog = const [],
    List<SavedSong> favorites = const [],
    int targetCount = 25,
    String? countryCode,
    String? countryName,
    String languageCode = 'en',
  }) async {
    final List<TrendingPlaylist> playlists = [];
    await for (final playlist in generateDiscoverWeeklyStream(
      phoneHistory: phoneHistory,
      aaHistory: aaHistory,
      historyMetadata: historyMetadata,
      weeklyLog: weeklyLog,
      favorites: favorites,
      targetCount: targetCount,
      countryCode: countryCode,
      countryName: countryName,
      languageCode: languageCode,
    )) {
      playlists.add(playlist);
    }
    return playlists;
  }

  /// Main entry point: yields each tailored playlist as it's ready
  Stream<TrendingPlaylist> generateDiscoverWeeklyStream({
    required Map<String, int> phoneHistory,
    required Map<String, int> aaHistory,
    required Map<String, SavedSong> historyMetadata,
    List<dynamic> weeklyLog = const [],
    List<SavedSong> favorites = const [],
    int targetCount = 25,
    String? countryCode,
    String? countryName,
    String languageCode = 'en',
  }) async* {
    final Set<String> globalSeenIds = {};
    final Set<String> globalSeenTitles = {};

    // Compute weekly counts from log
    final Map<String, int> weeklyCounts = {};
    for (var event in weeklyLog) {
      if (event is Map && event.containsKey('id')) {
        final id = event['id'] as String;
        weeklyCounts[id] = (weeklyCounts[id] ?? 0) + 1;
      }
    }

    final List<SavedSong> userHistoryMetadata = historyMetadata.values.toList();

    // Sort history by: 1. Weekly count, 2. Global count
    final List<SavedSong> sortedHistory = List.from(userHistoryMetadata);
    sortedHistory.sort((a, b) {
      // 1. Weekly count
      final wA = weeklyCounts[a.id] ?? 0;
      final wB = weeklyCounts[b.id] ?? 0;
      if (wA != wB) return wB.compareTo(wA);

      // 2. Global count
      final countA = (phoneHistory[a.id] ?? 0) + (aaHistory[a.id] ?? 0);
      final countB = (phoneHistory[b.id] ?? 0) + (aaHistory[b.id] ?? 0);
      return countB.compareTo(countA);
    });

    // 0. PERSONAL MIXES
    // 0.1 "Weekly Mix" - Most played (Weekly priority)
    if (sortedHistory.isNotEmpty) {
      final List<Map<String, dynamic>> weeklyTracks = [];
      for (var s in sortedHistory) {
        if (weeklyTracks.length >= 50) break;
        final cleanedTitle = _cleanTitle(s.title).toLowerCase();
        if (globalSeenIds.contains(s.id) ||
            globalSeenTitles.contains(cleanedTitle))
          continue;

        weeklyTracks.add(_mapToTrack(s, true));
        globalSeenIds.add(s.id);
        globalSeenTitles.add(cleanedTitle);
      }

      await _recoverMissingImages(weeklyTracks);
      yield _assemblePlaylist(
        _t('weekly_mix', languageCode: languageCode),
        weeklyTracks,
        owner: _t('weekly_mix_owner', languageCode: languageCode),
      );
    }

    // 0.2 "Discovery Mix" - Similar to top artists
    if (sortedHistory.isNotEmpty) {
      final Set<String> topArtistsSet = {};
      for (var s in sortedHistory) {
        final firstArtist = s.artist.split(',').first.trim();
        if (firstArtist.isNotEmpty) {
          topArtistsSet.add(firstArtist);
          if (topArtistsSet.length >= 20) break;
        }
      }
      final topArtists = topArtistsSet.toList()
        ..shuffle(Random(_getWeeklySeed()));
      if (topArtists.length > 10) topArtists.removeRange(10, topArtists.length);

      final discovery = await _createDynamicPlaylist(
        title: _t('discovery_mix', languageCode: languageCode),
        query: topArtists.join('|'),
        countryCode: countryCode,
        countryName: countryName,
        languageCode: languageCode,
        history: [],
        globalSeenIds: globalSeenIds,
        globalSeenTitles: globalSeenTitles,
      );
      if (discovery != null) yield discovery;
    }

    // 0.3 "Latest Hits" - Always 3rd
    final latestHits = await _createDynamicPlaylist(
      title: _t('latest_hits', languageCode: languageCode),
      query: 'Latest Hits',
      countryCode: countryCode,
      countryName: countryName,
      languageCode: languageCode,
      history: [],
      globalSeenIds: globalSeenIds,
      globalSeenTitles: globalSeenTitles,
      periodFilter: 'Latest',
    );
    if (latestHits != null) yield latestHits;

    // 1. GENRE MIXES & DECADES
    final sections = [
      {
        'title': _t('mix_pop', languageCode: languageCode),
        'key': 'mix_pop',
        'query': 'Pop',
        'genre': 'Pop',
        'period': 'Latest',
      },
      {
        'title': _t('mix_rock', languageCode: languageCode),
        'key': 'mix_rock',
        'query': 'Rock',
        'genre': 'Rock',
        'period': 'Latest',
      },
      {
        'title': _t('mix_dance', languageCode: languageCode),
        'key': 'mix_dance',
        'query': 'Dance',
        'genre': 'Dance',
        'period': 'Latest',
      },
      {
        'title': _t('mix_latin', languageCode: languageCode),
        'key': 'mix_latin',
        'query': 'Latin',
        'genre': 'Latin',
      },
      {
        'title': _t('mix_hip_hop', languageCode: languageCode),
        'key': 'mix_hip_hop',
        'query': 'Hip-Hop',
        'genre': 'Hip-Hop',
        'period': 'Latest',
      },
      {
        'title': _t('mix_rb', languageCode: languageCode),
        'key': 'mix_rb',
        'query': 'R&B',
        'genre': 'R&B',
        'period': 'Latest',
      },
      {
        'title': _t('mix_rap', languageCode: languageCode),
        'key': 'mix_rap',
        'query': 'Rap',
        'genre': 'Rap',
        'period': 'Latest',
      },
      {
        'title': _t('mix_country', languageCode: languageCode),
        'key': 'mix_country',
        'query': 'Country',
        'genre': 'Country',
        'period': 'Latest',
      },
      {
        'title': _t('mix_jazz', languageCode: languageCode),
        'key': 'mix_jazz',
        'query': 'Jazz',
        'genre': 'Jazz',
        'period': 'Latest',
      },
      {
        'title': _t('mix_chillout', languageCode: languageCode),
        'key': 'mix_chillout',
        'query': 'Chillout',
        'genre': 'Chillout',
        'period': 'Latest',
      },
      {
        'title': _t('hits_90s', languageCode: languageCode),
        'key': 'hits_90s',
        'query': '1990s',
        'period': '1990s',
      },
      {
        'title': _t('hits_80s', languageCode: languageCode),
        'key': 'hits_80s',
        'query': '1980s',
        'period': '1980s',
      },
      {
        'title': _t('hits_70s', languageCode: languageCode),
        'key': 'hits_70s',
        'query': '1970s',
        'period': '1970s',
      },
      {
        'title': _t('hits_60s', languageCode: languageCode),
        'key': 'hits_60s',
        'query': '1960s',
        'period': '1960s',
      },
    ];

    for (var sec in sections) {
      final String title = sec['title']!;
      // "Mix Latin" keeps user history, while others are 100% chart-based
      final bool useHistory = title == 'Mix Latin';

      final p = await _createDynamicPlaylist(
        title: title,
        query: sec['query']!,
        countryCode: countryCode,
        countryName: countryName,
        languageCode: languageCode,
        history: useHistory ? sortedHistory : [],
        globalSeenIds: globalSeenIds,
        globalSeenTitles: globalSeenTitles,
        periodFilter: sec['period'],
        genreFilter: sec['genre'],
      );
      if (p != null) yield p;
    }
  }

  /// Creates a single playlist by blending history (if allowed) and search results
  Future<TrendingPlaylist?> _createDynamicPlaylist({
    required String title,
    required String query,
    required List<SavedSong> history,
    required Set<String> globalSeenIds,
    required Set<String> globalSeenTitles,
    String? countryCode,
    String? countryName,
    String languageCode = 'en',
    String? periodFilter,
    String? genreFilter,
  }) async {
    final List<Map<String, dynamic>> tracks = [];
    final Set<String> playlistSeenIds = {};
    final Set<String> artists = {};

    // 1. FILL FROM USER HISTORY
    final bool isChartBased = title.contains('Mix') || title.contains('Hits');

    // "Mix Latin" is an exception that allowed a mix of history and charts
    final bool isLatin = title.toLowerCase().contains('latin');
    final int historyLimit = (isChartBased && !isLatin) ? 0 : 10;
    if (historyLimit > 0) {
      for (var s in history) {
        if (tracks.length >= historyLimit) break;
        final cleanedTitle = _cleanTitle(s.title).toLowerCase();
        if (globalSeenIds.contains(s.id) ||
            globalSeenTitles.contains(cleanedTitle))
          continue;

        bool matches = false;
        if (periodFilter != null && _isSongInPeriod(s, periodFilter)) {
          matches = true;
        } else if (genreFilter == null && !isChartBased) {
          if (tracks.length < 5) matches = true;
        } else if (title == 'Mix Latin' && tracks.length < 10) {
          // Allow history for Latin Mix as it's a "personal taste" exception
          matches = true;
        }

        if (matches) {
          tracks.add(_mapToTrack(s, true));
          playlistSeenIds.add(s.id);
          globalSeenIds.add(s.id);
          globalSeenTitles.add(cleanedTitle);
          artists.add(s.artist.split(',').first.trim());
        }
      }
    }

    // 2. FILL FROM SEARCH
    final random = Random(_getWeeklySeed());
    final List<String> searchQueries = title == 'Discovery Mix'
        ? (query.split(
            '|',
          )..shuffle(random)).map((a) => "Similar to $a").toList()
        : _generateSmartQueries(query, countryName, countryCode, languageCode);

    final List<Map<String, dynamic>> searchTracks = [];
    for (var q in searchQueries) {
      if (!isChartBased && (tracks.length + searchTracks.length >= 25)) break;

      final results = await _metadataService.searchSongs(
        query: q,
        limit: 40,
        countryCode: (countryName != null && q.contains(countryName))
            ? countryCode
            : null,
      );

      bool isCountryQ = countryName != null && q.contains(countryName);

      for (var r in results) {
        final s = r.song;
        final cleanedTitle = _cleanTitle(s.title).toLowerCase();
        if (playlistSeenIds.contains(s.id) ||
            globalSeenIds.contains(s.id) ||
            globalSeenTitles.contains(cleanedTitle))
          continue;
        if (periodFilter != null && !_isSongInPeriod(s, periodFilter)) continue;

        final artist = s.artist.split(',').first.trim();
        if (artists.contains(artist) &&
            (tracks.length + searchTracks.length < 15))
          continue;

        var t = _mapToTrack(s, false);
        if (isChartBased) t['isLocal'] = isCountryQ;

        searchTracks.add(t);
        playlistSeenIds.add(s.id);
        globalSeenIds.add(s.id);
        globalSeenTitles.add(cleanedTitle);
        artists.add(artist);

        if (!isChartBased && (tracks.length + searchTracks.length >= 25)) break;
      }
    }

    if (isChartBased) {
      final local = searchTracks.where((t) => t['isLocal'] == true).toList()
        ..shuffle(random);
      final global = searchTracks.where((t) => t['isLocal'] != true).toList()
        ..shuffle(random);

      tracks.clear();
      tracks.addAll(local.take(15));
      int allowedGlobal = tracks.length;
      tracks.addAll(global.take(allowedGlobal).take(25 - tracks.length));
    } else {
      searchTracks.shuffle(random);
      tracks.addAll(searchTracks.take(25 - tracks.length));
    }

    // --- FALLBACK: ensure at least 25 tracks if possible ---
    if (tracks.length < 25) {
      final Set<String> currentIds = tracks
          .map((t) => t['id'] as String)
          .toSet();

      // 1. Try to fill from existing search results (ignoring chart ratios)
      for (var t in searchTracks) {
        if (tracks.length >= 25) break;
        if (!currentIds.contains(t['id'])) {
          tracks.add(t);
          currentIds.add(t['id'] as String);
        }
      }

      // 2. If still < 25, search without any filters (period, genre, country)
      if (tracks.length < 25) {
        // Clean query if it's a pipe-separated list (Discovery Mix)
        final String fallbackQuery = title == 'Discovery Mix'
            ? query.split('|').first
            : query;

        final fallbackResults = await _metadataService.searchSongs(
          query: fallbackQuery,
          limit: 50,
        );

        for (var r in fallbackResults) {
          if (tracks.length >= 25) break;
          final s = r.song;
          final cleanedTitle = _cleanTitle(s.title).toLowerCase();
          if (currentIds.contains(s.id) ||
              globalSeenIds.contains(s.id) ||
              globalSeenTitles.contains(cleanedTitle)) {
            continue;
          }

          tracks.add(_mapToTrack(s, false));
          currentIds.add(s.id);
          playlistSeenIds.add(s.id);
          globalSeenIds.add(s.id);
          globalSeenTitles.add(cleanedTitle);
        }
      }
    }

    if (tracks.length < 5) return null;

    await _recoverMissingImages(tracks);

    return _assemblePlaylist(title, tracks);
  }

  List<String> _generateSmartQueries(
    String base,
    String? country,
    String? countryCode,
    String languageCode,
  ) {
    // Helper for translations
    String t(String key) => _t(key, languageCode: languageCode);

    if (base == 'Latest Hits') {
      final year = DateTime.now().year;
      final List<String> q = [];
      if (country != null) {
        q.addAll([
          "Top 50 $country",
          "${t('ranking')} $country $year",
          "$country Hits $year",
        ]);
      }
      q.addAll(["Global Top $year", "Viral 50 $year"]);
      return q;
    }

    if (base == 'Latin') {
      final List<String> q = [
        "Top Merengue Hits",
        "Top Bachata Hits",
        "Top Salsa Hits",
        "Top Latin Pop",
      ];
      return q;
    }

    if (base == 'Pop' ||
        base == 'Hip-Hop' ||
        base == 'R&B' ||
        base == 'Rap' ||
        base == 'Country') {
      final year = DateTime.now().year;
      final List<String> q = ["Top 50 $base $year", "Top $base Hits"];
      if (country != null) {
        q.insert(0, "Top $base $country");
        q.insert(1, "Hits $base $country $year");
      }
      return q;
    }

    if (base == 'Jazz') {
      final year = DateTime.now().year;
      final List<String> q = ["Top 50 $base", "Classic $base Hits"];
      if (country != null) {
        q.insert(0, "Top $base $country");
        q.insert(1, "Hits $base $country $year");
      }
      return q;
    }

    if (base == 'Rock') {
      final year = DateTime.now().year;
      final List<String> q = [
        "Hard Rock $year",
        "Heavy Metal",
        "Modern Rock Hits",
      ];
      if (country != null) {
        q.insertAll(0, [
          "Hard Rock $country",
          "Heavy Metal $country",
          "Rock $country $year",
        ]);
      }
      return q;
    }

    if (RegExp(r'^\d{4}s$').hasMatch(base)) {
      final decade = base.replaceAll('s', '');
      final shortDecade = decade.substring(2);
      final List<String> q = [];
      if (country != null) {
        q.addAll([
          "${t('ranking')} $country ${t('years')} $shortDecade",
          "Top Hits $country $decade",
          "${t('music')} ${t('years')} $shortDecade $country",
          "Best of $decade $country",
        ]);
      }
      q.addAll(["Top $base Hits", "Best of the $decade"]);
      return q;
    }

    final List<String> q = ["$base Hits"];
    if (country != null) q.insert(0, "$base $country");
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

  String _cleanTitle(String rawTitle) {
    String title = rawTitle;
    bool cleaning = true;
    while (cleaning) {
      String start = title;
      title = title.replaceFirst(RegExp(r'^[⬇️📱✨🎵🔥🎧📻]\s*'), '');
      title = title.replaceFirst(
        RegExp(r'^[\u{1F300}-\u{1F9FF}\u{2600}-\u{26FF}]\s*', unicode: true),
        '',
      );
      title = title.trim();
      if (start == title) cleaning = false;
    }
    return title;
  }

  Map<String, dynamic> _mapToTrack(SavedSong s, bool fromHistory) {
    String title = _cleanTitle(s.title);

    return {
      'title': title,
      'artist': s.artist.trim(),
      'album': s.album.trim(),
      'image': s.artUri ?? '',
      'id': s.id,
      'provider': 'AI',
      'fromHistory': fromHistory,
      if (s.youtubeUrl != null) 'youtubeUrl': s.youtubeUrl,
    };
  }

  TrendingPlaylist _assemblePlaylist(
    String title,
    List<Map<String, dynamic>> tracks, {
    String owner = "AI Discovery",
  }) {
    return TrendingPlaylist(
      id: "ai_${title.hashCode}_${_getWeeklySeed()}",
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

  Future<void> _recoverMissingImages(List<Map<String, dynamic>> tracks) async {
    final List<Future<void>> futures = [];
    for (var i = 0; i < tracks.length && i < 15; i++) {
      final t = tracks[i];
      if (t['image'] == null || t['image'].toString().isEmpty) {
        futures.add(() async {
          try {
            final results = await _metadataService.searchSongs(
              query: "${t['artist']} ${t['title']}",
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
      await Future.wait(
        futures,
      ).timeout(const Duration(seconds: 3), onTimeout: () => []);
    }
  }

  String _t(String key, {String? languageCode}) {
    final Map<String, String>? translations = _getTranslationsFor(
      languageCode ?? 'en',
    );
    return translations?[key] ?? _getTranslationsFor('en')?[key] ?? key;
  }

  Map<String, String>? _getTranslationsFor(String code) {
    try {
      return AppTranslations.translations[code];
    } catch (_) {
      return null;
    }
  }

  int _getWeeklySeed() {
    final now = DateTime.now();
    final year = now.year;
    // Simple week calculation: days since beginning of year / 7
    final days = now.difference(DateTime(year, 1, 1)).inDays;
    final week = days ~/ 7;
    return year * 100 + week;
  }
}
