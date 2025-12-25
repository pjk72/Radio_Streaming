import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/radio_provider.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import 'album_details_screen.dart';
import '../widgets/youtube_popup.dart';
import '../utils/genre_mapper.dart';
import '../services/music_metadata_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

enum MetadataViewMode { playlists, artists, albums }

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  String? _selectedPlaylistId;
  String? _selectedArtist;
  String? _selectedArtistDisplay;
  bool _selectedArtistIsGroup = false;
  String? _selectedAlbum;
  String? _selectedAlbumDisplay;
  bool _selectedAlbumIsGroup = false;
  MetadataViewMode _viewMode = MetadataViewMode.playlists;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _unlockTimer?.cancel();
    super.dispose();
  }

  Timer? _unlockTimer;

  void _startUnlockTimer(
    RadioProvider provider,
    SavedSong song,
    String playlistId,
  ) {
    _unlockTimer?.cancel();
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Keep holding to unlock..."),
        duration: Duration(milliseconds: 2000),
      ),
    );

    _unlockTimer = Timer(const Duration(seconds: 3), () async {
      await provider.unmarkSongAsInvalid(song.id, playlistId: playlistId);
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Song unlocked!")));
        HapticFeedback.heavyImpact();
      }
    });
  }

  void _cancelUnlockTimer() {
    if (_unlockTimer != null && _unlockTimer!.isActive) {
      _unlockTimer!.cancel();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    _unlockTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final allPlaylists = provider.playlists;

    // Sort: Favorites first, then Alphabetical
    final List<Playlist> sortedPlaylists = List.from(allPlaylists);
    sortedPlaylists.sort((a, b) {
      if (a.id == 'favorites') return -1;
      if (b.id == 'favorites') return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    // Collect all unique songs
    final Set<String> uniqueIds = {};
    final List<SavedSong> allSongs = [];
    for (var p in allPlaylists) {
      for (var s in p.songs) {
        if (uniqueIds.add(s.id)) {
          allSongs.add(s);
        }
      }
    }

    // 1. Determine Selection State
    final bool isSelectionActive =
        _selectedPlaylistId != null ||
        _selectedArtist != null ||
        _selectedAlbum != null;

    // 2. Determine Title & Song List (if selection active)
    String headerTitle = "Library";
    List<SavedSong> currentSongList = [];

    // Helper for dummy playlist creation
    Playlist createDummyPlaylist(String name, List<SavedSong> songs) {
      return Playlist(
        id: 'temp_view',
        name: name,
        songs: songs,
        createdAt: DateTime.now(),
      );
    }

    Playlist? effectivePlaylist;

    if (_selectedPlaylistId != null) {
      final p = allPlaylists.firstWhere(
        (p) => p.id == _selectedPlaylistId,
        orElse: () => allPlaylists.first,
      );
      headerTitle = p.name;
      currentSongList = p.songs;
      effectivePlaylist = p;
    } else if (_selectedArtist != null) {
      headerTitle = _selectedArtistDisplay ?? _selectedArtist!;

      if (_selectedArtistIsGroup) {
        currentSongList = allSongs.where((s) {
          final norm = s.artist
              .split('•')
              .first
              .trim()
              .split(RegExp(r'[,&/]'))
              .first
              .trim()
              .toLowerCase();
          return norm == _selectedArtist;
        }).toList();
      } else {
        currentSongList = allSongs
            .where((s) => s.artist == _selectedArtist)
            .toList();
      }
      effectivePlaylist = createDummyPlaylist(headerTitle, currentSongList);
    } else if (_selectedAlbum != null) {
      headerTitle = _selectedAlbumDisplay ?? _selectedAlbum!;

      if (_selectedAlbumIsGroup) {
        currentSongList = allSongs.where((s) {
          final norm = s.album
              .split('(')
              .first
              .trim()
              .split('[')
              .first
              .trim()
              .toLowerCase();
          return norm == _selectedAlbum;
        }).toList();
      } else {
        currentSongList = allSongs
            .where((s) => s.album == _selectedAlbum)
            .toList();
      }
      effectivePlaylist = createDummyPlaylist(headerTitle, currentSongList);
    } else {
      switch (_viewMode) {
        case MetadataViewMode.playlists:
          headerTitle = "Genres";
          break;
        case MetadataViewMode.artists:
          headerTitle = "Artists";
          break;
        case MetadataViewMode.albums:
          headerTitle = "Albums";
          break;
      }
    }

    // 3. Filter Song List by Search (if selection active)
    if (isSelectionActive && _searchQuery.isNotEmpty) {
      currentSongList = currentSongList.where((s) {
        return s.title.toLowerCase().contains(_searchQuery) ||
            s.artist.toLowerCase().contains(_searchQuery);
      }).toList();
    }

    // 4. Filter Playlists by Search (only if view mode is playlists and no selection)
    final displayPlaylists = !isSelectionActive && _searchQuery.isNotEmpty
        ? sortedPlaylists
              .where((p) => p.name.toLowerCase().contains(_searchQuery))
              .toList()
        : sortedPlaylists;

    // Helper for Mode Button
    Widget buildModeBtn(String title, MetadataViewMode mode) {
      final bool selected = _viewMode == mode;
      return GestureDetector(
        onTap: () {
          setState(() {
            _viewMode = mode;
            _searchController.clear();
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).primaryColor
                : Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? Colors.transparent : Colors.white24,
            ),
          ),
          child: Text(
            title,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              // Custom Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                color: Colors.white.withValues(alpha: 0.05),
                child: Column(
                  children: [
                    Row(
                      children: [
                        if (isSelectionActive)
                          IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new_rounded),
                            color: Colors.white,
                            onPressed: () {
                              setState(() {
                                _selectedPlaylistId = null;
                                _selectedArtist = null;
                                _selectedAlbum = null;
                                _searchController.clear();
                              });
                            },
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Icon(
                              _viewMode == MetadataViewMode.artists
                                  ? Icons.people
                                  : _viewMode == MetadataViewMode.albums
                                  ? Icons.album
                                  : Icons.category,
                              color: Colors.white,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            headerTitle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isSelectionActive) ...[
                          IconButton(
                            icon: Icon(
                              Icons.shuffle_rounded,
                              color: provider.isShuffleMode
                                  ? Colors.redAccent
                                  : Colors.white,
                            ),
                            tooltip: "Shuffle",
                            onPressed: () => provider.toggleShuffle(),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.play_circle_fill,
                              size: 32,
                              color: Colors.white,
                            ),
                            tooltip: "Play All",
                            onPressed: () {
                              if (_selectedPlaylistId != null) {
                                _playPlaylist(provider, effectivePlaylist!);
                              } else {
                                _playSongs(
                                  provider,
                                  currentSongList,
                                  headerTitle,
                                );
                              }
                            },
                          ),
                          const SizedBox(width: 8),
                        ] else ...[
                          IconButton(
                            icon: const Icon(
                              Icons.library_music_rounded,
                              size: 28,
                            ),
                            color: Colors.white,
                            tooltip: "Search & Add Song",
                            onPressed: () =>
                                _showAddSongDialog(context, provider),
                          ),
                          const SizedBox(width: 8),
                          if (_viewMode == MetadataViewMode.playlists)
                            IconButton(
                              icon: const Icon(Icons.add_rounded, size: 28),
                              color: Colors.white,
                              tooltip: "Create Playlist",
                              onPressed: () =>
                                  _showCreatePlaylistDialog(context, provider),
                            ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                    if (!isSelectionActive)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: Row(
                          children: [
                            buildModeBtn("Genres", MetadataViewMode.playlists),
                            const SizedBox(width: 8),
                            buildModeBtn("Artists", MetadataViewMode.artists),
                            const SizedBox(width: 8),
                            buildModeBtn("Albums", MetadataViewMode.albums),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    // Search Bar
                    Container(
                      width: double.infinity,
                      height: 36,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          hintText: "Search...",
                          hintStyle: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                          isDense: true,
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.white38,
                            size: 16,
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white38,
                                    size: 16,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              // Body Content
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (isSelectionActive) {
                      return RefreshIndicator(
                        onRefresh: () async {
                          if (_selectedPlaylistId != null) {
                            await provider.reloadPlaylists();
                          }
                        },
                        child: _buildSongList(
                          context,
                          provider,
                          effectivePlaylist!,
                          currentSongList,
                        ),
                      );
                    }

                    // Global Search OR Main View
                    if (!isSelectionActive && _searchQuery.isNotEmpty) {
                      if (_viewMode == MetadataViewMode.playlists) {
                        return _buildGlobalSearchResults(
                          context,
                          provider,
                          allPlaylists,
                        );
                      } else {
                        // Filter Logic for Artists/Albums Grid Search
                        if (_viewMode == MetadataViewMode.artists) {
                          final filteredArtists = allSongs
                              .where(
                                (s) => s.artist.toLowerCase().contains(
                                  _searchQuery,
                                ),
                              )
                              .toList();
                          return _buildArtistsGrid(
                            context,
                            provider,
                            filteredArtists,
                          );
                        } else {
                          final filteredAlbums = allSongs
                              .where(
                                (s) => s.album.toLowerCase().contains(
                                  _searchQuery,
                                ),
                              )
                              .toList();
                          return _buildAlbumsGrid(
                            context,
                            provider,
                            filteredAlbums,
                          );
                        }
                      }
                    }

                    switch (_viewMode) {
                      case MetadataViewMode.playlists:
                        return ListView(
                          key: const PageStorageKey('playlists_list'),
                          padding: const EdgeInsets.only(bottom: 80),
                          children: [
                            _buildPlaylistsGrid(
                              context,
                              provider,
                              displayPlaylists,
                            ),
                          ],
                        );
                      case MetadataViewMode.artists:
                        return _buildArtistsGrid(context, provider, allSongs);
                      case MetadataViewMode.albums:
                        return _buildAlbumsGrid(context, provider, allSongs);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _playPlaylist(RadioProvider provider, Playlist playlist) {
    if (playlist.songs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Playlist is empty")));
      return;
    }

    SavedSong startSong;
    if (provider.isShuffleMode) {
      final random = Random();
      startSong = playlist.songs[random.nextInt(playlist.songs.length)];
    } else {
      startSong = playlist.songs.first;
    }

    provider.playPlaylistSong(startSong, playlist.id);
  }

  Widget _buildPlaylistsGrid(
    BuildContext context,
    RadioProvider provider,
    List<Playlist> playlists,
  ) {
    if (playlists.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isEmpty
              ? "No playlists"
              : "No playlists match your search",
          style: const TextStyle(color: Colors.white54),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 1.0,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        // Determine image
        String? bgImage;
        // Favorites gets special treatment or standard 'Pop' etc?
        // Let's treat favorites specially or check name.
        if (playlist.id == 'favorites') {
          // Maybe a dedicated 'Favorites' image or just mapped
          bgImage = GenreMapper.getGenreImage("Favorites");
          // If genre mapper doesn't handle favorites specifically, it falls back to AI which is good.
          // Or we can force a specific one if we want.
        } else {
          bgImage = GenreMapper.getGenreImage(playlist.name);
        }

        // Check if this playlist is currently playing
        bool isPlaylistPlaying =
            provider.currentPlayingPlaylistId == playlist.id;

        // Fallback: Check if any song in the playlist matches the current track
        if (!isPlaylistPlaying && playlist.songs.isNotEmpty) {
          isPlaylistPlaying = playlist.songs.any(
            (s) =>
                provider.audioOnlySongId == s.id ||
                (s.title.trim().toLowerCase() ==
                        provider.currentTrack.trim().toLowerCase() &&
                    s.artist.trim().toLowerCase() ==
                        provider.currentArtist.trim().toLowerCase()),
          );
        }

        return InkWell(
          onTap: () {
            setState(() {
              _selectedPlaylistId = playlist.id;
              _searchController.clear();
            });
          },
          onLongPress: () =>
              _showDeletePlaylistDialog(context, provider, playlist),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: isPlaylistPlaying
                  ? Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.8),
                      width: 2,
                    )
                  : Border.all(color: Colors.white12),
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: bgImage == null
                  ? Colors.white.withValues(alpha: 0.1)
                  : null, // Fallback color
              boxShadow: isPlaylistPlaying
                  ? [
                      BoxShadow(
                        color: Colors.redAccent.withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: 2,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                if (bgImage != null)
                  Positioned.fill(
                    child: bgImage.startsWith('http')
                        ? CachedNetworkImage(
                            imageUrl: bgImage,
                            fit: BoxFit.cover,
                            color: Colors.black.withValues(alpha: 0.6),
                            colorBlendMode: BlendMode.darken,
                            errorWidget: (context, url, error) {
                              return Container(
                                color: Colors.white.withValues(alpha: 0.1),
                              );
                            },
                          )
                        : Image.asset(
                            bgImage,
                            fit: BoxFit.cover,
                            color: Colors.black.withValues(alpha: 0.6),
                            colorBlendMode: BlendMode.darken,
                          ),
                  ),
                Positioned(
                  right: -10,
                  bottom: -10,
                  child: Icon(
                    playlist.id == 'favorites'
                        ? Icons.favorite
                        : Icons.music_note,
                    size: 80,
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (playlist.id == 'favorites')
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8.0),
                          child: Icon(
                            Icons.favorite,
                            color: Colors.pinkAccent,
                            size: 24,
                          ),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8.0),
                          child: Icon(
                            Icons.music_note,
                            color: Colors.white70,
                            size: 24,
                          ),
                        ),
                      Text(
                        playlist.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          letterSpacing: 1.0,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "${playlist.songs.length} songs",
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSongList(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
    List<SavedSong> songs,
  ) {
    if (songs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_off_rounded, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text("No songs found", style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    // Grouping Logic
    final List<List<SavedSong>> groupedSongs = [];
    final Set<String> seenAlbums = {};

    for (var song in songs) {
      // Create a unique key for the album
      final key =
          "${song.album.trim().toLowerCase()}|${song.artist.trim().toLowerCase()}";

      if (seenAlbums.contains(key)) continue;

      // Find all songs belonging to this album
      final albumSongs = songs.where((s) {
        final k =
            "${s.album.trim().toLowerCase()}|${s.artist.trim().toLowerCase()}";
        return k == key;
      }).toList();

      groupedSongs.add(albumSongs);
      seenAlbums.add(key);
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: groupedSongs.length,
      itemBuilder: (context, index) {
        final group = groupedSongs[index];

        // If only one song, render strictly as before (Standalone)
        if (group.length == 1) {
          return _buildSongItem(context, provider, playlist, group.first);
        }

        // If multiple songs, render a Group Card
        return _buildAlbumGroup(context, provider, playlist, group);
      },
    );
  }

  Widget _buildAlbumGroup(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
    List<SavedSong> groupSongs,
  ) {
    return _AlbumGroupWidget(
      groupSongs: groupSongs,
      dismissDirection: playlist.id == 'favorites'
          ? DismissDirection.endToStart
          : DismissDirection.horizontal,
      onMove: () async {
        final result = await _showMoveAlbumDialog(
          context,
          provider,
          playlist,
          groupSongs,
        );
        // If copied (Favorites), do not dismiss the widget visually
        if (playlist.id == 'favorites') return false;
        return result;
      },
      onRemove: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF222222),
            title: const Text(
              "Delete Album",
              style: TextStyle(color: Colors.white),
            ),
            content: Text(
              "Remove '${groupSongs.first.album}' from this playlist?",
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  "Cancel",
                  style: TextStyle(color: Colors.white),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  "Delete",
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        );

        if (confirmed == true) {
          final songIds = groupSongs.map((s) => s.id).toList();
          if (playlist.id == 'temp_view') {
            await provider.removeSongsFromLibrary(songIds);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    "Removed '${groupSongs.first.album}' from library",
                  ),
                ),
              );
            }
          } else {
            await provider.removeSongsFromPlaylist(playlist.id, songIds);

            if (!provider.playlists.any((p) => p.id == playlist.id)) {
              setState(() {
                _selectedPlaylistId = null;
              });
            }

            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text("Removed '${groupSongs.first.album}'"),
                  action: SnackBarAction(
                    label: "Undo",
                    onPressed: () {
                      provider.restoreSongsToPlaylist(
                        playlist.id,
                        groupSongs,
                        playlistName: playlist.name,
                      );
                    },
                  ),
                ),
              );
            }
          }
          return true;
        }
        return false;
      },
      songBuilder: (ctx, song, index) {
        // Ensure we use the latest provider state for invalid check
        final freshProvider = Provider.of<RadioProvider>(ctx);
        return _buildSongItem(
          ctx,
          freshProvider,
          playlist,
          song,
          isGrouped: true,
          groupIndex: index,
        );
      },
    );
  }

  Widget _buildSongItem(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
    SavedSong song, {
    bool isGrouped = false,
    int? groupIndex,
  }) {
    final isInvalid =
        !song.isValid || provider.invalidSongIds.contains(song.id);

    return Dismissible(
      key: Key(song.id),
      direction: playlist.id == 'favorites'
          ? DismissDirection.endToStart
          : DismissDirection.horizontal,
      background: Container(
        alignment: Alignment.centerLeft,
        color: Colors.green,
        padding: const EdgeInsets.only(left: 24),
        child: const Icon(Icons.drive_file_move_outline, color: Colors.white),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        color: Colors.red,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _showMoveSongDialog(context, provider, playlist, song.id);
          return false;
        } else {
          return true;
        }
      },
      onDismissed: (direction) {
        if (direction == DismissDirection.endToStart) {
          final deletedSong = song;

          if (playlist.id == 'temp_view') {
            provider.removeSongFromLibrary(song.id);
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("Song removed from library"),
                duration: Duration(seconds: 2),
              ),
            );
          } else {
            provider.removeFromPlaylist(playlist.id, song.id);
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text("Song removed from playlist"),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () {
                    provider.restoreSongToPlaylist(playlist.id, deletedSong);
                  },
                ),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
      },
      child: Container(
        margin: isGrouped ? EdgeInsets.zero : const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: isInvalid
              ? Colors.white.withValues(alpha: 0.02)
              : (provider.audioOnlySongId == song.id ||
                    (song.title.trim().toLowerCase() ==
                            provider.currentTrack.trim().toLowerCase() &&
                        song.artist.trim().toLowerCase() ==
                            provider.currentArtist.trim().toLowerCase()))
              ? Colors.redAccent.withValues(alpha: 0.25) // Stronger alpha
              : isGrouped
              ? Colors.transparent
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: isGrouped
              ? BorderRadius.zero
              : BorderRadius.circular(16),
          border:
              (provider.audioOnlySongId == song.id ||
                  (song.title.trim().toLowerCase() ==
                          provider.currentTrack.trim().toLowerCase() &&
                      song.artist.trim().toLowerCase() ==
                          provider.currentArtist.trim().toLowerCase()))
              ? Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.8),
                  width: 1.5,
                )
              : null,
        ),
        child: GestureDetector(
          onTapDown: isInvalid
              ? (_) => _startUnlockTimer(provider, song, playlist.id)
              : null,
          onTapUp: isInvalid ? (_) => _cancelUnlockTimer() : null,
          onTapCancel: isInvalid ? _cancelUnlockTimer : null,
          child: ListTile(
            onTap: isInvalid
                ? null
                : () => _handleSongAudioAction(
                    provider,
                    song,
                    playlist.id,
                    adHocPlaylist: playlist,
                  ),
            // onLongPress removed, handled by GestureDetector's 3s timer via onTapDown
            visualDensity: isGrouped
                ? const VisualDensity(horizontal: 0, vertical: -4)
                : VisualDensity.compact,
            contentPadding: isGrouped
                ? const EdgeInsets.symmetric(horizontal: 16, vertical: 0)
                : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            leading: isGrouped
                ? Container(
                    width: 32,
                    alignment: Alignment.center,
                    child: Text(
                      "${groupIndex ?? ''}",
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                : MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        var albumName = song.album.trim();
                        // Clean song title: remove content in parentheses/brackets for better search
                        var songTitle = song.title
                            .replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '')
                            .trim();

                        // Filter artist name: keep only text before '•'
                        var cleanArtist = song.artist.split('•').first.trim();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => AlbumDetailsScreen(
                              albumName: albumName,
                              artistName: cleanArtist,
                              songName: songTitle,
                            ),
                          ),
                        );
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: song.artUri != null
                            ? CachedNetworkImage(
                                imageUrl: song.artUri!,
                                width: 48,
                                height: 48,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => Container(
                                  width: 48,
                                  height: 48,
                                  color: Colors.grey[900],
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white24,
                                  ),
                                ),
                              )
                            : Container(
                                width: 48,
                                height: 48,
                                color: Colors.grey[900],
                                child: const Icon(
                                  Icons.music_note,
                                  color: Colors.white24,
                                ),
                              ),
                      ),
                    ),
                  ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    song.title,
                    style: TextStyle(
                      color:
                          (provider.audioOnlySongId == song.id ||
                              (provider.currentTrack.isNotEmpty &&
                                  song.title.trim().toLowerCase() ==
                                      provider.currentTrack
                                          .trim()
                                          .toLowerCase() &&
                                  song.artist.trim().toLowerCase() ==
                                      provider.currentArtist
                                          .trim()
                                          .toLowerCase()))
                          ? Colors.redAccent
                          : (isInvalid ? Colors.white54 : Colors.white),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isGrouped)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 8),

                      _InvalidSongIndicator(
                        songId: song.id,
                        isStaticInvalid: !song.isValid,
                      ),
                      if (!isInvalid) ...[
                        GestureDetector(
                          onTap: () async {
                            showDialog(
                              context: context,
                              barrierDismissible: false,
                              builder: (ctx) => const Center(
                                child: CircularProgressIndicator(
                                  color: Colors.redAccent,
                                ),
                              ),
                            );

                            try {
                              final links = await provider
                                  .resolveLinks(
                                    title: song.title,
                                    artist: song.artist,
                                    spotifyUrl: song.spotifyUrl,
                                    youtubeUrl: song.youtubeUrl,
                                  )
                                  .timeout(
                                    const Duration(seconds: 10),
                                    onTimeout: () {
                                      throw TimeoutException(
                                        "Connection timed out",
                                      );
                                    },
                                  );

                              if (!mounted) return;
                              Navigator.of(context, rootNavigator: true).pop();

                              final url = links['youtube'] ?? song.youtubeUrl;
                              if (url != null) {
                                final videoId = YoutubePlayer.convertUrlToId(
                                  url,
                                );
                                if (videoId != null) {
                                  provider.pause();
                                  if (!mounted) return;
                                  showDialog(
                                    context: context,
                                    builder: (_) =>
                                        YouTubePopup(videoId: videoId),
                                  );
                                } else {
                                  launchUrl(
                                    Uri.parse(url),
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text("YouTube link not found"),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (mounted) {
                                Navigator.of(
                                  context,
                                  rootNavigator: true,
                                ).pop();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text("Error: $e")),
                                );
                              }
                            }
                          },
                          child: const FaIcon(
                            FontAwesomeIcons.youtube,
                            color: Color(0xFFFF0000),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 20),
                        GestureDetector(
                          onTap: () => _handleSongAudioAction(
                            provider,
                            song,
                            playlist.id,
                            adHocPlaylist: playlist,
                          ),
                          child:
                              (provider.audioOnlySongId == song.id &&
                                  provider.isLoading)
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    color: Colors.redAccent,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  (provider.audioOnlySongId == song.id &&
                                          provider.isPlaying)
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 28,
                                ),
                        ),
                      ],
                    ], // close else...[ and children
                  ),
                if (!isGrouped &&
                    song.releaseDate != null &&
                    song.releaseDate!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Text(
                      song.releaseDate!.split('-').first,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontWeight: FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!isGrouped)
                              Text(
                                song.artist,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      if (!isGrouped)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _InvalidSongIndicator(
                              songId: song.id,
                              isStaticInvalid: !song.isValid,
                            ),
                            if (!isInvalid) ...[
                              GestureDetector(
                                onTap: () async {
                                  showDialog(
                                    context: context,
                                    barrierDismissible: false,
                                    builder: (ctx) => const Center(
                                      child: CircularProgressIndicator(
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  );

                                  try {
                                    final links = await provider
                                        .resolveLinks(
                                          title: song.title,
                                          artist: song.artist,
                                          spotifyUrl: song.spotifyUrl,
                                          youtubeUrl: song.youtubeUrl,
                                        )
                                        .timeout(
                                          const Duration(seconds: 10),
                                          onTimeout: () {
                                            throw TimeoutException(
                                              "Connection timed out",
                                            );
                                          },
                                        );

                                    if (!mounted) return;
                                    Navigator.of(
                                      context,
                                      rootNavigator: true,
                                    ).pop();

                                    final url =
                                        links['youtube'] ?? song.youtubeUrl;
                                    if (url != null) {
                                      final videoId =
                                          YoutubePlayer.convertUrlToId(url);
                                      if (videoId != null) {
                                        provider.pause();
                                        if (!mounted) return;
                                        showDialog(
                                          context: context,
                                          builder: (_) =>
                                              YouTubePopup(videoId: videoId),
                                        );
                                      } else {
                                        launchUrl(
                                          Uri.parse(url),
                                          mode: LaunchMode.externalApplication,
                                        );
                                      }
                                    } else {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            "YouTube link not found",
                                          ),
                                        ),
                                      );
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      Navigator.of(
                                        context,
                                        rootNavigator: true,
                                      ).pop();
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text("Error: $e")),
                                      );
                                    }
                                  }
                                },
                                child: const FaIcon(
                                  FontAwesomeIcons.youtube,
                                  color: Color(0xFFFF0000),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 20),
                              GestureDetector(
                                onTap: () => _handleSongAudioAction(
                                  provider,
                                  song,
                                  playlist.id,
                                  adHocPlaylist: playlist,
                                ),
                                child:
                                    (provider.audioOnlySongId == song.id &&
                                        provider.isLoading)
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          color: Colors.redAccent,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(
                                        (provider.audioOnlySongId == song.id &&
                                                provider.isPlaying)
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        color: Colors.white,
                                        size: 28,
                                      ),
                              ),
                            ],
                          ], // close else...[ and children
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ), // Close ListTile
        ), // Close GestureDetector
      ),
    );
  }

  Future<void> _handleSongAudioAction(
    RadioProvider provider,
    SavedSong song,
    String playlistId, {
    Playlist? adHocPlaylist,
  }) async {
    // If this song is currently playing audio, toggle play/pause
    if (provider.audioOnlySongId == song.id) {
      provider.togglePlay();
      return;
    }

    if (playlistId == 'temp_view' && adHocPlaylist != null) {
      await provider.playAdHocPlaylist(adHocPlaylist, song.id);
      return;
    }

    // Otherwise, use the provider's optimized playlist song player
    // This handles background resolution, optimistic UI, and auto-skip on error.
    provider.playPlaylistSong(song, playlistId);
  }

  void _showCreatePlaylistDialog(BuildContext context, RadioProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a2e),
        title: const Text(
          "New Playlist",
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "Playlist Name",
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
          ),
        ),
        actions: [
          TextButton(
            child: const Text("Cancel"),
            onPressed: () => Navigator.pop(ctx),
          ),
          TextButton(
            child: const Text("Create"),
            onPressed: () {
              if (controller.text.isNotEmpty) {
                provider.createPlaylist(controller.text);
                Navigator.pop(ctx);
              }
            },
          ),
        ],
      ),
    );
  }

  void _showDeletePlaylistDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
  ) {
    if (playlist.id == 'favorites') return; // Cannot delete favorites
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a2e),
        title: const Text(
          "Delete Playlist",
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          "Delete '${playlist.name}'? Songs inside will be lost.",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            child: const Text("Cancel"),
            onPressed: () => Navigator.pop(ctx),
          ),
          TextButton(
            child: const Text(
              "Delete",
              style: TextStyle(color: Colors.redAccent),
            ),
            onPressed: () {
              provider.deletePlaylist(playlist.id);
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  Future<bool> _showMoveSongDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist currentPlaylist,
    String songId,
  ) async {
    final others = provider.playlists
        .where((p) => p.id != currentPlaylist.id)
        .toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No other playlists to move to.")),
      );
      return false;
    }

    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF1a1a2e),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Move to...",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: others
                      .map(
                        (p) => ListTile(
                          leading: const Icon(
                            Icons.folder,
                            color: Colors.white38,
                          ),
                          title: Text(
                            p.name,
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () {
                            provider.moveSong(songId, currentPlaylist.id, p.id);
                            Navigator.pop(ctx, true);
                            if (context.mounted) {
                              final isCopy = p.id == 'favorites';
                              final text = isCopy
                                  ? "Copied to ${p.name}"
                                  : "Moved to ${p.name}";
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(text)));
                            }
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        );
      },
    );

    return result ?? false;
  }

  Future<bool> _showMoveAlbumDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist currentPlaylist,
    List<SavedSong> groupSongs,
  ) async {
    final others = provider.playlists
        .where((p) => p.id != currentPlaylist.id)
        .toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No other playlists to move to.")),
      );
      return false;
    }

    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF1a1a2e),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Move ${groupSongs.first.album} to...",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: others
                      .map(
                        (p) => ListTile(
                          leading: const Icon(
                            Icons.folder,
                            color: Colors.white38,
                          ),
                          title: Text(
                            p.name,
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () {
                            final songIds = groupSongs
                                .map((s) => s.id)
                                .toList();
                            provider.moveSongs(
                              songIds,
                              currentPlaylist.id,
                              p.id,
                            );
                            Navigator.pop(ctx, true);
                            if (context.mounted) {
                              final isCopy = p.id == 'favorites';
                              final text = isCopy
                                  ? "Copied album to ${p.name}"
                                  : "Moved album to ${p.name}";
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text(text)));
                            }
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        );
      },
    );

    return result ?? false;
  }

  void _showAddSongDialog(BuildContext context, RadioProvider provider) {
    final controller = TextEditingController();
    List<SongSearchResult> results = [];
    final Set<SongSearchResult> selectedItems = {};
    bool isLoading = false;
    bool hasSearched = false;
    Timer? searchDebounce;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1a1a2e),
            title: const Text(
              "Add Song",
              style: TextStyle(color: Colors.white),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "Search by Song Name, Artist, or Album",
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  TextField(
                    controller: controller,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: "Enter search term...",
                      hintStyle: const TextStyle(color: Colors.white38),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (controller.text.isNotEmpty)
                            IconButton(
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white70,
                                size: 20,
                              ),
                              onPressed: () {
                                controller.clear();
                                setState(() {
                                  // Update state to hide the X button
                                });
                              },
                            ),
                          IconButton(
                            icon: const Icon(
                              Icons.search,
                              color: Colors.white70,
                            ),
                            onPressed: () async {
                              if (controller.text.isEmpty) return;
                              setState(() {
                                isLoading = true;
                                hasSearched = true;
                                results = [];
                              });
                              final res = await provider.searchMusic(
                                controller.text,
                              );
                              setState(() {
                                isLoading = false;
                                results = res;
                              });
                            },
                          ),
                        ],
                      ),
                      enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white),
                      ),
                    ),
                    onChanged: (val) {
                      searchDebounce?.cancel();
                      if (val.length >= 3) {
                        searchDebounce = Timer(
                          const Duration(milliseconds: 500),
                          () async {
                            setState(() {
                              isLoading = true;
                              hasSearched = true;
                              results = [];
                            });
                            final res = await provider.searchMusic(val);
                            if (context.mounted) {
                              setState(() {
                                isLoading = false;
                                results = res;
                              });
                            }
                          },
                        );
                      }
                    },
                    onSubmitted: (val) async {
                      if (val.isEmpty) return;
                      setState(() {
                        isLoading = true;
                        hasSearched = true;
                        results = [];
                      });
                      final res = await provider.searchMusic(val);
                      setState(() {
                        isLoading = false;
                        results = res;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  if (isLoading)
                    const SizedBox(
                      height: 100,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (hasSearched && results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        "No results found.",
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  else if (results.isNotEmpty)
                    Flexible(
                      child: SizedBox(
                        height: 500,
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: results.length,
                          separatorBuilder: (_, __) =>
                              const Divider(color: Colors.white12),
                          itemBuilder: (context, index) {
                            final item = results[index];
                            final s = item.song;
                            final isSelected = selectedItems.contains(item);

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              selected: isSelected,
                              selectedTileColor: Colors.white.withValues(
                                alpha: 0.1,
                              ),
                              onTap: () {
                                setState(() {
                                  if (isSelected) {
                                    selectedItems.remove(item);
                                  } else {
                                    selectedItems.add(item);
                                  }
                                });
                              },
                              leading: GestureDetector(
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => AlbumDetailsScreen(
                                        albumName: s.album,
                                        artistName: s.artist,
                                        artworkUrl: s.artUri,
                                        appleMusicUrl: s.appleMusicUrl,
                                        songName: s.title,
                                      ),
                                    ),
                                  );
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: s.artUri != null
                                      ? CachedNetworkImage(
                                          imageUrl: s.artUri!,
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, _, _) => Container(
                                            width: 50,
                                            height: 50,
                                            color: Colors.white10,
                                            child: const Icon(
                                              Icons.music_note,
                                              color: Colors.white54,
                                            ),
                                          ),
                                        )
                                      : Container(
                                          width: 50,
                                          height: 50,
                                          color: Colors.white10,
                                          child: const Icon(
                                            Icons.music_note,
                                            color: Colors.white54,
                                          ),
                                        ),
                                ),
                              ),
                              title: Text(
                                s.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                "${s.artist} • ${item.genre}",
                                style: const TextStyle(color: Colors.white70),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Checkbox(
                                value: isSelected,
                                onChanged: (val) {
                                  setState(() {
                                    if (val == true) {
                                      selectedItems.add(item);
                                    } else {
                                      selectedItems.remove(item);
                                    }
                                  });
                                },
                                activeColor: Colors.greenAccent,
                                checkColor: Colors.black,
                                side: const BorderSide(color: Colors.white54),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                child: const Text("Close"),
                onPressed: () => Navigator.pop(ctx),
              ),
              if (selectedItems.isNotEmpty)
                ElevatedButton.icon(
                  onPressed: () {
                    for (var item in selectedItems) {
                      provider.addFoundSongToGenre(item);
                    }
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          "Added ${selectedItems.length} songs to playlists",
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add, color: Colors.black),
                  label: Text(
                    "Add (${selectedItems.length})",
                    style: const TextStyle(color: Colors.black),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildGlobalSearchResults(
    BuildContext context,
    RadioProvider provider,
    List<Playlist> allPlaylists,
  ) {
    print("Building global search results: query='$_searchQuery'");
    // 1. Filter Playlists by name
    final matchedPlaylists = allPlaylists
        .where((p) => p.name.toLowerCase().contains(_searchQuery))
        .toList();

    // 2. Find Songs across ALL playlists
    final List<Map<String, dynamic>> matchedSongs = [];
    for (var p in allPlaylists) {
      for (var s in p.songs) {
        if (s.title.toLowerCase().contains(_searchQuery) ||
            s.artist.toLowerCase().contains(_searchQuery)) {
          matchedSongs.add({'playlist': p, 'song': s});
        }
      }
    }

    if (matchedPlaylists.isEmpty && matchedSongs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.search_off_rounded,
              size: 64,
              color: Colors.white24,
            ),
            const SizedBox(height: 16),
            Text(
              "No results found for '$_searchQuery'",
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (matchedPlaylists.isNotEmpty) ...[
          const Text(
            "Playlists",
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          _buildPlaylistsGrid(context, provider, matchedPlaylists),
          const SizedBox(height: 24),
        ],
        if (matchedSongs.isNotEmpty) ...[
          const Text(
            "Songs",
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: matchedSongs.length,
            itemBuilder: (context, index) {
              final item = matchedSongs[index];
              final SavedSong song = item['song'];
              final Playlist playlist = item['playlist'];

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: song.artUri != null
                        ? CachedNetworkImage(
                            imageUrl: song.artUri!,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              width: 48,
                              height: 48,
                              color: Colors.grey[900],
                              child: const Icon(
                                Icons.music_note,
                                color: Colors.white54,
                              ),
                            ),
                          )
                        : Container(
                            width: 48,
                            height: 48,
                            color: Colors.grey[900],
                            child: const Icon(
                              Icons.music_note,
                              color: Colors.white54,
                            ),
                          ),
                  ),
                  title: Text(
                    song.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.artist,
                        style: const TextStyle(color: Colors.white70),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            playlist.id == 'favorites'
                                ? Icons.favorite
                                : Icons.queue_music,
                            size: 12,
                            color: playlist.id == 'favorites'
                                ? Colors.pinkAccent
                                : Colors.white54,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              "in ${playlist.name}",
                              style: TextStyle(
                                color: playlist.id == 'favorites'
                                    ? Colors.pinkAccent
                                    : Colors.white54,
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      provider.playPlaylistSong(song, playlist.id);
                    },
                  ),
                  onTap: () {
                    provider.playPlaylistSong(song, playlist.id);
                  },
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _buildArtistsGrid(
    BuildContext context,
    RadioProvider provider,
    List<SavedSong> allSongs,
  ) {
    // Grouping Logic
    final Map<String, Set<String>> groupedVariants = {};
    final Map<String, String> normKeyToDisplay = {};

    for (var s in allSongs) {
      if (s.artist.isEmpty) continue;
      String raw = s.artist;
      String norm = raw
          .split('•')
          .first
          .trim()
          .split(RegExp(r'[,&/]'))
          .first
          .trim();
      String key = norm.toLowerCase();

      if (!groupedVariants.containsKey(key)) {
        groupedVariants[key] = {};
        normKeyToDisplay[key] = norm;
      }
      groupedVariants[key]!.add(raw);
    }

    final groups = groupedVariants.keys.toList()
      ..sort((a, b) => a.compareTo(b));

    if (groups.isEmpty) {
      return const Center(
        child: Text(
          "No artists found",
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    return GridView.builder(
      key: const PageStorageKey('artists_grid'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.8,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: groups.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          final favImage = GenreMapper.getGenreImage("Favorites");
          // Check if Favorites is playing
          bool isFavPlaying = provider.currentPlayingPlaylistId == 'favorites';
          // Only check song match if not already active playlist
          if (!isFavPlaying) {
            // We'd need to access the favorites list, but standard practice is
            // checking playlistId. We can leave it as ID check for simplicity
            // or check if current song is IS_FAV if needed.
            // But simpler to just rely on ID or maybe check if current song is favorited?
            // The user request says "where inside there is a song that is playing".
            // If ANY favorite song is playing?
            final favIds = provider.favorites;
            if (favIds.contains(
                  int.tryParse(provider.currentSongId ?? "") ?? -1,
                ) ||
                (provider.currentTrack.isNotEmpty &&
                    provider.favorites.isNotEmpty &&
                    // This is tricky without loading all favorites.
                    // Let's stick to playlist ID check or if current song is favored.
                    provider.favorites.any(
                      (fid) => fid.toString() == provider.audioOnlySongId,
                    ))) {
              // Actually provider.favorites is just IDs.
              // We can't easily know if 'currentTrack' matches a favorite by text without traversing all.
              // But we CAN check provider.isFavorite(currentSongId).
              // Let's assume if the current song is favorited, highlight the Favorites card.
              final currentId = int.tryParse(provider.currentSongId ?? "");
              if (currentId != null && provider.favorites.contains(currentId)) {
                isFavPlaying = true;
              }
            }
          }

          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedPlaylistId = 'favorites';
                _selectedArtist = null;
                _selectedAlbum = null;
                _searchController.clear();
              });
            },
            child: Container(
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: isFavPlaying
                    ? Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.8),
                        width: 2,
                      )
                    : Border.all(color: Colors.white12),
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                boxShadow: isFavPlaying
                    ? [
                        BoxShadow(
                          color: Colors.redAccent.withValues(alpha: 0.4),
                          blurRadius: 12,
                          spreadRadius: 2,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
                image: favImage != null
                    ? DecorationImage(
                        image: CachedNetworkImageProvider(favImage),
                        fit: BoxFit.cover,
                        colorFilter: ColorFilter.mode(
                          Colors.black.withValues(alpha: 0.5),
                          BlendMode.darken,
                        ),
                      )
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Center(
                      child: Icon(
                        Icons.favorite,
                        color: Colors.white.withValues(alpha: 0.9),
                        size: 40,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      "Favorites",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final groupKey = groups[index - 1];
        final variants = groupedVariants[groupKey]!;

        String displayArtist;
        String searchArtist;
        bool isGroup;
        int count = 0;
        bool isPlaying = false;

        if (variants.length == 1) {
          // Single
          displayArtist = variants.first;
          searchArtist = variants.first;
          isGroup = false;
          count = allSongs.where((s) => s.artist == displayArtist).length;

          // Check playing
          if (provider.currentArtist.trim().toLowerCase() ==
              displayArtist.trim().toLowerCase()) {
            isPlaying = true;
          }
        } else {
          // Group
          searchArtist = normKeyToDisplay[groupKey]!;
          displayArtist = "$searchArtist...";
          isGroup = true;

          for (var v in variants) {
            count += allSongs.where((s) => s.artist == v).length;
          }

          // Check playing (if any variant matches)
          final currentNorm = provider.currentArtist
              .split('•')
              .first
              .trim()
              .split(RegExp(r'[,&/]'))
              .first
              .trim()
              .toLowerCase();
          if (currentNorm == groupKey) isPlaying = true;
        }

        return _ArtistGridItem(
          artist: searchArtist,
          customDisplayName: displayArtist,
          songCount: count,
          isPlaying: isPlaying,
          onTap: () {
            setState(() {
              // Reset other selections
              _selectedPlaylistId = null;
              _selectedAlbum = null;
              _searchController.clear();

              if (isGroup) {
                _selectedArtist = groupKey; // key for filtering
                _selectedArtistDisplay = displayArtist;
                _selectedArtistIsGroup = true;
              } else {
                _selectedArtist = searchArtist; // original name
                _selectedArtistDisplay = searchArtist;
                _selectedArtistIsGroup = false;
              }
            });
          },
        );
      },
    );
  }

  Widget _buildAlbumsGrid(
    BuildContext context,
    RadioProvider provider,
    List<SavedSong> allSongs,
  ) {
    // ALBUM GROUPING LOGIC
    final Map<String, Set<String>> groupedAlbums = {};
    final Map<String, String> normKeyToDisplay = {};
    final Map<String, SavedSong> representativeSongs =
        {}; // One song per raw album to get art/artist

    for (var s in allSongs) {
      if (s.album.isEmpty) continue;
      String raw = s.album;
      // Normalization: Remove (Deluxe), [Live], etc.
      String norm = raw.split('(').first.trim().split('[').first.trim();
      String key = norm.toLowerCase();

      if (!groupedAlbums.containsKey(key)) {
        groupedAlbums[key] = {};
        normKeyToDisplay[key] = norm;
      }
      groupedAlbums[key]!.add(raw);

      if (!representativeSongs.containsKey(raw)) {
        representativeSongs[raw] = s;
      }
    }

    final groups = groupedAlbums.keys.toList()..sort((a, b) => a.compareTo(b));

    if (groups.isEmpty) {
      return const Center(
        child: Text("No albums found", style: TextStyle(color: Colors.white54)),
      );
    }

    return GridView.builder(
      key: const PageStorageKey('albums_grid'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.8,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: groups.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          final favImage = GenreMapper.getGenreImage("Favorites");
          bool isFavPlaying = provider.currentPlayingPlaylistId == 'favorites';

          final currentId = int.tryParse(provider.currentSongId ?? "");
          if (!isFavPlaying &&
              currentId != null &&
              provider.favorites.contains(currentId)) {
            isFavPlaying = true;
          }

          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedPlaylistId = 'favorites';
                _selectedArtist = null;
                _selectedAlbum = null;
                _searchController.clear();
              });
            },
            child: Container(
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: isFavPlaying
                    ? Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.8),
                        width: 2,
                      )
                    : Border.all(color: Colors.white12),
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                boxShadow: isFavPlaying
                    ? [
                        BoxShadow(
                          color: Colors.redAccent.withValues(alpha: 0.4),
                          blurRadius: 12,
                          spreadRadius: 2,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
                image: favImage != null
                    ? DecorationImage(
                        image: CachedNetworkImageProvider(favImage),
                        fit: BoxFit.cover,
                        colorFilter: ColorFilter.mode(
                          Colors.black.withValues(alpha: 0.5),
                          BlendMode.darken,
                        ),
                      )
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Center(
                      child: Icon(
                        Icons.favorite,
                        color: Colors.white.withValues(alpha: 0.9),
                        size: 40,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      "Favorites",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final groupKey = groups[index - 1];
        final variants = groupedAlbums[groupKey]!;

        String displayAlbum;
        String searchAlbum;
        bool isGroup;
        int count = 0;
        bool isPlaying = false;
        SavedSong? displaySong;

        if (variants.length == 1) {
          // Single
          displayAlbum = variants.first;
          searchAlbum = variants.first;
          isGroup = false;
          displaySong = representativeSongs[displayAlbum];

          final albumSongs = allSongs
              .where((s) => s.album == displayAlbum)
              .toList();
          count = albumSongs.length;

          // Check playing
          if (provider.currentAlbum.trim().toLowerCase() ==
                  displayAlbum.trim().toLowerCase() &&
              (displaySong != null &&
                  provider.currentArtist.trim().toLowerCase() ==
                      displaySong.artist.trim().toLowerCase())) {
            isPlaying = true;
          } else if (albumSongs.isNotEmpty) {
            // If any song in this specific album is playing
            isPlaying = albumSongs.any((s) => provider.audioOnlySongId == s.id);
          }
        } else {
          // Group
          searchAlbum = normKeyToDisplay[groupKey]!;
          displayAlbum = "$searchAlbum...";
          isGroup = true;
          // Use first variant for art
          displaySong = representativeSongs[variants.first];

          for (var v in variants) {
            count += allSongs.where((s) => s.album == v).length;
          }

          // Check playing (if any variant matches)
          final currentNorm = provider.currentAlbum
              .split('(')
              .first
              .trim()
              .split('[')
              .first
              .trim()
              .toLowerCase();
          if (currentNorm == groupKey) isPlaying = true;
        }

        if (displaySong == null) return const SizedBox();

        return GestureDetector(
          onTap: () {
            setState(() {
              _selectedArtist = null;
              _selectedPlaylistId = null;
              _searchController.clear();

              if (isGroup) {
                _selectedAlbum = groupKey;
                _selectedAlbumDisplay = displayAlbum;
                _selectedAlbumIsGroup = true;
              } else {
                _selectedAlbum = searchAlbum;
                _selectedAlbumDisplay = searchAlbum;
                _selectedAlbumIsGroup = false;
              }
            });
          },
          child: Container(
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: isPlaying
                  ? Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.8),
                      width: 2,
                    )
                  : Border.all(color: Colors.white12),
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
              boxShadow: isPlaying
                  ? [
                      BoxShadow(
                        color: Colors.redAccent.withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: 2,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
              // No generic background image for album card generally, just the art
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                    child: displaySong.artUri != null
                        ? CachedNetworkImage(
                            imageUrl: displaySong.artUri!,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              color: Colors.white10,
                              child: const Icon(
                                Icons.album,
                                color: Colors.white54,
                                size: 40,
                              ),
                            ),
                          )
                        : Container(
                            color: Colors.white10,
                            child: const Icon(
                              Icons.album,
                              color: Colors.white54,
                              size: 40,
                            ),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayAlbum,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        displaySong.artist,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        "$count Songs",
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _playSongs(
    RadioProvider provider,
    List<SavedSong> songs,
    String name,
  ) async {
    if (songs.isEmpty) return;
    final playlist = Playlist(
      id: 'temp_view',
      name: name,
      songs: songs,
      createdAt: DateTime.now(),
    );
    provider.playAdHocPlaylist(playlist, null);
  }
}

class _AlbumGroupWidget extends StatefulWidget {
  final List<SavedSong> groupSongs;
  final Widget Function(BuildContext, SavedSong, int) songBuilder;
  final Future<bool> Function() onMove;
  final Future<bool> Function() onRemove;
  final DismissDirection? dismissDirection;

  const _AlbumGroupWidget({
    required this.groupSongs,
    required this.songBuilder,
    required this.onMove,
    required this.onRemove,
    this.dismissDirection,
  });

  @override
  State<_AlbumGroupWidget> createState() => _AlbumGroupWidgetState();
}

class _AlbumGroupWidgetState extends State<_AlbumGroupWidget> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final firstSong = widget.groupSongs.first;
    final albumName = firstSong.album;
    final artistName = firstSong.artist;
    final artUri = firstSong.artUri;

    // Check if any song in this group is currently playing
    final isPlayingAlbum =
        !_isExpanded &&
        widget.groupSongs.any(
          (s) =>
              provider.audioOnlySongId == s.id ||
              (s.title.trim().toLowerCase() ==
                      provider.currentTrack.trim().toLowerCase() &&
                  s.artist.trim().toLowerCase() ==
                      provider.currentArtist.trim().toLowerCase()),
        );

    return Dismissible(
      key: Key("group_${albumName}_$artistName"),
      direction: widget.dismissDirection ?? DismissDirection.horizontal,
      background: Container(
        alignment: Alignment.centerLeft,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.green,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.only(left: 24),
        child: const Icon(Icons.drive_file_move_outline, color: Colors.white),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.red,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          return await widget.onMove();
        } else {
          return await widget.onRemove();
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: isPlayingAlbum
              ? Colors.redAccent.withValues(alpha: 0.05)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: isPlayingAlbum
              ? Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.6),
                  width: 1.5,
                )
              : Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Album Header
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  setState(() {
                    _isExpanded = !_isExpanded;
                  });
                },
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                  bottom: Radius.circular(0), // Rounded only top if expanded
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          // Navigate to Album Details
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => AlbumDetailsScreen(
                                albumName: albumName,
                                artistName: artistName,
                                artworkUrl: artUri,
                              ),
                            ),
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: artUri != null
                              ? CachedNetworkImage(
                                  imageUrl: artUri,
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => Container(
                                    width: 60,
                                    height: 60,
                                    color: Colors.white10,
                                    child: const Icon(
                                      Icons.album,
                                      color: Colors.white54,
                                    ),
                                  ),
                                )
                              : Container(
                                  width: 60,
                                  height: 60,
                                  color: Colors.white10,
                                  child: const Icon(
                                    Icons.album,
                                    color: Colors.white54,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              albumName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              artistName,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              "${widget.groupSongs.length} songs${(firstSong.releaseDate != null && firstSong.releaseDate!.isNotEmpty) ? " • ${firstSong.releaseDate!.split('-').first}" : ""}",
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        _isExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: Colors.white54,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_isExpanded) ...[
              const Divider(height: 1, color: Colors.white10),
              // Songs List
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: widget.groupSongs.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Colors.white10),
                itemBuilder: (ctx, i) {
                  return widget.songBuilder(ctx, widget.groupSongs[i], i + 1);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ArtistGridItem extends StatefulWidget {
  final String artist;
  final String? customDisplayName;
  final int songCount;
  final VoidCallback onTap;
  final bool isPlaying;

  const _ArtistGridItem({
    required this.artist,
    this.customDisplayName,
    required this.songCount,
    required this.onTap,
    this.isPlaying = false,
  });

  @override
  State<_ArtistGridItem> createState() => _ArtistGridItemState();
}

class _ArtistGridItemState extends State<_ArtistGridItem> {
  String? _imageUrl;

  @override
  void initState() {
    super.initState();
    _fetchImage();
  }

  @override
  void didUpdateWidget(covariant _ArtistGridItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist != widget.artist) {
      _fetchImage();
    }
  }

  Future<void> _fetchImage() async {
    try {
      // Use the part before any comma or '&' for better search results
      // ensuring we strip any "• Metadata" first if present in the passed string
      // though for display we might show more.
      var searchName = widget.artist.split('•').first.trim();
      searchName = searchName.split(RegExp(r'[,&/]')).first.trim();

      final uri = Uri.parse(
        "https://api.deezer.com/search/artist?q=${Uri.encodeComponent(searchName)}&limit=1",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['data'] != null && (json['data'] as List).isNotEmpty) {
          String? picture =
              json['data'][0]['picture_xl'] ??
              json['data'][0]['picture_big'] ??
              json['data'][0]['picture_medium'];

          if (picture != null && mounted) {
            setState(() {
              _imageUrl = picture;
            });
          }
        }
      }
    } catch (e) {
      // Ignore errors, default fallback will be shown
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: widget.isPlaying
              ? Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.8),
                  width: 2,
                )
              : Border.all(color: Colors.white12),
        ),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          boxShadow: widget.isPlaying
              ? [
                  BoxShadow(
                    color: Colors.redAccent.withValues(alpha: 0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                child: _imageUrl != null
                    ? CachedNetworkImage(
                        imageUrl: _imageUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: Colors.white10,
                          child: const Icon(
                            Icons.person,
                            color: Colors.white54,
                            size: 40,
                          ),
                        ),
                      )
                    : Container(
                        color: Colors.white10,
                        child: const Icon(
                          Icons.person,
                          color: Colors.white54,
                          size: 40,
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // Show full name (up to bullet) even if it contains , or &
                    widget.customDisplayName ??
                        widget.artist.split('•').first.trim(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    "${widget.songCount} Songs",
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InvalidSongIndicator extends StatelessWidget {
  final String songId;
  final bool isStaticInvalid;

  const _InvalidSongIndicator({
    required this.songId,
    this.isStaticInvalid = false,
  });

  @override
  Widget build(BuildContext context) {
    // Select specifically on whether the ID exists in the set.
    // This allows the widget to rebuild ONLY when this specific condition changes,
    // and it bypasses any potential staleness in the parent's data.
    return Selector<RadioProvider, bool>(
      selector: (_, provider) => provider.invalidSongIds.contains(songId),
      builder: (context, isRefInvalid, _) {
        if (!isStaticInvalid && !isRefInvalid) return const SizedBox.shrink();
        return const Padding(
          padding: EdgeInsets.only(right: 8.0),
          child: Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange,
            size: 20,
          ),
        );
      },
    );
  }
}
