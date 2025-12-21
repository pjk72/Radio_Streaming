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

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  String? _selectedPlaylistId;
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
    super.dispose();
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

    // Filter Logic
    final playlists = _selectedPlaylistId == null
        ? sortedPlaylists
              .where((p) => p.name.toLowerCase().contains(_searchQuery))
              .toList()
        : sortedPlaylists;

    final Playlist? selectedPlaylist = _selectedPlaylistId == null
        ? null
        : allPlaylists.firstWhere(
            (p) => p.id == _selectedPlaylistId,
            orElse: () => allPlaylists.first,
          );

    final List<SavedSong> filteredSongs = selectedPlaylist != null
        ? selectedPlaylist.songs.where((s) {
            final q = _searchQuery;
            if (q.isEmpty) return true;
            return s.title.toLowerCase().contains(q) ||
                s.artist.toLowerCase().contains(q);
          }).toList()
        : [];

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(
              alpha: 0.2,
            ), // Separate area background
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
                        if (_selectedPlaylistId != null)
                          IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new_rounded),
                            color: Colors.white,
                            onPressed: () {
                              setState(() {
                                _selectedPlaylistId = null;
                                _searchController.clear();
                              });
                            },
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.all(12.0),
                            child: Icon(
                              Icons.playlist_play_rounded,
                              color: Colors.white,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _selectedPlaylistId != null
                                ? selectedPlaylist?.name ?? "Playlist"
                                : "Playlists",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_selectedPlaylistId != null) ...[
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
                            onPressed: () =>
                                _playPlaylist(provider, selectedPlaylist!),
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
                        decoration: const InputDecoration(
                          hintText: "Search...",
                          hintStyle: TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                          isDense: true,
                          prefixIcon: Icon(
                            Icons.search,
                            color: Colors.white38,
                            size: 16,
                          ),
                          prefixIconConstraints: BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),

              // Body content
              Expanded(
                child: _selectedPlaylistId == null
                    ? ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          const SizedBox(height: 16),
                          _buildPlaylistsGrid(context, provider, playlists),
                        ],
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          await provider.reloadPlaylists();
                        },
                        child: _buildSongList(
                          context,
                          provider,
                          selectedPlaylist!,
                          filteredSongs,
                        ),
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
                        ? Image.network(
                            bgImage,
                            fit: BoxFit.cover,
                            color: Colors.black.withValues(alpha: 0.6),
                            colorBlendMode: BlendMode.darken,
                            errorBuilder: (context, error, stackTrace) {
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
          return true;
        }
        return false;
      },
      songBuilder: (context, song, index) => _buildSongItem(
        context,
        provider,
        playlist,
        song,
        isGrouped: true,
        groupIndex: index,
      ),
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
    final isInvalid = provider.invalidSongIds.contains(song.id);

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
        child: ListTile(
          onTap: isInvalid
              ? null
              : () => _handleSongAudioAction(provider, song, playlist.id),
          onLongPress: isInvalid
              ? () {
                  provider.unmarkSongAsInvalid(song.id);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Song marked as valid")),
                  );
                }
              : null,
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
                          ? Image.network(
                              song.artUri!,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
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
                    color: isInvalid
                        ? Colors.white38
                        : (provider.audioOnlySongId == song.id ||
                              (song.title.trim().toLowerCase() ==
                                      provider.currentTrack
                                          .trim()
                                          .toLowerCase() &&
                                  song.artist.trim().toLowerCase() ==
                                      provider.currentArtist
                                          .trim()
                                          .toLowerCase()))
                        ? Colors.redAccent
                        : Colors.white,
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

                    if (isInvalid)
                      const Padding(
                        padding: EdgeInsets.only(right: 8.0),
                        child: Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.orange,
                          size: 20,
                        ),
                      )
                    else ...[
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
                              final videoId = YoutubePlayer.convertUrlToId(url);
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
                              Navigator.of(context, rootNavigator: true).pop();
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
                        onTap: () =>
                            _handleSongAudioAction(provider, song, playlist.id),
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
                          if (isInvalid)
                            const Padding(
                              padding: EdgeInsets.only(right: 8.0),
                              child: Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.orange,
                                size: 20,
                              ),
                            )
                          else ...[
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
        ),
      ),
    );
  }

  Future<void> _handleSongAudioAction(
    RadioProvider provider,
    SavedSong song,
    String playlistId,
  ) async {
    // If this song is currently playing audio, toggle play/pause
    if (provider.audioOnlySongId == song.id) {
      provider.togglePlay();
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
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.search, color: Colors.white70),
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
                                      ? Image.network(
                                          s.artUri!,
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => Container(
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
                              ? Image.network(
                                  artUri,
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.cover,
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
