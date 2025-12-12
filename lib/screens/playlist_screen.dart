import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../providers/radio_provider.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import '../utils/genre_mapper.dart';

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

    // Filter Logic
    final playlists = _selectedPlaylistId == null
        ? allPlaylists
              .where((p) => p.name.toLowerCase().contains(_searchQuery))
              .toList()
        : allPlaylists;

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

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2), // Separate area background
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: [
          // Custom Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            color: Colors.white.withValues(alpha: 0.05),
            child: Row(
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
                Text(
                  _selectedPlaylistId != null
                      ? selectedPlaylist?.name ?? "Playlist"
                      : "My Playlists",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // Search Bar
                Container(
                  width: 160,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: "Search...",
                      hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: Icon(
                        Icons.search,
                        color: Colors.white38,
                        size: 16,
                      ),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.only(
                        top: 8,
                      ), // center vertical
                    ),
                  ),
                ),
                if (_selectedPlaylistId == null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.add_rounded, size: 28),
                    color: Colors.white,
                    tooltip: "Create Playlist",
                    onPressed: () =>
                        _showCreatePlaylistDialog(context, provider),
                  ),
                ],
              ],
            ),
          ),

          // Body content
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
    );
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
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              image: bgImage != null
                  ? DecorationImage(
                      image: bgImage.startsWith('http')
                          ? NetworkImage(bgImage)
                          : AssetImage(bgImage) as ImageProvider,
                      fit: BoxFit.cover,
                      colorFilter: ColorFilter.mode(
                        Colors.black.withValues(alpha: 0.6),
                        BlendMode.darken,
                      ),
                    )
                  : null,
              color: bgImage == null
                  ? Colors.white.withValues(alpha: 0.1)
                  : null, // Fallback color
              border: Border.all(color: Colors.white12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Stack(
              children: [
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
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final song = songs[index];
        return Dismissible(
          key: Key(song.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            color: Colors.red,
            padding: const EdgeInsets.only(right: 24),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) {
            provider.removeFromPlaylist(playlist.id, song.id);
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.all(12),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: song.artUri != null
                    ? Image.network(
                        song.artUri!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 56,
                          height: 56,
                          color: Colors.grey[900],
                          child: const Icon(
                            Icons.music_note,
                            color: Colors.white24,
                          ),
                        ),
                      )
                    : Container(
                        width: 56,
                        height: 56,
                        color: Colors.grey[900],
                        child: const Icon(
                          Icons.music_note,
                          color: Colors.white24,
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
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat.yMMMd().format(song.dateAdded),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (song.spotifyUrl != null) ...[
                        GestureDetector(
                          onTap: () => launchUrl(
                            Uri.parse(song.spotifyUrl!),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: const FaIcon(
                            FontAwesomeIcons.spotify,
                            color: Color(0xFF1DB954),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                      if (song.youtubeUrl != null) ...[
                        GestureDetector(
                          onTap: () => launchUrl(
                            Uri.parse(song.youtubeUrl!),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: const FaIcon(
                            FontAwesomeIcons.youtube,
                            color: Color(0xFFFF0000),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                      GestureDetector(
                        onTap: () {
                          final url =
                              song.appleMusicUrl ??
                              "https://music.apple.com/search?term=${Uri.encodeComponent("${song.title} ${song.artist}")}";
                          launchUrl(
                            Uri.parse(url),
                            mode: LaunchMode.externalApplication,
                          );
                        },
                        child: const FaIcon(
                          FontAwesomeIcons.apple,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.drive_file_move_outline,
                      color: Colors.white70,
                    ),
                    tooltip: "Move to...",
                    onPressed: () => _showMoveSongDialog(
                      context,
                      provider,
                      playlist,
                      song.id,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                    ),
                    tooltip: "Remove",
                    onPressed: () {
                      provider.removeFromPlaylist(playlist.id, song.id);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Song removed form playlist"),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
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

  void _showMoveSongDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist currentPlaylist,
    String songId,
  ) {
    final others = provider.playlists
        .where((p) => p.id != currentPlaylist.id)
        .toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No other playlists to move to.")),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a1a2e),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Container(
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
              ...others.map(
                (p) => ListTile(
                  leading: const Icon(Icons.folder, color: Colors.white38),
                  title: Text(
                    p.name,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    provider.moveSong(songId, currentPlaylist.id, p.id);
                    Navigator.pop(ctx);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Moved to ${p.name}")),
                      );
                    }
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
