import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_song.dart';
import '../models/playlist.dart';
import 'log_service.dart';
import 'package:flutter/foundation.dart';

class PlaylistLoadResult {
  final List<Playlist> playlists;
  final List<SavedSong> uniqueSongs;
  PlaylistLoadResult(this.playlists, this.uniqueSongs);
}

class PlaylistService {
  static const String _keyPlaylists = 'playlists_v2';
  static const String _keyOldSongs = 'saved_songs';

  static final PlaylistService _instance = PlaylistService._internal();
  factory PlaylistService() => _instance;
  PlaylistService._internal();

  final _playlistsUpdatedController = StreamController<void>.broadcast();
  Stream<void> get onPlaylistsUpdated => _playlistsUpdatedController.stream;

  List<Playlist>? _cachedPlaylists;
  List<SavedSong>? _cachedUniqueSongs;

  void _notifyListeners() {
    _playlistsUpdatedController.add(null);
  }

  Future<List<Playlist>> loadPlaylists() async {
    final result = await loadPlaylistsResult();
    return result.playlists;
  }

  Future<PlaylistLoadResult> loadPlaylistsResult() async {
    if (_cachedPlaylists != null && _cachedUniqueSongs != null) {
      return PlaylistLoadResult(_cachedPlaylists!, _cachedUniqueSongs!);
    }

    final prefs = await SharedPreferences.getInstance();

    // Check for V2 data
    if (prefs.containsKey(_keyPlaylists)) {
      final String? jsonString = prefs.getString(_keyPlaylists);
      if (jsonString != null) {
        final result = await compute(_decodePlaylists, jsonString);
        _cachedPlaylists = result.playlists;
        _cachedUniqueSongs = result.uniqueSongs;
        return result;
      }
    }

    // Migration / First Run
    List<Playlist> playlists = [];

    // Check for Old data
    if (prefs.containsKey(_keyOldSongs)) {
      final String? oldJson = prefs.getString(_keyOldSongs);
      if (oldJson != null) {
        final List<dynamic> oldList = jsonDecode(oldJson);
        final List<SavedSong> oldSongs = oldList
            .map((j) => SavedSong.fromJson(j))
            .toList();

        // Create default 'Favorites' with old songs
        playlists.add(
          Playlist(
            id: 'favorites',
            name: 'Favorites',
            songs: oldSongs,
            createdAt: DateTime.now(),
          ),
        );
      }
    }

    // Ensure at least one playlist exists if empty
    if (playlists.isEmpty) {
      playlists.add(
        Playlist(
          id: 'favorites',
          name: 'Favorites',
          songs: [],
          createdAt: DateTime.now(),
        ),
      );
    }

    await _savePlaylists(prefs, playlists);
    _cachedPlaylists = playlists;

    // Re-calculate unique songs for the result
    final Set<String> ids = {};
    final List<SavedSong> uniqueSongs = [];
    for (var p in playlists) {
      for (var s in p.songs) {
        if (ids.add(s.id)) uniqueSongs.add(s);
      }
    }
    _cachedUniqueSongs = uniqueSongs;

    return PlaylistLoadResult(playlists, uniqueSongs);
  }

  Future<void> _savePlaylists(
    SharedPreferences prefs,
    List<Playlist> playlists,
  ) async {
    _cachedPlaylists = playlists;
    _cachedUniqueSongs = null; // Clear stale unique songs cache
    final String jsonString = await compute(_encodePlaylists, playlists);
    await prefs.setString(_keyPlaylists, jsonString);
  }

  static String _encodePlaylists(List<Playlist> playlists) {
    return jsonEncode(playlists.map((p) => p.toJson()).toList());
  }

  static PlaylistLoadResult _decodePlaylists(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    final playlists = jsonList.map((j) => Playlist.fromJson(j)).toList();

    final Set<String> ids = {};
    final List<SavedSong> uniqueSongs = [];
    for (var p in playlists) {
      for (var s in p.songs) {
        if (ids.add(s.id)) {
          uniqueSongs.add(s);
        }
      }
    }
    return PlaylistLoadResult(playlists, uniqueSongs);
  }

  void clearCache() {
    _cachedPlaylists = null;
  }

  Future<Playlist> createPlaylist(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final newPlaylist = Playlist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      songs: [],
      createdAt: DateTime.now(),
    );

    playlists.add(newPlaylist);

