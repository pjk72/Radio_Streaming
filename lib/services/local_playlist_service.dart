import 'dart:io';
import 'package:on_audio_query/on_audio_query.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import 'log_service.dart';

class LocalPlaylistService {
  final OnAudioQuery _audioQuery = OnAudioQuery();
  Future<Map<String, List<SongModel>>> getLocalFolders() async {
    try {
      // Check permissions
      bool hasPermission = await _audioQuery.checkAndRequest();
      if (!hasPermission) {
        LogService().log("LocalPlaylistService: No storage permission");
        return {};
      }

      // Query all songs
      List<SongModel> songs = await _audioQuery.querySongs(
        sortType: null,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      if (songs.isEmpty) return {};

      // Group songs by parent folder
      Map<String, List<SongModel>> folderMap = {};
      for (var song in songs) {
        // Get folder path from data (which is the full path)
        final file = File(song.data);
        final folderPath = file.parent.path;
        if (!folderMap.containsKey(folderPath)) {
          folderMap[folderPath] = [];
        }
        folderMap[folderPath]!.add(song);
      }
      return folderMap;
    } catch (e) {
      LogService().log("LocalPlaylistService Error: $e");
      return {};
    }
  }

  Future<List<Playlist>> scanLocalPlaylists() async {
    try {
      final folderMap = await getLocalFolders();

      List<Playlist> localPlaylists = [];
      for (var entry in folderMap.entries) {
        final folderPath = entry.key;
        final folderSongs = entry.value;
        final folderName = folderPath.split(Platform.pathSeparator).last;
        if (folderSongs.isEmpty) continue;

        localPlaylists.add(
          Playlist(
            id: 'local_${folderPath.hashCode}',
            name: folderName,
            songs: folderSongs.map((s) => _mapSong(s)).toList(),
            createdAt: DateTime.now(),
            creator: 'local', // Special creator type
          ),
        );
      }
      return localPlaylists;
    } catch (e) {
      LogService().log("LocalPlaylistService Error: $e");
      return [];
    }
  }

  SavedSong _mapSong(SongModel s) {
    return SavedSong(
      id: 'local_${s.id}',
      title: s.title,
      artist: s.artist ?? 'Unknown Artist',
      album: s.album ?? 'Unknown Album',
      duration: Duration(milliseconds: s.duration ?? 0),
      dateAdded: DateTime.now(),
      localPath: s.data, // Using data path for local playback
      isValid: true,
    );
  }
}
