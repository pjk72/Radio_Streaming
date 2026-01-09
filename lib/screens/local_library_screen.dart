import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../services/local_playlist_service.dart';
import '../services/playlist_service.dart';
import '../providers/radio_provider.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';

class LocalLibraryScreen extends StatefulWidget {
  const LocalLibraryScreen({super.key});

  @override
  State<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

class _LocalLibraryScreenState extends State<LocalLibraryScreen> {
  final LocalPlaylistService _localService = LocalPlaylistService();
  final PlaylistService _playlistService = PlaylistService();

  bool _isLoading = true;
  Map<String, List<SongModel>> _folders = {};

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    setState(() => _isLoading = true);
    final folders = await _localService.getLocalFolders();
    if (mounted) {
      final radio = Provider.of<RadioProvider>(context, listen: false);
      bool anyUpdated = false;

      // 1. First, check all existing local playlists in RadioProvider
      final localPlaylists = radio.playlists
          .where((p) => p.creator == 'local')
          .toList();

      for (var existing in localPlaylists) {
        final path = _extractPathFromId(existing.id);
        final nameOnDevice = path != null
            ? path.split(Platform.pathSeparator).last
            : null;

        // Use a flag to track if we found this playlist on device
        bool foundOnDevice = path != null && folders.containsKey(path);

        if (foundOnDevice) {
          // Folder exists at same path. Check for name or content change.
          final deviceSongs = folders[path]!;
          final currentName = path.split(Platform.pathSeparator).last;

          final savedSongs = deviceSongs
              .map((s) => _mapToSavedSong(s))
              .toList();

          bool contentChanged = savedSongs.length != existing.songs.length;
          if (!contentChanged) {
            for (int i = 0; i < savedSongs.length; i++) {
              if (savedSongs[i].id != existing.songs[i].id) {
                contentChanged = true;
                break;
              }
            }
          }

          // SYNC NAME & CONTENT: If path is same but name or content differs
          if (contentChanged || existing.name != currentName) {
            final updatedPlaylist = existing.copyWith(
              name: currentName,
              songs: savedSongs,
            );
            await _playlistService.addPlaylist(updatedPlaylist);
            // Enrich metadata in background
            radio.enrichPlaylistMetadata(existing.id);
            anyUpdated = true;
          }
        } else {
          // FOLDER NOT FOUND BY PATH (Renamed or Moved)
          // Look for a folder on device that contains the same songs
          String? bestMatchPath;
          double bestMatchScore = 0;

          final existingSongIds = existing.songs.map((s) => s.id).toSet();

          for (var entry in folders.entries) {
            final devicePath = entry.key;
            final deviceSongs = entry.value;
            if (deviceSongs.isEmpty) continue;

            int matchCount = 0;
            for (var ds in deviceSongs) {
              if (existingSongIds.contains('local_${ds.id}')) {
                matchCount++;
              }
            }

            double score = matchCount / existing.songs.length;
            if (score > 0.7 && score > bestMatchScore) {
              bestMatchScore = score;
              bestMatchPath = devicePath;
            }
          }

          if (bestMatchPath != null) {
            // MIGRATION: Auto-migrate to new path/name
            final newName = bestMatchPath.split(Platform.pathSeparator).last;
            final newId = _generatePlaylistId(bestMatchPath);
            final deviceSongs = folders[bestMatchPath]!;

            final migratedPlaylist = Playlist(
              id: newId,
              name: newName,
              songs: deviceSongs.map((s) => _mapToSavedSong(s)).toList(),
              createdAt: existing.createdAt,
              creator: 'local',
            );

            // Important: Delete old ID reference and add new one
            await _playlistService.deletePlaylist(existing.id);
            await _playlistService.addPlaylist(migratedPlaylist);

            // Enrich metadata in background
            radio.enrichPlaylistMetadata(newId);
            anyUpdated = true;
          }
        }
      }

      setState(() {
        _folders = folders;
        _isLoading = false;
      });

      if (anyUpdated && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Synchronized local library & folder names"),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  SavedSong _mapToSavedSong(SongModel s) {
    return SavedSong(
      id: 'local_${s.id}',
      title: s.title,
      artist: s.artist ?? 'Unknown Artist',
      album: s.album ?? 'Unknown Album',
      duration: Duration(milliseconds: s.duration ?? 0),
      dateAdded: DateTime.now(),
      localPath: s.data,
      isValid: true,
    );
  }

  String? _extractPathFromId(String id) {
    if (!id.startsWith('local_folder_')) return null;
    try {
      final encoded = id.replaceFirst('local_folder_', '');
      return utf8.decode(base64Url.decode(encoded));
    } catch (_) {
      return null;
    }
  }

  String _generatePlaylistId(String path) {
    return 'local_folder_${base64Url.encode(utf8.encode(path))}';
  }

  Future<void> _toggleFolder(
    String path,
    String name,
    List<SongModel> songs,
    bool isAdded,
  ) async {
    final id = _generatePlaylistId(path);

    if (isAdded) {
      // Remove
      await _playlistService.deletePlaylist(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Removed '$name' from playlists")),
        );
      }
    } else {
      // Add
      final savedSongs = songs
          .map(
            (s) => SavedSong(
              id: 'local_${s.id}',
              title: s.title,
              artist: s.artist ?? 'Unknown Artist',
              album: s.album ?? 'Unknown Album',
              duration: Duration(milliseconds: s.duration ?? 0),
              dateAdded: DateTime.now(),
              localPath: s.data,
              isValid: true,
            ),
          )
          .toList();

      final playlist = Playlist(
        id: id,
        name: name,
        songs: savedSongs,
        createdAt: DateTime.now(),
        creator: 'local',
      );

      await _playlistService.addPlaylist(playlist);

      // Enrich metadata in background
      final radio = Provider.of<RadioProvider>(context, listen: false);
      radio.enrichPlaylistMetadata(id);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Added '$name' to playlists")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final radio = Provider.of<RadioProvider>(context);
    final sortedKeys = _folders.keys.toList()
      ..sort((a, b) {
        final nameA = a.split(Platform.pathSeparator).last.toLowerCase();
        final nameB = b.split(Platform.pathSeparator).last.toLowerCase();
        int cmp = nameA.compareTo(nameB);
        if (cmp != 0) return cmp;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text("Local Music Library"),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _loadFolders,
        color: Theme.of(context).primaryColor,
        child: _isLoading && _folders.isEmpty
            ? ListView(
                children: [
                  Container(
                    height: MediaQuery.of(context).size.height * 0.7,
                    alignment: Alignment.center,
                    child: const CircularProgressIndicator(),
                  ),
                ],
              )
            : sortedKeys.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Container(
                    height: MediaQuery.of(context).size.height * 0.7,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.folder_off,
                          size: 64,
                          color: Theme.of(
                            context,
                          ).textTheme.bodySmall?.color?.withValues(alpha: 0.24),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          "No music folders found",
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodyMedium?.color
                                ?.withValues(alpha: 0.54),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Swipe down to scan again",
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodySmall?.color
                                ?.withValues(alpha: 0.24),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: sortedKeys.length,
                itemBuilder: (ctx, index) {
                  final path = sortedKeys[index];
                  final songs = _folders[path]!;
                  final name = path.split(Platform.pathSeparator).last;
                  final id = _generatePlaylistId(path);

                  // Check if exists in RadioProvider playlists
                  final isAdded = radio.playlists.any((p) => p.id == id);

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    color: Theme.of(context).cardColor.withValues(alpha: 0.2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isAdded
                            ? Theme.of(
                                context,
                              ).primaryColor.withValues(alpha: 0.2)
                            : Colors.transparent,
                        width: 1,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        // "Possibility to click on folder to create or add"
                        if (!isAdded) {
                          _toggleFolder(path, name, songs, false);
                        } else {
                          // Maybe just show snackbar? Or re-add (update)?
                          _toggleFolder(
                            path,
                            name,
                            songs,
                            true,
                          ); // Currently toggles OFF
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Theme.of(context).canvasColor,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.audio_file,
                                color: Theme.of(context).iconTheme.color,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "${songs.length} songs",
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.color
                                              ?.withValues(alpha: 0.54),
                                        ),
                                  ),
                                  Text(
                                    path,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.color
                                              ?.withValues(alpha: 0.38),
                                          fontSize: 10,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              onPressed: () =>
                                  _toggleFolder(path, name, songs, isAdded),
                              icon: Icon(
                                isAdded
                                    ? Icons.check_circle
                                    : Icons.add_circle_outline,
                                color: isAdded
                                    ? Theme.of(context).primaryColor
                                    : Theme.of(context).iconTheme.color
                                          ?.withValues(alpha: 0.54),
                                size: 28,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
