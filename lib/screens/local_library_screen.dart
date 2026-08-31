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
import '../providers/language_provider.dart';

class LocalLibraryScreen extends StatefulWidget {
  const LocalLibraryScreen({super.key});

  @override
  State<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

class _LocalLibraryScreenState extends State<LocalLibraryScreen> {
  final LocalPlaylistService _localService = LocalPlaylistService();
  final PlaylistService _playlistService = PlaylistService();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  Map<String, List<SongModel>> _folders = {};
  final Set<String> _selectedPaths = {};
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _isMusicStreamFolder(String path) {
    final norm = path.replaceAll('\\', '/').toLowerCase();
    return norm.contains('/musicstream') ||
        norm.endsWith('/musicstream') ||
        norm.startsWith('musicstream/') ||
        norm == 'musicstream';
  }

  Future<void> _loadFolders() async {
    setState(() => _isLoading = true);
    final folders = await _localService.getLocalFolders();
    if (mounted) {
      final radio = Provider.of<RadioProvider>(context, listen: false);
      final lang = Provider.of<LanguageProvider>(context, listen: false);
      bool anyUpdated = false;

      // 1. Check all existing local playlists in RadioProvider
      final localPlaylists = radio.playlists
          .where((p) => p.creator == 'local')
          .toList();

      for (var existing in localPlaylists) {
        final path = _extractPathFromId(existing.id);
        bool foundOnDevice = path != null && folders.containsKey(path);

        if (foundOnDevice) {
          final deviceSongs = folders[path]!;
          final Map<String, SavedSong> existingSongMap = {
            for (var s in existing.songs) s.id: s
          };
          final savedSongs = deviceSongs.map((s) {
            final existingSong = existingSongMap['local_${s.id}'];
            if (existingSong != null) {
              return existingSong.copyWith(
                duration: Duration(milliseconds: s.duration ?? 0),
                localPath: s.data,
                isValid: true,
              );
            }
            return _mapToSavedSong(s, lang);
          }).toList();

          bool contentChanged = savedSongs.length != existing.songs.length;
          if (!contentChanged) {
            for (int i = 0; i < savedSongs.length; i++) {
              if (savedSongs[i].id != existing.songs[i].id) {
                contentChanged = true;
                break;
              }
            }
          }

          if (contentChanged) {
            final updatedPlaylist = existing.copyWith(songs: savedSongs);
            await _playlistService.addPlaylist(updatedPlaylist);
            radio.enrichPlaylistMetadata(existing.id);
            anyUpdated = true;
          }
        } else if (existing.id.startsWith('local_folder_')) {
          // Folder migrated/renamed (only check for single-folder playlists)
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
            final newName = bestMatchPath.split(Platform.pathSeparator).last;
            final newId = _generatePlaylistId(bestMatchPath);
            final deviceSongs = folders[bestMatchPath]!;

            final migratedPlaylist = Playlist(
              id: newId,
              name: newName,
              songs: deviceSongs.map((s) => _mapToSavedSong(s, lang)).toList(),
              createdAt: existing.createdAt,
              creator: 'local',
            );

            await _playlistService.deletePlaylist(existing.id);
            await _playlistService.addPlaylist(migratedPlaylist);
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
          SnackBar(
            content: Text(lang.translate('sync_local_library')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  SavedSong _mapToSavedSong(SongModel s, LanguageProvider lang) {
    return SavedSong(
      id: 'local_${s.id}',
      title: s.title,
      artist: s.artist ?? lang.translate('unknown_artist'),
      album: s.album ?? lang.translate('unknown_album'),
      genre: s.genre,
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
    if (!mounted) return;
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    final id = _generatePlaylistId(path);

    if (isAdded) {
      await _playlistService.deletePlaylist(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lang.translate('removed_from_playlists').replaceAll('{0}', name),
            ),
          ),
        );
      }
    } else {
      final savedSongs = songs.map((s) => _mapToSavedSong(s, lang)).toList();

      final playlist = Playlist(
        id: id,
        name: name,
        songs: savedSongs,
        createdAt: DateTime.now(),
        creator: 'local',
      );

      final radio = Provider.of<RadioProvider>(context, listen: false);
      await _playlistService.addPlaylist(playlist);
      radio.enrichPlaylistMetadata(id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lang.translate('added_to_playlists').replaceAll('{0}', name),
            ),
          ),
        );
      }
    }
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  void _toggleGroupSelection(List<String> paths) {
    setState(() {
      final allSelected = paths.every((p) => _selectedPaths.contains(p));
      if (allSelected) {
        _selectedPaths.removeAll(paths);
      } else {
        _selectedPaths.addAll(paths);
      }
    });
  }

  void _selectAll(List<String> visiblePaths) {
    setState(() {
      _selectedPaths.addAll(visiblePaths);
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedPaths.clear();
    });
  }

  Future<void> _showMergePlaylistDialog(
    LanguageProvider lang,
    RadioProvider radio,
  ) async {
    if (_selectedPaths.isEmpty) return;

    // Collect all songs from selected folders
    final List<SavedSong> combinedSongs = [];
    final Set<String> seenIds = {};

    for (var path in _selectedPaths) {
      final songs = _folders[path] ?? [];
      for (var s in songs) {
        final savedSong = _mapToSavedSong(s, lang);
        if (seenIds.add(savedSong.id)) {
          combinedSongs.add(savedSong);
        }
      }
    }

    if (combinedSongs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(lang.translate('no_songs_found')),
        ),
      );
      return;
    }

    // Propose a default playlist name based on selected folder names
    final folderNames = _selectedPaths
        .map((p) => p.split(Platform.pathSeparator).last)
        .toList();
    String defaultName = folderNames.length == 1
        ? folderNames.first
        : (folderNames.length <= 2
            ? folderNames.join(' + ')
            : '${folderNames.first} & +${folderNames.length - 1}');

    final nameController = TextEditingController(text: defaultName);

    final String? playlistName = await showDialog<String>(
      context: context,
      builder: (dlgCtx) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(
                Icons.merge_type,
                color: Theme.of(context).primaryColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  lang.translate('create_merged_playlist'),
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                lang.translate('selected_folders_count')
                    .replaceAll('{0}', '${_selectedPaths.length}')
                    .replaceAll('{1}', '${combinedSongs.length}'),
                style: TextStyle(
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: lang.translate('enter_playlist_name'),
                  hintText: lang.translate('playlist_name_hint'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  prefixIcon: const Icon(Icons.playlist_play),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dlgCtx).pop(null),
              child: Text(lang.translate('cancel')),
            ),
            ElevatedButton.icon(
              onPressed: () {
                final trimmed = nameController.text.trim();
                if (trimmed.isNotEmpty) {
                  Navigator.of(dlgCtx).pop(trimmed);
                }
              },
              icon: const Icon(Icons.check, size: 18),
              label: Text(lang.translate('save')),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (playlistName != null && playlistName.trim().isNotEmpty) {
      final newId = 'local_merged_${DateTime.now().millisecondsSinceEpoch}';
      final newPlaylist = Playlist(
        id: newId,
        name: playlistName.trim(),
        songs: combinedSongs,
        createdAt: DateTime.now(),
      );

      await _playlistService.addPlaylist(newPlaylist);
      radio.enrichPlaylistMetadata(newId);

      _deselectAll();

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final primaryColor = Theme.of(context).primaryColor;

      messenger.showSnackBar(
        SnackBar(
          backgroundColor: primaryColor,
          content: Text(
            lang.translate('merged_playlist_created')
                .replaceAll('{0}', newPlaylist.name)
                .replaceAll('{1}', '${combinedSongs.length}'),
            style: const TextStyle(color: Colors.white),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Widget _buildGroupHeader({
    required BuildContext context,
    required String title,
    required IconData icon,
    required List<String> paths,
    required bool isMusicStream,
  }) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    final allSelected = paths.isNotEmpty && paths.every((p) => _selectedPaths.contains(p));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: isMusicStream
                  ? Theme.of(context).primaryColor.withValues(alpha: 0.15)
                  : Theme.of(context).canvasColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size: 18,
              color: isMusicStream
                  ? Theme.of(context).primaryColor
                  : Theme.of(context).iconTheme.color?.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isMusicStream
                              ? Theme.of(context).primaryColor
                              : null,
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isMusicStream
                        ? Theme.of(context).primaryColor.withValues(alpha: 0.12)
                        : Theme.of(context).dividerColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${paths.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isMusicStream
                          ? Theme.of(context).primaryColor
                          : Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _toggleGroupSelection(paths),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                allSelected ? lang.translate('deselect_all') : lang.translate('select_all'),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).primaryColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderCard({
    required BuildContext context,
    required String path,
    required List<SongModel> songs,
    required LanguageProvider lang,
    required RadioProvider radio,
    required bool isMusicStream,
  }) {
    final id = _generatePlaylistId(path);
    final existingP = radio.playlists.where((p) => p.id == id).toList();
    final isAddedAsSingle = existingP.isNotEmpty;
    final folderName = isAddedAsSingle ? existingP.first.name : path.split(Platform.pathSeparator).last;
    final isSelected = _selectedPaths.contains(path);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      color: isSelected
          ? Theme.of(context).primaryColor.withValues(alpha: 0.12)
          : (isMusicStream
              ? Theme.of(context).primaryColor.withValues(alpha: 0.05)
              : Theme.of(context).cardColor.withValues(alpha: 0.2)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected
              ? Theme.of(context).primaryColor
              : (isMusicStream
                  ? Theme.of(context).primaryColor.withValues(alpha: 0.3)
                  : (isAddedAsSingle
                      ? Theme.of(context).primaryColor.withValues(alpha: 0.2)
                      : Colors.transparent)),
          width: isSelected ? 1.5 : (isMusicStream ? 1.2 : 1),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _toggleSelection(path),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Checkbox for Multi-select
              Checkbox(
                value: isSelected,
                activeColor: Theme.of(context).primaryColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                onChanged: (_) => _toggleSelection(path),
              ),
              const SizedBox(width: 4),

              // Folder Icon with MusicStream highlight badge
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Theme.of(context).primaryColor.withValues(alpha: 0.2)
                          : (isMusicStream
                              ? Theme.of(context).primaryColor.withValues(alpha: 0.15)
                              : Theme.of(context).canvasColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      isMusicStream ? Icons.folder_special : Icons.folder,
                      color: isMusicStream || isSelected
                          ? Theme.of(context).primaryColor
                          : Theme.of(context).iconTheme.color,
                    ),
                  ),
                  if (isMusicStream)
                    Positioned(
                      top: -4,
                      right: -4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.music_note,
                          size: 10,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),

              // Name, Badge, songs count, path
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            folderName,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: isMusicStream
                                      ? Theme.of(context).primaryColor
                                      : null,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isMusicStream) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: Theme.of(context).primaryColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              lang.translate('musicstream_badge'),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      lang.translate('songs_count').replaceAll('{0}', '${songs.length}'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.54),
                          ),
                    ),
                    Text(
                      path,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.38),
                            fontSize: 10,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // Single-folder toggle button (Quick add/remove individual playlist)
              IconButton(
                tooltip: isAddedAsSingle ? lang.translate('remove') : lang.translate('add'),
                onPressed: () => _toggleFolder(
                  path,
                  folderName,
                  songs,
                  isAddedAsSingle,
                ),
                icon: Icon(
                  isAddedAsSingle ? Icons.check_circle : Icons.add_circle_outline,
                  color: isAddedAsSingle
                      ? Theme.of(context).primaryColor
                      : Theme.of(context).iconTheme.color?.withValues(alpha: 0.54),
                  size: 26,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final radio = Provider.of<RadioProvider>(context);
    final lang = Provider.of<LanguageProvider>(context);

    // Sort folders by name
    final sortedKeys = _folders.keys.toList()
      ..sort((a, b) {
        // Put MusicStream folders first, then alphabetical
        final isMusicStreamA = _isMusicStreamFolder(a);
        final isMusicStreamB = _isMusicStreamFolder(b);
        if (isMusicStreamA && !isMusicStreamB) return -1;
        if (!isMusicStreamA && isMusicStreamB) return 1;

        final nameA = a.split(Platform.pathSeparator).last.toLowerCase();
        final nameB = b.split(Platform.pathSeparator).last.toLowerCase();
        int cmp = nameA.compareTo(nameB);
        if (cmp != 0) return cmp;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    // Filter by search query (folder name, path, or song title/artist)
    final filteredKeys = sortedKeys.where((path) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      final folderName = path.split(Platform.pathSeparator).last.toLowerCase();
      if (folderName.contains(q) || path.toLowerCase().contains(q)) {
        return true;
      }
      final songs = _folders[path] ?? [];
      for (var s in songs) {
        if (s.title.toLowerCase().contains(q) ||
            (s.artist != null && s.artist!.toLowerCase().contains(q))) {
          return true;
        }
      }
      return false;
    }).toList();

    final musicStreamKeys = filteredKeys.where(_isMusicStreamFolder).toList();
    final otherKeys = filteredKeys.where((k) => !_isMusicStreamFolder(k)).toList();

    // Total songs in current selection
    int totalSelectedSongs = 0;
    for (var path in _selectedPaths) {
      totalSelectedSongs += (_folders[path]?.length ?? 0);
    }

    final bool allVisibleSelected = filteredKeys.isNotEmpty &&
        filteredKeys.every((path) => _selectedPaths.contains(path));

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(lang.translate('local_library')),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        elevation: 0,
        actions: [
          if (_selectedPaths.isNotEmpty)
            IconButton(
              tooltip: lang.translate('deselect_all'),
              icon: const Icon(Icons.deselect),
              onPressed: _deselectAll,
            ),
          IconButton(
            tooltip: lang.translate('sync_local_library'),
            icon: const Icon(Icons.refresh),
            onPressed: _loadFolders,
          ),
        ],
      ),
      bottomNavigationBar: _selectedPaths.isNotEmpty
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, -2),
                    ),
                  ],
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_selectedPaths.length} ${lang.translate('folders_selected')}',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            lang.translate('songs_count').replaceAll('{0}', '$totalSelectedSongs'),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color
                                      ?.withValues(alpha: 0.6),
                                ),
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _showMergePlaylistDialog(lang, radio),
                      icon: const Icon(Icons.playlist_add, size: 20),
                      label: Text(lang.translate('merge_into_playlist')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: Column(
        children: [
          // Search & Filter Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val.trim();
                    });
                  },
                  decoration: InputDecoration(
                    hintText: lang.translate('search_folders_hint'),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchQuery = '';
                              });
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    filled: true,
                    fillColor: Theme.of(context).cardColor.withValues(alpha: 0.3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${filteredKeys.length} / ${sortedKeys.length} ${lang.translate('folders')}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.color
                            ?.withValues(alpha: 0.6),
                      ),
                    ),
                    if (filteredKeys.isNotEmpty)
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () {
                          if (allVisibleSelected) {
                            _deselectAll();
                          } else {
                            _selectAll(filteredKeys);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Text(
                            allVisibleSelected
                                ? lang.translate('deselect_all')
                                : lang.translate('select_all'),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Folder List View with Grouping
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadFolders,
              color: Theme.of(context).primaryColor,
              child: _isLoading && _folders.isEmpty
                  ? ListView(
                      children: [
                        Container(
                          height: MediaQuery.of(context).size.height * 0.6,
                          alignment: Alignment.center,
                          child: const CircularProgressIndicator(),
                        ),
                      ],
                    )
                  : filteredKeys.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            Container(
                              height: MediaQuery.of(context).size.height * 0.6,
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.folder_off,
                                    size: 64,
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.color
                                        ?.withValues(alpha: 0.24),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchQuery.isNotEmpty
                                        ? lang.translate('no_results')
                                        : lang.translate('no_music_folders'),
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.color
                                          ?.withValues(alpha: 0.54),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    lang.translate('swipe_down_scan'),
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color
                                          ?.withValues(alpha: 0.24),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(
                            0,
                            8,
                            0,
                            _selectedPaths.isNotEmpty ? 100 : 80,
                          ),
                          children: [
                            // 1. Group: MusicStream Folders
                            if (musicStreamKeys.isNotEmpty) ...[
                              _buildGroupHeader(
                                context: context,
                                title: lang.translate('musicstream_folders'),
                                icon: Icons.folder_special,
                                paths: musicStreamKeys,
                                isMusicStream: true,
                              ),
                              ...musicStreamKeys.map(
                                (path) => _buildFolderCard(
                                  context: context,
                                  path: path,
                                  songs: _folders[path]!,
                                  lang: lang,
                                  radio: radio,
                                  isMusicStream: true,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],

                            // 2. Group: Other Device Folders
                            if (otherKeys.isNotEmpty) ...[
                              _buildGroupHeader(
                                context: context,
                                title: lang.translate('other_device_folders'),
                                icon: Icons.folder,
                                paths: otherKeys,
                                isMusicStream: false,
                              ),
                              ...otherKeys.map(
                                (path) => _buildFolderCard(
                                  context: context,
                                  path: path,
                                  songs: _folders[path]!,
                                  lang: lang,
                                  radio: radio,
                                  isMusicStream: false,
                                ),
                              ),
                            ],
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }
}
