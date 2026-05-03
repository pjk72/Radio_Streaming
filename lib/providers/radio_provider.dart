import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';

import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'; // For AppLifecycleState
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/station.dart';

import '../models/saved_song.dart';
import '../models/playlist.dart';
import '../services/playlist_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/radio_audio_handler.dart'; // Import for casting
import '../services/ai_recommendation_service.dart';
import '../services/trending_service.dart';
import 'package:workmanager/workmanager.dart';
import '../services/background_tasks.dart';
import '../services/backup_service.dart';
import '../services/recognition_api_service.dart';
import '../utils/genre_mapper.dart';
import '../services/song_link_service.dart';
import '../services/music_metadata_service.dart';
import '../services/log_service.dart';
import '../services/lyrics_service.dart';
import '../services/entitlement_service.dart';
import 'theme_provider.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt_explode;
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/upgrade_proposal.dart';
import '../services/local_playlist_service.dart';
import 'package:app_links/app_links.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_translations.dart';

class RadioProvider with ChangeNotifier, WidgetsBindingObserver {
  List<Station> stations = [];
  static const String _keySavedStations = 'saved_stations';
  Timer? _metadataTimer;

  // External Intent Handling
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  StreamSubscription? _sharingSubscription;

  // --- Song Duration Tracking (ACRCloud) ---
  Duration? _currentSongDuration;
  Duration? _initialSongOffset;
  DateTime? _songSyncTime;

  Duration? get currentSongDuration => _currentSongDuration;
  Duration get currentSongPosition {
    if (_songSyncTime == null || _initialSongOffset == null) {
      return Duration.zero;
    }
    final elapsed = DateTime.now().difference(_songSyncTime!);
    final pos = _initialSongOffset! + elapsed;
    // Don't go beyond duration if we have it
    if (_currentSongDuration != null && pos > _currentSongDuration!) {
      return _currentSongDuration!;
    }
    return pos;
  }

  static const String _keyStartOption =
      'start_option'; // 'none', 'last', 'specific'
  static const String _keyStartupStationId = 'startup_station_id';
  static const String _keyLastPlayedStationId = 'last_played_station_id';
  static const String _keyCompactView = 'compact_view';
  static const String _keyShuffleMode = 'shuffle_mode';
  static const String _keyInvalidSongIds = 'invalid_song_ids';
  static const String _keyManageGridView = 'manage_grid_view';
  static const String _keyManageGroupingMode = 'manage_grouping_mode';
  static const String _keyFollowedArtists = 'followed_artists';
  static const String _keyFollowedAlbums = 'followed_albums';
  static const String _keyArtistImagesCache = 'artist_images_cache';
  static const String _keyCategoryCompactViews = 'category_compact_views';

  final Set<String> _followedArtists = {};
  final Set<String> _followedAlbums = {};

  static const String _keyUserPlayHistory = 'user_play_history';
  static const String _keyHistoryMetadata = 'history_metadata';
  static const String _keyRecentSongsOrder = 'recent_songs_order';
  static const String _keyAAUserPlayHistory = 'aa_user_play_history';
  static const String _keyAARecentSongsOrder = 'aa_recent_songs_order';
  static const String _keyLastSourceMap = 'last_source_map';
  static const String _keyWeeklyPlayLog = 'weekly_play_log';
  static const String _keyLifetimeDownloadCount = 'lifetime_download_count';
  static const String _keyEarnedDownloadCredits = 'earned_download_credits';
  static const String _keyCrossfadeDuration = 'crossfade_duration_v2';

  int _lifetimeDownloadCount = 0;
  int _earnedDownloadCredits = 0;
  int _crossfadeDuration = 7;

  int get crossfadeDuration => _crossfadeDuration;

  int get lifetimeDownloadCount => _lifetimeDownloadCount;
  int get earnedDownloadCredits => _earnedDownloadCredits;

  String _languageCode = 'en';
  void updateLanguageCode(String code) {
    if (_languageCode != code) {
      _languageCode = code;
      notifyListeners();
    }
  }

  String _translate(String key) {
    return AppTranslations.translations[_languageCode]?[key] ??
        AppTranslations.translations['en']?[key] ??
        key;
  }

  // --- QR Preparation State ---
  bool _isPreparingQR = false;
  String? _preparedDeepLink;
  Playlist? _preparingPlaylist;
  bool _isSilentPreparation = false;
  bool _isProactivelyResolving = false;

  bool get isPreparingQR => _isPreparingQR;
  String? get preparedDeepLink => _preparedDeepLink;
  Playlist? get preparingPlaylist => _preparingPlaylist;
  bool get isSilentPreparation => _isSilentPreparation;

  Map<String, int> _userPlayHistory = {};
  Map<String, SavedSong> _historyMetadata = {};
  List<String> _recentSongsOrder = [];

  Map<String, int> _aaUserPlayHistory = {};
  List<String> _aaRecentSongsOrder = [];
  Map<String, String> _lastSourceMap = {}; // songId -> 'car' or 'phone'
  List<dynamic> _weeklyPlayLog = [];

  static const String _keyPromotedPlaylists = 'promoted_playlists';

  // --- Enrichment Completion Reporting ---
  final _enrichmentController =
      StreamController<EnrichmentCompletion>.broadcast();
  Stream<EnrichmentCompletion> get onEnrichmentComplete =>
      _enrichmentController.stream;
  final List<TrendingPlaylist> _promotedPlaylists = [];
  List<TrendingPlaylist> get promotedPlaylists => _promotedPlaylists;

  Map<String, int> get userPlayHistory => _userPlayHistory;
  Map<String, int> get aaUserPlayHistory => _aaUserPlayHistory;
  Map<String, SavedSong> get historyMetadata => _historyMetadata;

  // --- Background Enrichment Tracking ---
  final Set<String> _enrichingPlaylists = {};
  Set<String> get enrichingPlaylists => _enrichingPlaylists;

  // --- Header Pinning State ---
  bool _isPinningMode = false;
  bool get isPinningMode => _isPinningMode;

  final List<String> _pinnedLibraryActions = [
    'search_add_song',
    'create_playlist',
    'scan_qr',
  ];
  final List<String> _pinnedPlaylistActions = [
    'play_all',
    'download',
    'share_playlist',
  ];

  List<String> get pinnedLibraryActions =>
      List.unmodifiable(_pinnedLibraryActions);
  List<String> get pinnedPlaylistActions =>
      List.unmodifiable(_pinnedPlaylistActions);

  void setPinningMode(bool value) {
    if (_isPinningMode != value) {
      _isPinningMode = value;
      notifyListeners();
    }
  }

  Future<void> togglePinnedAction(String actionId, bool isLibrary) async {
    final list = isLibrary ? _pinnedLibraryActions : _pinnedPlaylistActions;
    if (list.contains(actionId)) {
      list.remove(actionId);
    } else {
      list.add(actionId);
    }
    notifyListeners();
    await _savePinnedActions();
  }