    await _savePlaylists(prefs, playlists);
    _notifyListeners();
    return newPlaylist;
  }

  Future<void> deletePlaylist(String id) async {
    final prefs = await SharedPreferences.getInstance();
    var playlists = await loadPlaylists();

    // Don't allow deleting the last playlist if you want, or handle it in UI
    playlists.removeWhere((p) => p.id == id);

    if (playlists.isEmpty) {
      playlists.add(
        Playlist(
          id: 'favorites',
          name: 'Favorites',
          songs: [],
          createdAt: DateTime.now(),
        ),
      );
    }

    await _savePlaylists(prefs, playlists);
    _notifyListeners();
  }

  Future<void> addSongToPlaylist(String playlistId, SavedSong song) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      // Check duplicates
      if (!playlists[index].songs.any(
        (s) =>
            s.id == song.id ||
            (s.title == song.title && s.artist == song.artist),
      )) {
        playlists[index].songs.insert(0, song);
        await _savePlaylists(prefs, playlists);
        _notifyListeners();
      }
    }
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      playlists[index].songs.removeWhere((s) => s.id == songId);
      await _savePlaylists(prefs, playlists);
      _notifyListeners();
    }
  }

  Future<void> removeSongsFromPlaylist(
    String playlistId,
    List<String> songIds,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      playlists[index].songs.removeWhere((s) => songIds.contains(s.id));
      await _savePlaylists(prefs, playlists);
      _notifyListeners();
    }
  }

  Future<void> moveSong(
    String songId,
    String fromPlaylistId,
    String toPlaylistId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final fromIndex = playlists.indexWhere((p) => p.id == fromPlaylistId);
    final toIndex = playlists.indexWhere((p) => p.id == toPlaylistId);

    if (fromIndex != -1 && toIndex != -1) {
      final songIndex = playlists[fromIndex].songs.indexWhere(
        (s) => s.id == songId,
      );
      if (songIndex != -1) {
        final song = playlists[fromIndex].songs[songIndex];

        // Logic: specific request "only when you move a song ON THE FAVORITES CARD create a copy"
        // If moving TO favorites -> COPY (do not remove from source)
        // If moving TO others -> MOVE (remove from source)
        if (toPlaylistId != 'favorites') {
          playlists[fromIndex].songs.removeAt(songIndex);
        }

        // Add to destination (check duplicates)
        if (!playlists[toIndex].songs.any(
          (s) =>
              s.id == song.id ||
              (s.title == song.title && s.artist == song.artist),
        )) {
          playlists[toIndex].songs.insert(0, song);
        } else {
          // If already exists:
          // If we did a MOVE (removed from source), and it is valid to "merge", it's fine.
          // If we did a COPY, it just means it's already there.
        }

        await _savePlaylists(prefs, playlists);
        _notifyListeners();
      }
    }
  }

  Future<void> moveSongs(
    List<String> songIds,
    String fromPlaylistId,
    String toPlaylistId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final fromIndex = playlists.indexWhere((p) => p.id == fromPlaylistId);
    final toIndex = playlists.indexWhere((p) => p.id == toPlaylistId);

    if (fromIndex != -1 && toIndex != -1) {
      bool changed = false;
      for (var songId in songIds) {
        final songIndex = playlists[fromIndex].songs.indexWhere(
          (s) => s.id == songId,
        );
        if (songIndex != -1) {
          final song = playlists[fromIndex].songs[songIndex];

          if (toPlaylistId != 'favorites') {
            playlists[fromIndex].songs.removeAt(songIndex);
          }

          if (!playlists[toIndex].songs.any(
            (s) =>
                s.id == song.id ||
                (s.title == song.title && s.artist == song.artist),
          )) {
            playlists[toIndex].songs.insert(0, song);
          }
          changed = true;
        }
      }

      if (changed) {
        await _savePlaylists(prefs, playlists);
        _notifyListeners();
      }
    }
  }

  Future<bool> isSongInFavorites(String title, String artist) async {
    final playlists = await loadPlaylists();
    if (playlists.isEmpty) return false;

    // Check ALL playlists to see if the song is saved anywhere
    return playlists.any(
      (p) => p.songs.any((s) => s.title == title && s.artist == artist),
    );
  }

  Future<void> addToGenrePlaylist(String genre, SavedSong song) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    // 2. Find or Create Genre Playlist
    // Normalize genre name
    String targetName = genre.trim();
    if (targetName.isEmpty || targetName.toLowerCase() == 'unknown') {
      targetName = "Mix"; // Dedicated card for no genre
    }

    if (targetName.isNotEmpty) {
      int genreIndex = playlists.indexWhere(
        (p) => p.name.toLowerCase() == targetName.toLowerCase(),
      );

      if (genreIndex == -1) {
        // Create new
        final newPlaylist = Playlist(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: targetName, // e.g. "Pop", "Rock"
          songs: [],
          createdAt: DateTime.now(),
        );
        playlists.add(newPlaylist);
        genreIndex = playlists.length - 1;
      }

      // Add to Genre Playlist
      if (!playlists[genreIndex].songs.any(
        (s) => s.title == song.title && s.artist == song.artist,
      )) {
        playlists[genreIndex].songs.insert(0, song);
      }
    }

    await _savePlaylists(prefs, playlists);
    _notifyListeners();
  }

  Future<void> restoreSongsToPlaylist(
    String playlistId,
    List<SavedSong> songs, {
    String? playlistName,
  }) async {
    await restoreSongsToMultiplePlaylists(
      [playlistId],
      songs,
      playlistNames: playlistName != null ? {playlistId: playlistName} : null,
    );
  }

  Future<void> restoreSongsToMultiplePlaylists(
    List<String> playlistIds,
    List<SavedSong> songs, {
    Map<String, String>? playlistNames,
  }) async {
    LogService().log(
      "PlaylistService: Restoring ${songs.length} songs to ${playlistIds.join(', ')}",
    );
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();
    bool anyChanged = false;

    for (var playlistId in playlistIds) {
      var index = playlists.indexWhere((p) => p.id == playlistId);

      if (index == -1 &&
          playlistNames != null &&
          playlistNames.containsKey(playlistId)) {
        final newPlaylist = Playlist(
          id: playlistId,
          name: playlistNames[playlistId]!,
          songs: [],
          createdAt: DateTime.now(),
        );
        playlists.add(newPlaylist);
        index = playlists.length - 1;
      }

      if (index != -1) {
        final existingIds = playlists[index].songs.map((s) => s.id).toSet();
        final List<SavedSong> newSongs = songs
            .where((s) => !existingIds.contains(s.id))
            .toList();

        if (newSongs.isNotEmpty) {
          playlists[index].songs.insertAll(0, newSongs);
          anyChanged = true;
        }
      }
    }

    if (anyChanged) {
      await _savePlaylists(prefs, playlists);
      _notifyListeners();
      LogService().log("PlaylistService: Bulk import complete.");
    }
  }

  Future<void> markSongAsInvalid(String playlistId, String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final songIndex = playlists[index].songs.indexWhere(
        (s) => s.id == songId,
      );
      if (songIndex != -1) {
        playlists[index].songs[songIndex] = playlists[index].songs[songIndex]
            .copyWith(isValid: false);
        await _savePlaylists(prefs, playlists);
        _notifyListeners();
      }
    }
  }

  Future<void> markSongAsInvalidGlobally(String songId) async {
    LogService().log("Service: markSongAsInvalidGlobally for $songId");
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();
    bool changed = false;

    for (var i = 0; i < playlists.length; i++) {
      final songIndex = playlists[i].songs.indexWhere((s) => s.id == songId);
      if (songIndex != -1) {
        playlists[i].songs[songIndex] = playlists[i].songs[songIndex].copyWith(
          isValid: false,
        );
        changed = true;
        LogService().log(
          "Service: Found and marked invalid in playlist '${playlists[i].name}'",
        );
      }
    }

    if (changed) {
      await _savePlaylists(prefs, playlists);
      _notifyListeners();
      LogService().log("Service: Saved playlists and notified listeners");
    } else {
      LogService().log("Service: Song ID $songId not found in any playlist");
    }
  }

  Future<void> unmarkSongAsInvalidGlobally(String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();
    bool changed = false;

    for (var i = 0; i < playlists.length; i++) {
      final songIndex = playlists[i].songs.indexWhere((s) => s.id == songId);
      if (songIndex != -1) {
        playlists[i].songs[songIndex] = playlists[i].songs[songIndex].copyWith(
          isValid: true,
        );
        changed = true;
      }
    }

    if (changed) {
      await _savePlaylists(prefs, playlists);
      _notifyListeners();
    }
  }

  Future<void> unmarkSongAsInvalid(String playlistId, String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final songIndex = playlists[index].songs.indexWhere(
        (s) => s.id == songId,
      );
      if (songIndex != -1) {
        playlists[index].songs[songIndex] = playlists[index].songs[songIndex]
            .copyWith(isValid: true);
        await _savePlaylists(prefs, playlists);
        _notifyListeners();
      }
    }
  }

  Future<void> updateSongDuration(
    String playlistId,
    String songId,
    Duration duration,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();

    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final songIndex = playlists[index].songs.indexWhere(
        (s) => s.id == songId,
      );
      if (songIndex != -1) {
        playlists[index].songs[songIndex] = playlists[index].songs[songIndex]
            .copyWith(duration: duration);
        await _savePlaylists(prefs, playlists);
        _notifyListeners();
      }
    }
  }

  Future<void> removeSongFromAllPlaylists(String songId) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();
    bool changed = false;

    for (var p in playlists) {
      final initialLen = p.songs.length;
      p.songs.removeWhere((s) => s.id == songId);
      if (p.songs.length != initialLen) changed = true;
    }

    if (changed) {
      await _savePlaylists(prefs, playlists);
      _notifyListeners();
    }
  }

  Future<void> removeSongsFromAllPlaylists(List<String> songIds) async {
    final prefs = await SharedPreferences.getInstance();
    final playlists = await loadPlaylists();
    bool changed = false;

    for (var p in playlists) {
      final initialLen = p.songs.length;
      p.songs.removeWhere((s) => songIds.contains(s.id));
      if (p.songs.length != initialLen) changed = true;
    }

    if (changed) {
      await _savePlaylists(prefs, playlists);
      _notifyListeners();
    }
  }

  Future<void> saveAll(List<Playlist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    await _savePlaylists(prefs, playlists);
    _notifyListeners();
  }
}