  Future<void> _savePinnedActions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('pinned_library_actions', _pinnedLibraryActions);
    await prefs.setStringList(
      'pinned_playlist_actions',
      _pinnedPlaylistActions,
    );
  }

  List<SavedSong> getMostPlayedSongs() {
    if (_recentSongsOrder.isEmpty) return [];
    List<SavedSong> result = [];
    for (var id in _recentSongsOrder.reversed) {
      if (_historyMetadata.containsKey(id)) {
        result.add(_historyMetadata[id]!);
      } else {
        SavedSong? fallback;
        for (var s in _allUniqueSongs) {
          if (s.id == id) {
            fallback = s;
            break;
          }
        }
        if (fallback != null) result.add(fallback);
      }
    }
    return result;
  }

  // Duplicate Link Guard
  String? _lastProcessedLink;
  DateTime? _lastLinkTime;

  /// Merged Pareto: Top Songs from both Phone and AA
  List<Map<String, dynamic>> getUnifiedTopSongs() {
    final Set<String> allIds = {
      ..._userPlayHistory.keys,
      ..._aaUserPlayHistory.keys,
    };
    if (allIds.isEmpty) return [];

    final List<Map<String, dynamic>> result = [];
    for (var id in allIds) {
      if (!_historyMetadata.containsKey(id)) continue;
      final phoneCount = _userPlayHistory[id] ?? 0;
      final aaCount = _aaUserPlayHistory[id] ?? 0;
      if (phoneCount + aaCount == 0) continue;

      result.add({
        'song': _historyMetadata[id]!,
        'phoneCount': phoneCount,
        'aaCount': aaCount,
        'isAAMajority': aaCount > phoneCount,
      });
    }

    result.sort((a, b) {
      final totalA = (a['phoneCount'] as int) + (a['aaCount'] as int);
      final totalB = (b['phoneCount'] as int) + (b['aaCount'] as int);
      return totalB.compareTo(totalA);
    });

    return result;
  }

  /// Merged FIFO: Recently Played from both Phone and AA
  List<Map<String, dynamic>> getUnifiedRecentSongs() {
    // Combine IDs maintaining uniqueness, priority to the one most recently updated globaly
    // Since we don't have global timestamps, we use the _lastSourceMap as an indicator
    final Set<String> allIds = {..._recentSongsOrder, ..._aaRecentSongsOrder};
    if (allIds.isEmpty) return [];

    final List<Map<String, dynamic>> result = [];

    // We need a stable unified order. Let's create one based on the fact that
    // the last item in either list is likely the newest.
    // For simplicity, we'll collect all unique IDs and sort them by their appearance in the history timer if we had it,
    // but here we will just take the union and represent the source.
    // Greedy merge: take from both and the one appearing later in either list stays last
    // Actually, a simpler way is to just follow the _recentSongsOrder and _aaRecentSongsOrder union.
    for (var id in allIds) {
      if (!_historyMetadata.containsKey(id)) continue;
      result.add({
        'song': _historyMetadata[id]!,
        'isLastFromAA': _lastSourceMap[id] == 'car',
      });
    }

    // Sort by "Freshness" - since we don't have timestamps, we use the index in recent lists.
    // We'll give higher weights to items that appear later in either list.
    result.sort((a, b) {
      final songA = a['song'] as SavedSong;
      final songB = b['song'] as SavedSong;
      final idxA_p = _recentSongsOrder.indexOf(songA.id);
      final idxA_c = _aaRecentSongsOrder.indexOf(songA.id);
      final maxA = idxA_p > idxA_c ? idxA_p : idxA_c;

      final idxB_p = _recentSongsOrder.indexOf(songB.id);
      final idxB_c = _aaRecentSongsOrder.indexOf(songB.id);
      final maxB = idxB_p > idxB_c ? idxB_p : idxB_c;

      return maxB.compareTo(maxA);
    });

    return result;
  }

  List<Map<String, String>> getTopArtists() {
    final songArtMap = <String, String>{};
    final artistPlayCountsPhone = <String, int>{};
    final artistPlayCountsAA = <String, int>{};

    void aggregate(
      String? artistStr, {
      String? artUri,
      int? phoneCount,
      int? aaCount,
    }) {
      if (artistStr == null) return;
      final pieces = artistStr
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
      for (var p in pieces) {
        if (artUri != null && artUri.isNotEmpty) {
          songArtMap.putIfAbsent(p, () => artUri);
        }
        if (phoneCount != null) {
          artistPlayCountsPhone[p] =
              (artistPlayCountsPhone[p] ?? 0) + phoneCount;
        }
        if (aaCount != null) {
          artistPlayCountsAA[p] = (artistPlayCountsAA[p] ?? 0) + aaCount;
        }
      }
    }

    // 1. Collect Art
    for (var p in _playlists) {
      for (var s in p.songs) {
        aggregate(s.artist, artUri: s.artUri);
      }
    }
    for (var s in _historyMetadata.values) {
      aggregate(s.artist, artUri: s.artUri);
    }

    // 2. Aggregate Phone Plays
    _userPlayHistory.forEach((id, count) {
      if (count > 0) {
        String? artist = _historyMetadata[id]?.artist;
        if (artist == null) {
          for (var s in _allUniqueSongs) {
            if (s.id == id) {
              artist = s.artist;
              break;
            }
          }
        }
        aggregate(artist, phoneCount: count);
      }
    });

    // 3. Aggregate AA Plays
    _aaUserPlayHistory.forEach((id, count) {
      if (count > 0) {
        String? artist = _historyMetadata[id]?.artist;
        if (artist == null) {
          for (var s in _allUniqueSongs) {
            if (s.id == id) {
              artist = s.artist;
              break;
            }
          }
        }
        aggregate(artist, aaCount: count);
      }
    });

    final Set<String> allArtists = {
      ...artistPlayCountsPhone.keys,
      ...artistPlayCountsAA.keys,
      ..._followedArtists,
    };

    final List<Map<String, String>> result = [];
    final Set<String> processed = {};

    // 1. Followed Artists
    for (var artist in _followedArtists) {
      if (!processed.contains(artist)) {
        final ph = artistPlayCountsPhone[artist] ?? 0;
        final aa = artistPlayCountsAA[artist] ?? 0;
        result.add({
          'name': artist,
          'image': songArtMap[artist] ?? '',
          'isFavorite': 'true',
          'isAAMajority': (aa > ph).toString(),
        });
        processed.add(artist);
      }
    }

    // 2. Rank Others by Total Play Count and Recency
    final artistLastSeenIndex = <String, int>{};
    final unifiedRecentList = [..._recentSongsOrder, ..._aaRecentSongsOrder];

    for (int i = 0; i < unifiedRecentList.length; i++) {
      final id = unifiedRecentList[i];
      final artistStr = _historyMetadata[id]?.artist;
      if (artistStr != null) {
        final pieces = artistStr
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
        for (var p in pieces) {
          artistLastSeenIndex[p] = i;
        }
      }
    }

    final otherArtists = allArtists
        .where((a) => !processed.contains(a))
        .toList();
    otherArtists.sort((a, b) {
      final totalA =
          (artistPlayCountsPhone[a] ?? 0) + (artistPlayCountsAA[a] ?? 0);
      final totalB =
          (artistPlayCountsPhone[b] ?? 0) + (artistPlayCountsAA[b] ?? 0);
      int cmp = totalB.compareTo(totalA);
      if (cmp == 0) {
        final idxA = artistLastSeenIndex[a] ?? -1;
        final idxB = artistLastSeenIndex[b] ?? -1;
        return idxB.compareTo(idxA);
      }
      return cmp;
    });

    for (var artist in otherArtists) {
      final ph = artistPlayCountsPhone[artist] ?? 0;
      final aa = artistPlayCountsAA[artist] ?? 0;
      if (ph + aa == 0 && !allArtists.contains(artist)) continue;

      // Now that artists are individual, we can do a simpler favorite check
      bool isFollowed = false;
      final String lowerArtist = artist.toLowerCase();
      for (var f in _followedArtists) {
        if (f.toLowerCase().trim() == lowerArtist) {
          isFollowed = true;
          break;
        }
      }

      result.add({
        'name': artist,
        'image': songArtMap[artist] ?? '',
        'isFavorite': isFollowed.toString(),
        'isAAMajority': (aa > ph).toString(),
      });
    }

    return result;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh UI when app comes to foreground to sync any background tracking changes
      notifyListeners();
    }
  }

  bool _currentSongIsSaved = false;
  bool get currentSongIsSaved => _currentSongIsSaved;

  bool _isInOtherPlaylists = false;
  bool get isInOtherPlaylists => _isInOtherPlaylists;

  bool _isSavedAnywhere = false;
  bool get isSavedAnywhere => _isSavedAnywhere;

  bool _isRecognizing = false;
  bool _isCurrentTrackRecognized = false;
  bool _isWizardOpen = false;
  bool _showGlobalBanner = true;

  bool get isRecognizing =>
      _isRecognizing ||
      (_audioHandler.mediaItem.value?.extras?['isSearching'] == true);
  bool get isCurrentTrackRecognized => _isCurrentTrackRecognized;
  bool get showGlobalBanner => _showGlobalBanner;
  bool get isWizardOpen => _isWizardOpen;

  void setWizardOpen(bool value) {
    if (_isWizardOpen != value) {
      _isWizardOpen = value;
      notifyListeners();
    }
  }

  void setShowGlobalBanner(bool value) {
    if (_showGlobalBanner != value) {
      _showGlobalBanner = value;
      notifyListeners();
    }
  }

  List<String> get followedArtists => _followedArtists.toList();
  List<String> get followedAlbums => _followedAlbums.toList();

  bool isArtistFollowed(String artist) => _followedArtists.contains(artist);
  bool isAlbumFollowed(String album) => _followedAlbums.contains(album);

  void _onUserStatusChanged() {
    final email = _backupService.currentUser?.email.toLowerCase();

    SharedPreferences.getInstance().then((prefs) {
      if (email != null) {
        prefs.setString('user_email', email);
      } else {
        prefs.remove('user_email');
      }
    });

    if (_audioHandler is RadioAudioHandler) {
      _syncACRCloudStatus();
    }
    notifyListeners();
  }

  Future<void> _loadStations() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonStr = prefs.getString(_keySavedStations);

    final invalidIds = prefs.getStringList(_keyInvalidSongIds);
    if (invalidIds != null) {
      _invalidSongIds.clear();
      _invalidSongIds.addAll(invalidIds);
    }

    final savedArtists = prefs.getStringList(_keyFollowedArtists);
    if (savedArtists != null) {
      _followedArtists.clear();
      _followedArtists.addAll(savedArtists);
    }

    final savedAlbums = prefs.getStringList(_keyFollowedAlbums);
    if (savedAlbums != null) {
      _followedAlbums.clear();
      _followedAlbums.addAll(savedAlbums);
    }

    final pLib = prefs.getStringList('pinned_library_actions');
    if (pLib != null) {
      _pinnedLibraryActions.clear();
      _pinnedLibraryActions.addAll(pLib);
    }

    final pPlay = prefs.getStringList('pinned_playlist_actions');
    if (pPlay != null) {
      _pinnedPlaylistActions.clear();
      _pinnedPlaylistActions.addAll(pPlay);
    }

    _lifetimeDownloadCount = prefs.getInt(_keyLifetimeDownloadCount) ?? 0;
    _earnedDownloadCredits = prefs.getInt(_keyEarnedDownloadCredits) ?? 0;

    await _loadPromotedPlaylists();

    if (jsonStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        stations = decoded.map((e) => Station.fromJson(e)).toList();
        notifyListeners();
      } catch (e) {
        // Fallback if parse error
        stations = [];
        _saveStations(); // Reset corrupt data
      }
    } else {
      // First run: use default
      stations = [];
      _saveStations();
    }

    // --- APPLY SORTING LOGIC (Match RadioAudioHandler) ---
    // 1. Load Order locally to ensure synchronous sort
    final List<String>? orderStr = prefs.getStringList('station_order');
    List<int> order = [];
    if (orderStr != null) {
      order = orderStr
          .map((e) => int.tryParse(e) ?? -1)
          .where((e) => e != -1)
          .toList();
    }

    // 2. Determine Category Ranks
    final Map<String, int> categoryRank = {};
    int currentRank = 0;
    final Map<int, Station> stationMap = {for (var s in stations) s.id: s};

    for (var id in order) {
      final station = stationMap[id];
      if (station != null) {
        final cat = station.category;
        if (!categoryRank.containsKey(cat)) {
          categoryRank[cat] = currentRank++;
        }
      }
    }

    // 3. Multi-Level Sort
    stations.sort((a, b) {
      String catA = a.category;
      String catB = b.category;

      int rankA = categoryRank[catA] ?? 9999;
      int rankB = categoryRank[catB] ?? 9999;

      if (rankA != rankB) return rankA.compareTo(rankB);

      if (rankA == 9999) {
        int alpha = catA.compareTo(catB);
        if (alpha != 0) return alpha;
      }

      int idxA = order.indexOf(a.id);
      int idxB = order.indexOf(b.id);
      if (idxA == -1) idxA = 9999;
      if (idxB == -1) idxB = 9999;

      return idxA.compareTo(idxB);
    });
    // --- END SORTING ---

    _updateAudioHandler();
    _setupAudioHandlerCallbacks(); // Ensure callbacks are set
    notifyListeners();

    // Trigger AI pre-fetch in background after minimal delay to not block UI startup
    Future.delayed(const Duration(milliseconds: 500), () {
      final code = _detectCountryCode();
      preFetchForYou(countryName: _getCountryName(code), countryCode: code);
    });

    // Defer startup playback slightly to ensure UI is ready if needed, or just run it.
    // However, we shouldn't block.
    // _handleStartupPlayback(); // Removed automatic call
    _ensureStationImages();

    // Check Shazam keys status silently
    RecognitionApiService.checkKeysAvailability();
  }

  void _ensureStationImages() {
    bool changed = false;
    for (int i = 0; i < stations.length; i++) {
      final s = stations[i];
      if (s.logo == null || s.logo!.isEmpty) {
        final split = s.genre.split(RegExp(r'[|/,]'));
        if (split.isNotEmpty) {
          final firstGenre = split.first.trim();
          if (firstGenre.isNotEmpty) {
            final img = GenreMapper.getGenreImage(firstGenre);
            if (img != null) {
              stations[i] = Station(
                id: s.id,
                name: s.name,
                genre: s.genre,
                url: s.url,
                icon: s.icon,
                logo: img,
                color: s.color,
                category: s.category,
              );
              changed = true;
            }
          }
        }
      }
    }

    if (changed) {
      _saveStations();
    }
  }

  Future<void> handleStartupPlayback() async {
    final prefs = await SharedPreferences.getInstance();
    _startOption = prefs.getString(_keyStartOption) ?? 'none';
    _startupStationId = prefs.getInt(_keyStartupStationId);

    if (_startOption == 'none') return;

    int? targetId;

    if (_startOption == 'last') {
      targetId = prefs.getInt(_keyLastPlayedStationId);
    } else if (_startOption == 'specific') {
      targetId = _startupStationId;
    }

    if (targetId != null) {
      try {
        final station = stations.firstWhere((s) => s.id == targetId);
        playStation(station);
      } catch (e) {
        // Station likely deleted
      }
    }
  }

  Future<void> _saveStations() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(stations.map((s) => s.toJson()).toList());
    await prefs.setString(_keySavedStations, encoded);
    _updateAudioHandler();
    notifyListeners();
  }

  void _updateAudioHandler() {
    if (_audioHandler is RadioAudioHandler) {
      // Send ALL stations to the background handler (Android Auto)
      // This ensures Next/Prev buttons work for the entire list, not just favorites.
      _audioHandler.updateStations(stations);
    }
  }

  void refreshAudioHandlerPlaylists() {
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.refreshPlaylists();
    }
  }

  void _setupAudioHandlerCallbacks() {
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.onSkipNext = () {
        if (_currentPlayingPlaylistId != null) {
          playNext(true);
        } else {
          playNextStationInFavorites();
        }
      };
      _audioHandler.onSkipPrevious = () {
        if (_currentPlayingPlaylistId != null) {
          playPrevious();
        } else {
          playPreviousStationInFavorites();
        }
      };
      _audioHandler.onPreloadNext = _preloadNextForCrossfade;
    }
  }

  bool _isPreloading = false;
  Future<void> _preloadNextForCrossfade() async {
    // Only preload if we are in playlist mode using native player
    if (_currentPlayingPlaylistId == null || _isPreloading) return;

    // Just find the next song
    final nextSong = _getNextSongInPlaylist();
    if (nextSong != null) {
      _isPreloading = true;
      try {
        String? videoId;

        // PRIORITY 1: Local Files (Requirement 3: Downloads/Offline support)
        if (nextSong.localPath != null) {
          videoId = nextSong.localPath;
        } 
        // PRIORITY 1.5: Direct Stream URL
        else if (nextSong.rawStreamUrl != null && nextSong.rawStreamUrl!.isNotEmpty && nextSong.provider?.toLowerCase() != 'deezer') {
          videoId = nextSong.rawStreamUrl;
        }
        // PRIORITY 2: YouTube URL
        else if (nextSong.youtubeUrl != null) {
          videoId = YoutubePlayer.convertUrlToId(nextSong.youtubeUrl!);
          if (videoId == null && nextSong.youtubeUrl!.contains('v=')) {
            videoId = nextSong.youtubeUrl!.split('v=').last.split('&').first;
          }
        } 
        // PRIORITY 3: Legacy ID
        else if (nextSong.id.length == 11) {
          // Fallback ID
          videoId = nextSong.id;
        }

        // Optimization for Remote Playlists
        if (videoId == null &&
            _currentPlayingPlaylistId != null &&
            _currentPlayingPlaylistId!.startsWith('trending_')) {
          if (nextSong.id.length == 11) {
            videoId = nextSong.id;
          }
        }

        // If still null, try to resolve via search (Heavy!)
        if (videoId == null) {
          try {
            final links = await resolveLinks(
              title: nextSong.title,
              artist: nextSong.artist,
              appleMusicUrl: nextSong.appleMusicUrl,
            ).timeout(const Duration(seconds: 8));

            final url = links['youtube'];
            if (url != null) {
              videoId = YoutubePlayer.convertUrlToId(url);
              if (videoId == null && url.contains('v=')) {
                videoId = url.split('v=').last.split('&').first;
              }
            }
          } catch (e) {
            // resolution failed silently
          }
        }

        // SEQUENTIAL SEARCH FALLBACK
        if (videoId == null) {
          final yt = yt_explode.YoutubeExplode();
          try {
            var results = await yt.search.search("${nextSong.artist} ${nextSong.title}");
            if (results.isEmpty) {
              final cleanTitle = nextSong.title.replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '').trim();
              results = await yt.search.search("$cleanTitle ${nextSong.artist}");
            }
            if (results.isEmpty && nextSong.title.length > 5) {
              results = await yt.search.search(nextSong.title);
            }
            if (results.isNotEmpty) {
              videoId = results.first.id.value;
              LogService().log("Crossfade: Preload: Found ID via sequential search: $videoId");
            }
          } catch (e) {
            LogService().log("Crossfade: Preload: Sequential YouTube search error: $e");
          } finally {
            yt.close();
          }
        }

        if (videoId != null && nextSong.id != _audioOnlySongId) {
          if (_audioHandler is RadioAudioHandler) {
            // Pass all metadata to prevent missing info and frozen counter (Requirement 2 & 3)
            final metadata = {
              'title': nextSong.title,
              'artist': nextSong.artist,
              'album': nextSong.album,
              'artUri': nextSong.artUri,
              'duration': nextSong.duration?.inSeconds,
              'songId': nextSong.id,
              'type': 'playlist_song', // CRITICAL: Fixes frozen counter
              'playlistId': _currentPlayingPlaylistId,
              'localPath': nextSong.localPath,
              'releaseDate': nextSong.releaseDate,
              'youtubeUrl': nextSong.youtubeUrl,
              'appleMusicUrl': nextSong.appleMusicUrl,
            };
            await _audioHandler.preloadNextStream(videoId, nextSong.id, metadata);
          }
        }
      } finally {
        _isPreloading = false;
      }
    }
  }

  Future<void> addStations(List<Station> newStations) async {
    for (final s in newStations) {
      final index = stations.indexWhere(
        (existing) =>
            existing.url == s.url ||
            (existing.name.toLowerCase() == s.name.toLowerCase() &&
                existing.category == s.category),
      );

      if (index != -1) {
        stations[index] = s;
      } else {
        stations.add(s);
        if (!_stationOrder.contains(s.id)) {
          _stationOrder.add(s.id);
        }
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyStationOrder,
      _stationOrder.map((e) => e.toString()).toList(),
    );
    await _saveStations();
  }

  Future<void> toggleFavoritesBulk(List<int> ids, bool favorite) async {
    for (final id in ids) {
      if (favorite) {
        if (!_favorites.contains(id)) _favorites.add(id);
      } else {
        _favorites.remove(id);
      }
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyFavorites,
      _favorites.map((e) => e.toString()).toList(),
    );
  }

  Future<void> addStation(Station s) async {
    final index = stations.indexWhere((existing) => existing.id == s.id);
    if (index != -1) {
      stations[index] = s;
    } else {
      stations.add(s);
    }

    // Explicitly add to order list to ensure it exists for reordering immediately
    if (!_stationOrder.contains(s.id)) {
      _stationOrder.add(s.id);
      // We don't necessarily need to persist order immediately unless we want to be safe.
      // Saving stations already persists the station data.
      // But preserving order is good.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _keyStationOrder,
        _stationOrder.map((e) => e.toString()).toList(),
      );
    }
    await _saveStations();
  }

  Future<void> editStation(Station updated) async {
    final index = stations.indexWhere((s) => s.id == updated.id);
    if (index != -1) {
      stations[index] = updated;
      await _saveStations();

      // If currently playing this station, update current metadata if needed
      if (_currentStation?.id == updated.id) {
        _currentStation = updated;
        notifyListeners();
      }
    }
  }

  Future<void> deleteStation(int id) async {
    stations.removeWhere((s) => s.id == id);
    // Also remove from favorites and order
    if (_favorites.contains(id)) toggleFavorite(id);
    _stationOrder.remove(id);

    await _saveStations();
  }

  @override
  void notifyListeners() {
    // Safety guard: if we are in the middle of a build/layout phase,
    // defer the notification to the next frame to avoid "setState() called during build" errors.
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Double check if we still need to notify (not disposed)
        // super.notifyListeners() doesn't need a check itself but it's good practice.
        super.notifyListeners();
      });
    } else {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _metadataTimer?.cancel();
    _linkSubscription?.cancel();
    _sharingSubscription?.cancel();
    _enrichmentController.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // --- Auto-Skip Circuit Breaker ---
  int _autoSkipCount = 0;

  final AudioHandler _audioHandler;
  final EntitlementService _entitlementService;
  AudioHandler get audioHandler => _audioHandler;
  Timer? _youtubeKeepAliveTimer;
  final PlaylistService _playlistService = PlaylistService();
  final SongLinkService _songLinkService = SongLinkService();
  final MusicMetadataService _musicMetadataService = MusicMetadataService();
  final LyricsService _lyricsService = LyricsService();
  final RecognitionApiService _recognitionApiService = RecognitionApiService();
  final LocalPlaylistService _localPlaylistService = LocalPlaylistService();

  List<Playlist> _playlists = [];

  List<Playlist> get playlists => _playlists;

  List<SavedSong> _allUniqueSongs = [];
  List<SavedSong> get allUniqueSongs => _allUniqueSongs;

  bool _isSyncingMetadata = false;
  bool get isSyncingMetadata => _isSyncingMetadata;

  /// Returns the total number of unique songs currently downloaded (including local media)
  int get currentDownloadedSongsCount {
    final Set<String> downloadedIds = {};
    for (var playlist in _playlists) {
      for (var song in playlist.songs) {
        if (song.isDownloaded) {
          downloadedIds.add(song.id);
        }
      }
    }
    return downloadedIds.length;
  }

  /// Increments the persistent lifetime download count and saves to storage
  Future<void> incrementLifetimeDownloadCount() async {
    _lifetimeDownloadCount++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLifetimeDownloadCount, _lifetimeDownloadCount);
    notifyListeners();
  }

  /// Adds extra download credits (e.g. from Rewarded Ads) and saves to storage
  Future<void> addEarnedDownloadCredits(int count) async {
    _earnedDownloadCredits += count;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyEarnedDownloadCredits, _earnedDownloadCredits);
    notifyListeners();
  }

  Playlist? _tempPlaylist;
  DateTime? _lastPlayNextTime;
  DateTime? _lastPlayPreviousTime;
  DateTime? _zeroDurationStartTime;
  DateTime? _lastProcessingTime;
  Duration? _lastMonitoredPosition;
  DateTime? _lastMonitoredPositionTime;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  final BackupService _backupService;
  BackupService get backupService => _backupService;

  int _lastBackupTs = 0;
  int get lastBackupTs => _lastBackupTs;

  String _lastBackupType = 'manual';
  String get lastBackupType => _lastBackupType;

  String _startOption = 'none'; // 'none', 'last', 'specific'
  String get startOption => _startOption;
  int? _startupStationId;
  int? get startupStationId => _startupStationId;

  bool _isCompactView = false;
  bool get isCompactView => _isCompactView;

  final Map<String, bool> _categoryCompactViews = {};

  double _currentSpeed = 1.0;
  double get currentSpeed => _currentSpeed;

  Future<void> setAudioSpeed(double speed) async {
    _currentSpeed = speed;
    if (_audioHandler is RadioAudioHandler) {
      await _audioHandler.setSpeed(speed);
    }
    notifyListeners();
  }

  bool isCategoryCompact(String category) {
    return _categoryCompactViews[category] ?? _isCompactView;
  }

  bool _isManageGridView = false;
  bool get isManageGridView => _isManageGridView;

  int _manageGroupingMode = 0; // 0: none, 1: genre, 2: origin
  int get manageGroupingMode => _manageGroupingMode;

  // --- AI Recommendations Support ---
  final AIRecommendationService _aiService = AIRecommendationService();
  Future<List<TrendingPlaylist>>? _forYouFuture;
  Future<List<TrendingPlaylist>>? get forYouFuture => _forYouFuture;
  List<TrendingPlaylist?> _forYouList = [];
  List<TrendingPlaylist?> get forYouList {
    if (_forYouList.isEmpty && _promotedPlaylists.isEmpty) return [];

    final List<TrendingPlaylist?> result = [];

    // Position: After "Latest Hits" (Ultime Hit) or earlier if needed
    int latestHitsIndex = _forYouList.indexWhere(
      (p) => p != null && p.title == 'latest_hits',
    );

    if (latestHitsIndex != -1) {
      for (int i = 0; i < _forYouList.length; i++) {
        result.add(_forYouList[i]);
        if (i == latestHitsIndex) {
          result.addAll(_promotedPlaylists);
        }
      }
    } else {
      // Latest hits (AI) not yet available or all elements are null placeholders.
      // Prioritize promoted playlists if they exist, then append AI list.
      if (_promotedPlaylists.isNotEmpty) {
        result.addAll(_promotedPlaylists);
      }
      result.addAll(_forYouList);
    }

    return result;
  }

  StreamSubscription? _forYouSubscription;
  String? _lastForYouCountryCode;
  String? _lastForYouLanguageCode;
  int? _lastWeeklySeed;

  void preFetchForYou({
    String? countryName,
    String? countryCode,
    String? languageCode,
  }) {
    final langCode = languageCode ?? _detectLanguageCode();
    final seed = _getWeeklySeed();

    // Force rebuild if country, language or week changes
    if (_forYouList.isNotEmpty &&
        _lastForYouCountryCode == countryCode &&
        _lastForYouLanguageCode == langCode &&
        _lastWeeklySeed == seed)
      return;

    if (_lastForYouCountryCode != countryCode ||
        _lastForYouLanguageCode != langCode ||
        _lastWeeklySeed != seed) {
      LogService().log(
        "[RadioProvider] Cambio paese, lingua o settimana rilevato ($_lastForYouCountryCode -> $countryCode, $_lastForYouLanguageCode -> $langCode, $_lastWeeklySeed -> $seed): ricostruzione 'Per Te'...",
      );
    } else {
      LogService().log(
        "[RadioProvider] Avvio pre-fetch AI 'Per Te' (Country: $countryCode, Lang: $langCode, Seed: $seed)...",
      );
    }

    _lastForYouCountryCode = countryCode;
    _lastForYouLanguageCode = langCode;
    _lastWeeklySeed = seed;
    _forYouSubscription?.cancel();

    // Reset list with placeholders
    _forYouList = List.generate(15, (_) => null);

    // Also keep the future for any existing listeners (optional but safe)
    _forYouFuture = _aiService.generateDiscoverWeekly(
      phoneHistory: _userPlayHistory,
      aaHistory: _aaUserPlayHistory,
      historyMetadata: _historyMetadata,
      weeklyLog: _weeklyPlayLog,
      targetCount: 15,
      countryName: countryName,
      countryCode: countryCode,
      languageCode: langCode,
    );

    int index = 0;
    _forYouSubscription = _aiService
        .generateDiscoverWeeklyStream(
          phoneHistory: _userPlayHistory,
          aaHistory: _aaUserPlayHistory,
          historyMetadata: _historyMetadata,
          weeklyLog: _weeklyPlayLog,
          targetCount: 15,
          countryName: countryName,
          countryCode: countryCode,
          languageCode: langCode,
        )
        .listen(
          (playlist) {
            if (index < _forYouList.length) {
              _forYouList[index] = playlist;
            } else {
              _forYouList.add(playlist);
            }
            index++;
            notifyListeners();
          },
          onDone: () {
            // Clean up remaining nulls if fewer than 15 playlists were generated
            _forYouList.removeWhere((p) => p == null);
            notifyListeners();
          },
        );

    notifyListeners();
  }

  void resetForYou() {
    _forYouFuture = null;
    _forYouList.clear();
    _lastForYouCountryCode = null;
    _lastForYouLanguageCode = null;
    notifyListeners();
  }

  String _detectCountryCode() {
    try {
      final String systemLocale = Platform.localeName;
      final String normalized = systemLocale.replaceAll('-', '_');
      if (normalized.contains('_')) {
        final parts = normalized.split('_');
        if (parts.length > 1) {
          return parts[1].toUpperCase();
        }
      }
    } catch (_) {}
    return 'US';
  }

  String _detectLanguageCode() {
    try {
      final String systemLocale = Platform.localeName;
      return systemLocale.split('_').first.split('-').first.toLowerCase();
    } catch (_) {}
    return 'en';
  }

  int _getWeeklySeed() {
    final now = DateTime.now();
    final year = now.year;
    final days = now.difference(DateTime(year, 1, 1)).inDays;
    final week = days ~/ 7;
    return year * 100 + week;
  }

  String _getCountryName(String code) {
    // Minimal mapping for AI seeding if LanguageProvider not handy
    final Map<String, String> map = {
      'IT': 'Italy',
      'US': 'USA',
      'GB': 'United Kingdom',
      'FR': 'France',
      'DE': 'Germany',
      'ES': 'Spain',
      'CA': 'Canada',
      'AU': 'Australia',
      'BR': 'Brazil',
      'JP': 'Japan',
    };
    return map[code] ?? 'International';
  }

  // --- Promoted Playlists (Favorites to For You) ---

  void togglePromotedPlaylist(TrendingPlaylist playlist) {
    final index = _promotedPlaylists.indexWhere((p) => p.id == playlist.id);
    if (index != -1) {
      _promotedPlaylists.removeAt(index);
    } else {
      // Clone to avoid side effects if original changes
      final clone = TrendingPlaylist(
        id: playlist.id,
        title: playlist.title,
        provider: playlist.provider, // Store original provider
        imageUrls: List.from(playlist.imageUrls),
        externalUrl: playlist.externalUrl,
        trackCount: playlist.trackCount,
        owner: playlist.owner,
        categoryTitle: playlist.categoryTitle,
        predefinedTracks: playlist.predefinedTracks != null
            ? List<Map<String, dynamic>>.from(playlist.predefinedTracks!)
            : null,
      );
      _promotedPlaylists.add(clone);

      // Background scrape if needed
      if (clone.predefinedTracks == null || clone.predefinedTracks!.isEmpty) {
        _scrapeAndLinkPromoted(clone);
      }
    }
    _savePromotedPlaylists();
    notifyListeners();
  }

  void _scrapeAndLinkPromoted(TrendingPlaylist p) async {
    try {
      final service = TrendingService();
      final tracks = await service.getPlaylistTracks(p);
      service.dispose();

      if (tracks.isNotEmpty) {
        p.trackCount = tracks.length;
        p.predefinedTracks = tracks
            .map((t) => Map<String, dynamic>.from(t))
            .toList();
        _savePromotedPlaylists();
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error scraping promoted: $e");
    }
  }

  bool isPlaylistPromoted(String id) =>
      _promotedPlaylists.any((p) => p.id == id);

  Future<void> _savePromotedPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> list = _promotedPlaylists
        .map(
          (p) => {
            'id': p.id,
            'title': p.title,
            'provider': p.provider,
            'imageUrls': p.imageUrls,
            'externalUrl': p.externalUrl,
            'trackCount': p.trackCount,
            'owner': p.owner,
            'categoryTitle': p.categoryTitle,
            'predefinedTracks': p.predefinedTracks,
          },
        )
        .toList();
    await prefs.setString(_keyPromotedPlaylists, jsonEncode(list));
  }

  Future<void> _loadPromotedPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonStr = prefs.getString(_keyPromotedPlaylists);
    if (jsonStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        _promotedPlaylists.clear();
        for (var item in decoded) {
          _promotedPlaylists.add(
            TrendingPlaylist(
              id: item['id'],
              title: item['title'],
              provider: item['provider'],
              imageUrls: List<String>.from(item['imageUrls']),
              externalUrl: item['externalUrl'],
              trackCount: item['trackCount'] ?? -1,
              owner: item['owner'],
              categoryTitle: item['categoryTitle'],
              predefinedTracks: item['predefinedTracks'] != null
                  ? (item['predefinedTracks'] as List)
                        .map((t) => Map<String, dynamic>.from(t as Map))
                        .toList()
                  : null,
            ),
          );
        }
      } catch (e) {
        debugPrint("Error loading promoted playlists: $e");
      }
    }
  }

  Future<void> toggleFollowArtist(String artist) async {
    if (_followedArtists.contains(artist)) {
      _followedArtists.remove(artist);
    } else {
      _followedArtists.add(artist);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyFollowedArtists, _followedArtists.toList());
  }

  Future<void> resetArtistHistory(String artistName) async {
    // 1. Remove artist from followed list if present
    _followedArtists.remove(artistName);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyFollowedArtists, _followedArtists.toList());

    // 2. Clear play counts for all songs by this artist
    final List<String> toRemoveIds = [];
    final String searchName = artistName.toLowerCase().trim();

    _historyMetadata.forEach((id, song) {
      final songArtist = song.artist.toLowerCase();
      if (songArtist == searchName ||
          songArtist.contains("$searchName,") ||
          songArtist.contains(", $searchName") ||
          songArtist.endsWith(",$searchName")) {
        toRemoveIds.add(id);
      }
    });

    // Also remove from _userPlayHistory/aaHistory even if not in metadata (legacy or other sources)
    final allHistoryKeys = {
      ..._userPlayHistory.keys,
      ..._aaUserPlayHistory.keys,
    };

    for (var id in allHistoryKeys) {
      if (!toRemoveIds.contains(id)) {
        for (var s in _allUniqueSongs) {
          if (s.id == id) {
            final songArtist = s.artist.toLowerCase();
            if (songArtist == searchName ||
                songArtist.contains("$searchName,") ||
                songArtist.contains(", $searchName") ||
                songArtist.endsWith(",$searchName")) {
              toRemoveIds.add(id);
              break;
            }
          }
        }
      }
    }

    for (var id in toRemoveIds) {
      _userPlayHistory.remove(id);
      _recentSongsOrder.remove(id);
      _aaUserPlayHistory.remove(id);
      _aaRecentSongsOrder.remove(id);
    }

    await _saveUserPlayHistory();
    notifyListeners();
  }

  Future<void> toggleFollowAlbum(String album) async {
    if (_followedAlbums.contains(album)) {
      _followedAlbums.remove(album);
    } else {
      _followedAlbums.add(album);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyFollowedAlbums, _followedAlbums.toList());
  }

  Future<void> bulkToggleFavoriteSongs(
    List<SavedSong> songs,
    bool favorite,
  ) async {
    if (songs.isEmpty) return;

    if (favorite) {
      await addSongsToPlaylist('favorites', songs);
    } else {
      final ids = songs.map((s) => s.id).toList();
      await removeSongsFromPlaylist('favorites', ids);
    }
  }

  bool _isOffline = false; // Internal connectivity state

  final ThemeProvider? _themeProvider;

  RadioProvider(
    this._audioHandler,
    this._backupService,
    this._entitlementService, [
    this._themeProvider,
  ]) {
    WidgetsBinding.instance.addObserver(this);
    // connectivity_plus listener
    Connectivity().onConnectivityChanged.listen((results) {
      final bool isNowOffline = results.contains(ConnectivityResult.none);
      // Detected change from Offline -> Online
      if (_isOffline && !isNowOffline) {
        LogService().log("Internet Restored: Attempting auto-resume...");
        _retryAfterConnectionRestored();
      }
      _isOffline = isNowOffline;
    });
    // Check initial state
    Connectivity().checkConnectivity().then((results) {
      _isOffline = results.contains(ConnectivityResult.none);
    });

    _backupService.addListener(_onUserStatusChanged);
    _onUserStatusChanged(); // Initial sync

    _entitlementService.addListener(_onEntitlementChanged);

    _playlistService.onPlaylistsUpdated.listen((_) => reloadPlaylists());
    _checkAutoBackup(); // Start check
    // Listen to playback state from AudioService
    _audioHandler.playbackState.listen((state) {
      bool playing = state.playing;

      // Handle External Pause (Notification interaction)
      if (_hiddenAudioController != null && !_ignoringPause) {
        if (!playing && _isPlaying) {
          _hiddenAudioController!.pause();
        } else if (playing && !_isPlaying) {
          // Re-sync YouTube state if notification was resumed
          _hiddenAudioController!.play();
        }
      }

      // Check for error message updates
      if (state.errorMessage != _errorMessage) {
        _errorMessage = state.errorMessage;
        notifyListeners();
      }

      if (_isPlaying != playing) {
        if (!_ignoringPause) {
          _isPlaying = playing;
          notifyListeners();
        }
      }

      // Sync Shuffle Mode from System/Notification
      // Only sync if we are in Playlist Mode.
      // AudioHandler forces shuffleMode=none for Radio, which would incorrectly wipe our preference if we didn't check.
      if (_currentPlayingPlaylistId != null || _hiddenAudioController != null) {
        final bool isShuffle = state.shuffleMode == AudioServiceShuffleMode.all;
        if (_isShuffleMode != isShuffle) {
          _isShuffleMode = isShuffle;
          if (_isShuffleMode && _currentPlayingPlaylistId != null) {
            _generateShuffleList();
          } else {
            _shuffledIndices.clear();
          }
          notifyListeners();
        }
      }

      // Sync loading state for Radio (when no YouTube controller is active)
      if (_hiddenAudioController == null) {
        final bool isBuffering =
            state.processingState == AudioProcessingState.buffering;
        final bool isReadyOrError =
            state.processingState == AudioProcessingState.ready ||
            state.processingState == AudioProcessingState.error;

        if (isBuffering && !_isLoading) {
          _isLoading = true;
          _metadataTimer?.cancel(); // Cancel any pending recognition
          notifyListeners();
        } else if (isReadyOrError && _isLoading) {
          _isLoading = false;
          if (state.processingState == AudioProcessingState.ready) {
            // STREAMING STARTED: Now we can start the 5 second countdown for lyrics
            if (_currentTrackStartTime == null) {
              _currentTrackStartTime = DateTime.now();
              fetchLyrics(); // Re-trigger search with the updated start time
            }
          }
          notifyListeners();

          // Wait for loading to finish before identifying song
          if (state.processingState == AudioProcessingState.ready &&
              _currentStation != null &&
              _currentPlayingPlaylistId == null) {
            // CRITICAL: Cancel any existing timer to avoid duplicates on rapid state changes
            _metadataTimer?.cancel();

            // RadioAudioHandler handles recognition with intelligent scheduling.
            // Avoid duplicate attempts from Provider.
            if (isACRCloudEnabled) {
              LogService().log("Recognition: Deferring to RadioAudioHandler");
              return;
            }

            LogService().log("Recognition: Scheduling first attempt in 5s...");
            _metadataTimer = Timer(const Duration(seconds: 5), () {
              // Ensure we are still playing the radio and not loading
              if (_isPlaying &&
                  !_isLoading &&
                  _currentPlayingPlaylistId == null) {
                // Double check if ACRCloud is enabled via entitlements
                if (isACRCloudEnabled) {
                  LogService().log("Recognition: Launching first attempt...");
                  _attemptRecognition();
                }
              }
            });
          }
        }
      }
    });

    // Sync background history updates from RadioAudioHandler
    _audioHandler.customEvent.listen((event) {
      if (event is Map && event['type'] == 'history_updated') {
        _loadUserPlayHistory();
      }
    });

    // Listen to media item updates to capture duration
    _audioHandler.mediaItem.listen((item) {
      if (item != null &&
          item.duration != null &&
          _currentPlayingPlaylistId != null &&
          _audioOnlySongId != null) {
        _updateCurrentSongDuration(item.duration!);
      }
    });

    // Listen to media item changes (if updated from outside or by handler, e.g. Android Auto)
    _audioHandler.mediaItem.listen((item) {
      if (item == null) return;

      // CRITICAL FIX: Detect Radio Mode Return
      // If we are playing a station, ensure we exit Playlist Mode immediately
      // Guard: Don't exit playlist mode if the item is a playlist song!
      final isPlaylistSong = item.extras?['type'] == 'playlist_song';
      if (!isPlaylistSong &&
          (item.extras?['type'] == 'station' ||
              stations.any((s) => s.url == item.id))) {
        _currentPlayingPlaylistId = null;
      }

      // 1. Sync Metadata if it changed (within same station or from external source)
      bool metadataChanged = false;

      bool isNewSong = false;

      // Sync IDs
      final String? itemSongId = item.extras?['songId'];
      if (_audioOnlySongId != itemSongId) {
        _audioOnlySongId = itemSongId;
        metadataChanged = true;
        isNewSong = true;
      }

      final String? itemPlaylistId = item.extras?['playlistId'];
      if (itemPlaylistId != null && _currentPlayingPlaylistId != itemPlaylistId) {
        _currentPlayingPlaylistId = itemPlaylistId;
        metadataChanged = true;
      }

      if (_currentTrack != item.title) {
        _currentTrack = item.title;
        metadataChanged = true;
        isNewSong = true;
      }

      if (_currentArtist != (item.artist ?? "")) {
        _currentArtist = item.artist ?? "";
        metadataChanged = true;

        // Sync recognizing state from handler
        _isRecognizing = item.extras?['isSearching'] == true;

        // If recognition failed and artist reverted to station info (genre/name),
        // clear the artist image so the header falls back to the station logo.
        final stationForCheck = _currentStation;
        if (stationForCheck != null &&
            (_currentArtist == stationForCheck.genre ||
                _currentArtist == stationForCheck.name ||
                _isRecognizing)) {
          _currentArtistImage = null;
        } else if (_currentArtist.isNotEmpty &&
            _currentArtist != "Unknown Artist" &&
            _currentArtist != "Live Broadcast" &&
            !_isRecognizing &&
            _currentArtistImage == null) {
          // AUTO-FETCH artist image if artist changed and we don't have one
          fetchArtistImage(_currentArtist).then((img) {
            if (_currentArtist == item.artist && _currentArtistImage == null) {
              _currentArtistImage = img;
              notifyListeners();
            }
          });
        }
      }

      if (_currentAlbum != (item.album ?? "")) {
        _currentAlbum = item.album ?? "";
        metadataChanged = true;
      }

      final String? newArtUri = item.artUri?.toString();
      if (_currentAlbumArt != newArtUri) {
        // In playlist mode: only update artwork if we don't already have a valid one.
        // This prevents _enrichCurrentMetadata from replacing a known good artwork
        // with a potentially incorrect one found by the background metadata fetch.
        // However, if it is a NEW song, we must accept the new artwork!
        final bool isPlaylist = _currentPlayingPlaylistId != null;
        final bool currentArtIsValid =
            _currentAlbumArt != null && _currentAlbumArt!.isNotEmpty;
        if (isNewSong || !isPlaylist || !currentArtIsValid) {
          _currentAlbumArt = newArtUri;
          metadataChanged = true;
        }
      }

      // Sync Extras Fields
      final String? itemReleaseDate = item.extras?['releaseDate'];
      if (_currentReleaseDate != itemReleaseDate) {
        _currentReleaseDate = itemReleaseDate;
        metadataChanged = true;
      }

      final String? itemGenre = item.extras?['genre'];
      if (_currentGenre != itemGenre) {
        _currentGenre = itemGenre;
        metadataChanged = true;
      }

      // Sync External Links
      final String? itemYt = item.extras?['youtubeUrl'];
      if (_currentYoutubeUrl != itemYt) {
        _currentYoutubeUrl = itemYt;
        metadataChanged = true;
      }

      final String? itemAm = item.extras?['appleMusicUrl'];
      if (_currentAppleMusicUrl != itemAm) {
        _currentAppleMusicUrl = itemAm;
        metadataChanged = true;
      }

      // Sync Artist Image if available in extras (usually from pre-enriched/cached items)
      final String? itemArtistImage =
          item.extras?['artistImage'] ?? item.extras?['picture'];
      if (itemArtistImage != null && _currentArtistImage != itemArtistImage) {
        _currentArtistImage = itemArtistImage;
        metadataChanged = true;
      }

      // Sync Local Path if available in extras
      final String? itemLocalPath = item.extras?['localPath'];
      if (_currentLocalPath != itemLocalPath) {
        _currentLocalPath = itemLocalPath;
        metadataChanged = true;
      }

      // Sync Duration and Recognizing state (CRITICAL for Radio Progress Bar)
      bool stateChanged = false;
      final bool newRecognizing = item.extras?['isSearching'] == true;
      if (_isRecognizing != newRecognizing) {
        _isRecognizing = newRecognizing;
        stateChanged = true;
      }

      final bool newRecognized = item.extras?['isRecognized'] == true;
      if (_isCurrentTrackRecognized != newRecognized) {
        _isCurrentTrackRecognized = newRecognized;
        stateChanged = true;
      }

      if (_currentPlayingPlaylistId == null) {
        // Radio Mode: Sync duration to show progress bar after identification
        if (item.duration != _currentSongDuration) {
          _currentSongDuration = item.duration;
          stateChanged = true;
        }

        // Sync initial offset if provided (ACRCloud/Shazam matches)
        final double? offsetSec = item.extras?['offset'];
        if (offsetSec != null) {
          final newOffset = Duration(milliseconds: (offsetSec * 1000).toInt());
          if (_initialSongOffset != newOffset) {
            _initialSongOffset = newOffset;
            _songSyncTime = DateTime.now();
            stateChanged = true;
          }
        }
      }

      if (metadataChanged || stateChanged) {
        // Only set start time if we are already in 'ready' state.
        // If we are buffering/loading, leave it null so playback listener can trigger it when ready.
        final processingState =
            _audioHandler.playbackState.value.processingState;
        if (processingState == AudioProcessingState.ready) {
          _currentTrackStartTime = DateTime.now();
        } else {
          _currentTrackStartTime = null;
        }

        // Trigger lyrics fetch and other updates.
        // If user is on SongDetailsScreen, force:true to bypass timing guards
        // (_currentTrackStartTime can be momentarily null during recognition updates).
        fetchLyrics(force: _isObservingLyrics);
        checkIfCurrentSongIsSaved(); // Update save status for the new track

        // USER REQUEST: Avoid listing/updating phone UI if in car and background
        final bool isCar = item.extras?['isCar'] == true;
        final bool appIsActive =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

        if (!isCar || appIsActive) {
          notifyListeners();
        }
      }

      // --- User Play History Tracking ---
      // Removed from Provider logic: RadioAudioHandler now manages this in all isolates.

      // 2. Handle Station/Source Change
      if (_currentStation?.url != item.id) {
        // Prevent interference if we are handling YouTube locally
        if ((_currentStation?.url.startsWith('youtube://') ?? false) ||
            (item.id == 'external_audio')) {
          return;
        }

        // Find the station by URL
        try {
          final newStation = stations.firstWhere((s) => s.url == item.id);

          // Update local state without triggering a play command (since it's already playing)
          _currentStation = newStation;
          _isLoading = false;
          _currentPlayingPlaylistId =
              null; // FORCE RESET: We are in Radio Mode now

          // If it was a station switch from outside but metadata was already handled above,
          // we might want to ensure track isn't reset to "Live Broadcast" if item has info.
          // Guard: Only reset if we are NOT in playlist mode.
          if (_currentPlayingPlaylistId == null &&
              (item.title == "Station" || item.title == newStation.name)) {
            _currentTrack = "Live Broadcast";
            _currentArtist = "";
          }

          notifyListeners();
        } catch (_) {
          // Check if it is a playlist song request from Android Auto
          if (item.extras?['type'] == 'playlist_song') {
            final String? videoId = item.extras?['videoId'];
            final String? playlistId = item.extras?['playlistId'];
            final String? songId = item.extras?['songId'];

            if (videoId != null && songId != null && _audioOnlySongId != songId) {
              Future.microtask(() {
                playYoutubeAudio(
                  videoId,
                  songId,
                  playlistId: playlistId,
                  overrideTitle: item.title,
                  overrideArtist: item.artist,
                  overrideArtUri: item.artUri?.toString(),
                );
              });
            }
          }

          // Check if it is a playlist command (Play All / Shuffle)
          if (item.extras?['type'] == 'playlist_cmd') {
            final String? playlistId = item.extras?['playlistId'];
            final String? cmd = item.extras?['cmd'];
            if (playlistId != null) {
              Future.microtask(() async {
                try {
                  final playlist = playlists.firstWhere(
                    (p) => p.id == playlistId,
                  );
                  if (playlist.songs.isEmpty) return;

                  if (cmd == 'shuffle') {
                    if (!_isShuffleMode) toggleShuffle();
                    // Play random
                    final random = Random();
                    final song =
                        playlist.songs[random.nextInt(playlist.songs.length)];
                    playPlaylistSong(song, playlistId);
                  } else {
                    // Play all (start from first)
                    if (_isShuffleMode) toggleShuffle();
                    playPlaylistSong(playlist.songs.first, playlistId);
                  }
                } catch (_) {}
              });
            }
          }
        }
      }
    });

    // Set initial volume if possible, or just default local
    setVolume(_volume);

    // Load persisted data
    _loadStationOrder();
    _loadStartupSettings();
    _loadYouTubeSettings();
    _loadManageSettings();

    _loadArtistImagesCache();
    _loadStations();

    _loadPlaylists().then((_) {
      // Start background scan for local duplicates after data is ready
      Future.delayed(const Duration(seconds: 3), _scanForLocalUpgrades);
      // Check and request permissions if local content is present
      ensureLocalPermissions();
      // Initialize sharing handlers only AFTER data (playlists) is ready
      _initExternalHandlers();
    });
  }

  // --- Upgrade Proposals (Duplicate Detection) ---
  List<UpgradeProposal> _upgradeProposals = [];
  List<UpgradeProposal> get upgradeProposals => _upgradeProposals;

  final OnAudioQuery _audioQuery = OnAudioQuery();

  Future<void> _scanForLocalUpgrades() async {
    LogService().log("Starting Scan for Local Upgrades...");
    if (kIsWeb) return;

    // Check permissions silently first
    if (Platform.isAndroid) {
      if (await Permission.audio.isGranted ||
          await Permission.storage.isGranted) {
        // Permission granted, proceed
      } else {
        // Just return, don't nag user on startup if they haven't granted yet.
        // Or strictly, we could try to request if we want to be aggressive,
        // but "background check" implies non-intrusive.
        // However, if the user *wants* this, they probably gave permission.
        // Let's check status.
        final status = await Permission.audio.status;
        if (!status.isGranted) return;
      }
    }

    try {
      final localSongs = await _audioQuery.querySongs(
        sortType: null,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );

      if (localSongs.isEmpty) return;

      // Normalize helper
      String normalize(String s) {
        return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
      }

      final List<UpgradeProposal> newProposals = [];
      final uniqueProposalIds =
          <String>{}; // prevent duplicates in proposal list

      for (var playlist in _playlists) {
        for (var song in playlist.songs) {
          // Skip if already local
          if (song.localPath != null || song.id.startsWith('local_')) continue;

          // Simple match
          final sTitle = normalize(song.title);
          final sArtist = normalize(song.artist);

          if (sTitle.isEmpty) continue;

          for (var local in localSongs) {
            final lTitle = normalize(local.title);
            final lArtist = normalize(local.artist ?? '');

            // Heuristic: Exact match of simplified strings
            // Check title match AND (artist match OR artist is unknown/empty in one side)
            // Stricter: Require artist match if artist exists
            bool artistMatch = false;
            if (sArtist.isNotEmpty && lArtist.isNotEmpty) {
              artistMatch =
                  sArtist.contains(lArtist) || lArtist.contains(sArtist);
            } else {
              // Permissive matching: If one side is missing artist info,
              // we allow a match based on title alone if it's an exact match.
              artistMatch = true;
            }

            if (artistMatch && (lTitle == sTitle || lTitle.contains(sTitle))) {
              if (uniqueProposalIds.add("${playlist.id}_${song.id}")) {
                newProposals.add(
                  UpgradeProposal(
                    playlistId: playlist.id,
                    songId: song.id,
                    songTitle: song.title,
                    songArtist: song.artist,
                    songAlbum: song.album,
                    localPath: local.data,
                    localId: local.id,
                  ),
                );
              }
              break; // Found a match for this song, move to next song
            }
          }
        }
      }

      if (newProposals.isNotEmpty) {
        _upgradeProposals = newProposals;
        notifyListeners();
        LogService().log(
          "Found ${newProposals.length} local upgrades available.",
        );
      }
    } catch (e) {
      LogService().log("Error scanning for local upgrades: $e");
    }
  }

  Future<void> applyUpgrades(List<UpgradeProposal> toApply) async {
    if (toApply.isEmpty) return;

    for (var proposal in toApply) {
      // Get playlist
      final index = _playlists.indexWhere((p) => p.id == proposal.playlistId);
      if (index == -1) continue;

      final songIndex = _playlists[index].songs.indexWhere(
        (s) => s.id == proposal.songId,
      );
      if (songIndex == -1) continue;

      // Update Song
      final original = _playlists[index].songs[songIndex];
      final updated = original.copyWith(
        localPath: proposal.localPath,
        // We keep the original metadata (Title/Artist) as source of truth if user liked it,
        // OR we could update it to match file.
        // User said "sostituendo la canzone online con quello offline".
        // keeping metadata is usually safer for UI consistency, but valid local path enables offline play.
        // We definitely set localPath.
        // We might want to set isValid=true if it was invalid.
        isValid: true,
      );

      _playlists[index].songs[songIndex] = updated;
    }

    await _playlistService.saveAll(_playlists);
    _upgradeProposals.clear();
    notifyListeners();
  }

  Future<void> _loadArtistImagesCache() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonStr = prefs.getString(_keyArtistImagesCache);
    if (jsonStr != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(jsonStr);
        decoded.forEach((key, value) {
          _artistImageCache[key] = value as String?;
        });
      } catch (e) {
        LogService().log("Error loading artist image cache: $e");
      }
    }
  }

  Future<void> _saveArtistImagesCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyArtistImagesCache, jsonEncode(_artistImageCache));
  }

  Future<void> _loadManageSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isManageGridView = prefs.getBool(_keyManageGridView) ?? false;
    _manageGroupingMode = prefs.getInt(_keyManageGroupingMode) ?? 0;
    notifyListeners();
  }

  void playNextFavorite() {
    // Navigate through ALL stations, not just favorites
    final list = allStations;

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int nextIndex = 0;
    if (currentIndex != -1) {
      nextIndex = (currentIndex + 1) % list.length;
    }

    playStation(list[nextIndex]);
  }

  void playPreviousFavorite() {
    // Navigate through ALL stations, not just favorites
    final list = allStations;

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int prevIndex = 0;
    if (currentIndex != -1) {
      prevIndex = (currentIndex - 1 + list.length) % list.length;
    } else {
      prevIndex = list.length - 1;
    }

    playStation(list[prevIndex]);
  }

  void playNextStationInFavorites() {
    List<Station> list = allStations
        .where((s) => _favorites.contains(s.id))
        .toList();
    if (list.isEmpty) list = allStations;

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int nextIndex = 0;
    if (currentIndex != -1) {
      nextIndex = (currentIndex + 1) % list.length;
    }

    playStation(list[nextIndex]);
  }

  void playPreviousStationInFavorites() {
    List<Station> list = allStations
        .where((s) => _favorites.contains(s.id))
        .toList();
    if (list.isEmpty) list = allStations;

    if (list.isEmpty) return;

    int currentIndex = list.indexWhere((s) => s.id == _currentStation?.id);

    int prevIndex = 0;
    if (currentIndex != -1) {
      prevIndex = (currentIndex - 1 + list.length) % list.length;
    } else {
      prevIndex = list.length - 1;
    }

    playStation(list[prevIndex]);
  }

  bool _isSyncingDownloads = false;

  Future<void> _loadPlaylists() async {
    LogService().log("[RadioProvider] _loadPlaylists started...");
    final result = await _playlistService.loadPlaylistsResult();
    _playlists = result.playlists;
    _allUniqueSongs = result.uniqueSongs;

    // Proactive Sync: Ensure all duplicates share download status
    if (!_isSyncingDownloads) {
      _isSyncingDownloads = true;
      try {
        LogService().log("[RadioProvider] Starting syncAllDownloadStatuses...");
        await syncAllDownloadStatuses();
      } finally {
        _isSyncingDownloads = false;
      }
    }

    refreshAudioHandlerPlaylists(); // Force AA update
    checkIfCurrentSongIsSaved();
    notifyListeners();
    LogService().log("[RadioProvider] _loadPlaylists finished.");
  }

  Future<Playlist> createPlaylist(String name, {List<SavedSong>? songs}) async {
    final newPlaylist = await _playlistService.createPlaylist(
      name,
      songs: songs,
    );
    await _loadPlaylists(); // Refresh local list
    return newPlaylist;
  }

  Future<void> deletePlaylist(String id) async {
    // 1. Collect paths of downloaded songs in this playlist before deletion
    final playlist = _playlists.firstWhere(
      (p) => p.id == id,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    final List<String> potentialPathsToDelete = playlist.songs
        .where((s) => s.isDownloaded)
        .map((s) => s.localPath!)
        .toList();

    await _playlistService.deletePlaylist(id);
    await _loadPlaylists();

    if (potentialPathsToDelete.isNotEmpty) {
      await _cleanupUnreferencedFiles(potentialPathsToDelete);
    }
  }

  Future<String?> addToPlaylist(String? playlistId) async {
    if (_currentTrack == "Live Broadcast") return null;

    // Sanitize album name: remove station name etc.
    String cleanAlbum = _currentAlbum;
    final stationName = _currentStation?.name ?? "";
    if (stationName.isNotEmpty && cleanAlbum.contains(stationName)) {
      cleanAlbum = cleanAlbum
          .replaceAll(stationName, "")
          .replaceAll("•", "")
          .trim();
    }

    // Create Song Object
    final song = SavedSong(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: _currentTrack,
      artist: _currentArtist,
      album: cleanAlbum,
      artUri: _currentAlbumArt,
      youtubeUrl: _currentYoutubeUrl,
      appleMusicUrl:
          _currentAppleMusicUrl ??
          "https://music.apple.com/search?term=${Uri.encodeComponent("$_currentTrack $_currentArtist")}",
      dateAdded: DateTime.now(),
      releaseDate: _currentReleaseDate,
      duration: _audioHandler.mediaItem.value?.duration,
    );

    // 1. Auto-Classification Logic (Default / Heart Button)
    if (playlistId == null) {
      // Determine effective genre
      String effectiveGenre = _currentGenre ?? _currentStation?.genre ?? "Mix";

      // Clean up genre string
      if (effectiveGenre.contains('|')) {
        effectiveGenre = effectiveGenre.split('|').first.trim();
      }
      if (effectiveGenre.contains('/')) {
        effectiveGenre = effectiveGenre.split('/').first.trim();
      }

      if (effectiveGenre.trim().isEmpty ||
          effectiveGenre.toLowerCase() == 'unknown') {
        effectiveGenre = "Mix";
      }

      await _playlistService.addToGenrePlaylist(effectiveGenre, song);
      await _loadPlaylists();
      return effectiveGenre;
    }

    // 2. Explicit Target Logic (e.g. Move to Favorites)
    if (playlistId.startsWith('local_')) return null;
    await _playlistService.addSongToPlaylist(playlistId, song);
    await _loadPlaylists();

    // Find name for return value
    final p = playlists.firstWhere(
      (p) => p.id == playlistId,
      orElse: () => playlists.first, // Fallback safe
    );
    return p.name;
  }

  Future<void> addSongToPlaylist(String playlistId, SavedSong song) async {
    if (playlistId.startsWith('local_')) return;

    // Ensure we have a YouTube ID whenever possible for ALL songs (including Local files)
    // This makes local-file playlists shareable via the YouTube ID protocol.
    SavedSong songToSave = song;
    if (songToSave.youtubeUrl == null || songToSave.youtubeUrl!.isEmpty) {
      try {
        final resolvedUrl = await searchYoutubeVideo(
          songToSave.title,
          songToSave.artist,
        );
        if (resolvedUrl != null) {
          songToSave = songToSave.copyWith(youtubeUrl: resolvedUrl);
        }
      } catch (_) {}
    }

    await _playlistService.addSongToPlaylist(playlistId, songToSave);
    await _loadPlaylists();
  }

  Future<void> updateSongInPlaylist(String playlistId, SavedSong song) async {
    await updateSongsInPlaylist(playlistId, [song]);
  }

  Future<void> updateSongsInPlaylist(
    String playlistId,
    List<SavedSong> songs,
  ) async {
    if (playlistId.startsWith('local_')) return;
    await _playlistService.updateSongsInPlaylist(playlistId, songs);
    await _loadPlaylists();
  }

  /// Normalizes a string for song matching by removing non-alphanumeric chars,
  /// extra whitespace, and common suffixes in brackets/parentheses.
  String _normalizeForMatching(String s) {
    String res = s.toLowerCase();
    // Remove content within parentheses/brackets (e.g. "(Official Video)", "[Remastered]")
    res = res.replaceAll(RegExp(r'\([^)]*\)'), '');
    res = res.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    // Remove all non-alphanumeric
    res = res.replaceAll(RegExp(r'[^\w\d]'), '');
    return res.trim();
  }

  String _cleanQuery(String s) {
    String res = s.toLowerCase();
    // 1. Remove bracketed content (Official Video, Lyrics, Remastered, etc)
    res = res.replaceAll(RegExp(r'\([^)]*\)'), '');
    res = res.replaceAll(RegExp(r'\[[^\]]*\]'), '');

    // 2. Remove common YouTube / Audio noise strings
    final noise = [
      'official music video',
      'official video',
      'official audio',
      'music video',
      'lyric video',
      'lyrics',
      'official',
      'full hd',
      '4k',
      '8k',
      'hd',
      'hq',
      'hifi',
      'prod by',
      'prod.',
      'prod ',
      'remastered',
      'video clip',
      'videoclip',
      'high quality',
    ];

    for (var n in noise) {
      res = res.replaceAll(n, '');
    }

    // 3. Handle separators (iTunes likes clean title artist)
    res = res.replaceAll(RegExp(r'[\-\:\|\\\/]'), ' ');

    // 4. Clean up file extensions
    res = res.replaceAll(RegExp(r'\.(mp3|m4a|wav|flac|ogg)$'), '');

    // 5. Final normalization
    res = res.replaceAll(RegExp(r'\s+'), ' ').trim();
    return res;
  }

  Future<void> updateSongDownloadStatusGlobally(
    SavedSong downloadedSong,
  ) async {
    bool changed = false;

    final targetTitle = _normalizeForMatching(downloadedSong.title);
    final targetArtist = _normalizeForMatching(downloadedSong.artist);

    if (targetTitle.isEmpty) return;

    for (int i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      if (playlist.creator == 'local') continue;

      bool playlistChanged = false;
      final updatedSongsInPlaylist = List<SavedSong>.from(playlist.songs);
      for (int j = 0; j < updatedSongsInPlaylist.length; j++) {
        final song = updatedSongsInPlaylist[j];

        // Match by exact ID or normalized Title + Artist
        bool isMatch = song.id == downloadedSong.id;
        if (!isMatch) {
          isMatch =
              _normalizeForMatching(song.title) == targetTitle &&
              _normalizeForMatching(song.artist) == targetArtist;
        }

        if (isMatch) {
          if (song.localPath != downloadedSong.localPath) {
            LogService().log(
              "Sync: Found match for '${song.title}' in playlist '${playlist.name}'. Updating status.",
            );
            updatedSongsInPlaylist[j] = song.copyWith(
              localPath: downloadedSong.localPath,
              forceClearLocalPath: downloadedSong.localPath == null,
              youtubeUrl: downloadedSong.youtubeUrl?.isNotEmpty == true
                  ? downloadedSong.youtubeUrl
                  : song.youtubeUrl,
              isValid: downloadedSong.isValid,
            );
            playlistChanged = true;
          }
        }
      }
      if (playlistChanged) {
        _playlists[i] = playlist.copyWith(songs: updatedSongsInPlaylist);
        changed = true;
      }
    }

    if (changed) {
      await _playlistService.saveAll(_playlists);
      await _loadPlaylists(); // REFRESH ALL STATE (including unique songs)
    }
  }

  /// Scans the entire library and ensures all occurrences of the same song
  /// share the same localPath if at least one of them is downloaded.
  Future<void> syncAllDownloadStatuses() async {
    final Map<String, String> bestPaths = {}; // "artist|title" -> path

    String combinedKey(String a, String t) =>
        "${_normalizeForMatching(a)}|${_normalizeForMatching(t)}";

    // 1. Collect best paths
    for (var p in _playlists) {
      for (var s in p.songs) {
        if (s.localPath != null && s.localPath!.isNotEmpty) {
          final k = combinedKey(s.artist, s.title);
          if (k.length < 3) continue; // Skip very short/empty keys

          // Prefer app-managed paths (.mst / _secure)
          if (!bestPaths.containsKey(k) ||
              s.localPath!.endsWith('.mst') ||
              s.localPath!.contains('_secure')) {
            bestPaths[k] = s.localPath!;
          }
        }
      }
    }

    if (bestPaths.isEmpty) return;

    bool overallChanged = false;
    for (int i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      if (playlist.creator == 'local') continue;

      bool playlistChanged = false;
      final updatedSongs = List<SavedSong>.from(playlist.songs);
      for (int j = 0; j < updatedSongs.length; j++) {
        final s = updatedSongs[j];
        final k = combinedKey(s.artist, s.title);
        if (bestPaths.containsKey(k) && s.localPath != bestPaths[k]) {
          updatedSongs[j] = s.copyWith(localPath: bestPaths[k]);
          playlistChanged = true;
        }
      }

      if (playlistChanged) {
        _playlists[i] = playlist.copyWith(songs: updatedSongs);
        overallChanged = true;
      }
    }

    if (overallChanged) {
      await _playlistService.saveAll(_playlists);
      await _loadPlaylists();
    }
  }

  Future<void> addSongsToPlaylist(
    String playlistId,
    List<SavedSong> songs,
  ) async {
    if (playlistId.startsWith('local_')) return;
    await _playlistService.addSongsToPlaylist(playlistId, songs);
    await _loadPlaylists();
  }

  Future<void> refreshPlaylistInBackground(String playlistId) async {
    _isSyncingMetadata = true;
    notifyListeners();
    // 1. Locate the playlist
    Playlist? target;
    try {
      target = _playlists.firstWhere((p) => p.id == playlistId);
    } catch (_) {
      _isSyncingMetadata = false;
      notifyListeners();
      return;
    }

    bool changed = false;
    final List<SavedSong> updatedSongs = List.from(target.songs);

    // 2. Validate Local File Structure
    for (int i = 0; i < updatedSongs.length; i++) {
      final song = updatedSongs[i];
      if (song.localPath != null && song.localPath!.isNotEmpty) {
        final file = File(song.localPath!);
        if (!(await file.exists())) {
          LogService().log(
            "refreshPlaylistInBackground: Local file missing for ${song.title}, cleaning up...",
          );
          // Try to find it again on the device before giving up
          final foundPath = await _localPlaylistService.findSongOnDevice(
            song.title,
            song.artist,
          );
          if (foundPath != null) {
            updatedSongs[i] = song.copyWith(localPath: foundPath);
            changed = true;
          } else {
            updatedSongs[i] = song.copyWith(forceClearLocalPath: true);
            changed = true;
          }
        }
      }
    }

    if (changed) {
      await _playlistService.updateSongsInPlaylist(playlistId, updatedSongs);
      await _loadPlaylists(); // Refresh internal state
    }

    // 3. Chain to Video Link resolution (passes the now-updated songs)
    try {
      final latestPlaylist = _playlists.firstWhere((p) => p.id == playlistId);
      await resolvePlaylistLinksInBackground(playlistId, latestPlaylist.songs);
    } catch (_) {
      // Playlist might have been deleted
    } finally {
      _isSyncingMetadata = false;
      notifyListeners();
    }
  }

  Future<void> resolvePlaylistLinksInBackground(
    String playlistId,
    List<SavedSong> songs,
  ) async {
    // Start almost immediately but don't block the UI
    Future.delayed(const Duration(milliseconds: 500), () async {
      final List<SavedSong> updatedSongs = [];
      int successCount = 0;
      int failedCount = 0;

      for (var song in songs) {
        bool changed = false;
        SavedSong currentSong = song;

        // 1. Resolve Links (YouTube)
        if (currentSong.youtubeUrl == null || currentSong.youtubeUrl!.isEmpty) {
          try {
            // Minimal pause to stay relatively fast while avoiding harsh rate limits
            await Future.delayed(const Duration(milliseconds: 200));

            final links = await resolveLinks(
              title: currentSong.title,
              artist: currentSong.artist,
              appleMusicUrl: currentSong.appleMusicUrl,
            );

            if (links['youtube'] != null) {
              currentSong = currentSong.copyWith(youtubeUrl: links['youtube']);
              changed = true;
              successCount++;
            } else {
              // Second tier: Deep search via YouTube specifically
              final results = await searchMusic(
                "${currentSong.title} ${currentSong.artist}",
              );
              if (results.isNotEmpty) {
                final best = results.first.song;
                currentSong = currentSong.copyWith(
                  youtubeUrl: best.youtubeUrl,
                  artUri:
                      (currentSong.artUri == null ||
                          currentSong.artUri!.isEmpty)
                      ? best.artUri
                      : currentSong.artUri,
                  album:
                      (currentSong.album.isEmpty ||
                          currentSong.album == 'Unknown Album')
                      ? best.album
                      : currentSong.album,
                );
                changed = true;
                successCount++;
              } else {
                failedCount++;
              }
            }
          } catch (e) {
            failedCount++;
            debugPrint("Error resolving links for ${currentSong.title}: $e");
          }
        } else {
          successCount++;
        }

        // 2. Check and Correct Album Photos (Metadata)
        try {
          final cleanTitle = _cleanQuery(currentSong.title);
          final cleanArtist = _cleanQuery(currentSong.artist);
          final metaResults = await searchMusic("$cleanTitle $cleanArtist");

          if (metaResults.isNotEmpty) {
            final bestMatch = metaResults.first.song;
            // Update artwork if available and different, or if we are replacing YouTube art
            if (bestMatch.artUri != null &&
                bestMatch.artUri!.isNotEmpty &&
                (bestMatch.artUri != currentSong.artUri ||
                    (currentSong.isYoutubeArt && !bestMatch.isYoutubeArt))) {
              currentSong = currentSong.copyWith(
                artUri: bestMatch.artUri,
                // Also update Album/ReleaseDate if missing or better
                album:
                    (currentSong.album.isEmpty ||
                        currentSong.album == 'Unknown Album')
                    ? bestMatch.album
                    : currentSong.album,
                releaseDate:
                    (currentSong.releaseDate == null ||
                        currentSong.releaseDate!.isEmpty)
                    ? bestMatch.releaseDate
                    : currentSong.releaseDate,
              );
              changed = true;
            }
          }

          // Fallback to Odesli (SongLink) if iTunes failed to provide non-YouTube artwork
          if (!changed && currentSong.isYoutubeArt) {
            final links = await resolveLinks(
              title: currentSong.title,
              artist: currentSong.artist,
              appleMusicUrl: currentSong.appleMusicUrl,
              youtubeUrl: currentSong.youtubeUrl,
            );

            final odesliThumb = links['thumbnailUrl'];
            if (odesliThumb != null && odesliThumb.isNotEmpty) {
              final bool isOdesliThumbYoutube =
                  odesliThumb.contains('ytimg.com') ||
                  odesliThumb.contains('ggpht.com') ||
                  odesliThumb.contains('img.youtube.com');

              if (!isOdesliThumbYoutube) {
                currentSong = currentSong.copyWith(artUri: odesliThumb);
                changed = true;
                debugPrint(
                  "Odesli match for ${currentSong.title}: Found better thumb at $odesliThumb",
                );
              }
            }
          }
        } catch (e) {
          debugPrint("Error enriching metadata for ${currentSong.title}: $e");
        }

        if (changed) {
          updatedSongs.add(currentSong);
        }

        // Batch update every 5 songs to show progress but avoid constant disk I/O
        if (updatedSongs.length >= 5) {
          await updateSongsInPlaylist(playlistId, updatedSongs);
          updatedSongs.clear();
        }
      }

      // Final batch for remaining songs
      if (updatedSongs.isNotEmpty) {
        await updateSongsInPlaylist(playlistId, updatedSongs);
      }

      // Broadcast completion
      try {
        final playlist = _playlists.firstWhere((p) => p.id == playlistId);
        _enrichmentController.add(
          EnrichmentCompletion(
            playlistId: playlistId,
            playlistName: playlist.name,
            successCount: successCount,
            failCount: failedCount,
          ),
        );
      } catch (_) {}
    });
  }

  Future<void> renamePlaylist(String id, String newName) async {
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index != -1 && _playlists[index].creator == 'local') return;

    await _playlistService.renamePlaylist(id, newName);
    await _loadPlaylists();
  }

  Future<void> copyPlaylist(String sourceId, String targetId) async {
    try {
      final source = _playlists.firstWhere((p) => p.id == sourceId);
      if (source.songs.isEmpty) return;

      await _playlistService.addSongsToPlaylist(targetId, source.songs);
      await _loadPlaylists();
    } catch (e) {
      debugPrint("Error copying playlist: $e");
    }
  }

  Future<void> updateSongPath(
    String playlistId,
    String songId,
    String newPath,
  ) async {
    try {
      final p = _playlists.firstWhere((p) => p.id == playlistId);
      final index = p.songs.indexWhere((s) => s.id == songId);
      if (index != -1) {
        final s = p.songs[index].copyWith(localPath: newPath);
        final updatedSongs = List<SavedSong>.from(p.songs);
        updatedSongs[index] = s;
        final updatedPlaylist = p.copyWith(songs: updatedSongs);

        await _playlistService.addPlaylist(updatedPlaylist);
        await _loadPlaylists();
      }
    } catch (e) {
      debugPrint("Error updating song path: $e");
    }
  }

  Future<String?> findSongOnDevice(
    String title,
    String artist, {
    String? filename,
  }) async {
    return await _localPlaylistService.findSongOnDevice(
      title,
      artist,
      filename: filename,
    );
  }

  Future<bool> tryFixLocalSongPath(String playlistId, SavedSong song) async {
    String? filename;
    if (song.localPath != null) {
      filename = song.localPath!.split(Platform.pathSeparator).last;
    }

    final newPath = await findSongOnDevice(
      song.title,
      song.artist,
      filename: filename,
    );
    if (newPath != null) {
      await updateSongPath(playlistId, song.id, newPath);
      return true;
    }
    return false;
  }

  Future<void> markSongAsInvalid(String playlistId, String songId) async {
    await _playlistService.markSongAsInvalid(playlistId, songId);
    if (!_invalidSongIds.contains(songId)) {
      _invalidSongIds.add(songId);
    }
    await _loadPlaylists();
  }

  Future<void> clearSongPath(String playlistId, String songId) async {
    try {
      final p = _playlists.firstWhere((p) => p.id == playlistId);
      final index = p.songs.indexWhere((s) => s.id == songId);
      if (index != -1) {
        // Clear path and ensure it's marked as valid (since it can play online)
        final s = p.songs[index].copyWith(
          forceClearLocalPath: true,
          isValid: true,
        );
        final updatedSongs = List<SavedSong>.from(p.songs);
        updatedSongs[index] = s;
        final updatedPlaylist = p.copyWith(songs: updatedSongs);

        await _playlistService.addPlaylist(updatedPlaylist);

        // Also unmark from global invalid list if it was there
        if (_invalidSongIds.contains(songId)) {
          await unmarkSongAsInvalid(songId, playlistId: playlistId);
        } else {
          await _loadPlaylists();
        }
      }
    } catch (e) {
      debugPrint("Error clearing song path: $e");
    }
  }

  Future<void> validateLocalSongsInPlaylist(String playlistId) async {
    try {
      final index = _playlists.indexWhere((p) => p.id == playlistId);
      if (index == -1) return;

      final p = _playlists[index];
      bool anyChanged = false;
      final List<SavedSong> currSongs = List.from(p.songs);
      final List<SavedSong> changedSongsToSync = [];
      final Set<String> revivedIds = {};
      final Set<String> invalidatedIds = {};

      for (int i = 0; i < currSongs.length; i++) {
        final s = currSongs[i];

        final isLocal =
            s.id.startsWith('local_') ||
            s.localPath != null ||
            p.creator == 'local';
        if (!isLocal) continue;

        bool needsCheck = false;
        if (s.isValid) {
          if (s.localPath != null) {
            final f = File(s.localPath!);
            // A valid song should be at least 100KB (header + some data)
            // MST files are encrypted, but should still have size
            if (!await f.exists() || (await f.length()) < 1024 * 50) {
              needsCheck = true;
            }
          } else if (p.creator == 'local' || s.id.startsWith('local_')) {
            needsCheck = true;
          }
        } else {
          // Even if marked invalid, we check if we can fix it
          needsCheck = true;
        }

        if (needsCheck) {
          final newPath = await _localPlaylistService.findSongOnDevice(
            s.title,
            s.artist,
          );

          if (newPath != null) {
            LogService().log("Found/Fixed local song: ${s.title} at $newPath");
            final updated = s.copyWith(localPath: newPath, isValid: true);
            currSongs[i] = updated;
            changedSongsToSync.add(updated);
            if (_invalidSongIds.contains(s.id)) revivedIds.add(s.id);
            anyChanged = true;
          } else {
            final bool canRevert =
                s.youtubeUrl != null || s.appleMusicUrl != null;

            if (canRevert) {
              if (s.localPath != null) {
                LogService().log(
                  "Downloaded song ${s.title} missing file, reverting to online.",
                );
                final updated = s.copyWith(
                  forceClearLocalPath: true,
                  isValid: true,
                );
                currSongs[i] = updated;
                changedSongsToSync.add(updated);
                if (_invalidSongIds.contains(s.id)) revivedIds.add(s.id);
                anyChanged = true;
              }
            } else {
              LogService().log(
                "Local song ${s.title} not found, marking invalid.",
              );
              final updated = s.copyWith(
                isValid: false,
                forceClearLocalPath: true,
              );
              currSongs[i] = updated;
              changedSongsToSync.add(updated);
              if (!_invalidSongIds.contains(s.id)) invalidatedIds.add(s.id);
              anyChanged = true;
            }
          }
        }
      }

      if (anyChanged) {
        _playlists[index] = p.copyWith(songs: currSongs);
        await _playlistService.saveAll(_playlists);

        // Sync changes to OTHER playlists and persist all
        for (var updatedSong in changedSongsToSync) {
          await _syncSongDownloadStatusInternal(updatedSong);
        }
        await _playlistService.saveAll(_playlists);

        if (revivedIds.isNotEmpty || invalidatedIds.isNotEmpty) {
          bool prefChanged = false;
          for (var id in revivedIds) {
            if (_invalidSongIds.remove(id)) prefChanged = true;
            await _playlistService.unmarkSongAsInvalidGlobally(id);
          }
          for (var id in invalidatedIds) {
            if (!_invalidSongIds.contains(id)) {
              _invalidSongIds.add(id);
              prefChanged = true;
            }
            await _playlistService.markSongAsInvalidGlobally(id);
          }

          if (prefChanged) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
          }
        }

        notifyListeners();
        LogService().log(
          "Validated playlist $playlistId: Consolidated changes saved and UI notified.",
        );
      }
    } catch (e) {
      LogService().log("Error validating local songs: $e");
    }
  }

  /// Internal sync that doesn't reload entire state from disk to avoid race conditions
  Future<void> _syncSongDownloadStatusInternal(SavedSong updatedSong) async {
    final targetTitle = _normalizeForMatching(updatedSong.title);
    final targetArtist = _normalizeForMatching(updatedSong.artist);

    for (int i = 0; i < _playlists.length; i++) {
      bool playlistChanged = false;
      final songs = List<SavedSong>.from(_playlists[i].songs);
      for (int j = 0; j < songs.length; j++) {
        if (songs[j].id == updatedSong.id ||
            (_normalizeForMatching(songs[j].title) == targetTitle &&
                _normalizeForMatching(songs[j].artist) == targetArtist)) {
          if (songs[j].localPath != updatedSong.localPath ||
              songs[j].isValid != updatedSong.isValid) {
            songs[j] = songs[j].copyWith(
              localPath: updatedSong.localPath,
              forceClearLocalPath: updatedSong.localPath == null,
              isValid: updatedSong.isValid,
              youtubeUrl: updatedSong.youtubeUrl ?? songs[j].youtubeUrl,
            );
            playlistChanged = true;
          }
        }
      }
      if (playlistChanged) {
        _playlists[i] = _playlists[i].copyWith(songs: songs);
      }
    }
  }

  Future<void> reorderPlaylists(int oldIndex, int newIndex) async {
    await _playlistService.reorderPlaylists(oldIndex, newIndex);
    await _loadPlaylists();
  }

  Future<void> removeFromPlaylist(String playlistId, String songId) async {
    if (playlistId.startsWith('local_')) return;

    // 1. Find the song to get its potential physical path
    final playlist = _playlists.firstWhere(
      (p) => p.id == playlistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    final song = playlist.songs.firstWhere(
      (s) => s.id == songId,
      orElse: () => SavedSong(
        id: '',
        title: '',
        artist: '',
        album: '',
        dateAdded: DateTime.now(),
      ),
    );
    final String? path = song.isDownloaded ? song.localPath : null;

    await _playlistService.removeSongFromPlaylist(playlistId, songId);
    await _loadPlaylists();

    if (path != null) {
      await _cleanupUnreferencedFiles([path]);
    }

    if (playlistId == 'favorites') return;

    final p = _playlists.firstWhere(
      (element) => element.id == playlistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    if (p.id.isNotEmpty && p.songs.isEmpty) {
      await _playlistService.deletePlaylist(playlistId);
      await _loadPlaylists();
    }
  }

  Future<void> restoreSongToPlaylist(String playlistId, SavedSong song) async {
    await _playlistService.addSongToPlaylist(playlistId, song);
    await _loadPlaylists();
  }

  Future<void> copySong(
    String songId,
    String fromPayloadId,
    String toPayloadId,
  ) async {
    await _playlistService.copySong(songId, fromPayloadId, toPayloadId);
    await _loadPlaylists();
  }

  Future<void> copySongs(
    List<String> songIds,
    String fromPayloadId,
    String toPayloadId,
  ) async {
    await _playlistService.copySongs(songIds, fromPayloadId, toPayloadId);
    await _loadPlaylists();
  }

  Future<void> moveSong(
    String songId,
    String fromPayloadId,
    String toPayloadId,
  ) async {
    await _playlistService.moveSong(songId, fromPayloadId, toPayloadId);
    await _loadPlaylists();
  }

  Future<void> moveSongs(
    List<String> songIds,
    String fromPayloadId,
    String toPayloadId,
  ) async {
    await _playlistService.moveSongs(songIds, fromPayloadId, toPayloadId);
    await _loadPlaylists();
  }

  Future<void> restoreSongsToPlaylist(
    String playlistId,
    List<SavedSong> songs, {
    String? playlistName,
  }) async {
    await _playlistService.restoreSongsToPlaylist(
      playlistId,
      songs,
      playlistName: playlistName,
    );
    await _loadPlaylists();
  }

  Future<void> removeSongsFromPlaylist(
    String playlistId,
    List<String> songIds,
  ) async {
    await _playlistService.removeSongsFromPlaylist(playlistId, songIds);
    await _loadPlaylists();

    if (playlistId == 'favorites') return;

    final p = _playlists.firstWhere(
      (element) => element.id == playlistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );

    if (p.id.isNotEmpty && p.songs.isEmpty) {
      await _playlistService.deletePlaylist(playlistId);
      await _loadPlaylists();
    }
  }

  Future<void> removeSongFromLibrary(String songId) async {
    // 1. Get path before removal
    String? path;
    for (var p in _playlists) {
      final s = p.songs.firstWhere(
        (s) => s.id == songId,
        orElse: () => SavedSong(
          id: '',
          title: '',
          artist: '',
          album: '',
          dateAdded: DateTime.now(),
        ),
      );
      if (s.id.isNotEmpty && s.isDownloaded) {
        path = s.localPath;
        break;
      }
    }

    await _playlistService.removeSongFromAllPlaylists(songId);
    await _loadPlaylists();

    if (path != null) {
      await _cleanupUnreferencedFiles([path]);
    }
  }

  Future<void> removeSongsFromLibrary(List<String> songIds) async {
    // 1. Collect paths before removal
    final List<String> paths = [];
    final idSet = songIds.toSet();
    for (var p in _playlists) {
      for (var s in p.songs) {
        if (idSet.contains(s.id) && s.isDownloaded && s.localPath != null) {
          paths.add(s.localPath!);
        }
      }
    }

    await _playlistService.removeSongsFromAllPlaylists(songIds);
    await _loadPlaylists();

    if (paths.isNotEmpty) {
      await _cleanupUnreferencedFiles(paths);
    }
  }

  Future<List<SongSearchResult>> searchMusic(String query) async {
    final countryCode = _detectCountryCode();

    // 1. Search via iTunes Metadata Service
    LogService().log(
      'Searching Music for query: "$query" (Country: $countryCode)',
    );
    List<SongSearchResult> itunesResults = [];
    try {
      itunesResults = await _musicMetadataService
          .searchSongs(
            query: query,
            limit: 30, // Reduced to 30 to make room for YouTube results
            countryCode: countryCode,
          )
          .timeout(const Duration(seconds: 8));
      LogService().log('iTunes Search Results: ${itunesResults.length}');
    } catch (e) {
      LogService().log('iTunes Search Error: $e');
    }

    // 2. Search via YouTube (as fallback or supplement)
    List<SongSearchResult> youtubeResults = [];
    try {
      final yt = yt_explode.YoutubeExplode();
      final searchList = await yt.search
          .searchContent(query, filter: yt_explode.TypeFilters.video)
          .timeout(const Duration(seconds: 8));

      for (var result in searchList.take(20)) {
        if (result is yt_explode.SearchVideo) {
          youtubeResults.add(
            SongSearchResult(
              song: SavedSong(
                id: result.id.value,
                title: result.title,
                artist: result.author,
                album: 'YouTube',
                artUri: result.thumbnails.isNotEmpty
                    ? result.thumbnails.last.url.toString()
                    : null,
                youtubeUrl:
                    'https://www.youtube.com/watch?v=${result.id.value}',
                dateAdded: DateTime.now(),
              ),
              genre: 'YouTube',
            ),
          );
        }
      }
      LogService().log('YouTube Search Results: ${youtubeResults.length}');
      yt.close();
    } catch (e) {
      LogService().log('YouTube Search Error: $e');
    }

    // 3. Merge results: prioritizing iTunes for high-quality metadata, then YouTube
    final List<SongSearchResult> combined = [...itunesResults];

    // Add YouTube results that are not already present (based on title/artist matching if possible, but for now just append)
    // We only add YouTube if itunesResults are few OR if the user specifically searched for something only on YT
    for (var ytRes in youtubeResults) {
      bool alreadyPresent = itunesResults.any(
        (it) =>
            it.song.title.toLowerCase() == ytRes.song.title.toLowerCase() &&
            it.song.artist.toLowerCase() == ytRes.song.artist.toLowerCase(),
      );
      if (!alreadyPresent) {
        combined.add(ytRes);
      }
    }

    return combined;
  }

  Future<void> addFoundSongToGenre(SongSearchResult result) async {
    // Check if result.genre is valid, otherwise use default
    String genre = result.genre;
    if (genre.isEmpty) genre = "Mix";

    await _playlistService.addToGenrePlaylist(genre, result.song);
    await _loadPlaylists();
  }

  Future<void> addFoundSongsToGenre(List<SongSearchResult> results) async {
    if (results.isEmpty) return;

    await _playlistService.addSongsToGenrePlaylists(
      results.map((r) => (genre: r.genre, song: r.song)).toList(),
    );
    await _loadPlaylists();
  }

  Future<void> enrichPlaylistMetadata(String playlistId) async {
    final playlist = _playlists.firstWhere(
      (p) => p.id == playlistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    if (playlist.id.isEmpty) return;

    _isSyncingMetadata = true;
    _enrichingPlaylists.add(playlistId);
    notifyListeners();

    List<SavedSong> songsToProcess = playlist.songs
        .where((s) => s.artUri == null || s.artUri!.isEmpty)
        .toList();

    if (songsToProcess.isEmpty) {
      _isSyncingMetadata = false;
      notifyListeners();
      return;
    }

    bool anyChanged = false;
    List<SavedSong> updatedSongs = List.from(playlist.songs);

    // Process in small batches or with delays to avoid API throttling
    for (int i = 0; i < songsToProcess.length; i++) {
      final song = songsToProcess[i];
      try {
        // Clean query: remove file extensions or path info if present
        String cleanTitle = song.title
            .replaceAll(RegExp(r'\.(mp3|m4a|wav|flac|ogg)$'), '')
            .trim();
        final results = await searchMusic("$cleanTitle ${song.artist}");

        if (results.isNotEmpty) {
          final match = results.first.song;
          int idx = updatedSongs.indexWhere((s) => s.id == song.id);
          if (idx != -1) {
            updatedSongs[idx] = updatedSongs[idx].copyWith(
              artUri: match.artUri,
              album:
                  (updatedSongs[idx].album == 'Unknown Album' ||
                      updatedSongs[idx].album.isEmpty)
                  ? match.album
                  : updatedSongs[idx].album,
              releaseDate:
                  (updatedSongs[idx].releaseDate == null ||
                      updatedSongs[idx].releaseDate!.isEmpty)
                  ? match.releaseDate
                  : updatedSongs[idx].releaseDate,
            );
            anyChanged = true;
          }
        }

        // Batch update to show progress in UI
        if (anyChanged && (i % 5 == 0 || i == songsToProcess.length - 1)) {
          // BUG FIX: Only pass the subset that was modified in this batch if possible,
          // but PlaylistService.updateSongsInPlaylist merges by ID, so it is safe to pass the FULL list
          // ONLY IF the list is not stale. To avoid data loss from stale lists, we re-fetch the playlist structure
          // before updating, or simply use the current mutated state if we are sure no concurrent edits happened.
          // For now, we use a more precise update by passing ONLY the current modified song or the batch.
          await _playlistService.updateSongsInPlaylist(
            playlistId,
            updatedSongs,
          );
          await _loadPlaylists(); // This notifies listeners
          anyChanged = false; // Reset for next batch
        }

        await Future.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        LogService().log("Metadata Enrichment Error for ${song.title}: $e");
      }
    }

    _isSyncingMetadata = false;
    _enrichingPlaylists.remove(playlistId);
    notifyListeners();
  }

  // ... rest of class
  Station? _currentStation;
  bool _isPlaying = false;
  double _volume = 0.8;
  final List<int> _favorites = [];
  String _currentTrack = "Live Broadcast";
  String _currentArtist = "Unknown Artist";
  String _currentAlbum = "";
  String? _currentAlbumArt;
  String? _currentArtistImage;
  String? _currentYoutubeUrl;
  String? _currentAppleMusicUrl;
  String? _currentDeezerUrl;
  String? _currentTidalUrl;
  String? _currentAmazonMusicUrl;
  String? _currentNapsterUrl;

  String? _currentReleaseDate;
  String? _currentGenre;
  String? _currentLocalPath;

  LyricsData _currentLyrics = LyricsData.empty();
  LyricsData get currentLyrics =>
      _currentLyrics; // This will hold translated or original

  LyricsData? _originalLyrics;
  bool _isLyricsTranslated = false;
  bool get isLyricsTranslated => _isLyricsTranslated;

  bool _isTranslatingLyrics = false;
  bool get isTranslatingLyrics => _isTranslatingLyrics;

  bool _isFetchingLyrics = false;
  bool get isFetchingLyrics => _isFetchingLyrics;
  DateTime? _currentTrackStartTime;

  bool _isLoading = false;
  final List<String> _metadataLog = [];

  // Lyrics Synchronization Offset
  Duration _lyricsOffset = Duration.zero;
  Duration get lyricsOffset => _lyricsOffset;

  void setLyricsOffset(Duration offset) {
    _lyricsOffset = offset;
    notifyListeners();
  }

  // Track invalid songs
  final List<String> _invalidSongIds = [];
  List<String> get invalidSongIds => _invalidSongIds;

  bool get isLoading => _isLoading;
  bool _hasPerformedRestore = false;
  bool get hasPerformedRestore => _hasPerformedRestore;
  Timer? _playbackMonitor; // Robust backup for end-of-song detection
  Timer? _invalidDetectionTimer;

  Station? get currentStation => _currentStation;
  bool get isPlaying => _isPlaying;

  double get volume => _volume;
  List<int> get favorites => _favorites;
  List<String> get metadataLog => _metadataLog;
  String _lastApiResponse = "No ACR response yet.";
  String get lastApiResponse => _lastApiResponse;
  String _lastSongLinkResponse = "No SongLink response yet.";
  String get lastSongLinkResponse => _lastSongLinkResponse;

  // Backup Override
  bool _backupOverride = false;
  bool get backupOverride => _backupOverride;

  // Backup State
  bool _isBackingUp = false;
  bool get isBackingUp => _isBackingUp;

  bool _isRestoring = false;
  bool get isRestoring => _isRestoring;

  void enableBackupOverride() {
    _backupOverride = true;
    notifyListeners();
  }

  bool get canInitiateBackup =>
      !_isBackingUp &&
      !_isRestoring &&
      (_lastBackupTs != 0 || _hasPerformedRestore || _backupOverride);

  // Return sorted stations if custom order exists, otherwise default list
  List<Station> get allStations {
    if (!_useCustomOrder || _stationOrder.isEmpty) return stations;

    // Create a map for fast lookup
    final Map<int, Station> stationMap = {for (var s in stations) s.id: s};
    final List<Station> sorted = [];

    // Add stations in order
    for (var id in _stationOrder) {
      if (stationMap.containsKey(id)) {
        sorted.add(stationMap[id]!);
        stationMap.remove(id);
      }
    }

    // Append any new/remaining stations that weren't in the saved order
    sorted.addAll(stationMap.values);

    return sorted;
  }

  String get currentTrack => _currentTrack;
  String get currentArtist => _currentArtist;
  String get currentAlbum => _currentAlbum;
  String? get currentAlbumArt => _currentAlbumArt;
  String? get currentArtistImage => _currentArtistImage;
  String? get currentYoutubeUrl => _currentYoutubeUrl;
  String? get currentAppleMusicUrl => _currentAppleMusicUrl;
  String? get currentDeezerUrl => _currentDeezerUrl;
  String? get currentTidalUrl => _currentTidalUrl;
  String? get currentAmazonMusicUrl => _currentAmazonMusicUrl;
  String? get currentNapsterUrl => _currentNapsterUrl;

  String? get currentReleaseDate => _currentReleaseDate;
  String? get currentGenre => _currentGenre;
  String? get currentLocalPath => _currentLocalPath;

  bool get isCurrentSongSaved {
    if (_currentTrack == "Live Broadcast" || _playlists.isEmpty) return false;

    for (var p in _playlists) {
      if (p.songs.any(
        (s) => s.title == _currentTrack && s.artist == _currentArtist,
      )) {
        return true;
      }
    }
    return false;
  }

  // Station Ordering
  List<int> _stationOrder = [];
  bool _useCustomOrder = false;
  bool get useCustomOrder => _useCustomOrder;

  static const String _keyFavorites = 'favorites';
  static const String _keyStationOrder = 'station_order';

  static const String _keyGenreOrder = 'genre_order';
  static const String _keyCategoryOrder = 'category_order'; // New
  static const String _keyUseCustomOrder = 'use_custom_order';
  static const String _keyHasPerformedRestore = 'has_performed_restore';
  // Persistent Youtube Player State via WebView
  // Persistent Youtube Player State
  YoutubePlayerController? _hiddenAudioController;
  String? _audioOnlySongId;

  YoutubePlayerController? get hiddenAudioController => _hiddenAudioController;
  String? get audioOnlySongId => _audioOnlySongId;
  String? _currentPlayingPlaylistId;
  String? get currentPlayingPlaylistId => _currentPlayingPlaylistId;
  String? get currentSongId => _audioOnlySongId;

  bool _isShuffleMode = false;
  bool get isShuffleMode => _isShuffleMode;

  bool _isRepeatMode = true;
  bool get isRepeatMode => _isRepeatMode;

  bool _ignoringPause = false;

  /// Returns true if [playlistId] refers to a remote/streaming playlist
  /// (trending sources: YouTube/Audius/Deezer/Apple Music).
  /// Such playlists should never have their songs marked invalid.
  bool _isRemotePlaylistId(String playlistId) {
    if (playlistId.startsWith('trending_')) return true;
    if (playlistId.startsWith('apple_')) return true;
    return false;
  }

  // Shuffle Logic
  List<int> _shuffledIndices = [];

  List<SavedSong> get activeQueue {
    if (_currentPlayingPlaylistId == null) return [];

    Playlist playlist;
    if (_tempPlaylist != null &&
        _tempPlaylist!.id == _currentPlayingPlaylistId) {
      playlist = _tempPlaylist!;
    } else {
      playlist = playlists.firstWhere(
        (p) => p.id == _currentPlayingPlaylistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
    }

    if (playlist.songs.isEmpty) return [];

    if (_isShuffleMode && _shuffledIndices.length == playlist.songs.length) {
      return _shuffledIndices.map((i) => playlist.songs[i]).toList();
    }

    return playlist.songs;
  }

  void toggleShuffle() async {
    _isShuffleMode = !_isShuffleMode;

    if (_isShuffleMode && _currentPlayingPlaylistId != null) {
      _generateShuffleList();
    } else {
      _shuffledIndices.clear();
    }

    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShuffleMode, _isShuffleMode);
    await _audioHandler.setShuffleMode(
      _isShuffleMode
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
  }

  void _generateShuffleList() {
    if (_currentPlayingPlaylistId == null) return;

    Playlist playlist;
    if (_tempPlaylist != null &&
        _tempPlaylist!.id == _currentPlayingPlaylistId) {
      playlist = _tempPlaylist!;
    } else {
      playlist = playlists.firstWhere(
        (p) => p.id == _currentPlayingPlaylistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
    }

    if (playlist.songs.isEmpty) return;

    _shuffledIndices = List.generate(playlist.songs.length, (i) => i);
    _shuffledIndices.shuffle();

    // Optional: Move current song to start of shuffle list so we don't jump?
    // Or just let the user find their place.
    // Better UX: If we are playing song X, find X in shuffled list and swap it to current position?
    // No, standard shuffle usually just reshuffles the queue.
    // But to support "Previous" correctly, we need a consistent list.
    // Let's ensure the current song remains the "current" one in the shuffled context.

    if (_audioOnlySongId != null) {
      final currentIndex = playlist.songs.indexWhere(
        (s) => s.id == _audioOnlySongId,
      );
      if (currentIndex != -1) {
        // Move current song index to the beginning (or handle it logically)
        // Actually, pure random shuffle is fine, we just need to find where the current song IS in the shuffled list
        // and continue from there.
      }
    }
  }

  void toggleRepeat() {
    _isRepeatMode = !_isRepeatMode;
    notifyListeners();
  }

  Future<void> playAdHocPlaylist(Playlist playlist, String? startSongId) async {
    _tempPlaylist = playlist;
    _currentPlayingPlaylistId = playlist.id;

    if (playlist.songs.isEmpty) return;

    int startIndex = 0;
    if (startSongId != null) {
      final idx = playlist.songs.indexWhere((s) => s.id == startSongId);
      if (idx != -1) startIndex = idx;
    }

    SavedSong? songToPlay;
    // Find first valid song starting from requested index
    for (int i = startIndex; i < playlist.songs.length; i++) {
      final s = playlist.songs[i];
      if (s.isValid && !_invalidSongIds.contains(s.id)) {
        songToPlay = s;
        break;
      }
    }

    // Fallback: If no valid song found forward, or list empty
    if (songToPlay == null) {
      // Just try the requested one and let error handler deal with it
      // or try finding one from the beginning if we started mid-way?
      // Let's just try the startIndex one.
      if (startIndex < playlist.songs.length) {
        songToPlay = playlist.songs[startIndex];
      }
    }

    if (songToPlay != null) {
      // If the requested song is already playing, skip restarting the stream to avoid stutter.
      // E.g. when seamlessly transitioning into an album playlist view.
      if (songToPlay.id == _audioOnlySongId) {
        _generateShuffleList();
        notifyListeners();
        return;
      }
      await playPlaylistSong(songToPlay, playlist.id);
    }
  }

  Future<void> playDirectAudio(
    String streamUrl,
    String songId, {
    String? playlistId,
    String? overrideTitle,
    String? overrideArtist,
    String? overrideAlbum,
    String? overrideArtUri,
  }) async {
    LogService().log(
      "Playback: Starting Direct Stream: ${overrideTitle ?? 'Audio'} ($streamUrl)",
    );
    _invalidDetectionTimer?.cancel();
    _invalidDetectionTimer = null;

    _currentPlayingPlaylistId = playlistId;
    _audioOnlySongId = songId;

    String title = overrideTitle ?? "Audio";
    String artist = overrideArtist ?? "Direct Stream";
    String? artwork = overrideArtUri;
    String? album = overrideAlbum;

    _currentStation = Station(
      id: -998,
      name: playlistId ?? "Remote",
      genre: "Direct Stream",
      url: streamUrl,
      icon: "cloud_queue",
      color: "0xFF2196F3",
      logo: artwork,
      category: "Remote",
    );
    _currentTrack = title;
    _currentArtist = artist;
    _currentAlbum = album ?? "";
    _currentAlbumArt = artwork;
    _isPlaying = true;
    _isLoading = true;
    notifyListeners();

    try {
      await _audioHandler.playFromUri(Uri.parse(streamUrl), {
        'title': title,
        'artist': artist,
        'artUri': artwork,
        'album': album ?? "Remote",
        'type': 'playlist_song',
        'songId': songId,
        'playlistId': playlistId,
        'is_resolved': true,
        'user_initiated': true,
      });
    } catch (e) {
      LogService().log("Error in playDirectAudio: $e");
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> playYoutubeAudio(
    String videoId,
    String songId, {
    String? playlistId,
    String? overrideTitle,
    String? overrideArtist,
    String? overrideAlbum,
    String? overrideArtUri,
    bool isLocal = false,
    bool isResolved = false,
  }) async {
    LogService().log(
      "Playback: Starting YouTube audio: ${overrideTitle ?? 'Audio'} (https://youtube.com/watch?v=$videoId)",
    );
    _invalidDetectionTimer?.cancel(); // CANCEL invalid detection timer
    _invalidDetectionTimer?.cancel(); // CANCEL invalid detection timer
    _invalidDetectionTimer = null;

    String? oldPlaylistId = _currentPlayingPlaylistId;
    _currentPlayingPlaylistId = playlistId;

    if (playlistId != null && oldPlaylistId != playlistId && _isShuffleMode) {
      _generateShuffleList();
    }

    // Determine metadata: Use overrides if provided, otherwise fallback to search
    String title = overrideTitle ?? "Audio";
    String artist = overrideArtist ?? "YouTube";
    String? artwork = overrideArtUri;
    String? album = overrideAlbum;
    String? releaseDate;
    Duration? songDuration;

    // Only search if we don't have overrides
    if (overrideTitle == null) {
      // Use current playlist if available for better lookup, otherwise search all
      List<Playlist> searchLists = [];
      if (playlistId != null) {
        if (_tempPlaylist != null && _tempPlaylist!.id == playlistId) {
          searchLists = [_tempPlaylist!];
        } else {
          searchLists = playlists.where((p) => p.id == playlistId).toList();
        }
      } else {
        searchLists = [...playlists];
        if (_tempPlaylist != null) searchLists.add(_tempPlaylist!);
      }

      // Fallback to searching all if specific lookup fails
      if (searchLists.isEmpty) searchLists = playlists;

      for (var p in searchLists) {
        final match = p.songs.firstWhere(
          (s) => s.id == songId,
          orElse: () => SavedSong(
            id: '',
            title: '',
            artist: '',
            album: '',
            dateAdded: DateTime.now(),
          ),
        );
        if (match.id.isNotEmpty) {
          title = match.title;
          artist = match.artist;
          artwork = match.artUri;
          album = match.album;
          releaseDate = match.releaseDate;
          songDuration = match.duration;
          break;
        }
      }
    }

    // --------------------------------------------------------------------------------
    // 1. UPDATE UI IMMEDIATELY (Prevent flicker / "No Station")
    // --------------------------------------------------------------------------------

    String playlistName = "Playlist";
    if (playlistId != null) {
      try {
        final pl = playlists.firstWhere((p) => p.id == playlistId);
        playlistName = pl.name;
      } catch (_) {}
    }

    _currentStation = Station(
      id: -999, // Dummy ID for external playback
      name: playlistName,
      genre: isLocal ? "Local Device" : "My Playlist",
      url: isLocal ? videoId : "youtube://$videoId",
      icon: isLocal ? "smartphone" : "youtube",
      color: isLocal ? "0xFF4CAF50" : "0xFFFF0000",
      logo: artwork,
      category: "Playlist",
    );
    _currentTrack = title;
    _currentArtist = artist;
    _currentAlbum = album ?? ""; // Empty instead of "Playlist"
    _currentAlbumArt = artwork;
    _currentReleaseDate = releaseDate;
    _currentArtistImage = null;
    _currentLocalPath = isLocal ? videoId : null;
    _isPlaying = true; // Show 'Pause' icon
    // _isLoading = true; // Optional: Show loading state, but better to show song info

    _currentTrackStartTime = DateTime.now();
    checkIfCurrentSongIsSaved(); // Check if this song from the playlist is already saved somewhere
    notifyListeners(); // <--- CRITICAL: Update UI BEFORE async delays

    // --------------------------------------------------------------------------------
    // 2. NATIVE PLAYBACK (Anti-Standby Fix)
    // --------------------------------------------------------------------------------

    _isLoading = true;
    notifyListeners();

    try {
      // Race condition guard: Abort if song changed while fetching stream

      // Bypass blocking resolution in Provider - Let AudioHandler handle it (and use cache)
      // We pass the VideoId as the URI.
      Uri uri;
      if (isLocal) {
        uri = Uri.file(videoId);
      } else {
        uri = Uri.parse(videoId);
      }

      await _audioHandler.playFromUri(uri, {
        'title': title,
        'artist': artist,
        'artUri': artwork,
        'album': album ?? (isLocal ? "Local Device" : "Playlist"),
        'duration': (songDuration != null && songDuration.inSeconds > 0)
            ? songDuration.inSeconds
            : null,
        'type': 'playlist_song',
        'playlistId': playlistId,
        'songId': songId,
        'videoId': videoId,
        'stableId': isLocal
            ? songId
            : (videoId.length == 11 ? videoId : songId),
        'isLocal': isLocal,
        'is_resolved': isResolved || isLocal,
      });

      _audioOnlySongId = songId;
      _isPlaying = true;
      // _isLoading = false; // LET AUDIO HANDLER STATE CONTROL LOADING
      // notifyListeners();

      // --- Metadata Enrichment (Deep Check) ---
      // If we have incomplete data (unknown artist, generic title, missing art),
      // trigger real-time enrichment in background.
      final lowerTitle = title.toLowerCase();
      final hasExtension =
          lowerTitle.endsWith('.mp3') ||
          lowerTitle.endsWith('.m4a') ||
          lowerTitle.endsWith('.wav') ||
          lowerTitle.endsWith('.flac') ||
          lowerTitle.endsWith('.ogg');

      final isGeneric =
          title == "Shared Song" ||
          title == "Audio" ||
          artist == "Unknown" ||
          artist == "YouTube" ||
          artist == "Local File" ||
          hasExtension;

      final isMissingArt =
          artwork == null || artwork.isEmpty || artwork.contains('placeholder');

      if (isGeneric || isMissingArt) {
        // Run in background without awaiting
        _enrichCurrentMetadata(
          videoId: videoId,
          songId: songId,
          playlistId: playlistId,
          currentTitle: title,
          currentArtist: artist,
          isLocal: isLocal,
        );
      }

      // Clean up old controller if it exists
      if (_hiddenAudioController != null) {
        _hiddenAudioController!.removeListener(_youtubeListener);
        _hiddenAudioController!.dispose();
        _hiddenAudioController = null;
      }
      return; // Success!
    } catch (e) {
      debugPrint("Native YouTube playback failed, falling back: $e");
    }

    // --------------------------------------------------------------------------------
    // 3. FALLBACK: WEBVIEW (Legacy)
    // --------------------------------------------------------------------------------

    // Switch to external playback mode
    _ignoringPause = true; // Prevent internal stop from pausing YouTube
    try {
      await _audioHandler.customAction('startExternalPlayback', {
        'title': title,
        'artist': artist,
        'artUri': artwork,
      });
    } finally {
      // Delay disabling flag slightly to ensure async events are processed
      Future.delayed(const Duration(seconds: 1), () {
        _ignoringPause = false;
      });
    }

    // Enable Wakelock
    try {
      if (!kIsWeb) {
        WakelockPlus.enable();
      }
    } catch (_) {}

    if (_hiddenAudioController != null) {
      if (_hiddenAudioController!.initialVideoId == videoId ||
          _hiddenAudioController!.metadata.videoId == videoId) {
        _hiddenAudioController!.seekTo(const Duration(seconds: 0));
        _hiddenAudioController!.play();
      } else {
        // Remove listener to prevent 'ended' event of previous video triggering next
        _hiddenAudioController!.removeListener(_youtubeListener);
        _hiddenAudioController!.load(videoId);
      }
    } else {
      // First launch loop
      _hiddenAudioController = YoutubePlayerController(
        initialVideoId: videoId,
        flags: const YoutubePlayerFlags(
          autoPlay: false,
          mute: false,
          enableCaption: false,
          hideControls: true,
          forceHD: false,
        ),
      );
      notifyListeners();

      // Increased delay: Ensure the Widget/WebView is fully integrated into the OS view hierarchy
      await Future.delayed(const Duration(milliseconds: 1500));

      // Retry loop for the first hand-shake
      int attempts = 0;
      while (attempts < 3) {
        _hiddenAudioController!.load(videoId);
        await Future.delayed(const Duration(milliseconds: 500));
        _hiddenAudioController!.play();

        // Check if it's moving or at least buffering
        await Future.delayed(const Duration(milliseconds: 1000));
        if (_hiddenAudioController!.value.isPlaying ||
            _hiddenAudioController!.value.playerState == PlayerState.playing ||
            _hiddenAudioController!.value.playerState ==
                PlayerState.buffering) {
          break;
        }
        attempts++;
      }
    }

    // --- RECOVERY TIMER ---
    // Background insurance: OS might try to pause the webview when screen turns off.
    _youtubeKeepAliveTimer?.cancel();
    _youtubeKeepAliveTimer = Timer.periodic(const Duration(seconds: 5), (
      timer,
    ) {
      if (_isPlaying && _hiddenAudioController != null) {
        final state = _hiddenAudioController!.value.playerState;
        if (state != PlayerState.playing &&
            state != PlayerState.buffering &&
            state != PlayerState.ended) {
          debugPrint("YouTube Keep-Alive: Forcing play...");
          _hiddenAudioController!.play();
        }
      } else if (!_isPlaying) {
        timer.cancel();
      }
    });

    // Ensure listener is attached (remove first to avoid duplicates)
    _hiddenAudioController!.removeListener(_youtubeListener);
    _hiddenAudioController!.addListener(_youtubeListener);

    _audioOnlySongId = songId;
    _isPlaying = true; // Ensure state is correct
    _isLoading = false;
    notifyListeners();

    // Start Monitor
    _startPlaybackMonitor();

    // Fetch lyrics for the song
    fetchLyrics();
  }

  bool _isCheckingStallInternet = false;

  Future<bool> _hasInternetConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _startPlaybackMonitor() {
    _stopPlaybackMonitor();
    _playbackMonitor = Timer.periodic(const Duration(milliseconds: 300), (
      timer,
    ) async {
      if (_hiddenAudioController == null) {
        timer.cancel();
        return;
      }

      try {
        final value = _hiddenAudioController!.value;

        // Notify AudioHandler of position for Android Auto Progress Bar
        _audioHandler.customAction('updatePlaybackPosition', {
          'position': value.position.inMilliseconds,
          'duration': value.metaData.duration.inMilliseconds,
          'isPlaying': value.isPlaying,
        });

        // Only check if we are actually playing
        if (value.playerState == PlayerState.playing) {
          final position = value.position;
          final duration = value.metaData.duration;

          // --- STALL DETECTION (Only check at start of song < 15s) ---
          if (position.inSeconds < 15) {
            if (_lastMonitoredPosition == position) {
              if (_lastMonitoredPositionTime == null) {
                _lastMonitoredPositionTime = DateTime.now();
              } else {
                final diff = DateTime.now().difference(
                  _lastMonitoredPositionTime!,
                );
                if (diff.inSeconds > 12) {
                  if (_isOffline) {
                    // If offline, assume stall is due to network and just wait.
                    _lastMonitoredPositionTime =
                        null; // Reset timer to allow re-check later
                    return;
                  }

                  if (_isCheckingStallInternet) return;

                  _isCheckingStallInternet = true;
                  final hasInternet = await _hasInternetConnection();
                  _isCheckingStallInternet = false;

                  if (hasInternet) {
                    // Ricontrolla condizione di stallo dopo l'attesa
                    if (_hiddenAudioController != null &&
                        _hiddenAudioController!.value.playerState ==
                            PlayerState.playing &&
                        _hiddenAudioController!.value.position ==
                            _lastMonitoredPosition) {
                      final bool isRemotePlaylist =
                          _currentPlayingPlaylistId != null &&
                          _isRemotePlaylistId(_currentPlayingPlaylistId!);

                      if (isRemotePlaylist) {
                        debugPrint(
                          "Stallo Rilevato (>12s) - Playlist Remota: Skipping.",
                        );
                        _lastMonitoredPositionTime = null;
                        playNext(false);
                        return;
                      }

                      debugPrint(
                        "Stallo Rilevato (>12s) e Internet OK. Salto (no invalidazione).",
                      );
                      // _markCurrentSongAsInvalid(); // RIMOSSO to reduce skips/removals
                      playNext(false); // Passa alla successiva

                      _lastMonitoredPosition = null;
                      _lastMonitoredPositionTime = null;
                      return;
                    }
                  } else {
                    debugPrint(
                      "Stallo Rilevato (>12s) - Nessuna connessione Internet. Attendo...",
                    );
                  }
                }
              }
            } else {
              _lastMonitoredPosition = position;
              _lastMonitoredPositionTime = DateTime.now();
            }
          }
          // -----------------------

          if (duration.inMilliseconds > 0) {
            final remainingMs =
                duration.inMilliseconds - position.inMilliseconds;

            if (remainingMs <= 200 && !_isLoading) {
              // Only intervene if practically finished to avoid dead air,
              // but don't force it 1s early which causes double-skips.
              _isLoading = true;
              notifyListeners();

              debugPrint(
                "PlaybackMonitor: Song finished (remaining: $remainingMs ms).",
              );
              playNext(false); // Changed to false (system initiated)
            }
          }
        } else {
          // Not playing, reset stall tracker
          _lastMonitoredPosition = null;
          _lastMonitoredPositionTime = null;
        }
      } catch (e) {
        // safeguards
      }
    });
  }

  void _stopPlaybackMonitor() {
    _playbackMonitor?.cancel();
    _playbackMonitor = null;
  }

  Future<void> stopYoutubeAudio() async {
    if (_hiddenAudioController != null) {
      final controller = _hiddenAudioController!;

      // Remove listener to prevent memory leaks or unwanted callbacks
      controller.removeListener(_youtubeListener);
      _stopPlaybackMonitor();

      // Clear reference immediately to update UI
      _hiddenAudioController = null;
      _audioOnlySongId = null;
      _invalidDetectionTimer?.cancel();
      _invalidDetectionTimer = null;
      _zeroDurationStartTime = null;
      _lastMonitoredPosition = null;
      _lastMonitoredPositionTime = null;

      // Reset PlayerBar Metadata
      _currentPlayingPlaylistId = null;
      _currentStation = null;
      _currentTrack = "Live Broadcast";
      _currentArtist = "";
      _currentAlbum = "";
      _currentAlbumArt = null;
      _isPlaying = false;

      checkIfCurrentSongIsSaved(); // Reset save status
      notifyListeners();

      // Dispose controller to close connections
      controller.pause();
      controller.dispose();

      await _audioHandler.customAction('stopExternalPlayback');

      try {
        if (!kIsWeb) {
          WakelockPlus.disable();
        }
      } catch (_) {}
    }
  }

  void _retryAfterConnectionRestored() async {
    // 1. If we have a YouTube controller, try resume
    if (_hiddenAudioController != null) {
      if (_hiddenAudioController!.value.errorCode != 0) {
        _hiddenAudioController!.reload();
      } else {
        _hiddenAudioController!.play();
      }
    }

    // 2. Resume Native Playback (AudioHandler)
    if (_audioHandler.playbackState.value.processingState ==
            AudioProcessingState.error ||
        _audioHandler.playbackState.value.errorMessage ==
            "No Internet Connection") {
      _audioHandler.customAction('retryPlayback');
    }

    // 3. If we stalled during "Loading" (e.g. Resolution failed)
    if ((_isLoading || _errorMessage == "No Internet Connection") &&
        _currentPlayingPlaylistId != null &&
        _audioOnlySongId != null) {
      // Helper to find song
      SavedSong? targetSong;
      try {
        final p = playlists.firstWhere(
          (p) => p.id == _currentPlayingPlaylistId,
        );
        targetSong = p.songs.firstWhere((s) => s.id == _audioOnlySongId);
      } catch (_) {}

      if (targetSong != null) {
        LogService().log("Retrying playlist song: ${targetSong.title}");
        _isLoading = true;
        notifyListeners();
        playPlaylistSong(targetSong, _currentPlayingPlaylistId!);
      }
    }
  }

  void _youtubeListener() {
    if (_hiddenAudioController == null) return;

    final value = _hiddenAudioController!.value;
    final state = value.playerState;

    // 1. Explicit Error Check
    if (value.errorCode != 0) {
      if (_isOffline) {
        LogService().log(
          "Offline: Ignoring YouTube Error code ${value.errorCode}",
        );
        return;
      }

      final bool isRemotePlaylist =
          _currentPlayingPlaylistId != null &&
          _currentPlayingPlaylistId!.startsWith('trending_');

      if (isRemotePlaylist) {
        LogService().log(
          "YouTube Player Error: ${value.errorCode}. Remote Playlist: Skipping.",
        );
        playNext(false);
        return;
      }

      LogService().log(
        "YouTube Player Error: ${value.errorCode}. Marking song invalid.",
      );
      final idToInvalidate = _audioOnlySongId;
      playNext(false);
      _markCurrentSongAsInvalid(songId: idToInvalidate);
      return;
    }

    // 2. Health Check: "Stuck" detection
    bool isProcessing = state == PlayerState.buffering;
    if (_isPlaying &&
        (state == PlayerState.unknown || state == PlayerState.cued)) {
      isProcessing = true;
    }

    if (isProcessing) {
      _zeroDurationStartTime = null;

      if (_lastProcessingTime == null) {
        _lastProcessingTime = DateTime.now();
      } else {
        final diff = DateTime.now().difference(_lastProcessingTime!);
        if (diff.inSeconds > 12) {
          if (_isOffline) {
            LogService().log("Offline: Ignoring buffering stuck detected.");
            _lastProcessingTime = null;
            return;
          }

          final bool isRemotePlaylist =
              _currentPlayingPlaylistId != null &&
              _isRemotePlaylistId(_currentPlayingPlaylistId!);

          if (isRemotePlaylist) {
            LogService().log(
              "Playback Processing Timeout (>12s). Playlist Remota: Ignoro controllo video.",
            );
            _lastProcessingTime = null;
            return;
          }

          LogService().log(
            "Playback Processing Timeout (>12s in $state). Skipping (no invalid).",
          );
          playNext(false);
          _lastProcessingTime = null;
          return;
        }
      }

      if (!_isLoading) {
        _isLoading = true;
        notifyListeners();
      }
    } else {
      // Not processing (Playing, Paused, Ended, or Cued-while-paused)
      _lastProcessingTime = null;
    }

    if (_isLoading) {
      _isLoading = false;
      notifyListeners();
    }
    if (!_isPlaying) {
      _isPlaying = true;
      notifyListeners();
    }

    // RESET CIRCUIT BREAKER ON SUCCESSFUL PLAYBACK (> 5 seconds)
    if (_autoSkipCount > 0 &&
        state == PlayerState.playing &&
        value.position.inSeconds > 5) {
      LogService().log(
        "Playback successful (>5s). Resetting auto-skip counter.",
      );
      _autoSkipCount = 0;
    }

    // Check for Zero Duration (Invalid Song) with Timestamp Approach
    if (_hiddenAudioController != null) {
      final duration = _hiddenAudioController!.value.metaData.duration;
      if (duration.inMilliseconds == 0) {
        if (_isPlaying) {
          if (_zeroDurationStartTime == null) {
            _zeroDurationStartTime = DateTime.now();
            debugPrint(
              "Detected Zero Duration. Starting invalid detection timer...",
            );
          } else {
            // Check elapsed time
            final diff = DateTime.now().difference(_zeroDurationStartTime!);
            if (diff.inSeconds >= 12) {
              if (_isOffline) {
                debugPrint("Offline: Ignoring zero duration.");
                _zeroDurationStartTime = null;
              } else {
                debugPrint(
                  "Song has had Zero Duration for >12s in Playing State. Skipping.",
                );
                playNext(false);
                _zeroDurationStartTime = null;
              }
            }
          }
        } else {
          _zeroDurationStartTime = null;
        }
      } else {
        // Duration is valid
        _zeroDurationStartTime = null;
      }
    }
    // 3. Sync Playing State
    if (state == PlayerState.playing || state == PlayerState.buffering) {
      if (!_isPlaying) {
        _isPlaying = true;
        notifyListeners();
      }
      // Clear loading if we are playing, buffering, or moving
      if (_isLoading ||
          (_hiddenAudioController!.value.position.inSeconds > 0)) {
        if (_isLoading) {
          _isLoading = false;
          notifyListeners();
        }
      }
    } else if (state == PlayerState.paused || state == PlayerState.cued) {
      // Treat 'cued' as effectively paused/stopped if it's not starting
      _zeroDurationStartTime = null;
      if (_isLoading) {
        _isLoading = false;
        notifyListeners();
      }
      if (_isPlaying) {
        _isPlaying = false;
        notifyListeners();
      }
    } else if (state == PlayerState.ended) {
      _zeroDurationStartTime = null;
      if (!_isLoading) {
        _isLoading = true;
        notifyListeners();
        playNext(true);
      }
    } else if (state == PlayerState.unknown) {
      // Often happens on error
      // We can debounce this too? Usually just ignore or treat as buffering?
    }
  }

  void clearYoutubeAudio() {
    _youtubeKeepAliveTimer?.cancel();
    _youtubeKeepAliveTimer = null;
    _stopPlaybackMonitor();
    _hiddenAudioController?.dispose();
    _hiddenAudioController = null;
    _audioOnlySongId = null;
    _currentPlayingPlaylistId = null;
    _currentStation = null; // Also clear station
    notifyListeners();
  }

  static const String _keyPreferYouTubeAudioOnly = 'prefer_youtube_audio_only';

  bool _preferYouTubeAudioOnly = false;

  bool get preferYouTubeAudioOnly => _preferYouTubeAudioOnly;

  bool get isACRCloudEnabled =>
      _entitlementService.isFeatureEnabled('song_recognition');

  List<String> _genreOrder = [];
  List<String> get genreOrder => _genreOrder;

  List<String> _categoryOrder = [];
  List<String> get categoryOrder => _categoryOrder;

  Future<void> _loadStationOrder() async {
    final prefs = await SharedPreferences.getInstance();

    _useCustomOrder = prefs.getBool(_keyUseCustomOrder) ?? false;

    final List<String>? orderStr = prefs.getStringList(_keyStationOrder);
    if (orderStr != null) {
      _stationOrder = orderStr
          .map((e) => int.tryParse(e) ?? -1)
          .where((e) => e != -1)
          .toList();
    }

    // Load Favorites
    final List<String>? favStr = prefs.getStringList(_keyFavorites);
    if (favStr != null) {
      _favorites.clear();
      _favorites.addAll(
        favStr.map((e) => int.tryParse(e) ?? -1).where((e) => e != -1),
      );
    }
    // Load Genre Order
    final List<String>? genreStr = prefs.getStringList(_keyGenreOrder);
    if (genreStr != null) {
      _genreOrder = genreStr;
    }

    // Load Category Order
    final List<String>? categoryStr = prefs.getStringList(_keyCategoryOrder);
    if (categoryStr != null) {
      _categoryOrder = categoryStr;
    }

    notifyListeners();
  }

  Future<void> reorderGenres(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = _genreOrder.removeAt(oldIndex);
    _genreOrder.insert(newIndex, item);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyGenreOrder, _genreOrder);
  }

  Future<void> reorderCategories(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = _categoryOrder.removeAt(oldIndex);
    _categoryOrder.insert(newIndex, item);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyCategoryOrder, _categoryOrder);
  }

  Future<void> moveCategory(
    String category,
    String? afterCategory,
    String? beforeCategory,
  ) async {
    final int currentIndex = _categoryOrder.indexOf(category);
    if (currentIndex == -1) return;

    _categoryOrder.removeAt(currentIndex);

    int targetIndex = -1;

    if (afterCategory != null) {
      final afterIndex = _categoryOrder.indexOf(afterCategory);
      if (afterIndex != -1) {
        targetIndex = afterIndex + 1;
      }
    } else if (beforeCategory != null) {
      final beforeIndex = _categoryOrder.indexOf(beforeCategory);
      if (beforeIndex != -1) {
        targetIndex = beforeIndex;
      }
    }

    if (targetIndex != -1) {
      if (targetIndex > _categoryOrder.length) {
        _categoryOrder.add(category);
      } else {
        _categoryOrder.insert(targetIndex, category);
      }
    } else {
      // Fallback: Reference not found.
      // If we intended to put it BEFORE something, and that something is missing/unknown,
      // putting it at the TOP is usually safer/more expected than the bottom for visibility.
      // If 'after' was specified but missing, we fall through to here? No, 'after' logic handles itself.
      if (beforeCategory != null) {
        _categoryOrder.insert(0, category);
      } else {
        // Default (after=null, before=null) -> Top? or Bottom?
        // Usually implies empty list or drag to start?
        _categoryOrder.insert(0, category);
      }
    }

    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyCategoryOrder, _categoryOrder);
  }

  Future<void> moveStation(
    int stationId,
    int? afterStationId,
    int? beforeStationId,
  ) async {
    LogService().log(
      "moveStation: Moving $stationId. After: $afterStationId, Before: $beforeStationId",
    );

    // Ensure order list is fully populated and CLEAN
    // We must check if the CONTENTS match, not just the length.
    // 1. Remove "Ghost" IDs (IDs in order list that no longer exist in stations)
    final Set<int> currentStationIds = stations.map((s) => s.id).toSet();
    final int removedCount = _stationOrder.length;
    _stationOrder.removeWhere((id) => !currentStationIds.contains(id));
    if (_stationOrder.length != removedCount) {
      LogService().log(
        "moveStation: Cleaned up ${removedCount - _stationOrder.length} ghost stations.",
      );
    }

    // 2. Add Missing IDs (IDs in stations but not in order list)
    final existingOrderIds = _stationOrder.toSet();
    final missing = stations
        .where((s) => !existingOrderIds.contains(s.id))
        .map((s) => s.id);

    if (missing.isNotEmpty) {
      LogService().log(
        "moveStation: Adding ${missing.length} missing stations to order...",
      );
      _stationOrder.addAll(missing);
    }

    // Auto-enable custom order
    if (!_useCustomOrder) {
      _useCustomOrder = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyUseCustomOrder, true);
    }

    final int currentIndex = _stationOrder.indexOf(stationId);
    if (currentIndex == -1) {
      LogService().log(
        "moveStation: Error - Station ID $stationId not found in order list.",
      );
      return;
    }

    _stationOrder.removeAt(currentIndex);

    int targetIndex = -1;

    if (afterStationId != null) {
      final afterIndex = _stationOrder.indexOf(afterStationId);
      if (afterIndex != -1) {
        targetIndex = afterIndex + 1;
      }
    } else if (beforeStationId != null) {
      final beforeIndex = _stationOrder.indexOf(beforeStationId);
      if (beforeIndex != -1) {
        targetIndex = beforeIndex;
      }
    }

    if (targetIndex != -1) {
      if (targetIndex > _stationOrder.length) {
        _stationOrder.add(stationId);
      } else {
        _stationOrder.insert(targetIndex, stationId);
      }
    } else {
      // Fallback
      if (beforeStationId != null) {
        _stationOrder.insert(0, stationId);
      } else if (afterStationId != null) {
        _stationOrder.add(stationId);
      } else {
        _stationOrder.insert(0, stationId);
      }
    }

    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyStationOrder,
      _stationOrder.map((e) => e.toString()).toList(),
    );
  }

  // Helper to ensure all genres are in the order list (if new ones appear)
  void syncGenres(List<String> currentGenres) {
    bool changed = false;
    // Add missing
    for (var g in currentGenres) {
      if (!_genreOrder.contains(g)) {
        _genreOrder.add(g);
        changed = true;
      }
    }
    // Remove obsolete
    _genreOrder.removeWhere((g) => !currentGenres.contains(g));

    if (changed) {
      // Save silently? Or just wait for next reorder?
      // Better to save if we modified meaningful state, but avoiding IO spam is good.
    }
  }

  void syncCategories(List<String> currentCategories) {
    bool changed = false;
    for (var c in currentCategories) {
      if (!_categoryOrder.contains(c)) {
        _categoryOrder.add(c);
        changed = true;
      }
    }
    _categoryOrder.removeWhere((c) => !currentCategories.contains(c));
    if (changed) {
      notifyListeners();
    }
  }

  Future<void> setCustomOrder(bool enabled) async {
    _useCustomOrder = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseCustomOrder, enabled);
  }

  Future<void> _saveHasPerformedRestore() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHasPerformedRestore, _hasPerformedRestore);
  }

  Future<void> _loadUserPlayHistory() async {
    final prefs = await SharedPreferences.getInstance();

    // Load User Play History
    final playHistoryStr = prefs.getString(_keyUserPlayHistory);
    if (playHistoryStr != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(playHistoryStr);
        _userPlayHistory = decoded.map(
          (key, value) => MapEntry(key, value as int),
        );
      } catch (_) {}
    }

    // Load Android Auto History
    final aaPlayHistoryStr = prefs.getString(_keyAAUserPlayHistory);
    if (aaPlayHistoryStr != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(aaPlayHistoryStr);
        _aaUserPlayHistory = decoded.map(
          (key, value) => MapEntry(key, value as int),
        );
      } catch (_) {}
    }

    final metadataStr = prefs.getString(_keyHistoryMetadata);
    if (metadataStr != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(metadataStr);
        _historyMetadata = decoded.map(
          (key, value) => MapEntry(key, SavedSong.fromJson(value)),
        );
      } catch (_) {}
    }

    _recentSongsOrder = prefs.getStringList(_keyRecentSongsOrder) ?? [];
    _aaRecentSongsOrder = prefs.getStringList(_keyAARecentSongsOrder) ?? [];

    final lastSourceStr = prefs.getString(_keyLastSourceMap);
    if (lastSourceStr != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(lastSourceStr);
        _lastSourceMap = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {}
    }

    final weeklyLogStr = prefs.getString(_keyWeeklyPlayLog);
    if (weeklyLogStr != null) {
      try {
        _weeklyPlayLog = jsonDecode(weeklyLogStr);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _loadStartupSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _startOption = prefs.getString(_keyStartOption) ?? 'none';
    _hasPerformedRestore = prefs.getBool(_keyHasPerformedRestore) ?? false;
    _startupStationId = prefs.getInt(_keyStartupStationId);
    // _isACRCloudEnabled is now dynamically derived.
    _isCompactView = prefs.getBool(_keyCompactView) ?? false;
    _crossfadeDuration = prefs.getInt(_keyCrossfadeDuration) ?? 7;
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.setCrossfadeDuration(
        _crossfadeDuration,
      );
    }

    final catViewsStr = prefs.getString(_keyCategoryCompactViews);
    if (catViewsStr != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(catViewsStr);
        _categoryCompactViews.clear();
        _categoryCompactViews.addAll(
          decoded.map((k, v) => MapEntry(k, v as bool)),
        );
      } catch (_) {}
    }
    _isShuffleMode = prefs.getBool(_keyShuffleMode) ?? false;
    // Sync initial state to AudioHandler
    if (_isShuffleMode) {
      _audioHandler.setShuffleMode(AudioServiceShuffleMode.all);
    } else {
      _audioHandler.setShuffleMode(AudioServiceShuffleMode.none);
    }

    // Load invalid songs
    final invalidList = prefs.getStringList(_keyInvalidSongIds);
    if (invalidList != null) {
      _invalidSongIds.clear();
      _invalidSongIds.addAll(invalidList);
    }

    await _loadUserPlayHistory();
  }

  Future<void> _saveUserPlayHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUserPlayHistory, jsonEncode(_userPlayHistory));
    await prefs.setString(
      _keyAAUserPlayHistory,
      jsonEncode(_aaUserPlayHistory),
    );

    final metadataEncoded = _historyMetadata.map(
      (k, v) => MapEntry(k, v.toJson()),
    );
    await prefs.setString(_keyHistoryMetadata, jsonEncode(metadataEncoded));
    await prefs.setStringList(_keyRecentSongsOrder, _recentSongsOrder);
    await prefs.setStringList(_keyAARecentSongsOrder, _aaRecentSongsOrder);
    await prefs.setString(_keyLastSourceMap, jsonEncode(_lastSourceMap));
  }

  Future<void> setCrossfadeDuration(int seconds) async {
    if (_crossfadeDuration != seconds) {
      _crossfadeDuration = seconds;
      notifyListeners();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyCrossfadeDuration, seconds);
      if (_audioHandler is RadioAudioHandler) {
        _audioHandler.setCrossfadeDuration(seconds);
      }
    }
  }

  Future<void> setStartOption(String option) async {
    _startOption = option;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyStartOption, option);
    notifyListeners();
  }

  Future<void> setStartupStationId(int? id) async {
    _startupStationId = id;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_keyStartupStationId);
    } else {
      await prefs.setInt(_keyStartupStationId, id);
    }
    notifyListeners();
  }

  Future<void> reorderStations(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    // Ensure we have a working list populated with all IDs if _stationOrder was empty/partial
    if (_stationOrder.isEmpty || _stationOrder.length != stations.length) {
      _stationOrder = allStations.map((s) => s.id).toList();
    }

    final int item = _stationOrder.removeAt(oldIndex);
    _stationOrder.insert(newIndex, item);

    // Auto-enable custom order if we reorder
    if (!_useCustomOrder) {
      _useCustomOrder = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyUseCustomOrder, true);
    }

    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyStationOrder,
      _stationOrder.map((e) => e.toString()).toList(),
    );
  }

  void _addLog(String message) {
    final time =
        "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}";
    _metadataLog.insert(0, "[$time] $message");
    if (_metadataLog.length > 50) _metadataLog.removeLast();
    notifyListeners();
  }

  void playStation(Station station) async {
    LogService().log("Analytics Result: $station");
    LogService().log("Analytics Result: $station");

    // If we're playing from a playlist (YouTube), stop it first
    if (_hiddenAudioController != null) {
      clearYoutubeAudio();
      _isShuffleMode = false;
    }

    // Ensure playlist mode is OFF so next/prev buttons work for Radio
    _currentPlayingPlaylistId = null;
    _audioOnlySongId = null;
    _metadataTimer
        ?.cancel(); // Cancel any pending recognition timer from previous station

    // Save as "last played" immediately
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLastPlayedStationId, station.id);

    try {
      if (_currentStation?.id == station.id && _isPlaying) {
        pause();
        return;
      }

      _currentStation = station;
      _isLoading = true;
      _currentTrack = station.name;
      _currentArtist = station.genre;
      _currentAlbum = "";
      _currentAlbumArt = station.logo;
      _currentArtistImage = null;
      _currentYoutubeUrl = null;
      _currentAppleMusicUrl = null;
      _currentDeezerUrl = null;
      _currentTidalUrl = null;
      _currentAmazonMusicUrl = null;
      _currentNapsterUrl = null;

      // _addLog("Connecting: ${station.name}...");
      notifyListeners();

      // USE AUDIO HANDLER
      await _audioHandler.playFromUri(Uri.parse(station.url), {
        'title': station.name,
        'artist': station.genre,
        'album': 'Live Radio',
        'artUri': station.logo,
        'user_initiated': true,
      });

      // _isLoading = false; // Remove manual reset, let listener handle it for accuracy
      // notifyListeners();
      // _addLog("Playing via Service");

      // Recognition and Lyrics are now triggered by the playback state listener
      // once buffering is complete.
    } catch (e) {
      _isLoading = false;
      // _addLog("Error: $e");
      notifyListeners();
    }
  }

  void togglePlay() {
    LogService().log("Analytics Result: toggle_play");
    LogService().log("Analytics Result: toggle_play");

    if (_hiddenAudioController != null) {
      _ignoringPause = true; // Guard against notification echo and state loop
      final state = _hiddenAudioController!.value.playerState;
      final bool currentlyPlaying =
          state == PlayerState.playing || state == PlayerState.buffering;

      if (currentlyPlaying) {
        _hiddenAudioController!.pause();
        _isPlaying = false;
        // Immediate sync to AudioHandler to avoid lag
        _audioHandler.customAction('updatePlaybackPosition', {
          'position': _hiddenAudioController!.value.position.inMilliseconds,
          'duration':
              _hiddenAudioController!.value.metaData.duration.inMilliseconds,
          'isPlaying': false,
        });
      } else {
        if (state == PlayerState.ended) {
          _hiddenAudioController!.seekTo(const Duration(seconds: 0));
        }
        _hiddenAudioController!.play();
        _isPlaying = true;
        // Immediate sync to AudioHandler
        _audioHandler.customAction('updatePlaybackPosition', {
          'position': _hiddenAudioController!.value.position.inMilliseconds,
          'duration':
              _hiddenAudioController!.value.metaData.duration.inMilliseconds,
          'isPlaying': true,
        });
      }
      notifyListeners();

      // Release guard after a short delay
      Future.delayed(const Duration(milliseconds: 600), () {
        _ignoringPause = false;
      });
      return;
    } else if (_currentPlayingPlaylistId != null) {
      // Native Playlist Mode
      if (_isPlaying) {
        pause();
      } else {
        resume();
      }
      return;
    }

    if (_currentStation == null) {
      if (stations.isNotEmpty) playStation(stations[0]);
      return;
    }
    if (_isPlaying) {
      pause();
    } else {
      resume();
    }
  }

  void pause() async {
    // _metadataTimer?.cancel(); // Handled by listener
    await _audioHandler.pause();
    // playing state listener will update _isPlaying
  }

  void stop() async {
    _autoSkipCount = 0; // Reset on manual stop
    await _audioHandler.stop();
  }

  void resume() async {
    if (_currentStation != null || _currentPlayingPlaylistId != null) {
      await _audioHandler.play();
    }
  }

  // Helper to instantly kill current audio to prevent overlaps/ghosting
  // Async to ensure the platform channel actually stops playing before proceeding
  Future<void> stopPreviousStream() async {
    if (_hiddenAudioController != null) {
      _hiddenAudioController!.removeListener(_youtubeListener);
      _hiddenAudioController!.pause();
      // Give the native player a moment to process the pause
      await Future.delayed(const Duration(milliseconds: 100));
      _hiddenAudioController!.dispose();
      _hiddenAudioController = null;
    }
    // Also stop the background audio handler completely
    await _audioHandler.stop();

    _stopPlaybackMonitor();
    _metadataTimer?.cancel(); // Crucial: Stop ghost recognition
    _invalidDetectionTimer?.cancel();
    _isLoading = true;
    notifyListeners();
  }

  Future<void> playNext([bool userInitiated = true]) async {
    // 1. Interrupt immediately to stop music NOW
    if (userInitiated) {
      await stopPreviousStream();
    } else {
      // For auto-skip, the player is likely already ended/stopped,
      // but we still ensure cleanup to be safe.
      await stopPreviousStream();
    }

    // Debounce to ensure it only clicks once within a short window (1 second)
    final now = DateTime.now();
    if (_lastPlayNextTime != null &&
        now.difference(_lastPlayNextTime!) < const Duration(seconds: 1)) {
      // debugPrint("playNext: Ignored (Debounced)");
      return;
    }
    _lastPlayNextTime = now;

    if (userInitiated) {
      _autoSkipCount = 0; // Reset on user action
    } else {
      _autoSkipCount++;
      if (_autoSkipCount > 5) {
        LogService().log(
          "Circuit Breaker: Too many consecutive auto-skips ($_autoSkipCount). Stopping playback.",
        );
        stop();
        _errorMessage = "Unable to play songs"; // Optional: Inform UI
        notifyListeners();
        _autoSkipCount = 0;
        return;
      }
    }

    LogService().log(
      "playNext: Performing skip. userInitiated=$userInitiated. Current Track: $_currentTrack",
    );

    if (_hiddenAudioController != null || _currentPlayingPlaylistId != null) {
      _playNextInPlaylist(userInitiated: userInitiated);
    } else {
      playNextStationInFavorites();
    }
  }

  Future<void> playPrevious() async {
    // 1. Interrupt immediately
    await stopPreviousStream();

    final now = DateTime.now();
    if (_lastPlayPreviousTime != null &&
        now.difference(_lastPlayPreviousTime!) < const Duration(seconds: 1)) {
      return;
    }
    _lastPlayPreviousTime = now;

    LogService().log(
      "playPrevious: Performing skip. Current Track: $_currentTrack",
    );
    if (_hiddenAudioController != null || _currentPlayingPlaylistId != null) {
      _playPreviousInPlaylist();
    } else {
      playPreviousStationInFavorites();
    }
  }

  SavedSong? _getNextSongInPlaylist() {
    if (_currentPlayingPlaylistId == null) return null;

    Playlist playlist;
    if (_tempPlaylist != null &&
        _tempPlaylist!.id == _currentPlayingPlaylistId) {
      playlist = _tempPlaylist!;
    } else {
      playlist = playlists.firstWhere(
        (p) => p.id == _currentPlayingPlaylistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
    }
    if (playlist.songs.isEmpty) return null;

    // Filter out invalid songs to prevent playing them
    // Logic: Look for the next song. If invalid, keep looking.
    // We limit this to the playlist length to avoid infinite loops if ALL are invalid.

    int currentIndex = -1;
    if (_audioOnlySongId != null) {
      currentIndex = playlist.songs.indexWhere((s) => s.id == _audioOnlySongId);
    }

    int attempts = 0;
    // We Loop to find a VALID formatted song
    while (attempts < playlist.songs.length) {
      int nextIndex = 0;

      if (_isShuffleMode) {
        if (_shuffledIndices.length != playlist.songs.length) {
          _generateShuffleList();
        }

        int currentShuffledIndex = -1;
        if (currentIndex != -1) {
          currentShuffledIndex = _shuffledIndices.indexOf(currentIndex);
        }

        if (currentShuffledIndex != -1) {
          if (currentShuffledIndex + 1 >= _shuffledIndices.length) {
            nextIndex = _shuffledIndices[0];
          } else {
            nextIndex = _shuffledIndices[currentShuffledIndex + 1];
          }
        } else {
          if (_shuffledIndices.isNotEmpty) {
            nextIndex = _shuffledIndices[0];
          }
        }
      } else {
        if (currentIndex != -1) {
          if (currentIndex + 1 >= playlist.songs.length) {
            nextIndex = 0;
          } else {
            nextIndex = currentIndex + 1;
          }
        } else {
          nextIndex = 0;
        }
      }

      final candidate = playlist.songs[nextIndex];
      // Check if this candidate is valid
      // A song is valid if:
      // 1. It is not in the _invalidSongIds list (Legacy)
      // 2. Its .isValid flag is true
      // 3. Its duration is NOT zero (if known)
      if (!candidate.isValid || _invalidSongIds.contains(candidate.id)) {
        currentIndex = nextIndex;
        attempts++;
        continue;
      }
      return candidate;
    }

    return null; // All songs invalid or list empty
  }

  Future<void> _playNextInPlaylist({bool userInitiated = true}) async {
    LogService().log(
      "Advancing to next song in playlist. userInitiated=$userInitiated",
    );
    final nextSong = _getNextSongInPlaylist();
    if (nextSong != null && _currentPlayingPlaylistId != null) {
      await playPlaylistSong(nextSong, _currentPlayingPlaylistId!);
    } else {
      LogService().log("No next song found in playlist or no active playlist.");
    }
  }

  Future<void> _playPreviousInPlaylist() async {
    if (_currentPlayingPlaylistId == null || _audioOnlySongId == null) return;

    Playlist playlist;
    if (_tempPlaylist != null &&
        _tempPlaylist!.id == _currentPlayingPlaylistId) {
      playlist = _tempPlaylist!;
    } else {
      playlist = playlists.firstWhere(
        (p) => p.id == _currentPlayingPlaylistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
    }
    if (playlist.songs.isEmpty) return;

    final currentOriginalIndex = playlist.songs.indexWhere(
      (s) => s.id == _audioOnlySongId,
    );
    if (currentOriginalIndex == -1) return;

    int prevIndex;

    if (_isShuffleMode) {
      // Ensure shuffle list is valid
      if (_shuffledIndices.length != playlist.songs.length) {
        _generateShuffleList();
      }

      int currentShuffledIndex = _shuffledIndices.indexOf(currentOriginalIndex);
      if (currentShuffledIndex == -1) {
        _generateShuffleList();
        currentShuffledIndex = _shuffledIndices.indexOf(currentOriginalIndex);
      }

      if (currentShuffledIndex - 1 < 0) {
        // Start of shuffled list
        prevIndex =
            _shuffledIndices[_shuffledIndices.length - 1]; // Loop to end
      } else {
        prevIndex = _shuffledIndices[currentShuffledIndex - 1];
      }
    } else {
      // Normal Order
      prevIndex =
          (currentOriginalIndex - 1 + playlist.songs.length) %
          playlist.songs.length;
    }

    final prevSong = playlist.songs[prevIndex];

    await playPlaylistSong(prevSong, playlist.id);
  }

  Future<void> playPlaylistSong(SavedSong song, String? playlistId) async {
    // STOP PREVIOUS STREAM IMMEDIATELY
    // Re-use helper to be sure, although playNext/Prev already called it.
    // This covers case where playPlaylistSong is called directly (e.g. clicking item in list)
    await stopPreviousStream();

    LogService().log("Analytics Result: play_song");

    // Prevent playback of invalid songs
    if (!song.isValid || _invalidSongIds.contains(song.id)) {
      LogService().log("Skipping invalid song request: ${song.title}");
      _playNextInPlaylist();
      return;
    }
    // Optimistic UI update
    _currentTrack = song.title;
    _currentArtist = song.artist;
    _currentAlbum = song.album; // Optimistic Album
    _currentAlbumArt = song.artUri;
    _audioOnlySongId =
        song.id; // Also update ID so ID-based UI remains consistent

    // RESET PLAYBACK IMMEDIATE (UI FEEDBACK)
    // Update MediaItem to new song with 0 duration to reset counters/bar
    _audioHandler.updateMediaItem(
      MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        artUri: song.artUri != null ? Uri.tryParse(song.artUri!) : null,
        duration: (song.duration != null && song.duration!.inSeconds > 0)
            ? song.duration
            : null,
        extras: {
          'isLocal': song.localPath != null,
          'type': 'playlist_song',
          'songId': song.id,
          'playlistId': playlistId,
        },
      ),
    );
    // Reset position state if possible (though stream might lag slightly, this helps)
    // We invoke stop() which usually resets state in AudioService handlers
    // _audioHandler.stop(); // Redundant and potentially causes race with awaited stop() below

    String playlistName = "Playlist";
    if (playlistId != null) {
      try {
        final pl = playlists.firstWhere((p) => p.id == playlistId);
        playlistName = pl.name;
      } catch (_) {}
    }

    // Optimistically set station to prevent "Select a station" flash
    _currentStation = Station(
      id: -999,
      name: playlistName,
      genre: "My Playlist",
      url: "youtube://loading",
      icon: "youtube",
      color: "0xFF212121",
      logo: song.artUri,
      category: "Playlist",
    );

    // Lyrics fetch moved to after successful resolution
    _currentTrackStartTime = DateTime.now();

    _metadataTimer?.cancel(); // CANCEL recognition timer
    _isLoading = true; // User initiated: Force loading state immediately
    _isPlaying = true; // Optimistically show pause icon
    notifyListeners();

    try {
      // We manually manage state to show "Loading" while we resolved/stop
      _ignoringPause = true;
      _isLoading = true;
      _isPlaying = true; // Maintain "Playing" state in UI (Pause icon)
      notifyListeners();

      // REMOVED redundant await _audioHandler.stop() - handled by playFromUri/playYoutubeAudio
      // This avoids extra delay and race conditions with the 'stopped' event broadcast.

      // Delay resetting to ensure any pending events from the PREVIOUS player state are ignored
      Future.delayed(const Duration(milliseconds: 1000), () {
        _ignoringPause = false;
      });

      String? videoId;

      // 0. LOCAL FILE CHECK (Priority over stream)
      if (song.localPath != null) {
        final file = File(song.localPath!);
        if (await file.exists()) {
          await playYoutubeAudio(
            song.localPath!,
            song.id,
            playlistId: playlistId,
            overrideTitle: song.title,
            overrideArtist: song.artist,
            overrideAlbum: song.album,
            overrideArtUri: song.artUri,
            isLocal: true,
          );
          fetchLyrics(); // Fetch lyrics for local file
          return;
        } else {
          // File check failed
          if (_isOffline) {
            LogService().log(
              "Offline: Local file check failed for ${song.localPath}. Attempting to play anyway.",
            );
            // Try to play locally even if check failed (e.g. permission issue or flaky check)
            // This prevents clearing the path when we have no internet to Fallback anyway.
            await playYoutubeAudio(
              song.localPath!,
              song.id,
              playlistId: playlistId,
              overrideTitle: song.title,
              overrideArtist: song.artist,
              overrideAlbum: song.album,
              overrideArtUri: song.artUri,
              isLocal: true,
            );
            return;
          }

          LogService().log(
            "Local file not found: ${song.localPath}. Reverting to online.",
          );
          // Instead of invalidating, we clear the local path and let it fall through to online playback
          final updated = song.copyWith(forceClearLocalPath: true);

          // Sync this change so UI updates (removes download icon)
          await _syncSongDownloadStatusInternal(updated);
          await _playlistService.saveAll(_playlists);

          // Update local variable to proceed with online logic
          // ignore: parameter_assignments
          song = updated;
        }
      }

      // 1. Direct Stream Support (Audius, etc.)
      bool isDeezer = song.provider?.toLowerCase() == 'deezer';

      if (song.rawStreamUrl != null &&
          song.rawStreamUrl!.isNotEmpty &&
          !isDeezer) {
        LogService().log("Direct Link: Using rawStreamUrl for ${song.title}");
        await playYoutubeAudio(
          song.rawStreamUrl!,
          song.id,
          playlistId: playlistId,
          overrideTitle: song.title,
          overrideArtist: song.artist,
          overrideAlbum: song.album,
          overrideArtUri: song.artUri,
          isLocal: false,
          isResolved: true,
        );
        return;
      }

      if (song.youtubeUrl != null) {
        videoId = YoutubePlayer.convertUrlToId(song.youtubeUrl!);
        // If it was already a raw 11-char ID, use it directly
        if (videoId == null && song.youtubeUrl!.length == 11) {
          videoId = song.youtubeUrl;
        }
      }

      // Optimization for Remote Playlists:
      // If we don't have a videoId yet but the song ID itself looks like a YouTube ID
      // and it's from a trending or remote playlist, use it directly.
      if (videoId == null &&
          playlistId != null &&
          playlistId.startsWith('trending_')) {
        if (song.id.length == 11) {
          videoId = song.id;
          LogService().log(
            "Remote Playlist: Using Song ID as direct YouTube ID: $videoId",
          );
        }
      }

      if (videoId == null) {
        Map<String, String?> links = {};
        try {
          links = await resolveLinks(
            title: song.title,
            artist: song.artist,
            youtubeUrl: song.youtubeUrl,
            appleMusicUrl: song.appleMusicUrl,
          ).timeout(const Duration(seconds: 8));
        } catch (e) {
          LogService().log(
            "ResolveLinks failed or timed out: $e. Proceeding to fallback.",
          );
        }

        // Race condition guard after deep search
        if (_audioOnlySongId != song.id) return;

        final url = links['youtube'];
        if (url != null) {
          videoId = YoutubePlayer.convertUrlToId(url);
          // Fallback manual
          if (videoId == null && url.contains('v=')) {
            videoId = url.split('v=').last.split('&').first;
          }
        }
      }

      // 3. SEQUENTIAL SEARCH: YoutubeExplode
      // If we still don't have a videoId, try multiple search queries in sequence
      if (videoId == null) {
        final yt = yt_explode.YoutubeExplode();
        try {
          // Attempt 1: Artist + Title (Best for specific matches)
          LogService().log("Search Step 1: '${song.artist} ${song.title}'");
          var results = await yt.search.search("${song.artist} ${song.title}");

          // Attempt 2: Clean Title + Artist (Fallback)
          if (results.isEmpty) {
            final cleanTitle = song.title
                .replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '')
                .trim();
            LogService().log("Search Step 2: '$cleanTitle ${song.artist}'");
            results = await yt.search.search("$cleanTitle ${song.artist}");
          }

          // Attempt 3: Title only (if long enough)
          if (results.isEmpty && song.title.length > 5) {
            LogService().log("Search Step 3: '${song.title}'");
            results = await yt.search.search(song.title);
          }

          if (results.isNotEmpty && _audioOnlySongId == song.id) {
            videoId = results.first.id.value;
            LogService().log("Found ID via sequential search: $videoId");
          }
        } catch (e) {
          LogService().log("Sequential YouTube search error: $e");
        } finally {
          yt.close();
        }
      }

      // Fetch Lyrics immediately before playing via YouTube (after resolution)
      fetchLyrics();

      if (videoId != null) {
        // Clear loading after a maximum of 15 seconds regardless of state events
        final currentId = song.id;
        Future.delayed(const Duration(seconds: 15), () {
          if (_isLoading && _audioOnlySongId == currentId) {
            _isLoading = false;
            notifyListeners();
          }
        });

        // Race condition guard: If user clicked another song while resolving, abort
        if (_audioOnlySongId != song.id) {
          debugPrint(
            "playPlaylistSong: Song changed during resolution, aborting.",
          );
          return;
        }

        await playYoutubeAudio(
          videoId,
          song.id,
          playlistId: playlistId,
          overrideTitle: song.title,
          overrideArtist: song.artist,
          overrideAlbum: song.album,
          overrideArtUri: song.artUri,
        ); // Recursive metadata update
      } else {
        _isLoading = false;
        notifyListeners();

        // No Video ID found -> Invalid Song (Metadata issue)
        if (playlistId != null) {
          if (_isOffline) {
            LogService().log(
              "Offline: Cannot resolve video ID for ${song.title}. Waiting for connection...",
            );
            _isLoading = false;
            notifyListeners();
            return;
          }

          if (_isRemotePlaylistId(playlistId)) {
            LogService().log(
              "Trending Playlist: Cannot resolve video ID for ${song.title}. Skipping without marking as invalid.",
            );
          } else {
            LogService().log(
              "No Video ID found for: ${song.title}. Skipping (not invalidating).",
            );
          }

          await Future.delayed(const Duration(seconds: 1));
          playNext(false);
        }
      }
    } catch (e) {
      _isLoading = false;
      notifyListeners();

      LogService().log("Error in playPlaylistSong: $e");

      if (playlistId != null) {
        await Future.delayed(const Duration(seconds: 1));
        playNext(false);
      }
    }
  }

  void previewSong(SavedSong song) {
    _currentTrack = song.title;
    _currentArtist = song.artist;
    _currentAlbum = song.album;
    _currentAlbumArt = song.artUri;
    // Do NOT set isLoading or trigger audio.
    // Just update UI to reflect selection.
    notifyListeners();
  }

  void setVolume(double vol) {
    _volume = vol;
    _audioHandler.customAction('setVolume', {'volume': vol});
    notifyListeners();
  }

  bool _isObservingLyrics = false;
  String? _lastLyricsSearch;

  void setObservingLyrics(bool isObserving) {
    if (_isObservingLyrics != isObserving) {
      _isObservingLyrics = isObserving;
      if (_isObservingLyrics) {
        // Trigger immediate search when entering the SongDetailsScreen
        fetchLyrics(force: true);
      }
    }
  }

  Future<void> refreshLyrics() async {
    _lastLyricsSearch = null;
    await fetchLyrics(force: true);
  }

  Future<void> fetchLyrics({
    bool force = false,
    bool fromRecognition = false,
  }) async {
    // 1. Visibility & Entitlement Guards
    if (!_isObservingLyrics && !force) return;
    if (!_entitlementService.isFeatureEnabled('lyrics')) return;

    // 2. Metadata Guard
    if (_currentTrack.isEmpty ||
        _currentTrack == "Live Broadcast" ||
        _currentArtist.isEmpty) {
      _currentLyrics = LyricsData.empty();
      _lastLyricsSearch = null;
      notifyListeners();
      return;
    }

    // 3. Prepare Search Key & Duplicate Guard
    final sanitizedArtist = _sanitizeArtistName(_currentArtist);
    final cleanArtist = LyricsService.cleanString(sanitizedArtist);
    final cleanTitle = LyricsService.cleanString(_currentTrack);
    final searchKey = "$cleanArtist|$cleanTitle";

    // Prevent duplicate searches for the same song if already fetching or if we already have the lyrics
    if (!force && _lastLyricsSearch == searchKey) {
      if (_isFetchingLyrics || _currentLyrics.lines.isNotEmpty) {
        return;
      }
    }

    // 4. Radio/Playlist Context
    final bool isRadio = _currentPlayingPlaylistId == null && _currentStation != null;

    // 5. Radio-Specific Guard: Only fetch if recognized
    if (isRadio && isACRCloudEnabled && !_isCurrentTrackRecognized) {
      LogService().log("[Lyrics] Radio: Waiting for recognition for \"$_currentTrack\"");
      _lastLyricsSearch = searchKey;
      _isFetchingLyrics = false;
      _currentLyrics = LyricsData.empty();
      notifyListeners();
      return;
    }

    // 6. Streaming Timing Guard (Wait for audio to actually start)
    if (_currentTrackStartTime == null && !force) {
      LogService().log("Lyrics Search: Waiting for streaming to start...");
      return;
    }

    // Optional: Keep a small delay for new tracks to let metadata settle, unless forced (page entry)
    if (!force && !fromRecognition) {
      final streamStartTime = _currentTrackStartTime ?? DateTime.now();
      final elapsedSinceStream = DateTime.now().difference(streamStartTime);
      if (elapsedSinceStream < const Duration(seconds: 4)) {
        final waitMs = (const Duration(seconds: 4) - elapsedSinceStream).inMilliseconds;
        LogService().log("[Lyrics] Throttling search for ${waitMs}ms...");
        await Future.delayed(Duration(milliseconds: waitMs));
        
        // Re-verify after delay
        if (_currentTrack.isEmpty || 
            "$cleanArtist|$cleanTitle" != "$_currentArtist|$_currentTrack") return;
      }
    }

    // 7. Initiate Search
    _isFetchingLyrics = true;
    _lastLyricsSearch = searchKey;
    
    // Clear old lyrics only if it's a new song
    if (_currentLyrics.lines.isEmpty || _lastLyricsSearch != searchKey) {
      _currentLyrics = LyricsData.empty();
      _originalLyrics = null;
      _isLyricsTranslated = false;
      _lyricsOffset = Duration.zero;
    }
    notifyListeners();

    try {
      LogService().log("[Lyrics] Fetching for $searchKey (isRadio: $isRadio)...");
      
      final results = await _lyricsService.fetchLyrics(
        artist: _currentArtist,
        title: _currentTrack,
        isRadio: isRadio,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          LogService().log("[Lyrics] Search TIMEOUT for \"$_currentTrack\"");
          return LyricsData.empty();
        },
      );

      // Only update if metadata hasn't changed while we were fetching
      if (_lastLyricsSearch == searchKey) {
        if (results.lines.isNotEmpty) {
          _currentLyrics = results;
          _originalLyrics = results;
          _isLyricsTranslated = false;
        } else {
          _currentLyrics = LyricsData.empty();
        }
      }
    } catch (e) {
      LogService().log("[Lyrics] Error fetching lyrics: $e");
      if (_lastLyricsSearch == searchKey) {
        _currentLyrics = LyricsData.empty();
      }
    } finally {
      if (_lastLyricsSearch == searchKey) {
        _isFetchingLyrics = false;
        notifyListeners();
      }
    }
  }

  Future<void> toggleLyricsTranslation(String langCode) async {
    if (_currentLyrics.lines.isEmpty && _originalLyrics == null) return;

    // If already translated, revert to original
    if (_isLyricsTranslated && _originalLyrics != null) {
      _currentLyrics = _originalLyrics!;
      _isLyricsTranslated = false;
      notifyListeners();
      return;
    }

    // Begin translation
    _isTranslatingLyrics = true;
    notifyListeners();

    try {
      final baseLyrics = _originalLyrics ?? _currentLyrics;
      // Use language code for translation (e.g. 'it', 'es', 'zh')
      // Map basic locale string directly
      String targetLang = langCode.split('_').first;

      final translated = await _lyricsService.translateLyrics(
        baseLyrics,
        targetLang,
      );

      _currentLyrics = translated;
      _isLyricsTranslated = true;
    } catch (e) {
      LogService().log("Error in toggleLyricsTranslation: $e");
    } finally {
      _isTranslatingLyrics = false;
      notifyListeners();
    }
  }

  void toggleFavorite(int id) async {
    if (_favorites.contains(id)) {
      _favorites.remove(id);
    } else {
      _favorites.add(id);
    }
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _keyFavorites,
      _favorites.map((e) => e.toString()).toList(),
    );
  }

  // --- External Links (SongLink) ---

  Future<String?> addCurrentSongToGenrePlaylist() async {
    if (_currentTrack.isEmpty || _currentStation == null) return null;

    final songId = "${_currentTrack}_${_currentArtist}";
    final genre = _currentGenre ?? "Mix";

    // Sanitize album name: remove station name etc.
    String cleanAlbum = _currentAlbum;
    final stationName = _currentStation?.name ?? "";
    if (stationName.isNotEmpty && cleanAlbum.contains(stationName)) {
      cleanAlbum = cleanAlbum
          .replaceAll(stationName, "")
          .replaceAll("•", "")
          .trim();
    }

    // If we don't have a YouTube URL yet (common for radio station metadata),
    // try to find one proactively so the song is "sharable" later.
    String? resolvedUrl = _currentYoutubeUrl;
    if (resolvedUrl == null || resolvedUrl.isEmpty) {
      _isLoading = true;
      notifyListeners();
      try {
        resolvedUrl = await searchYoutubeVideo(_currentTrack, _currentArtist);
      } catch (_) {}
      _isLoading = false;
    }

    final song = SavedSong(
      id: songId,
      title: _currentTrack,
      artist: _currentArtist,
      album: cleanAlbum,
      artUri: _currentAlbumArt ?? _currentStation!.logo ?? "",
      duration: _currentSongDuration ?? Duration.zero,
      dateAdded: DateTime.now(),
      youtubeUrl: resolvedUrl, // Now with a better chance of being sharable
      isValid: true,
    );

    // Optimistic Update
    _currentSongIsSaved = true;
    notifyListeners();

    try {
      // Use service to add to specific genre playlist
      await _playlistService.addToGenrePlaylist(genre, song);
    } catch (e) {
      // Revert if failed
      _currentSongIsSaved = false;
      notifyListeners();
      return null;
    }

    return genre;
  }

  String _cleanSongTitle(String title) {
    return title.replaceAll("⬇️ ", "").replaceAll("📱 ", "").trim();
  }

  Future<void> checkIfCurrentSongIsSaved() async {
    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") {
      _currentSongIsSaved = false;
      _isInOtherPlaylists = false;
      _isSavedAnywhere = false;
    } else {
      _currentSongIsSaved = await isInFavoritesLogic();
      _isInOtherPlaylists = await isInOtherPlaylistsLogic();
      _isSavedAnywhere = await isSavedAnywhereLogic();
    }
    notifyListeners();
  }

  Future<bool> isInFavoritesLogic() async {
    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") return false;
    final cleanTitle = _cleanSongTitle(_currentTrack);
    final playlists = await _playlistService.loadPlaylists();
    final fav = playlists.firstWhere(
      (p) => p.id == 'favorites',
      orElse: () => Playlist(
        id: 'favorites',
        name: 'Favorites',
        songs: [],
        createdAt: DateTime.now(),
      ),
    );
    return fav.songs.any(
      (s) => _cleanSongTitle(s.title) == cleanTitle && s.artist == _currentArtist,
    );
  }

  Future<bool> isInOtherPlaylistsLogic() async {
    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") return false;
    final cleanTitle = _cleanSongTitle(_currentTrack);
    final playlists = await _playlistService.loadPlaylists();
    return playlists.any(
      (p) =>
          p.id != 'favorites' &&
          p.songs.any(
            (s) => _cleanSongTitle(s.title) == cleanTitle && s.artist == _currentArtist,
          ),
    );
  }

  Future<bool> isSavedAnywhereLogic() async {
    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") return false;
    return await _playlistService.isSongInFavorites(
      _cleanSongTitle(_currentTrack),
      _currentArtist,
    );
  }

  Future<void> removeCurrentSongFromPlaylist(String playlistId) async {
    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") return;
    final cleanTitle = _cleanSongTitle(_currentTrack);
    final cleanArtist = _currentArtist;

    try {
      final playlists = await _playlistService.loadPlaylists();
      final index = playlists.indexWhere((p) => p.id == playlistId);
      if (index != -1) {
        final initialLen = playlists[index].songs.length;
        playlists[index].songs.removeWhere((s) {
          final sTitle = _cleanSongTitle(s.title);
          return sTitle == cleanTitle && s.artist == cleanArtist;
        });
        if (playlists[index].songs.length != initialLen) {
          await _playlistService.saveAll(playlists);
          if (playlistId == 'favorites') {
            _currentSongIsSaved = false;
          }
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint("Error removing song from playlist: $e");
    }
  }

  Future<bool?> toggleCurrentSongFavorite() async {
    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") return null;
    if (_isRecognizing) return null;

    final cleanTitle = _cleanSongTitle(_currentTrack);
    final cleanArtist = _currentArtist;

    if (_currentSongIsSaved) {
      // Remove
      try {
        final playlists = await _playlistService.loadPlaylists();
        bool changed = false;
        for (var p in playlists) {
          final initialLen = p.songs.length;
          p.songs.removeWhere((s) {
            final sTitle = _cleanSongTitle(s.title);
            return sTitle == cleanTitle && s.artist == cleanArtist;
          });
          if (p.songs.length != initialLen) changed = true;
        }
        if (changed) {
          await _playlistService.saveAll(playlists);
        }
        _currentSongIsSaved = false;
        notifyListeners();
        return false;
      } catch (e) {
        debugPrint("Error toggling favorite (remove): $e");
        return null;
      }
    } else {
      // Add
      try {
        // Sanitize album name: remove station name etc.
        String cleanAlbum = _currentAlbum;
        final stationName = _currentStation?.name ?? "";
        if (stationName.isNotEmpty && cleanAlbum.contains(stationName)) {
          cleanAlbum = cleanAlbum
              .replaceAll(stationName, "")
              .replaceAll("•", "")
              .trim();
        }

        // If we don't have a YouTube URL yet (common for radio station metadata),
        // try to find one proactively so the song is "sharable" later.
        String? resolvedUrl = _currentYoutubeUrl;
        if (resolvedUrl == null || resolvedUrl.isEmpty) {
          _isLoading =
              true; // Use private isLoading if available or just proceed
          notifyListeners();
          try {
            resolvedUrl = await searchYoutubeVideo(cleanTitle, cleanArtist);
          } catch (_) {}
          _isLoading = false;
        }

        final songId = "${cleanTitle}_${cleanArtist}";
        final song = SavedSong(
          id: songId,
          title: cleanTitle,
          artist: cleanArtist,
          album: cleanAlbum,
          artUri: _currentAlbumArt ?? _currentStation?.logo ?? "",
          duration: _currentSongDuration ?? Duration.zero,
          dateAdded: DateTime.now(),
          youtubeUrl: resolvedUrl, // Now with a better chance of being sharable
          isValid: true,
        );

        await _playlistService.addSongToPlaylist('favorites', song);
        _currentSongIsSaved = true;
        notifyListeners();
        return true;
      } catch (e) {
        debugPrint("Error toggling favorite (add): $e");
        return null;
      }
    }
  }

  String _sanitizeArtistName(String artist) {
    // Stop at first occurrence of ( , & /
    // Regex split using [\(,&/]
    if (artist.isEmpty) return artist;
    return artist.split(RegExp(r'[\\(,&/]')).first.trim();
  }

  Future<void> fetchSmartLinks({bool keepExistingArtwork = false}) async {
    // If not playing, don't fetch anything to save resources
    if (!_isPlaying &&
        _currentPlayingPlaylistId == null &&
        (_hiddenAudioController == null ||
            !_hiddenAudioController!.value.isPlaying)) {
      // However, we must allow fetching if we are PAUSED but have content.
      // Easiest check: do we have a station or playlist active?
      // If we are completely stopped (no station, no playlist), return.
      if (_currentStation == null && _currentPlayingPlaylistId == null) return;
    }

    if (_currentTrack.isEmpty || _currentTrack == "Live Broadcast") return;

    // Reset images to prevent showing previous song's art
    // respecting the flag
    if (!keepExistingArtwork) {
      _currentAlbumArt = _currentStation?.logo;
    }
    _currentArtistImage =
        null; // Always reset artist image for now? Or keep? stick to album art for now.

    // Check if song is already saved
    checkIfCurrentSongIsSaved();
    notifyListeners();

    final links = await resolveLinks(
      title: _currentTrack,
      artist: _currentArtist,
      youtubeUrl: _currentYoutubeUrl,
      appleMusicUrl: _currentAppleMusicUrl,
    );

    // Update State
    if (links.containsKey('thumbnailUrl')) {
      if (!keepExistingArtwork || _currentAlbumArt == null) {
        _currentAlbumArt = links['thumbnailUrl'];
      }
    }

    // Fetch Artist Image using Deezer (Requested Method)
    try {
      if (_currentArtist.isNotEmpty) {
        final query = _sanitizeArtistName(_currentArtist);
        final uri = Uri.parse(
          "https://api.deezer.com/search/artist?q=${Uri.encodeComponent(query)}&limit=1",
        );
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final json = jsonDecode(response.body);
          if (json['data'] != null && (json['data'] as List).isNotEmpty) {
            String? picture =
                json['data'][0]['picture_xl'] ??
                json['data'][0]['picture_big'] ??
                json['data'][0]['picture_medium'];

            if (picture != null) {
              _currentArtistImage = picture;
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error fetching artist image from Deezer: $e");
    }

    if (links.containsKey('youtube')) _currentYoutubeUrl = links['youtube'];
    if (links.containsKey('appleMusic')) {
      _currentAppleMusicUrl = links['appleMusic'];
    }
    if (links.containsKey('deezer')) _currentDeezerUrl = links['deezer'];
    if (links.containsKey('tidal')) _currentTidalUrl = links['tidal'];
    if (links.containsKey('amazonMusic')) {
      _currentAmazonMusicUrl = links['amazonMusic'];
    }
    if (links.containsKey('napster')) _currentNapsterUrl = links['napster'];

    notifyListeners();

    // Update Notification/Audio Service
    if (_currentStation != null) {
      _audioHandler.updateMediaItem(
        MediaItem(
          id: _currentStation!.url,
          title: _currentTrack,
          artist: (_currentGenre != null && _currentGenre!.isNotEmpty)
              ? "$_currentArtist"
              : _currentArtist,
          album: _currentAlbum.isNotEmpty
              ? ((_currentGenre != null && _currentGenre!.isNotEmpty)
                    ? "$_currentAlbum"
                    : _currentAlbum)
              : _currentGenre,
          genre: _currentGenre,
          artUri: _currentAlbumArt != null
              ? Uri.parse(_currentAlbumArt!)
              : (_currentStation?.logo != null
                    ? Uri.parse(_currentStation!.logo!)
                    : null),
          extras: {
            'url': _currentStation!.url,
            'stationId': _currentStation!.id,
            'type': 'station',
            'youtubeUrl': _currentYoutubeUrl,
            'appleMusicUrl': _currentAppleMusicUrl,
            'deezerUrl': _currentDeezerUrl,
            'tidalUrl': _currentTidalUrl,
            'amazonMusicUrl': _currentAmazonMusicUrl,
            'napsterUrl': _currentNapsterUrl,
          },
        ),
      );
    }
  }

  // --- Backup & Restore Logic ---

  String _backupFrequency = 'manual';
  String get backupFrequency => _backupFrequency;

  Future<void> _checkAutoBackup() async {
    // Wait for auth to settle
    await Future.delayed(const Duration(seconds: 2));

    final prefs = await SharedPreferences.getInstance();
    _backupFrequency = prefs.getString('backup_frequency') ?? 'manual';
    _lastBackupTs = prefs.getInt('last_backup_ts') ?? 0;
    _lastBackupType = prefs.getString('last_backup_type') ?? 'manual';
    notifyListeners();

    // Sync Workmanager Schedule
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      if (_backupFrequency == 'daily') {
        Workmanager().registerPeriodicTask(
          kAutoBackupTask,
          kAutoBackupTask,
          frequency: const Duration(hours: 24),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else if (_backupFrequency == 'weekly') {
        Workmanager().registerPeriodicTask(
          kAutoBackupTask,
          kAutoBackupTask,
          frequency: const Duration(days: 7),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else {
        Workmanager().cancelByUniqueName(kAutoBackupTask);
      }
    }

    if (!_backupService.isSignedIn) return;

    if (_backupFrequency == 'manual') return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - _lastBackupTs;

    bool due = false;
    if (_backupFrequency == 'daily' && diff > 86400000) due = true;
    if (_backupFrequency == 'weekly' && diff > 604800000) due = true;

    if (due) {
      await performBackup(isAuto: true);
    }
  }

  Future<void> setBackupFrequency(String freq) async {
    _backupFrequency = freq;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backup_frequency', freq);
    notifyListeners();

    // Check immediately if we switched to auto and it is due
    _checkAutoBackup();
  }

  Future<void> performBackup({bool isAuto = false}) async {
    if (!_backupService.isSignedIn) return;

    _isBackingUp = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'stations': stations.map((s) => s.toJson()).toList(),
        'favorites': _favorites,
        'station_order': _stationOrder,
        'genre_order': _genreOrder,
        'category_order': _categoryOrder,
        'invalid_song_ids': _invalidSongIds,
        'playlists': _playlists.map((p) => p.toJson()).toList(),
        'user_play_history': _userPlayHistory,
        'history_metadata': _historyMetadata.map(
          (k, v) => MapEntry(k, v.toJson()),
        ),
        'recent_songs_order': _recentSongsOrder,
        'followed_artists': _followedArtists.toList(),
        'followed_albums': _followedAlbums.toList(),
        'promoted_playlists': _promotedPlaylists
            .map((p) => p.toJson())
            .toList(),
        'theme_settings': {
          'theme_id': prefs.getString('theme_id'),
          'custom_primary': prefs.getInt('custom_primary'),
          'custom_bg': prefs.getInt('custom_bg'),
          'custom_card': prefs.getInt('custom_card'),
          'custom_surface': prefs.getInt('custom_surface'),
          'custom_bg_image': prefs.getString('custom_bg_image'),
        },
        'playback_settings': {
          'crossfade_duration': _crossfadeDuration,
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'version': 3, // Increment version
        'type': isAuto ? 'auto' : 'manual',
      };

      await _backupService.uploadBackup(jsonEncode(data));

      _lastBackupTs = DateTime.now().millisecondsSinceEpoch;
      _lastBackupType = isAuto ? 'auto' : 'manual';
      await prefs.setInt('last_backup_ts', _lastBackupTs);
      await prefs.setString('last_backup_type', _lastBackupType);
      notifyListeners();

      _addLog("Backup Complete");
    } catch (e) {
      _addLog("Backup Failed: $e");
      rethrow;
    } finally {
      _isBackingUp = false;
      notifyListeners();
    }
  }

  Future<void> restoreBackup({bool isFullReplace = false}) async {
    if (!_backupService.isSignedIn) return;

    // Ferma la riproduzione per ripulire PlayerBar e NowPlayingHeader durante lo switch
    try {
      await _audioHandler.stop();
    } catch (_) {}

    _isRestoring = true;
    notifyListeners();

    try {
      LogService().log("[RadioProvider] Starting restoreBackup...");
      final jsonStr = await _backupService.downloadBackup().timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw Exception("Backup download timed out"),
      );
      if (jsonStr == null) {
        throw Exception("No backup found");
      }
      LogService().log(
        "[RadioProvider] Backup downloaded, length: ${jsonStr.length}",
      );

      final data = jsonDecode(jsonStr);

      // Restore Stations
      if (data['stations'] != null) {
        final List<dynamic> sList = data['stations'];
        final List<Station> backupStations = sList
            .map((e) => Station.fromJson(e))
            .toList();

        if (isFullReplace) {
          stations = backupStations;
        } else {
          // Merge Logic: Keep local "new" stations
          final Map<int, Station> mergedMap = {for (var s in stations) s.id: s};
          for (var s in backupStations) {
            mergedMap[s.id] = s;
          }
          stations = mergedMap.values.toList();
        }
        await _saveStations(); // Persist
      }

      // Restore Favorites
      if (data['favorites'] != null) {
        _favorites.clear();
        _favorites.addAll((data['favorites'] as List).map((e) => e as int));
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _keyFavorites,
          _favorites.map((e) => e.toString()).toList(),
        );
      }

      // Restore Orders
      if (data['station_order'] != null) {
        _stationOrder = (data['station_order'] as List)
            .map((e) => e as int)
            .toList();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _keyStationOrder,
          _stationOrder.map((e) => e.toString()).toList(),
        );
      }
      if (data['genre_order'] != null) {
        _genreOrder = (data['genre_order'] as List)
            .map((e) => e as String)
            .toList();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_keyGenreOrder, _genreOrder);
      }
      if (data['category_order'] != null) {
        _categoryOrder = (data['category_order'] as List)
            .map((e) => e as String)
            .toList();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_keyCategoryOrder, _categoryOrder);
      }

      // Restore Invalid Songs
      if (data['invalid_song_ids'] != null) {
        final List<String> loadedInvalid = (data['invalid_song_ids'] as List)
            .map((e) => e.toString())
            .toList();

        if (isFullReplace) {
          _invalidSongIds.clear();
          _invalidSongIds.addAll(loadedInvalid);
        } else {
          // Merge with existing
          for (var id in loadedInvalid) {
            if (!_invalidSongIds.contains(id)) {
              _invalidSongIds.add(id);
            }
          }
        }

        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
      }

      // Restore Promoted Playlists (Favorites from Trending)
      if (data['promoted_playlists'] != null) {
        final List<dynamic> ppList = data['promoted_playlists'];
        _promotedPlaylists.clear();
        _promotedPlaylists.addAll(
          ppList.map((e) => TrendingPlaylist.fromJson(e)).toList(),
        );
        LogService().log(
          "[RadioProvider] Restored ${_promotedPlaylists.length} promoted playlists.",
        );
        await _savePromotedPlaylists();
      }

      // Restore Play History & Metadata
      if (data['user_play_history'] != null) {
        final Map<String, dynamic> history = data['user_play_history'];
        _userPlayHistory = history.map((k, v) => MapEntry(k, v as int));
      }
      if (data['history_metadata'] != null) {
        final Map<String, dynamic> meta = data['history_metadata'];
        _historyMetadata = {};
        for (var entry in meta.entries) {
          var s = SavedSong.fromJson(entry.value);
          if (s.localPath != null && s.localPath!.isNotEmpty) {
            final file = File(s.localPath!);
            if (!await file.exists()) {
              s = s.copyWith(forceClearLocalPath: true);
            }
          }
          _historyMetadata[entry.key] = s;
        }
      }
      if (data['recent_songs_order'] != null) {
        _recentSongsOrder = (data['recent_songs_order'] as List)
            .map((e) => e as String)
            .toList();
      }
      await _saveUserPlayHistory();

      // Restore Followed Artists & Albums
      if (data['followed_artists'] != null) {
        _followedArtists.clear();
        _followedArtists.addAll(
          (data['followed_artists'] as List).map((e) => e as String),
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _keyFollowedArtists,
          _followedArtists.toList(),
        );
      }
      if (data['followed_albums'] != null) {
        _followedAlbums.clear();
        _followedAlbums.addAll(
          (data['followed_albums'] as List).map((e) => e as String),
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_keyFollowedAlbums, _followedAlbums.toList());
      }

      // Playlists
      if (data['playlists'] != null) {
        final List<dynamic> pList = data['playlists'];
        final List<Playlist> backupPlaylists = pList
            .map((e) => Playlist.fromJson(e))
            .toList();

        // Check for missing local files and restore online links
        for (int i = 0; i < backupPlaylists.length; i++) {
          final p = backupPlaylists[i];
          final updatedSongs = <SavedSong>[];
          for (var song in p.songs) {
            if (song.localPath != null && song.localPath!.isNotEmpty) {
              final file = File(song.localPath!);
              if (!await file.exists()) {
                updatedSongs.add(song.copyWith(forceClearLocalPath: true));
              } else {
                updatedSongs.add(song);
              }
            } else {
              updatedSongs.add(song);
            }
          }
          backupPlaylists[i] = p.copyWith(songs: updatedSongs);
        }

        // Merge Logic: Keep local "new" playlists that aren't in backup
        // 1. Create Map of current local playlists
        final Map<String, Playlist> mergedMap = {
          for (var p in _playlists) p.id: p,
        };

        // 2. Update/Add playlists from backup (Backup is source of truth for its own data)
        for (var p in backupPlaylists) {
          mergedMap[p.id] = p;
        }

        // 3. Result contains Backup versions + New Local versions
        _playlists = mergedMap.values.toList();
        await _playlistService.saveAll(_playlists);
      }

      _addLog("Restore Complete");
      _hasPerformedRestore = true;
      await _saveHasPerformedRestore();

      // Automatically set backup frequency correctly after restore
      if (_backupFrequency == 'manual') {
        LogService().log(
          "[RadioProvider] Switching backup frequency to 'daily' after restore.",
        );
        await setBackupFrequency('daily');
      }

      // Update last backup timestamp to current time to prevent immediate automatic backup
      _lastBackupTs = DateTime.now().millisecondsSinceEpoch;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_backup_ts', _lastBackupTs);

      LogService().log(
        "[RadioProvider] Finalizing restore: updating local state...",
      );

      // Restore Theme Settings
      if (data['theme_settings'] != null) {
        final theme = data['theme_settings'];
        if (theme['theme_id'] != null)
          await prefs.setString('theme_id', theme['theme_id']);
        if (theme['custom_primary'] != null)
          await prefs.setInt('custom_primary', theme['custom_primary']);
        if (theme['custom_bg'] != null)
          await prefs.setInt('custom_bg', theme['custom_bg']);
        if (theme['custom_card'] != null)
          await prefs.setInt('custom_card', theme['custom_card']);
        if (theme['custom_surface'] != null)
          await prefs.setInt('custom_surface', theme['custom_surface']);
        if (theme['custom_bg_image'] != null)
          await prefs.setString('custom_bg_image', theme['custom_bg_image']);

        // Reload theme if provider is available
        await _themeProvider?.loadSettings();
      }

      // Restore Playback Settings
      if (data['playback_settings'] != null) {
        final playback = data['playback_settings'];
        if (playback['crossfade_duration'] != null) {
          await setCrossfadeDuration(playback['crossfade_duration']);
        }
      }

      await _loadPlaylists(); // Refresh state

      // Manual trigger for AI recommendations to ensure "For You" is ready
      final code = _detectLanguageCode();
      preFetchForYou(languageCode: code);

      // Dismiss spinner BEFORE potential permission dialog
      _isRestoring = false;
      notifyListeners();

      LogService().log("[RadioProvider] Checking permissions...");
      await ensureLocalPermissions();

      LogService().log("[RadioProvider] restoreBackup completed successfully.");
    } catch (e, stack) {
      LogService().log("[RadioProvider] restoreBackup FAILED: $e\n$stack");
      _isRestoring = false;
      notifyListeners();
      if (e.toString().contains("No backup found")) {
        _hasPerformedRestore = true;
        await _saveHasPerformedRestore();
      }
      _addLog("Restore Failed: $e");
      rethrow;
    }
  }

  Future<void> ensureLocalPermissions() async {
    if (kIsWeb) return;

    // FATAL FIX: Only request if app is in the foreground.
    // Permission requests while backgrounded or during early initialization can cause:
    // "Unable to detect current Android Activity" fatal crash.
    final bool isResumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!isResumed) {
      LogService().log(
        "[RadioProvider] Skipping permission request: App not in foreground.",
      );
      return;
    }

    try {
      // Check if any playlist is local or contains local songs
      bool hasLocalContent =
          _playlists.any((p) => p.id.startsWith('local_')) ||
          _playlists.any(
            (p) => p.songs.any(
              (s) => s.localPath != null && s.localPath!.isNotEmpty,
            ),
          );

      if (!hasLocalContent) {
        // Also check unique songs
        hasLocalContent = _allUniqueSongs.any(
          (s) => s.localPath != null && s.localPath!.isNotEmpty,
        );
      }

      if (hasLocalContent) {
        if (Platform.isAndroid) {
          // For Android 13+ (API 33+) we need Permission.audio
          // For older, Permission.storage
          final statusAudio = await Permission.audio.request();
          if (statusAudio.isPermanentlyDenied) {
            // Permanently denied, could show a snackbar or similar if needed.
          } else if (statusAudio.isDenied) {
            // Try legacy storage permission for older Androids
            await Permission.storage.request();
          }
        } else if (Platform.isIOS) {
          await Permission.mediaLibrary.request();
        }
      }
    } catch (e) {
      LogService().log("[RadioProvider] Permission request failed: $e");
    }
  }

  Future<void> setPreferYouTubeAudioOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    _preferYouTubeAudioOnly = value;
    await prefs.setBool(_keyPreferYouTubeAudioOnly, value);
    notifyListeners();
  }

  Future<void> _loadYouTubeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _preferYouTubeAudioOnly =
        prefs.getBool(_keyPreferYouTubeAudioOnly) ?? false;
    notifyListeners();
  }

  Future<Map<String, String?>> resolveLinks({
    required String title,
    required String artist,
    String? youtubeUrl,
    String? appleMusicUrl,
  }) async {
    try {
      _lastSongLinkResponse = "Song Link: Fetching for '$title'...";
      notifyListeners();

      // Determine best source URL for SongLink
      String? sourceUrl;

      // 2. Fallback to full URLs
      // Filter out generic search URLs which SongLink likely can't handle

      if (youtubeUrl != null &&
          !youtubeUrl.contains('search_query') &&
          !youtubeUrl.contains('/results')) {
        sourceUrl = youtubeUrl;
      }

      if (sourceUrl == null &&
          appleMusicUrl != null &&
          appleMusicUrl.contains('music.apple.com')) {
        sourceUrl = appleMusicUrl;
      }

      // 2b. EMERGENCY FALLBACK: iTunes Search
      // If we don't have a specific track link, use Title + Artist to find one via iTunes
      if (sourceUrl == null) {
        sourceUrl = await _fetchItunesUrl("$title $artist");
      }

      // Debug Log construction
      String debugLog = "--- SONG LINK CHECK (Manual) ---\n";
      debugLog += "1. Metadata: Title='$title', Artist='$artist'\n";
      debugLog +=
          "2. Initial URLs: Youtube='${youtubeUrl ?? 'null'}', Apple='${appleMusicUrl ?? 'null'}'\n";
      debugLog += "4. Selected Source URL: '${sourceUrl ?? 'null'}'\n";
      debugLog += "----------------------------\n\n";

      _lastSongLinkResponse = "${debugLog}Fetching API...";
      notifyListeners();

      final links = await _songLinkService.fetchLinks(
        url: sourceUrl,
        countryCode: _currentStation?.countryCode ?? 'IT',
      );

      // Log Capture
      String serviceLog = _songLinkService.lastRawJson;
      if (serviceLog.isEmpty) {
        serviceLog = jsonEncode(links);
      }
      _lastSongLinkResponse = debugLog + serviceLog;
      notifyListeners();

      return links;
    } catch (e) {
      if (_songLinkService.lastRawJson.isNotEmpty) {
        _lastSongLinkResponse = _songLinkService.lastRawJson;
      } else {
        _lastSongLinkResponse = "Error: $e";
      }
      notifyListeners();
      return {};
    }
  }

  Future<String?> _fetchItunesUrl(String query) async {
    try {
      final encodedOriginal = Uri.encodeComponent(query);
      final url = Uri.parse(
        'https://itunes.apple.com/search?term=$encodedOriginal&limit=1&media=music',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['resultCount'] > 0) {
          final result = data['results'][0];
          return result['trackViewUrl'] as String?;
        }
      }
    } catch (e) {
      debugPrint("iTunes Search Error: $e");
    }
    return null;
  }

  Future<void> reloadPlaylists() async {
    await _loadPlaylists();
  }

  Future<void> setCompactView(bool value) async {
    _isCompactView = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCompactView, value);
    notifyListeners();
  }

  Future<void> setCategoryCompact(String category, bool value) async {
    _categoryCompactViews[category] = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyCategoryCompactViews,
      jsonEncode(_categoryCompactViews),
    );
    notifyListeners();
  }

  void _onEntitlementChanged() {
    if (_audioHandler is RadioAudioHandler) {
      _syncACRCloudStatus();
    }
    notifyListeners();
  }

  void _syncACRCloudStatus() async {
    final enabled = isACRCloudEnabled;
    if (_audioHandler is RadioAudioHandler) {
      _audioHandler.setACRCloudEnabled(enabled);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('acr_cloud_enabled', enabled);
    } catch (_) {}
  }

  Future<void> setACRCloudEnabled(bool value) async {
    // Deprecated: UI no longer toggles this.
    // Kept as no-op or to allow external overrides if absolutely needed.
  }

  Future<void> setManageGridView(bool value) async {
    _isManageGridView = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyManageGridView, value);
    notifyListeners();
  }

  Future<void> setManageGroupingMode(int value) async {
    _manageGroupingMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyManageGroupingMode, value);
    notifyListeners();
  }

  void _markCurrentSongAsInvalid({String? songId}) async {
    final targetId = songId ?? _audioOnlySongId;
    bool isLocal = false;

    if (targetId != null) {
      for (var p in _playlists) {
        try {
          final s = p.songs.firstWhere((s) => s.id == targetId);
          if (s.localPath != null || s.id.startsWith('local_')) {
            isLocal = true;
            break;
          }
        } catch (_) {}
      }
    }

    // Remote Check: Do NOT mark invalid if from a remote trending/Spotify playlist
    if (_currentPlayingPlaylistId != null &&
        _isRemotePlaylistId(_currentPlayingPlaylistId!)) {
      LogService().log(
        "Blocking 'Mark Invalid' - Song is from a trending playlist",
      );
      return;
    }

    // Connectivity Check: Do NOT mark invalid if internet is down (unless it is a local file)
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none) && !isLocal) {
      LogService().log("Blocking 'Mark Invalid' - No Internet Connection");
      return;
    }

    if (targetId != null) {
      LogService().log("Marking Song Invalid: $targetId");
      if (!_invalidSongIds.contains(targetId)) {
        _invalidSongIds.add(targetId);
        LogService().log(
          "Added to invalidSongIds. Count: ${_invalidSongIds.length}",
        );

        // 1. Update In-Memory Playlists Immediately (Instant UI Feedback)
        bool memoryUpdated = false;
        for (var i = 0; i < _playlists.length; i++) {
          final p = _playlists[i];
          final index = p.songs.indexWhere((s) => s.id == targetId);
          if (index != -1) {
            final updatedSong = p.songs[index].copyWith(
              isValid: false,
              forceClearLocalPath: true,
            );
            p.songs[index] = updatedSong;
            memoryUpdated = true;
          }
        }
        if (memoryUpdated) {
          LogService().log(
            "Updated _playlists in memory immediately and cleared localPath.",
          );
        }

        // 2. Notify UI immediately
        notifyListeners();

        // 3. Persist ID list
        final prefs = await SharedPreferences.getInstance();
        prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
        LogService().log("Persisted invalidSongIds to Prefs");

        // 4. Mark globally in DB (Async)
        await _playlistService.markSongAsInvalidGlobally(targetId);

        // Also sync localPath clearance globally
        try {
          final s = _allUniqueSongs.firstWhere((s) => s.id == targetId);
          await _syncSongDownloadStatusInternal(
            s.copyWith(
              localPath: null,
              forceClearLocalPath: true,
              isValid: false,
            ),
          );
          await _playlistService.saveAll(_playlists);
        } catch (_) {
          // Fallback if not in unique
          await _playlistService.saveAll(_playlists);
        }

        LogService().log(
          "Marked invalid globally via Service and cleared localPath.",
        );

        // 5. Update Temp Playlist
        if (_tempPlaylist != null) {
          final index = _tempPlaylist!.songs.indexWhere(
            (s) => s.id == targetId,
          );
          if (index != -1) {
            _tempPlaylist!.songs[index] = _tempPlaylist!.songs[index].copyWith(
              isValid: false,
              forceClearLocalPath: true,
            );
            LogService().log(
              "Updated _tempPlaylist in memory for index $index and cleared localPath",
            );
          }
        }
      } else {
        LogService().log("Song ID $targetId already in invalidSongIds");
      }
    } else {
      LogService().log("Cannot mark invalid: targetId is null");
    }
  }

  Future<void> unmarkSongAsInvalid(String songId, {String? playlistId}) async {
    bool changed = false;
    if (_invalidSongIds.contains(songId)) {
      _invalidSongIds.remove(songId);
      changed = true;
      // Persist immediately
      SharedPreferences.getInstance().then((prefs) {
        prefs.setStringList(_keyInvalidSongIds, _invalidSongIds);
      });
    }

    // Always try to unmark globally, regardless of specific playlistId
    await _playlistService.unmarkSongAsInvalidGlobally(songId);
    await reloadPlaylists(); // Refresh local list

    // Also unmark in temp playlist if active
    if (_tempPlaylist != null) {
      final index = _tempPlaylist!.songs.indexWhere((s) => s.id == songId);
      if (index != -1) {
        _tempPlaylist!.songs[index] = _tempPlaylist!.songs[index].copyWith(
          isValid: true,
        );
      }
    }

    changed = true;

    if (changed) notifyListeners();
  }

  Future<void> _updateCurrentSongDuration(Duration duration) async {
    if (_currentPlayingPlaylistId == null || _audioOnlySongId == null) return;

    // Check if we need to update
    final playlist = playlists.firstWhere(
      (p) => p.id == _currentPlayingPlaylistId,
      orElse: () =>
          Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
    );
    final songIndex = playlist.songs.indexWhere(
      (s) => s.id == _audioOnlySongId,
    );

    if (songIndex != -1) {
      final song = playlist.songs[songIndex];
      // Only update if missing or zero
      if (song.duration == null || song.duration == Duration.zero) {
        // Double check duration is valid
        if (duration > Duration.zero) {
          LogService().log("Updating duration for ${song.title} to $duration");
          await _playlistService.updateSongDuration(
            _currentPlayingPlaylistId!,
            _audioOnlySongId!,
            duration,
          );
          // Auto-reload handled by listener
        } else {
          LogService().log("Failed to update duration for ${song.title}");
        }
      }
    }
  }

  Future<void> _attemptRecognition() async {
    // Entitlement Check: song_recognition
    LogService().log(
      "Recognition: Entitlement Check: ${_entitlementService.isFeatureEnabled('song_recognition')}",
    );
    if (!_entitlementService.isFeatureEnabled('song_recognition')) {
      _isRecognizing = false; // Ensure loading state is OFF
      return;
    }
    LogService().log("Recognition: ACRCloud Enabled: $isACRCloudEnabled");
    if (!isACRCloudEnabled) return;

    // Defer to RadioAudioHandler for radio playback
    if (_currentPlayingPlaylistId == null) {
      _metadataTimer?.cancel();
      return;
    }

    // Strict Input Guard: Must be playing a station to recognize
    if (!_isPlaying ||
        _currentStation == null ||
        _currentPlayingPlaylistId != null)
      return;

    // Guard: Don't start another recognition if one is already in progress
    if (_isRecognizing) return;

    LogService().log(
      "Recognition: Starting identification for ${_currentStation!.name}",
    );
    _lastApiResponse = "Identifying...";
    _isRecognizing = true; // Start loading state

    // Update AudioHandler to show identifying state on Android Auto
    _audioHandler.updateMediaItem(
      MediaItem(
        id: _currentStation!.url,
        title: _currentStation?.name ?? "Radio",
        album: _currentStation?.name ?? "Radio",
        artUri: _currentStation?.logo != null
            ? Uri.tryParse(_currentStation!.logo!)
            : null,
        extras: {
          'url': _currentStation!.url,
          'stationId': _currentStation?.id,
          'type': 'station',
          'isSearching': true,
        },
      ),
    );
    notifyListeners();

    final result = await _recognitionApiService.identifyStream(
      _currentStation!.url,
    );
    _isRecognizing = false; // Stop loading state
    notifyListeners();

    if (result != null && result.containsKey('track')) {
      final trackInfo = result['track'];
      if (trackInfo != null) {
        final title = trackInfo['title'];
        final artists = trackInfo['subtitle'];

        String? album;
        String? releaseDate;

        if (trackInfo['sections'] != null && trackInfo['sections'] is List) {
          try {
            final metadata =
                (trackInfo['sections'] as List).firstWhere(
                      (s) => s['type'] == 'SONG',
                    )['metadata']
                    as List;
            try {
              album = metadata.firstWhere((m) => m['title'] == 'Album')['text'];
            } catch (_) {}
            try {
              releaseDate = metadata.firstWhere(
                (m) => m['title'] == 'Released',
              )['text'];
            } catch (_) {}
          } catch (_) {}
        }

        // Log raw response for debug
        _lastApiResponse = jsonEncode(result);

        // Update Metadata
        if (title != _currentTrack || artists != _currentArtist) {
          LogService().log("ShazamAPI: Match found: $title - $artists");

          final stationName = _currentStation?.name ?? "Radio";
          _currentTrack = title ?? "Unknown Title";
          _currentArtist = artists ?? "Unknown Artist";
          // Include station name in album field for context
          _currentAlbum = (album != null && album.isNotEmpty)
              ? "$stationName • $album"
              : stationName;
          _currentReleaseDate = releaseDate;

          // Extract Genre
          String? genre;
          if (trackInfo['genres'] != null &&
              trackInfo['genres']['primary'] != null) {
            genre = trackInfo['genres']['primary'];
          }
          _currentGenre = genre;

          // Reset artwork/state
          // Preserve station logo as placeholder instead of null
          _currentAlbumArt = _currentStation?.logo;
          _currentArtistImage = null;

          // Reset External Links
          _currentYoutubeUrl = null;
          _currentAppleMusicUrl = null;
          _currentDeezerUrl = null;
          _currentTidalUrl = null;
          _currentAmazonMusicUrl = null;
          _currentNapsterUrl = null;

          // --- Reset Duration Info ---
          _currentSongDuration = null;
          _initialSongOffset = null;
          _songSyncTime = null;

          checkIfCurrentSongIsSaved(); // Check if this new song is already saved

          // Try to find artwork from Shazam
          String? shazamArtwork;
          if (trackInfo['images'] != null &&
              trackInfo['images']['coverart'] != null) {
            shazamArtwork = trackInfo['images']['coverart'];
          }

          if (shazamArtwork != null) {
            _currentAlbumArt = shazamArtwork;
          }

          notifyListeners();

          // Trigger fetchSmartLinks (which does SongLink search and updates artwork/links)
          await fetchSmartLinks(keepExistingArtwork: shazamArtwork != null);
          fetchLyrics(fromRecognition: true);
        } else {
          LogService().log("ShazamAPI: Same song detected.");
          _lastApiResponse = "Same song: $title";

          // Ensure genre is updated even if song is same (in case it wasn't caught before)
          String? genre;
          if (trackInfo['genres'] != null &&
              trackInfo['genres']['primary'] != null) {
            genre = trackInfo['genres']['primary'];
          }
          if (genre != null) _currentGenre = genre;

          checkIfCurrentSongIsSaved();

          notifyListeners();
        }

        // Shazam usually doesn't provide precise offsets, we'll schedule a fixed delay check.
        int nextCheckDelay = 60000; // 60s default
        LogService().log(
          "Recognition: Next check scheduled in ${nextCheckDelay ~/ 1000}s",
        );
        _metadataTimer?.cancel();
        _metadataTimer = Timer(
          Duration(milliseconds: nextCheckDelay),
          _attemptRecognition,
        );
      } else {
        _lastApiResponse = "No music found in stream sample.";
        _restoreDefaultRadioState();
        _scheduleRetry(45); // Retry sooner if just talk/ad
      }
    } else {
      _lastApiResponse = "Recognition failed or no match.";
      _restoreDefaultRadioState();
      _scheduleRetry(45); // Retry
    }
  }

  void _restoreDefaultRadioState() {
    // CRITICAL GUARD: Never restore radio state if we are in Playlist Mode!
    if (_currentPlayingPlaylistId != null || _hiddenAudioController != null) {
      LogService().log(
        "Recognition: Guard triggered - ignoring radio state restore during playlist playback",
      );
      return;
    }

    // Reset to default station images as requested
    // "Force the default radio image"
    _currentAlbumArt = _currentStation?.logo;
    _currentArtistImage = null; // Will fallback to station logo in UI
    _currentTrack = _currentStation?.name ?? "Live Broadcast";
    _currentArtist = _currentStation?.genre ?? "";
    _currentLyrics = LyricsData.empty();

    // Also reset duration info as there is no specific song
    _currentSongDuration = null;
    _initialSongOffset = null;
    _songSyncTime = null;

    if (_currentStation != null) {
      // Explicitly update AudioHandler (Android Auto) with the Station Logo
      _audioHandler.updateMediaItem(
        MediaItem(
          id: _currentStation!.url,
          title: _currentTrack,
          artist: _currentArtist,
          album: _currentStation!.name,
          artUri: _currentStation!.logo != null
              ? Uri.tryParse(_currentStation!.logo!)
              : null,
          extras: {
            'url': _currentStation!.url,
            'stationId': _currentStation!.id,
            'type': 'station',
          },
        ),
      );
    }

    checkIfCurrentSongIsSaved();
    notifyListeners();
  }

  void _scheduleRetry(int seconds) {
    LogService().log("Recognition: Scheduling retry in ${seconds}s");
    _metadataTimer?.cancel();
    _metadataTimer = Timer(Duration(seconds: seconds), _attemptRecognition);
  }

  // --- Artist Image Caching ---
  final Map<String, String?> _artistImageCache = {};

  Future<String?> fetchArtistImage(String artistName) async {
    // 1. Normalize name for cache key
    final rawKey = artistName.trim().toLowerCase();

    // 2. Check Cache
    if (_artistImageCache.containsKey(rawKey)) {
      return _artistImageCache[rawKey];
    }

    // Helper: Returns URL (String), "NOT_FOUND" (String), or null (Error)
    Future<String?> searchDeezer(String query) async {
      if (query.isEmpty) return "NOT_FOUND";
      try {
        final uri = Uri.parse(
          "https://api.deezer.com/search/artist?q=${Uri.encodeComponent(query)}&limit=1",
        );
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final json = jsonDecode(response.body);
          if (json['data'] != null && (json['data'] as List).isNotEmpty) {
            return json['data'][0]['picture_xl'] ??
                json['data'][0]['picture_big'] ??
                json['data'][0]['picture_medium'];
          } else {
            return "NOT_FOUND";
          }
        } else {
          LogService().log(
            "Artist fetch failed ($query): ${response.statusCode}",
          );
        }
      } catch (e) {
        LogService().log("Error fetching artist '$query': $e");
      }
      return null; // Network or Server Error
    }

    // 3. Prepare Sanitized Name
    String searchName = artistName;
    searchName = searchName.split('•').first;
    searchName = searchName.split('(').first;
    searchName = searchName.split('[').first;
    searchName = searchName.split('{').first;

    final lowerName = searchName.toLowerCase();
    if (lowerName.contains(' feat')) {
      searchName = searchName.substring(0, lowerName.indexOf(' feat'));
    } else if (lowerName.contains(' ft.')) {
      searchName = searchName.substring(0, lowerName.indexOf(' ft.'));
    }

    searchName = searchName.split(' - ').first; // "Artist - Title" split
    searchName = searchName
        .split(RegExp(r'[,;&/|+\*\._]'))
        .first; // Special chars
    searchName = searchName.trim();

    // 4. Attempt 1: Sanitized Name
    String? result = await searchDeezer(searchName);

    // 5. Attempt 2: Raw Name (Fallback if Sanitized failed/empty, mimicking Artist Page)
    if ((result == "NOT_FOUND" || result == null) &&
        searchName != artistName.trim()) {
      // LogService().log("Sanitized search failed for '$searchName', trying raw: '$artistName'");
      final rawResult = await searchDeezer(artistName.trim());

      // If Raw found something, use it
      if (rawResult != null && rawResult != "NOT_FOUND") {
        result = rawResult;
      } else if (rawResult == "NOT_FOUND" && result == "NOT_FOUND") {
        // Both confirmed NOT FOUND
        result = "NOT_FOUND";
      }
      // If rawResult is null (Error), keep previous result (which might be NOT_FOUND or null)
    }

    // 6. Cache & Return
    if (result != null && result != "NOT_FOUND") {
      _artistImageCache[rawKey] = result;
      _saveArtistImagesCache(); // Persist
      return result;
    } else if (result == "NOT_FOUND") {
      _artistImageCache[rawKey] = null;
      _saveArtistImagesCache(); // Persist even if not found to avoid repeated searches
      return null;
    } else {
      // Error case: Do not cache, allow retry
      return null;
    }
  }

  Future<void> findMissingArtworks({String? playlistId}) async {
    _isSyncingMetadata = true;
    notifyListeners();
    try {
      final List<SavedSong> toProcess = [];
      if (playlistId != null) {
        try {
          final p = _playlists.firstWhere((p) => p.id == playlistId);
          for (var s in p.songs) {
            if (s.artUri == null ||
                s.artUri!.isEmpty ||
                s.artUri!.contains('placeholder') ||
                s.isYoutubeArt ||
                s.album == 'Unknown Album' ||
                s.album.isEmpty ||
                s.youtubeUrl == null ||
                s.youtubeUrl!.isEmpty) {
              toProcess.add(s);
            }
          }
        } catch (_) {
          // If it's a temp playlist (artist/album view), we can't find it by ID in _playlists.
          for (var s in _allUniqueSongs) {
            if (s.artUri == null ||
                s.artUri!.isEmpty ||
                s.artUri!.contains('placeholder') ||
                s.isYoutubeArt ||
                s.album == 'Unknown Album' ||
                s.album.isEmpty ||
                s.youtubeUrl == null ||
                s.youtubeUrl!.isEmpty) {
              toProcess.add(s);
            }
          }
        }
      } else {
        // Process all unique songs that are missing art or video links
        for (var s in _allUniqueSongs) {
          if (s.artUri == null ||
              s.artUri!.isEmpty ||
              s.artUri!.contains('placeholder') ||
              s.isYoutubeArt ||
              s.album == 'Unknown Album' ||
              s.album.isEmpty ||
              s.youtubeUrl == null ||
              s.youtubeUrl!.isEmpty) {
            toProcess.add(s);
          }
        }
      }

      if (toProcess.isEmpty) return;

      bool anyChanged = false;
      // Use a set to avoid processing same song twice
      final processIds = toProcess.map((s) => s.id).toSet();

      for (var songId in processIds) {
        final song = _allUniqueSongs.firstWhere(
          (s) => s.id == songId,
          orElse: () => toProcess.firstWhere((tp) => tp.id == songId),
        );

        try {
          String cleanTitle = song.title
              .replaceAll(
                RegExp(r'^\d+[\s.-]+'),
                '',
              ) // Remove leading track numbers (e.g., "01 - ")
              .replaceAll(
                RegExp(r'\.(mp3|m4a|wav|flac|ogg)$', caseSensitive: false),
                '',
              ) // Remove extensions
              .trim();
          String cleanArtist = song.artist
              .replaceAll('Unknown Artist', '')
              .trim();

          final results = await _musicMetadataService.searchSongs(
            query: "$cleanTitle $cleanArtist".trim(),
            limit: 1,
          );

          if (results.isNotEmpty) {
            final match = results.first.song;
            if (match.artUri != null &&
                match.artUri!.isNotEmpty &&
                (match.artUri != song.artUri ||
                    (song.isYoutubeArt && !match.isYoutubeArt))) {
              // Update metadata in all playlists
              bool songChanged = false;
              for (int i = 0; i < _playlists.length; i++) {
                final playlist = _playlists[i];
                final songIndex = playlist.songs.indexWhere(
                  (s) => s.id == songId,
                );
                if (songIndex != -1) {
                  final updatedSongs = List<SavedSong>.from(playlist.songs);
                  updatedSongs[songIndex] = updatedSongs[songIndex].copyWith(
                    artUri: match.artUri,
                    album:
                        (updatedSongs[songIndex].album == 'Unknown Album' ||
                            updatedSongs[songIndex].album.isEmpty)
                        ? match.album
                        : updatedSongs[songIndex].album,
                    appleMusicUrl:
                        updatedSongs[songIndex].appleMusicUrl ??
                        match.appleMusicUrl,
                  );
                  _playlists[i] = playlist.copyWith(songs: updatedSongs);
                  songChanged = true;
                  anyChanged = true;
                }
              }
              if (songChanged) {
                final idx = _allUniqueSongs.indexWhere((s) => s.id == songId);
                if (idx != -1) {
                  _allUniqueSongs[idx] = _allUniqueSongs[idx].copyWith(
                    artUri: match.artUri,
                    album:
                        (_allUniqueSongs[idx].album == 'Unknown Album' ||
                            (_allUniqueSongs[idx].album.isEmpty))
                        ? match.album
                        : _allUniqueSongs[idx].album,
                    appleMusicUrl:
                        _allUniqueSongs[idx].appleMusicUrl ??
                        match.appleMusicUrl,
                  );
                }
              }
            }
          } else if (song.isYoutubeArt) {
            // Fallback to Odesli in findMissingArtworks too if it's YouTube
            final links = await resolveLinks(
              title: song.title,
              artist: song.artist,
              appleMusicUrl: song.appleMusicUrl,
              youtubeUrl: song.youtubeUrl,
            );

            final extraThumb = links['thumbnailUrl'];
            if (extraThumb != null && extraThumb.isNotEmpty) {
              final bool isExtraThumbYoutube =
                  extraThumb.contains('ytimg.com') ||
                  extraThumb.contains('ggpht.com') ||
                  extraThumb.contains('img.youtube.com');

              if (!isExtraThumbYoutube) {
                // Update globally
                anyChanged = true;
                for (int i = 0; i < _playlists.length; i++) {
                  final playlist = _playlists[i];
                  final sIdx = playlist.songs.indexWhere((s) => s.id == songId);
                  if (sIdx != -1) {
                    final updated = List<SavedSong>.from(playlist.songs);
                    updated[sIdx] = updated[sIdx].copyWith(artUri: extraThumb);
                    _playlists[i] = playlist.copyWith(songs: updated);
                  }
                }
                final uIdx = _allUniqueSongs.indexWhere((s) => s.id == songId);
                if (uIdx != -1) {
                  _allUniqueSongs[uIdx] = _allUniqueSongs[uIdx].copyWith(
                    artUri: extraThumb,
                  );
                }
              }
            }
          }

          // Also try to resolve YouTube/Other links if missing
          final songToFix = _allUniqueSongs.firstWhere((s) => s.id == songId);
          if (songToFix.youtubeUrl == null || songToFix.youtubeUrl!.isEmpty) {
            final links = await resolveLinks(
              title: songToFix.title,
              artist: songToFix.artist,
              appleMusicUrl: songToFix.appleMusicUrl,
            );

            if (links.isNotEmpty) {
              for (int i = 0; i < _playlists.length; i++) {
                final playlist = _playlists[i];
                final songIndex = playlist.songs.indexWhere(
                  (s) => s.id == songId,
                );
                if (songIndex != -1) {
                  final updatedSongs = List<SavedSong>.from(playlist.songs);
                  updatedSongs[songIndex] = updatedSongs[songIndex].copyWith(
                    youtubeUrl:
                        updatedSongs[songIndex].youtubeUrl ?? links['youtube'],
                  );
                  _playlists[i] = playlist.copyWith(songs: updatedSongs);
                  anyChanged = true;
                }
              }
              final idx = _allUniqueSongs.indexWhere((s) => s.id == songId);
              if (idx != -1) {
                _allUniqueSongs[idx] = _allUniqueSongs[idx].copyWith(
                  youtubeUrl:
                      _allUniqueSongs[idx].youtubeUrl ?? links['youtube'],
                );
              }
            }
          }
        } catch (e) {
          LogService().log("Error finding artwork for ${song.title}: $e");
          if (e.toString().contains('RateLimited')) {
            LogService().log(
              "iTunes Rate Limit hit (403/429). Aborting metadata sync for now.",
            );
            break; // Stop spamming API
          }
        }

        // Small delay to avoid rate limits
        await Future.delayed(const Duration(milliseconds: 300));
      }

      if (anyChanged) {
        await _playlistService.saveAll(_playlists);
        notifyListeners();
      }
    } finally {
      _isSyncingMetadata = false;
      notifyListeners();
    }
  }

  Future<void> _deletePhysicalFile(String? path) async {
    if (path == null || path.isEmpty) return;

    final file = File(path);
    if (await file.exists()) {
      try {
        await file.delete();
        LogService().log("Deleted physical file: $path");
      } catch (e) {
        LogService().log("Error deleting physical file $path: $e");
      }
    }
  }

  Future<void> _cleanupUnreferencedFiles(List<String> pathsToCheck) async {
    if (pathsToCheck.isEmpty) return;

    // Build a set of all localPaths currently in use across all playlists
    final Set<String> activePaths = {};
    for (var p in _playlists) {
      for (var s in p.songs) {
        if (s.localPath != null && s.localPath!.isNotEmpty) {
          activePaths.add(s.localPath!);
        }
      }
    }

    for (var path in pathsToCheck.toSet()) {
      // Only delete if NOT in activePaths AND is a download (security check)
      final isDownload =
          path.toLowerCase().contains('_secure.') ||
          path.toLowerCase().endsWith('.mst') ||
          path.toLowerCase().contains('offline_music');

      if (isDownload && !activePaths.contains(path)) {
        await _deletePhysicalFile(path);
      }
    }
  }

  Future<void> enrichAllArtists() async {
    // Get all unique artists from all playlists
    final Set<String> artists = {};
    for (var playlist in _playlists) {
      for (var song in playlist.songs) {
        if (song.artist.isNotEmpty) {
          artists.add(song.artist);
        }
      }
    }

    if (artists.isEmpty) return;

    // Filter out those already professionally cached or explicitly marked NOT_FOUND
    final List<String> toFetch = artists.where((a) {
      final key = a.trim().toLowerCase();
      // We only fetch if NOT in cache. If it's in cache (even as null), we already tried.
      return !_artistImageCache.containsKey(key);
    }).toList();

    if (toFetch.isEmpty) return;

    // Process in batches with delays to avoid Deezer rate limits
    for (var artist in toFetch) {
      try {
        await fetchArtistImage(artist);
        // Small delay to be polite to the API
        await Future.delayed(const Duration(milliseconds: 250));
      } catch (e) {
        LogService().log("Error in bulk artist enrichment for $artist: $e");
      }
    }
  }

  // Allow external updates (e.g. from UI fetch)
  void setArtistImage(String? imageUrl) {
    if (_currentArtistImage != imageUrl) {
      _currentArtistImage = imageUrl;
      notifyListeners();
    }
  }

  Future<String?> searchYoutubeVideo(String title, String artist) async {
    final yt = yt_explode.YoutubeExplode();
    try {
      final results = await yt.search.search("$artist $title");
      if (results.isNotEmpty) {
        return "https://www.youtube.com/watch?v=${results.first.id.value}";
      }
      return null;
    } catch (e) {
      debugPrint("searchYoutubeVideo error: $e");
      return null;
    } finally {
      yt.close();
    }
  }

  // --- External Intent Handlers ---
  void _initExternalHandlers() {
    // 1. Deep Links (app_links)
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      await handleExternalUri(uri);
    });
    _appLinks
        .getInitialLink()
        .then((uri) async {
          if (uri != null) await handleExternalUri(uri);
        })
        .catchError((e) {
          debugPrint("app_links error: $e");
          return null;
        });

    // 2. Share Target (receive_sharing_intent)
    _sharingSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(
          (files) async {
            LogService().log(
              "ReceiveSharingIntent Stream: ${files.length} items found.",
            );
            if (files.isNotEmpty) {
              for (var file in files) {
                LogService().log(
                  "Shared Item: type=${file.type}, path='${file.path}'",
                );
                if (file.type == SharedMediaType.text ||
                    file.type == SharedMediaType.url) {
                  await _handleSharedText(file.path);
                } else if (file.type == SharedMediaType.file) {
                  _handleSharedFile(file.path);
                }
              }
            }
          },
          onError: (Object err) {
            debugPrint("getIntentDataStream error: $err");
          },
        );

    ReceiveSharingIntent.instance
        .getInitialMedia()
        .then((files) async {
          LogService().log(
            "ReceiveSharingIntent Initial: ${files.length} items found.",
          );
          if (files.isNotEmpty) {
            for (var file in files) {
              LogService().log(
                "Initial Shared Item: type=${file.type}, path='${file.path}'",
              );
              if (file.type == SharedMediaType.text ||
                  file.type == SharedMediaType.url) {
                await _handleSharedText(file.path);
              } else if (file.type == SharedMediaType.file) {
                _handleSharedFile(file.path);
              }
            }
          }
        })
        .catchError((e) {
          debugPrint("getInitialMedia error: $e");
        });
  }

  void _handleSharedFile(String path) {
    debugPrint("Handling Shared File: $path");
    // Check if it's an audio file by extension
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.mp3') ||
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.wav') ||
        lowerPath.endsWith('.flac') ||
        lowerPath.endsWith('.ogg')) {
      // In this app, local files provided via intent-filter VIEW are played
      // using playYoutubeAudio with isLocal: true.
      playYoutubeAudio(
        path,
        path, // Using path as unique songId for session
        overrideTitle: path.split('/').last,
        overrideArtist: "Local File",
        isLocal: true,
      );
    }
  }

  Future<void> _handleSharedText(String text) async {
    LogService().log("RAW Shared Text: '$text'");
    debugPrint("Handling Shared Text: $text");

    // 1. Check if it's our deep link
    if (text.contains('pjk72.github.io/musicstream/share.html') ||
        text.contains('pjk72.github.io/musicstream/playlist.html') ||
        text.startsWith('musicstream://')) {
      final urlRegExp = RegExp(r'(https?:\/\/[^\s]+|musicstream:\/\/[^\s]+)');
      final match = urlRegExp.firstMatch(text);
      if (match != null) {
        final uri = Uri.tryParse(match.group(0)!);
        if (uri != null) {
          await handleExternalUri(uri);
          return;
        }
      }
    }

    // 2. Check if it's a YouTube link
    final String? videoId = YoutubePlayer.convertUrlToId(text);
    if (videoId != null && !text.contains("list=")) {
      _importVideoFromId(videoId, sharedText: text);
      return;
    }

    // 3. Check for other music providers (Apple Music, Spotify, Amazon)
    final lowerText = text.toLowerCase();
    if (lowerText.contains("music.apple.com") ||
        lowerText.contains("spotify.com") ||
        lowerText.contains("spotify.link") ||
        lowerText.contains("spotify:") ||
        lowerText.contains("spotify") ||
        lowerText.contains("amazon.com") ||
        lowerText.contains("amazon.it") ||
        lowerText.contains("amazon.de") ||
        lowerText.contains("amazon.fr") ||
        lowerText.contains("amazon.es") ||
        lowerText.contains("music.amazon.")) {
      LogService().log("Multi-provider Music Link detected: $text");

      if (lowerText.contains("/playlist/") ||
          lowerText.contains("/library/playlist/")) {
        _handlePlaylistShare(text);
      } else {
        await _handleMusicLinkShare(text);
      }
      return;
    }

    LogService().log("Shared text not recognized as Music Link: $text");
  }

  Future<void> _handleMusicLinkShare(String text) async {
    debugPrint("Resolving Music Link via SongLink: $text");

    // 1. Extract URL (more robustly)
    final urlMatch = RegExp(r'(https?:\/\/[^\s<>"]+)').firstMatch(text);
    if (urlMatch == null) {
      LogService().log("SongLink: No URL found in text: $text");
      return;
    }
    String url = urlMatch.group(0)!;

    // Clean URL (remove trailing punctuation that might have been caught)
    while (url.endsWith('.') ||
        url.endsWith(',') ||
        url.endsWith(')') ||
        url.endsWith('!')) {
      url = url.substring(0, url.length - 1);
    }

    LogService().log("SongLink: Resolved URL: $url");

    // Pre-Processing: Clean URL (Remove query parameters and region prefixes)
    if (url.contains("spotify.com") || url.contains("amazon.")) {
      // Remove query string: ?si=... etc.
      if (url.contains('?')) {
        url = url.split('?').first;
      }

      if (url.contains("spotify.com/intl-")) {
        url = url.replaceFirst(RegExp(r'/intl-[a-z-]+/'), '/');
      }
      LogService().log("SongLink: Normalized URL: $url");
    }

    try {
      // 2. Resolve across platforms using Odesli
      final countryCode = _detectCountryCode();
      final links = await _songLinkService.fetchLinks(
        url: url,
        countryCode: countryCode,
      );

      final title = links['title'];
      final artist = links['artist'];
      final youtubeUrl = links['youtube'] ?? links['youtubeMusic'];
      final artwork = links['thumbnailUrl'];

      if (title != null &&
          title.isNotEmpty &&
          artist != null &&
          artist.isNotEmpty) {
        LogService().log(
          "SongLink: Resolution Success: $title by $artist. YouTube: $youtubeUrl",
        );

        // FALLBACK: If Odesli doesn't provide a YouTube link, we search for it manually!
        String? finalYoutubeUrl = youtubeUrl;
        if (finalYoutubeUrl == null) {
          LogService().log(
            "SongLink: No direct YouTube link. Searching manually for $title by $artist...",
          );
          final searchUrl = await searchYoutubeVideo(title, artist);
          if (searchUrl != null) {
            finalYoutubeUrl = searchUrl;
            LogService().log(
              "SongLink: Manual Search Success: $finalYoutubeUrl",
            );
          }
        }

        final songId = DateTime.now().millisecondsSinceEpoch.toString();

        // 3. Import to Shared Songs and Trigger Playback
        await _importSharedSong(
          id: songId,
          title: title,
          artist: artist,
          album: "Shared Link",
          artUri: artwork,
          youtubeUrl: finalYoutubeUrl,
        );
        return;
      } else {
        LogService().log(
          "SongLink: Resolution succeeded but metadata (title/artist) is missing. Trying manual fallback...",
        );
        _handleMusicLinkShareManual(text);
        return;
      }
    } catch (e) {
      LogService().log(
        "SongLink Resolution failed: $e. Falling back to pattern parsing.",
      );
      // Fallback to our manual pattern parsing if API fails
      _handleMusicLinkShareManual(text);
    }
  }

  void _handleMusicLinkShareManual(String text) {
    debugPrint("Parsing Alternative Music Link (Manual): $text");

    // Pattern extraction: Many shares use "Title by Artist" or "Artist - Title"
    String? title;
    String? artist;

    // Pattern 1: "{Title} by {Artist}" (Apple/Spotify style - multilingual)
    final byPattern = RegExp(
      r'(.+?)\s+(by|di|von|de|por)\s+(.+?)(\s+(on|su|auf|sur|en)\s+|-|\n|$)',
      caseSensitive: false,
    );
    final byMatch = byPattern.firstMatch(text);
    if (byMatch != null) {
      title = byMatch.group(1)?.trim();
      artist = byMatch.group(3)?.trim();
    } else {
      // Pattern 2: "{Artist} - {Title}"
      final dashPattern = RegExp(
        r'(.+?)\s+-\s+(.+?)(\s+(on|su|auf|sur|en)\s+|$)',
      );
      final dashMatch = dashPattern.firstMatch(text);
      if (dashMatch != null) {
        artist = dashMatch.group(1)?.trim();
        title = dashMatch.group(2)?.trim();
      }
    }

    // Pattern 3: Amazon Music style "I'm listening to [Title] by [Artist] on Amazon Music"
    // Already handled by Pattern 1 if it has "by" or "di", but let's be safe.
    if (title == null || artist == null) {
      final amazonExpr = RegExp(
        r'(sto ascoltando|listening to|écoute|escuchando|escuto)\s+(.+?)\s+(by|di|von|de|por)\s+(.+?)(\s+|$)',
        caseSensitive: false,
      );
      final match = amazonExpr.firstMatch(text);
      if (match != null) {
        title = match.group(2)?.trim();
        artist = match.group(4)?.trim();
      }
    }

    // Cleanup: remove "Check out", "Listen to", "Ascolta", URLs, or "on Spotify" if regex captured too much
    if (title != null) {
      title = title
          .replaceAll(
            RegExp(
              r'(Check out|Listen to|Ascolta|Hör dir|Ecouter|Escucha|Escute|Suono di|Sto ascoltando|I am listening to)[:\s]*',
              caseSensitive: false,
            ),
            "",
          )
          .trim();
      if (title.contains("http")) title = null; // Guard against bad capture
    }

    if (title != null && artist != null) {
      LogService().log("Manual Extraction Success: $title by $artist");

      // Trigger async search and import
      _importSharedSongFromMetadata(title, artist, text);
    } else {
      LogService().log(
        "Manual Extraction failed for patterns. Trying Meta-Tag Scraping...",
      );
      _handleMusicLinkShareScrape(text);
    }
  }

  Future<void> _handleMusicLinkShareScrape(String text) async {
    // 1. Extract URL
    final urlMatch = RegExp(r'(https?:\/\/[^\s<>"]+)').firstMatch(text);
    if (urlMatch == null) return;
    String url = urlMatch.group(0)!;

    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final html = response.body;

        // Extract og:title and og:description
        final titleMatch = RegExp(
          r'<meta property="og:title" content="([^"]+)"',
        ).firstMatch(html);
        final descMatch = RegExp(
          r'<meta property="og:description" content="([^"]+)"',
        ).firstMatch(html);

        String? scrapedTitle = titleMatch?.group(1);
        String? scrapedArtist = descMatch?.group(1);

        if (scrapedTitle != null && scrapedTitle.isNotEmpty) {
          // Spotify: Description often has "[Artist] · Song · [Year]" or "Listen to [Song] on Spotify. [Artist] · [Year]"
          // We'll try to clean it
          if (scrapedArtist != null) {
            scrapedArtist = scrapedArtist.split(' · ').first;
            scrapedArtist = scrapedArtist
                .replaceAll("Listen to ", "")
                .replaceAll("Ascolta ", "");
          }

          LogService().log(
            "Meta-Tag Scraping Success: $scrapedTitle by $scrapedArtist",
          );
          await _importSharedSongFromMetadata(
            scrapedTitle,
            scrapedArtist ?? "Shared Artist",
            text,
          );
          return;
        }
      }
    } catch (e) {
      LogService().log("Meta-Tag Scraping failed: $e");
    }

    LogService().log(
      "Meta-Tag Scraping failed to yield metadata. Trying Deep Fallback...",
    );
    // Deep Fallback (final attempt)
    final urlRegExp = RegExp(r'https?:\/\/[^\s]+');
    final textNoUrl = text
        .replaceAll(urlRegExp, "")
        .replaceAll("\n", " ")
        .trim();
    if (textNoUrl.length > 3) {
      _importSharedSongFromMetadata(
        textNoUrl,
        _translate('shared_artist'),
        text,
      );
    }
  }

  Future<void> _importSharedSongFromMetadata(
    String title,
    String artist,
    String originalText,
  ) async {
    // 1. Search for a playable YouTube video
    final youtubeUrl = await searchYoutubeVideo(title, artist);
    if (youtubeUrl == null) {
      LogService().log(
        "Manual Metadata Flow: Failed to find YouTube video for $title by $artist",
      );
      return;
    }

    final songId = DateTime.now().millisecondsSinceEpoch.toString();

    // 2. Import and Play
    await _importSharedSong(
      id: songId,
      title: title,
      artist: artist,
      album: _translate('shared_link'),
      youtubeUrl: youtubeUrl,
    );
  }

  Future<void> _importVideoFromId(String videoId, {String? sharedText}) async {
    final yt = yt_explode.YoutubeExplode();
    try {
      final video = await yt.videos.get(videoId);

      // Try to parse Artist - Title from video title if possible
      String title = video.title;
      String artist = video.author;

      if (video.title.contains(' - ')) {
        final parts = video.title.split(' - ');
        artist = parts[0].trim();
        title = parts[1].trim();
      }

      await _importSharedSong(
        id: videoId,
        title: title,
        artist: artist,
        album: _translate('youtube_share'),
        artUri: video.thumbnails.highResUrl,
      );
    } catch (e) {
      debugPrint("Error fetching video metadata for share: $e");
      // Fallback: use limited info if metadata fetch fails
      await _importSharedSong(
        id: videoId,
        title: _translate('shared_song'),
        artist: _translate('unknown'),
      );
    } finally {
      yt.close();
    }
  }

  Future<bool> handleExternalUri(Uri uri) async {
    // Prevent duplicate processing (some OS events fire twice)
    final linkStr = uri.toString();
    if (_lastProcessedLink == linkStr &&
        _lastLinkTime != null &&
        DateTime.now().difference(_lastLinkTime!) <
            const Duration(seconds: 2)) {
      return false;
    }
    _lastProcessedLink = linkStr;
    _lastLinkTime = DateTime.now();

    debugPrint("Processing External URI: $uri");
    if (uri.path.contains('share.html') ||
        uri.path.contains('playlist.html') ||
        uri.scheme == 'musicstream') {
      final params = uri.queryParameters;
      final host = uri.host.toLowerCase();
      final type =
          params['type'] ??
          (params.containsKey('token') ||
                  host.startsWith('playlist') ||
                  uri.path.contains('playlist.html')
              ? 'playlist'
              : (host == 'song' || uri.path.contains('share.html')
                    ? 'song'
                    : null));

      if (type == 'song') {
        return await _importSharedSong(
          id: params['id'],
          title: params['title'],
          artist: params['artist'],
          album: params['album'],
          artUri: params['artUri'],
        );
      } else if (type == 'playlist') {
        final data = params['data'];
        final token = params['token'];

        if (token != null && token.trim().isNotEmpty) {
          return await importPlaylistByToken(token.trim());
        } else if (data != null && data.trim().isNotEmpty) {
          return await importSharedPlaylist(data.trim());
        }
      }
    }
    return false;
  }

  Future<bool> _importSharedSong({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? artUri,
    String? youtubeUrl,
  }) async {
    if (title == null || artist == null) return false;

    LogService().log("Importing Shared Song: $title by $artist");

    // 1. Ensure "Shared Songs" playlist exists
    Playlist? sharedPlaylist;
    final sharedSongsTitle = _translate('shared_songs');
    try {
      sharedPlaylist = _playlists.firstWhere(
        (p) =>
            p.name == "Shared Songs" ||
            p.name == sharedSongsTitle ||
            p.id == "shared_songs",
      );
    } catch (_) {
      // Create it if not found
      final newPlaylist = Playlist(
        id: "shared_songs",
        name: sharedSongsTitle,
        songs: [],
        createdAt: DateTime.now(),
        creator: 'app',
      );
      await _playlistService.addPlaylist(newPlaylist);
      await _loadPlaylists();
      sharedPlaylist = newPlaylist;
    }

    // 2. Prepare song object
    final songId = id ?? DateTime.now().millisecondsSinceEpoch.toString();
    final song = SavedSong(
      id: songId,
      title: title,
      artist: artist,
      album: album ?? _translate('imported'),
      artUri: artUri,
      youtubeUrl:
          youtubeUrl ??
          ((id != null && id.length == 11)
              ? "https://youtube.com/watch?v=$id"
              : null),
      dateAdded: DateTime.now(),
    );

    // 3. Add to playlist
    await _playlistService.addSongToPlaylist(sharedPlaylist.id, song);
    await _loadPlaylists();

    // Safety delay for state sync
    await Future.delayed(const Duration(milliseconds: 500));

    // 4. Trigger playback
    if (song.youtubeUrl != null) {
      final vId = YoutubePlayer.convertUrlToId(song.youtubeUrl!);
      LogService().log(
        "Shared Song Playback: YouTube Video ID: $vId for ${song.title}",
      );
      if (vId != null) {
        await playYoutubeAudio(
          vId,
          song.id,
          playlistId: sharedPlaylist.id,
          overrideTitle: song.title,
          overrideArtist: song.artist,
          overrideArtUri: song.artUri,
          overrideAlbum: song.album,
        );
      }
    } else {
      // Search fallback if no direct ID
      final results = await searchMusic("${song.title} ${song.artist}");
      if (results.isNotEmpty) {
        final best = results.first.song;
        final vId = best.youtubeUrl != null
            ? YoutubePlayer.convertUrlToId(best.youtubeUrl!)
            : null;
        if (vId != null) {
          await playYoutubeAudio(
            vId,
            song.id,
            playlistId: sharedPlaylist.id,
            overrideTitle: song.title,
            overrideArtist: song.artist,
            overrideArtUri: best.artUri ?? song.artUri,
            overrideAlbum: best.album,
          );
        }
      }
    }
    return true;
  }

  Future<void> _enrichCurrentMetadata({
    required String videoId,
    required String songId,
    String? playlistId,
    required String currentTitle,
    required String currentArtist,
    bool isLocal = false,
  }) async {
    // Wait a brief moment to let playback stabilize
    await Future.delayed(const Duration(seconds: 2));

    // Safety check: is this still the song we are playing?
    if (_audioOnlySongId != songId) return;

    LogService().log(
      "Metadata Enrichment: Searching for '$currentTitle' by '$currentArtist'",
    );

    // 1. Clean Title for searching
    String cleanTitle = currentTitle;
    if (isLocal) {
      // Remove extension (e.g. .mp3, .m4a)
      final lastDot = cleanTitle.lastIndexOf('.');
      if (lastDot != -1 && (cleanTitle.length - lastDot) < 6) {
        cleanTitle = cleanTitle.substring(0, lastDot).trim();
      }
      // Replace underscores/hyphens with spaces
      cleanTitle = cleanTitle.replaceAll('_', ' ').replaceAll('-', ' ').trim();
    }

    String query = cleanTitle;
    if (currentArtist != _translate('unknown') &&
        currentArtist != "YouTube" &&
        currentArtist != "Local File") {
      query = "$currentArtist $cleanTitle";
    }

    try {
      final results = await _musicMetadataService.searchSongs(
        query: query,
        limit: 1,
      );
      if (results.isNotEmpty) {
        final match = results.first.song;
        LogService().log(
          "Metadata Enrichment Match: ${match.title} by ${match.artist}",
        );

        // 2. Map discovered data
        final String newTitle = match.title;
        final String newArtist = match.artist;
        final String? newArtwork = match.artUri;
        final String newAlbum = match.album;

        // 3. Update internal state if currently playing
        if (_audioOnlySongId == songId) {
          // Check if current metadata is generic/incomplete
          final bool isCurrentlyGeneric = _currentTrack == "Shared Song" ||
              _currentTrack == "Audio" ||
              _currentArtist == "Unknown" ||
              _currentArtist == "YouTube" ||
              _currentArtist == "Local File" ||
              _currentTrack.toLowerCase().endsWith('.mp3') ||
              _currentTrack.toLowerCase().endsWith('.m4a');

          if (isCurrentlyGeneric) {
            _currentTrack = newTitle;
            _currentArtist = newArtist;
            _currentAlbum = newAlbum;
          }

          if (newArtwork != null && newArtwork.isNotEmpty) {
            // Only replace artwork if we don't already have a good one for this song.
            final bool hasValidArt =
                _currentAlbumArt != null && _currentAlbumArt!.isNotEmpty;
            if (!hasValidArt) {
              _currentAlbumArt = newArtwork;
            }
          }

          // 4. Update artist image specifically (only if missing)
          if (_currentArtistImage == null) {
            fetchArtistImage(newArtist).then((img) {
              if (_audioOnlySongId == songId && _currentArtistImage == null) {
                _currentArtistImage = img;
                notifyListeners();
              }
            });
          }

          // 5. BROADCAST TO AUDIO SERVICE / ANDROID AUTO
          _audioHandler.updateMediaItem(
            MediaItem(
              id: isLocal ? videoId : "youtube://$videoId",
              title: isCurrentlyGeneric ? newTitle : _currentTrack,
              artist: isCurrentlyGeneric ? newArtist : _currentArtist,
              album: isCurrentlyGeneric ? newAlbum : _currentAlbum,
              artUri: _currentAlbumArt != null
                  ? Uri.tryParse(_currentAlbumArt!)
                  : (newArtwork != null ? Uri.tryParse(newArtwork) : null),
              extras: {
                'url': isLocal ? videoId : "youtube://$videoId",
                'type': 'playlist_song',
                'songId': songId,
                'playlistId': playlistId,
                'isLocal': isLocal,
                'is_enriched': true, // CRITICAL: Signal to listener to guard
              },
            ),
          );

          notifyListeners();
          LogService().log("Live Metadata Enrichment Applied!");

          // 5. Optionally PERSIST to the playlist if it was a saved song
          if (playlistId != null) {
            bool found = false;
            for (int i = 0; i < _playlists.length; i++) {
              if (_playlists[i].id == playlistId) {
                final songs = List<SavedSong>.from(_playlists[i].songs);
                final idx = songs.indexWhere((s) => s.id == songId);
                if (idx != -1) {
                  final s = songs[idx];
                  // Guard playlist update too
                  final bool songIsGeneric = s.title == "Shared Song" ||
                      s.title == "Audio" ||
                      s.artist == "Unknown" ||
                      s.artist == "YouTube" ||
                      s.artist == "Local File" ||
                      s.title.toLowerCase().endsWith('.mp3');

                  final bool songHasArt =
                      s.artUri != null && s.artUri!.isNotEmpty;

                  songs[idx] = s.copyWith(
                    title: songIsGeneric ? newTitle : s.title,
                    artist: songIsGeneric ? newArtist : s.artist,
                    album: songIsGeneric ? newAlbum : s.album,
                    artUri: songHasArt ? s.artUri : newArtwork,
                  );
                  _playlists[i] = _playlists[i].copyWith(songs: songs);
                  found = true;
                  break;
                }
              }
            }
            if (found) {
              await _playlistService.saveAll(_playlists);
              LogService().log(
                "Metadata Enrichment: Persisted to playlist $playlistId",
              );
            }
          }
        }
      } else {
        // Fallback: If no metadata service match, try to fetch from YouTube specifically
        if (!isLocal) {
          LogService().log(
            "Metadata Enrichment: No music service match, trying YouTube metadata fallback.",
          );
          final yt = yt_explode.YoutubeExplode();
          try {
            final video = await yt.videos.get(videoId);
            if (_audioOnlySongId == songId) {
              String ytTitle = video.title;
              String ytArtist = video.author;
              if (video.title.contains(' - ')) {
                final parts = video.title.split(' - ');
                ytArtist = parts[0].trim();
                ytTitle = parts[1].trim();
              }

              _currentTrack = ytTitle;
              _currentArtist = ytArtist;
              // Only replace artwork if we don't already have a valid one.
              final bool hasValidArt = _currentAlbumArt != null && _currentAlbumArt!.isNotEmpty;
              if (!hasValidArt) {
                _currentAlbumArt = video.thumbnails.highResUrl;
              }

              // Update the current MediaItem too — use _currentAlbumArt to keep consistency
              _audioHandler.updateMediaItem(
                MediaItem(
                  id: "youtube://$videoId",
                  title: ytTitle,
                  artist: ytArtist,
                  artUri: _currentAlbumArt != null
                      ? Uri.tryParse(_currentAlbumArt!)
                      : null,
                  extras: {
                    'url': "youtube://$videoId",
                    'type': 'playlist_song',
                    'songId': songId,
                    'playlistId': playlistId,
                    'isLocal': false,
                    'is_enriched': true, // CRITICAL: Signal to listener to guard
                  },
                ),
              );

              notifyListeners();
              LogService().log(
                "Metadata Enrichment: YouTube metadata fallback applied.",
              );
            }
          } catch (_) {
          } finally {
            yt.close();
          }
        }
      }
    } catch (e) {
      LogService().log("Metadata Enrichment Error: $e");
    }
  }

  // --- PLAYLIST SHARING (App-to-App) ---

  /// Silently resolve missing IDs in the background as soon as the user selects a playlist.
  Future<void> proactiveResolvePlaylist(Playlist playlist) async {
    if (_isPreparingQR || _isProactivelyResolving) return;

    // Check if we actually need to do any work
    final ytRegex = RegExp(
      r'(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?/\s]{11})',
    );
    bool needsResolution = playlist.songs.any(
      (s) => s.youtubeUrl == null || !ytRegex.hasMatch(s.youtubeUrl!),
    );
    bool needsMetadata = playlist.songs.any(
      (s) => s.artUri == null || s.artUri!.isEmpty,
    );

    if (!needsResolution && !needsMetadata) return;

    _isProactivelyResolving = true;
    try {
      if (needsMetadata) {
        // Trigger artwork/album enrichment
        enrichPlaylistMetadata(playlist.id);
      }

      if (needsResolution) {
        // Since we now rely on the cloud for sharing and the recipient handles missing YouTube IDs,
        // we no longer proactively generate and upload QR data to the cloud when entering a playlist.
        // If we want local youtube resolution, we should call a separate local resolution method here, 
        // but for now we skip doing anything cloud-related.
      }
    } finally {
      _isProactivelyResolving = false;
    }
  }

  Future<void> startQRPreparation(
    Playlist playlist,
    Function(String)? onComplete, {
    bool silent = false,
  }) async {
    // Nessun blocco: carichiamo istantaneamente i dati sul Cloud.
    // L'arricchimento dei dati mancanti (YouTube IDs) sarà gestito dal destinatario.
    _isPreparingQR = true;
    _isSilentPreparation = silent;
    _preparingPlaylist = playlist;
    if (!silent) notifyListeners();

    try {
      await _finishQRPrepCloud(playlist, onComplete);
    } catch (e) {
      LogService().log("QR sharing error: $e");
      onComplete?.call("");
    } finally {
      _isPreparingQR = false;
      _isSilentPreparation = false;
      _preparingPlaylist = null;
      notifyListeners();
    }
  }

  Future<void> _finishQRPrepCloud(
    Playlist playlist,
    Function(String)? onComplete,
  ) async {
    try {
      // MOD: Invia l'intera struttura delle canzoni per un import istantaneo (Full Sync)
      // Aggiungiamo anche una data di scadenza (es. 30 giorni) per l'auto-cancellazione (TTL)
      final expiresAt = DateTime.now().add(const Duration(days: 30));

      final cloudPayload = {
        'n': playlist.name,
        's': playlist.songs.map((s) {
          final json = s.toJson();
          json.remove('localPath'); // Sicurezza: non condividere il percorso locale
          return json;
        }).toList(),
        'v': 6, // Versione 6: Full Data Sync
        'ts': FieldValue.serverTimestamp(),
        'expiresAt': expiresAt, // Let the SDK handle conversion to Timestamp
      };

      // 1. Upload to Firestore to get a Token
      final docRef = await FirebaseFirestore.instance
          .collection('shared_playlists')
          .add(cloudPayload);

      final String token = docRef.id;

      // 2. The QR Code Link should point to the Github Web Redirector
      // Note: We use query parameters for better support on static pages
      final webUrl =
          "https://pjk72.github.io/musicstream/playlist.html?token=$token";

      // 3. For "Text Sharing" (button), we keep the original large deep link as fallback
      // Since it's a fallback, we use whatever YouTube URLs are currently available
      final currentIds = playlist.songs.map((s) {
        if (s.youtubeUrl == null) return "?";
        final regExp = RegExp(
          r'(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?/\s]{11})',
        );
        final match = regExp.firstMatch(s.youtubeUrl!);
        return match?.group(1) ?? "?";
      }).toList();

      final jsonStr = jsonEncode({'n': playlist.name, 'i': currentIds, 'v': 5});
      final compressed = zlib.encode(utf8.encode(jsonStr));
      _preparedDeepLink =
          "musicstream://playlist?data=${base64UrlEncode(compressed)}";

      // Pass the WEB URL to the callback for the QR UI
      onComplete?.call(webUrl);
    } catch (e) {
      LogService().log("Cloud Prep Error: $e");
      onComplete?.call("");
    }
  }

  Future<bool> importPlaylistByToken(String token) async {
    try {
      LogService().log("Importing Cloud Playlist with token: $token");

      final doc = await FirebaseFirestore.instance
          .collection('shared_playlists')
          .doc(token)
          .get();

      if (!doc.exists) {
        LogService().log("Shared playlist not found or expired.");
        return false;
      }

      final data = doc.data()!;
      final String name = data['n'] ?? "Shared Playlist";
      final int version = data['v'] ?? 5;

      List<SavedSong> songs = [];

      if (version >= 6) {
        // Full Sync: Ricostruiamo le canzoni direttamente dal JSON
        final List<dynamic> songsData = data['s'] ?? [];
        songs = songsData
            .map((s) {
              final map = Map<String, dynamic>.from(s);
              map.remove('localPath'); // Rimuoviamo sempre il percorso locale per sicurezza
              return SavedSong.fromJson(map);
            })
            .toList();
        LogService().log(
          "Cloud Protocol v6 (Full Sync): Importazione di ${songs.length} canzoni completata.",
        );
      } else {
        // Fallback per versioni precedenti (solo ID)
        final List<dynamic> idList = data['i'] ?? [];
        int counter = 0;
        songs = idList.map((id) {
          final String val = id.toString();
          counter++;
          return SavedSong(
            id: "shared_${val}_${DateTime.now().microsecondsSinceEpoch}_$counter",
            title: _translate('fetching_metadata'),
            artist: _translate('syncing_yt'),
            album: _translate('imported_via_cloud'),
            youtubeUrl: "https://www.youtube.com/watch?v=$val",
            dateAdded: DateTime.now(),
          );
        }).toList();
      }

      final String newId = "shared_pl_${DateTime.now().millisecondsSinceEpoch}";
      final playlist = Playlist(
        id: newId,
        name: name == "Shared Playlist" ? _translate('shared_playlist') : name,
        songs: songs,
        createdAt: DateTime.now(),
        creator: 'shared',
      );

      await _playlistService.addPlaylist(playlist);
      await _loadPlaylists();

      // Avviamo sempre l'arricchimento per risolvere eventuali link YouTube mancanti
      _startBackgroundEnrichment(newId, playlist.songs);

      LogService().log(
        "Cloud Playlist Imported Successfully: ${playlist.name}",
      );
      return true;
    } catch (e) {
      LogService().log("Failed to import cloud playlist: $e");
      return false;
    }
  }

  void cancelQRPreparation() {
    _isPreparingQR = false;
    _preparingPlaylist = null;
    notifyListeners();
  }

  Future<void> sharePlaylistText(Playlist playlist, String deepLink) async {
    try {
      if (deepLink.isEmpty) return;
      await Share.share(deepLink);
    } catch (e) {
      LogService().log("Error sharing playlist text: $e");
    }
  }

  @Deprecated("Use startQRPreparation + QR UI")
  Future<void> shareLocalPlaylist(Playlist playlist) async {
    // Legacy support: We perform a quick one-off resolution without complex progress state
    await startQRPreparation(playlist, (resolved) async {
      if (resolved.isNotEmpty) {
        await sharePlaylistText(playlist, resolved);
      }
    });
  }

  Future<bool> importSharedPlaylist(String base64Data) async {
    try {
      // 1. Decode and Decompress
      final compressedBytes = base64Url.decode(base64Data);
      final bytes = zlib.decode(compressedBytes);
      final jsonStr = utf8.decode(bytes);
      final jsonMap = jsonDecode(jsonStr);

      Playlist playlist;

      // Handle the new protocol Version 5: ID-Only
      if (jsonMap.containsKey('v') && jsonMap['v'] == 5) {
        final String name = jsonMap['n'] ?? "Shared Playlist";
        final List<dynamic> idList = jsonMap['i'] ?? [];
        int counter = 0;
        final List<SavedSong> songs = idList.map((id) {
          final String val = id.toString();
          counter++;
          return SavedSong(
            id: "shared_${val}_${DateTime.now().microsecondsSinceEpoch}_$counter",
            title: _translate('fetching_metadata'),
            artist: _translate('syncing_yt'),
            album: _translate('imported_via_cloud'),
            youtubeUrl: "https://www.youtube.com/watch?v=$val",
            dateAdded: DateTime.now(),
          );
        }).toList();

        playlist = Playlist(
          id: "shared_pl_${DateTime.now().millisecondsSinceEpoch}",
          name: name == "Shared Playlist"
              ? _translate('shared_playlist')
              : name,
          songs: songs,
          createdAt: DateTime.now(),
          creator: 'shared',
        );
        LogService().log(
          "Version 5 Protocol: Created playlist with ${songs.length} songs.",
        );
      } else if (jsonMap.containsKey('v') && jsonMap['v'] == 4) {
        // Version 4: Ultra-Slim
        final String name = jsonMap['n'] ?? "Shared Playlist";
        final bool isUltra = (jsonMap['u'] ?? 0) == 1;
        final List<dynamic> songsData = jsonMap['s'] ?? [];

        final List<SavedSong> songs = songsData.map((s) {
          if (isUltra) {
            final String val = s.toString();
            final String url = val.length == 11
                ? "https://www.youtube.com/watch?v=$val"
                : val;
            return SavedSong(
              id: "shared_${val}_${DateTime.now().microsecondsSinceEpoch}",
              title: _translate('fetching_metadata'),
              artist: _translate('syncing_yt'),
              album: _translate('shared'),
              youtubeUrl: url,
              dateAdded: DateTime.now(),
            );
          } else {
            final String val = s[2]?.toString() ?? "";
            final String url = val.length == 11
                ? "https://www.youtube.com/watch?v=$val"
                : val;
            return SavedSong(
              id: "shared_${val}_${DateTime.now().microsecondsSinceEpoch}",
              title: s[0] ?? "",
              artist: s[1] ?? "",
              album: _translate('shared'),
              youtubeUrl: url,
              dateAdded: DateTime.now(),
            );
          }
        }).toList();

        playlist = Playlist(
          id: "shared_pl_${DateTime.now().millisecondsSinceEpoch}",
          name: name == "Shared Playlist"
              ? _translate('shared_playlist')
              : name,
          songs: songs,
          createdAt: DateTime.now(),
          creator: 'shared',
        );
      } else if (jsonMap.containsKey('v') && jsonMap['v'] == 3) {
        // Version 3: Positional Slim Format
        final String name = jsonMap['n'] ?? "Shared Playlist";
        final List<dynamic> songsData = jsonMap['s'] ?? [];
        final List<SavedSong> songs = songsData.map((s) {
          final String val = s[2]?.toString() ?? "";
          final String url = val.length == 11
              ? "https://www.youtube.com/watch?v=$val"
              : val;
          return SavedSong(
            id: "shared_${val}_${DateTime.now().millisecondsSinceEpoch}",
            title: s[0] ?? "",
            artist: s[1] ?? "",
            album: _translate('shared'),
            youtubeUrl: url,
            dateAdded: DateTime.now(),
          );
        }).toList();

        playlist = Playlist(
          id: "shared_pl_${DateTime.now().millisecondsSinceEpoch}",
          name: name == "Shared Playlist"
              ? _translate('shared_playlist')
              : name,
          songs: songs,
          createdAt: DateTime.now(),
          creator: 'shared',
        );
      } else {
        // Version 1/2: Full JSON
        final Map<String, dynamic> cleanMap = Map<String, dynamic>.from(jsonMap);
        if (cleanMap['songs'] is List) {
          for (var s in cleanMap['songs']) {
            if (s is Map) s.remove('localPath');
          }
        }
        playlist = Playlist.fromJson(cleanMap);
      }

      LogService().log(
        "Importing Shared Playlist: ${playlist.name} (${playlist.songs.length} songs)",
      );

      // Save the playlist
      final newId = "shared_pl_${DateTime.now().millisecondsSinceEpoch}";
      final newPlaylist = playlist.copyWith(id: newId);
      await _playlistService.addPlaylist(newPlaylist);
      await _loadPlaylists();

      // Step 2: ACTIVATE AUTOMATIC METADATA ENRICHMENT
      // Ensure background recovery for ALL imported lists (v3, v4, v5, full JSON) to recover artworks and missing titles.
      _startBackgroundEnrichment(newId, newPlaylist.songs);

      return true;
    } catch (e) {
      LogService().log("Failed to import shared playlist: $e");
      return false;
    }
  }

  /// Implementation of User's automatic search/enrichment proposal
  Future<void> _startBackgroundEnrichment(
    String playlistId,
    List<SavedSong> pendingSongs,
  ) async {
    LogService().log(
      "Starting Background Metadata Enrichment for $playlistId...",
    );
    _enrichingPlaylists.add(playlistId);
    notifyListeners();

    int successCount = 0;
    int failCount = 0;

    try {
      const int batchSize = 5;
      for (int i = 0; i < pendingSongs.length; i += batchSize) {
        final batch = pendingSongs.skip(i).take(batchSize).toList();
        final List<SavedSong> enrichedBatch = [];

        for (final song in batch) {
          try {
            final enriched = await _fetchMetadataFromYoutube(song);
            if (enriched.title != _translate('fetching_metadata') &&
                enriched.artUri != null) {
              successCount++;
            } else {
              failCount++;
            }
            enrichedBatch.add(enriched);
          } catch (e) {
            failCount++;
            LogService().log("Enrichment failed for ${song.youtubeUrl}: $e");
            enrichedBatch.add(song);
          }
        }

        await _playlistService.updateSongsInPlaylist(playlistId, enrichedBatch);
        _loadPlaylists();
        await Future.delayed(const Duration(seconds: 1));
      }
    } finally {
      _enrichingPlaylists.remove(playlistId);
      notifyListeners();

      // Report results to UI
      final pl = _playlists.firstWhere(
        (p) => p.id == playlistId,
        orElse: () =>
            Playlist(id: '', name: '', songs: [], createdAt: DateTime.now()),
      );
      _enrichmentController.add(
        EnrichmentCompletion(
          playlistId: playlistId,
          playlistName: pl.name,
          successCount: successCount,
          failCount: failCount,
        ),
      );

      LogService().log(
        "Background Enrichment Complete for $playlistId. Success: $successCount, Failed: $failCount",
      );
    }
  }

  /// Helper to fetch info using YoutubeExplode
  Future<SavedSong> _fetchMetadataFromYoutube(SavedSong song) async {
    if (song.youtubeUrl == null) return song;

    // Fast path: if the song already has a working artwork and a real title, don't spam the network!
    if (song.artUri != null &&
        song.artUri!.isNotEmpty &&
        song.title != 'Fetching Metadata') {
      return song;
    }

    final yt = yt_explode.YoutubeExplode();
    try {
      final videoId = song.youtubeUrl!.split('v=').last.split('&').first;
      final video = await yt.videos.get(videoId);

      String artist = _translate('unknown_artist');
      String title = video.title;

      if (video.title.contains(" - ")) {
        final parts = video.title.split(" - ");
        artist = parts[0].trim();
        title = parts[1].trim();
      } else {
        artist = video.author;
      }

      return song.copyWith(
        title: title,
        artist: artist,
        album: _translate('fetched_from_yt'),
        artUri: video.thumbnails.highResUrl,
        isValid: true,
      );
    } finally {
      yt.close();
    }
  }

  // --- EXTERNAL PLAYLIST SCRAPER (Spotify/Apple/Amazon) ---

  Future<void> _handlePlaylistShare(String text) async {
    final urlMatch = RegExp(r'(https?:\/\/[^\s<>"]+)').firstMatch(text);
    if (urlMatch == null) return;
    String url = urlMatch.group(0)!;

    LogService().log("External Playlist Share Detected: $url");

    if (url.contains("youtube.com") || url.contains("youtu.be")) {
      LogService().log(_translate('yt_playlists_disabled'));
      return;
    } else {
      await _importExternalPlaylist(url);
    }
  }

  Future<void> _importExternalPlaylist(String url) async {
    try {
      LogService().log("Heavy Duty Scraper Starting: $url");
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        LogService().log("Scraper: Server error ${response.statusCode}");
        return;
      }

      final html = response.body;

      // 1. Precise Title Extraction & Cleaning
      final titleMatch = RegExp(
        r'<meta property="og:title" content="([^"]+)"',
      ).firstMatch(html);
      String plTitle = titleMatch?.group(1) ?? _translate('shared_playlist');

      // Intensive Cleanup for all providers
      plTitle = plTitle
          .replaceAll("on Amazon Music", "")
          .replaceAll("on Spotify", "")
          .replaceAll("on Apple Music", "")
          .replaceAll("Playlist - ", "")
          .replaceAll("Playlist: ", "")
          .trim();

      if (plTitle.isEmpty || plTitle.contains("Music") && plTitle.length < 10)
        plTitle = _translate('imported_playlist');
      LogService().log("Scraper: Targeted Playlist Name: '$plTitle'");

      final Set<String> tracksToResolve = {};

      // 2. PATTERN A: Script Block Harvester (__NEXT_DATA__ or JSON-LD)
      final nameRegex = RegExp(r'"name":"([^"]+)"', caseSensitive: false);
      final names = nameRegex.allMatches(html).map((m) => m.group(1)!).toList();

      final List<String> potentialTracks = names.where((n) {
        final low = n.toLowerCase();
        return n.length > 2 &&
            !low.contains("spotify") &&
            !low.contains("apple music") &&
            !low.contains("amazon music") &&
            !low.contains("playlist") &&
            !low.contains("search") &&
            !low.contains("home") &&
            !low.contains("library") &&
            !low.contains("created by") &&
            n != plTitle;
      }).toList();

      if (potentialTracks.isNotEmpty) {
        LogService().log(
          "Scraper Pattern A: Found ${potentialTracks.length} candidates in JSON/Script blocks.",
        );
        tracksToResolve.addAll(potentialTracks);
      }

      // 3. PATTERN B: Apple Music List Extraction (Table rows)
      if (url.contains("music.apple.com")) {
        final appleRegex = RegExp(
          r'class="songs-list-row__song-name"[^>]*>([^<]+)<',
        );
        final appMatches = appleRegex.allMatches(html);
        if (appMatches.isNotEmpty) {
          LogService().log(
            "Scraper Pattern B: Found ${appMatches.length} candidates in Apple Music list.",
          );
          for (var m in appMatches) tracksToResolve.add(m.group(1)!);
        }
      }

      // 4. PATTERN C: Spotify Specific metadata extraction
      if (url.contains("spotify.com")) {
        final spDescRegex = RegExp(
          r'<meta property="og:description" content="([^"]+)"',
        );
        final descMatch = spDescRegex.firstMatch(html);
        if (descMatch != null) {
          final desc = descMatch.group(1)!;
          if (desc.contains(" · ")) {
            final tracks = desc.split(" · ");
            for (var t in tracks) {
              final cleanT = t
                  .replaceAll("Listen to ", "")
                  .replaceAll("Ascolta ", "")
                  .trim();
              if (cleanT.length > 3) tracksToResolve.add(cleanT);
            }
          }
        }
      }

      // 5. PATTERN D: Brute Force "Track" link metadata
      final bruteRegex = RegExp(r'track\/[a-zA-Z0-9]+\/([^"]+)');
      final bruteMatches = bruteRegex.allMatches(html);
      for (var m in bruteMatches) {
        final decoded = Uri.decodeComponent(m.group(1)!).replaceAll("-", " ");
        if (decoded.length > 3) tracksToResolve.add(decoded);
      }

      if (tracksToResolve.isEmpty) {
        LogService().log(
          "Scraper: FAILED to identify any tracks. Attempting deep fallback search...",
        );
        final deepRegex = RegExp(r'([^"<>]+)\s+-\s+([^"<>]+)');
        final deepMatches = deepRegex.allMatches(html).take(10);
        for (var m in deepMatches) {
          final cand = "${m.group(1)} - ${m.group(2)}".trim();
          if (cand.length > 5 && !cand.contains("{") && !cand.contains("}"))
            tracksToResolve.add(cand);
        }
      }

      if (tracksToResolve.isEmpty) {
        LogService().log(
          "Scraper: Absolutely no tracks found. Import aborted.",
        );
        return;
      }

      LogService().log(
        "Scraper: Finalizing ${tracksToResolve.length} items for resolution.",
      );

      final newPlaylist = await _playlistService.createPlaylist(plTitle);
      final playlistId = newPlaylist.id;

      int resolvedCount = 0;
      final finalItems = tracksToResolve.toList();
      for (int i = 0; i < finalItems.length && i < 40; i++) {
        String rawTitle = finalItems[i];
        String searchTitle = rawTitle;
        String searchArtist = _translate('shared_artist');

        if (rawTitle.contains(" by ")) {
          final parts = rawTitle.split(" by ");
          searchTitle = parts[0];
          searchArtist = parts[1];
        } else if (rawTitle.contains(" - ")) {
          final parts = rawTitle.split(" - ");
          searchArtist = parts[0];
          searchTitle = parts[1];
        }

        final ytUrl = await searchYoutubeVideo(searchTitle, searchArtist);
        if (ytUrl != null) {
          final song = SavedSong(
            id: "${DateTime.now().millisecondsSinceEpoch}_$i",
            title: searchTitle,
            artist: searchArtist,
            album: plTitle,
            youtubeUrl: ytUrl,
            dateAdded: DateTime.now(),
          );
          await _playlistService.addSongToPlaylist(playlistId, song);
          resolvedCount++;
        }
      }

      await _loadPlaylists();
      LogService().log(
        "Success: '$plTitle' imported ($resolvedCount songs resolved on YouTube)",
      );
    } catch (e) {
      LogService().log("Heavy Duty Scraper Failure: $e");
    }
  }

  static const List<String> _userSessionKeys = [
    // Radio & stations
    _keySavedStations,
    _keyStartOption,
    _keyStartupStationId,
    _keyLastPlayedStationId,
    _keyCompactView,
    _keyShuffleMode,
    _keyManageGridView,
    _keyManageGroupingMode,
    _keyCategoryCompactViews,
    'station_order',
    _keyFavorites,
    _keyGenreOrder,
    _keyCategoryOrder,
    _keyUseCustomOrder,

    // Playlists
    'playlists_v2',

    // Play history
    _keyUserPlayHistory,
    _keyHistoryMetadata,
    _keyRecentSongsOrder,
    _keyAAUserPlayHistory,
    _keyAARecentSongsOrder,
    _keyLastSourceMap,
    _keyWeeklyPlayLog,

    // Followed artists/albums
    _keyFollowedArtists,
    _keyFollowedAlbums,
    _keyArtistImagesCache,
    _keyInvalidSongIds,

    // UI customization
    'pinned_library_actions',
    'pinned_playlist_actions',

    // Backup settings
    'backup_frequency',
    'last_backup_ts',
    'last_backup_type',

    // AI cache
    'for_you_cache',
    'for_you_cache_country',

    // Trending Promoted Playlists
    _keyPromotedPlaylists,

    // Audio settings
    _keyCrossfadeDuration,
    _keyPreferYouTubeAudioOnly,
  ];

  Future<void> snapshotGuestSession() async {
    if (_backupService.isSignedIn) {
      LogService().log("[RadioProvider] snapshotGuestSession skipped: User is signed in to Google.");
      return;
    }
    LogService().log("[RadioProvider] Starting guest session snapshot...");
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> snapshot = {};

      for (var key in _userSessionKeys) {
        if (prefs.containsKey(key)) {
          final val = prefs.get(key);
          snapshot[key] = val;
          LogService().log("[RadioProvider] Snapshot captured key: $key");
        }
      }
      
      final themeKeys = [
        'theme_id',
        'custom_primary',
        'custom_bg',
        'custom_card',
        'custom_surface',
        'custom_bg_image',
        'initial_setup_v2'
      ];
      for (var key in themeKeys) {
        if (prefs.containsKey(key)) {
          snapshot[key] = prefs.get(key);
        }
      }

      final jsonStr = jsonEncode(snapshot);
      await prefs.setString('guest_session_snapshot', jsonStr);
      LogService().log("[RadioProvider] Guest session snapshot saved. Size: ${jsonStr.length} chars.");
    } catch (e) {
      LogService().log("[RadioProvider] Error during guest snapshot: $e");
    }
  }

  Future<void> _restoreGuestSessionToPrefs(SharedPreferences prefs) async {
    final snapshotStr = prefs.getString('guest_session_snapshot');
    if (snapshotStr != null) {
      final Map<String, dynamic> snapshot = jsonDecode(snapshotStr);
      for (var entry in snapshot.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value is String) await prefs.setString(key, value);
        else if (value is int) await prefs.setInt(key, value);
        else if (value is bool) await prefs.setBool(key, value);
        else if (value is double) await prefs.setDouble(key, value);
        else if (value is List) await prefs.setStringList(key, value.map((e) => e.toString()).toList());
      }
      LogService().log("[RadioProvider] Guest session data restored to SharedPreferences.");
    }
  }

  Future<void> resetAllData({ThemeProvider? themeProvider, bool restoreGuest = true}) async {
    final prefs = await SharedPreferences.getInstance();

    // Ferma la musica per ripulire PlayerBar e NowPlayingHeader
    try {
      await _audioHandler.stop();
    } catch (_) {}

    // 1. Clear memory state (RadioProvider)
    stations.clear();
    _currentStation = null;
    _currentTrack = "";
    _currentArtist = "";
    _currentAlbum = "";
    _currentAlbumArt = null;
    _currentArtistImage = null;
    _currentPlayingPlaylistId = null;
    _stationOrder.clear();
    _useCustomOrder = false;

    _followedArtists.clear();
    _followedAlbums.clear();
    _userPlayHistory.clear();
    _aaUserPlayHistory.clear();
    _historyMetadata.clear();
    _recentSongsOrder.clear();
    _aaRecentSongsOrder.clear();
    _lastSourceMap.clear();
    _promotedPlaylists.clear();
    _weeklyPlayLog.clear();
    _favorites.clear();
    _playlists.clear();
    resetForYou(); // Pulisce le raccomandazioni AI "Per Te"

    // 2. Clear all user-session SharedPreferences keys
    for (var key in _userSessionKeys) {
      await prefs.remove(key);
    }

    // 3. Ripristina il ThemeProvider di base (prima del restore ospite)
    if (themeProvider != null) {
      await themeProvider.resetToDefaults();
    }

    if (restoreGuest) {
      // 4. Ripristina la cache Guest salvata precedentemente
      await _restoreGuestSessionToPrefs(prefs);
    }

    // 5. Ricarica i servizi locali e la UI (tema e playlist inclusi)
    PlaylistService().clearCache();
    if (themeProvider != null) {
      await themeProvider.loadSettings();
    }
    
    // 6. Ricarica lo stato Radio
    await _loadStations();
    await _loadPlaylists();
    await _loadUserPlayHistory();
    await _loadStationOrder();
    await _loadStartupSettings();
    notifyListeners();
  }
}

class EnrichmentCompletion {
  final String playlistId;
  final String playlistName;
  final int successCount;
  final int failCount;
  EnrichmentCompletion({
    required this.playlistId,
    required this.playlistName,
    required this.successCount,
    required this.failCount,
  });
}
