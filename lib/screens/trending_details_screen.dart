import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:math';

import '../services/trending_service.dart';
import '../services/spotify_service.dart';
import '../providers/radio_provider.dart';
import '../models/saved_song.dart';
import '../models/playlist.dart';

import '../widgets/player_bar.dart';
import '../widgets/native_ad_widget.dart';
import '../widgets/mini_visualizer.dart';
import '../services/log_service.dart';

class _AdItem {
  const _AdItem();
}

class TrendingDetailsScreen extends StatefulWidget {
  final TrendingPlaylist playlist;

  const TrendingDetailsScreen({super.key, required this.playlist});

  @override
  State<TrendingDetailsScreen> createState() => _TrendingDetailsScreenState();
}

class _TrendingDetailsScreenState extends State<TrendingDetailsScreen> {
  final ScrollController _scrollController = ScrollController();
  List<Map<String, String>> _tracks = [];
  List<dynamic> _items = [];
  bool _isLoading = true;
  late TrendingService _trendingService;
  late SpotifyService _spotifyService;
  String? _lastScrollSongId;

  @override
  void initState() {
    super.initState();
    _fetchTracks();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchTracks() async {
    _spotifyService = SpotifyService();
    await _spotifyService.init();
    _trendingService = TrendingService(_spotifyService);

    final tracks = await _trendingService.getPlaylistTracks(widget.playlist);

    LogService().log(
      "TrendingDetails: Tracks fetched: ${tracks.length} tracks for playlist '${widget.playlist.title}'",
    );

    if (mounted) {
      setState(() {
        _tracks = tracks;
        _isLoading = false;
        _buildItems();
      });
    }
  }

  void _buildItems() {
    _items = [];
    if (_tracks.isNotEmpty) {
      _items.add(const _AdItem()); // Ad at start
      for (int i = 0; i < _tracks.length; i++) {
        _items.add(_tracks[i]);
        if ((i + 1) % 10 == 0 && (i + 1) < _tracks.length) {
          _items.add(const _AdItem()); // Ad every 10 songs
        }
      }
      _items.add(const _AdItem()); // Ad at end
    }
  }

  @override
  Widget build(BuildContext context) {
    // Extract metadata efficiently
    final mainImage = widget.playlist.imageUrls.isNotEmpty
        ? widget.playlist.imageUrls.first
        : '';
    final title = widget.playlist.title;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Background Image
          if (mainImage.isNotEmpty)
            CachedNetworkImage(
              imageUrl: mainImage,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(color: Colors.grey[900]),
            )
          else
            Container(color: Colors.grey[900]),

          // 2. Dark Overlay
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.6),
                  Colors.black.withOpacity(0.9),
                  Colors.black,
                ],
              ),
            ),
          ),

          // 3. Content
          Positioned.fill(
            child: CustomScrollView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              slivers: [
                // Header
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top + 60,
                      left: 24,
                      right: 24,
                      bottom: 24,
                    ),
                    child: Column(
                      children: [
                        // Artwork Shadowed
                        Container(
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.5),
                                blurRadius: 30,
                                offset: const Offset(0, 15),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: mainImage.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: mainImage,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => const Center(
                                    child: Icon(
                                      Icons.music_note,
                                      size: 80,
                                      color: Colors.white54,
                                    ),
                                  ),
                                )
                              : const Center(
                                  child: Icon(
                                    Icons.music_note,
                                    size: 80,
                                    color: Colors.white54,
                                  ),
                                ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Actions Row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton.icon(
                              onPressed: _playRandom,
                              icon: const Icon(Icons.shuffle, size: 18),
                              label: const Text("Shuffle Play"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context).primaryColor,
                                foregroundColor:
                                    Theme.of(
                                          context,
                                        ).primaryColor.computeLuminance() >
                                        0.5
                                    ? Colors.black
                                    : Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(25),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              icon: const Icon(
                                Icons.stop_circle_outlined,
                                color: Colors.redAccent,
                                size: 30,
                              ),
                              onPressed: () {
                                Provider.of<RadioProvider>(
                                  context,
                                  listen: false,
                                ).stop();
                              },
                              tooltip: "Stop",
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.copy_all,
                                color: _isLoading || _tracks.isEmpty
                                    ? Colors.white24
                                    : Colors.orangeAccent,
                                size: 30,
                              ),
                              onPressed: _isLoading || _tracks.isEmpty
                                  ? null
                                  : _showCopyDialog,
                              tooltip: "Copy List",
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // Tracks List
                _buildTrackSliver(context),
              ],
            ),
          ),

          // 4. Back Button
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: CircleAvatar(
                  backgroundColor: Colors.black.withOpacity(0.5),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: "Back",
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const PlayerBar(),
    );
  }

  Widget _buildTrackSliver(BuildContext context) {
    if (_isLoading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_tracks.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Text(
            "No tracks found",
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    return Consumer<RadioProvider>(
      builder: (context, provider, child) {
        final playingSongId =
            provider.currentSongId ??
            provider.audioHandler.mediaItem.value?.extras?['songId'];
        final theme = Theme.of(context);
        final isPlayingState =
            provider.audioHandler.playbackState.value.playing;

        // Auto-scroll logic
        if (playingSongId != null &&
            playingSongId != _lastScrollSongId &&
            _items.isNotEmpty) {
          final index = _items.indexWhere((item) {
            if (item is! Map) return false;
            if (item['id'] == playingSongId) return true;

            // Fallback for unstable IDs (like lofi playlists): match by title
            final currentItemTitle = provider.currentTrack;
            if (currentItemTitle != "Live Broadcast" &&
                item['title'] == currentItemTitle) {
              return true;
            }
            return false;
          });
          if (index != -1) {
            _lastScrollSongId = playingSongId;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_scrollController.hasClients) {
                // Estimate offset: Header (~480) + Index * ItemHeight (~72)
                // This is an approximation.
                final double headerHeight = 480.0;
                final double itemHeight = 72.0;
                final double offset = headerHeight + (index * itemHeight);

                // Center it: offset - screenHeight/2 + itemHeight/2
                final double target =
                    offset -
                    (MediaQuery.of(context).size.height / 2) +
                    (itemHeight / 2);

                _scrollController.animateTo(
                  target.clamp(0.0, _scrollController.position.maxScrollExtent),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOut,
                );
              }
            });
          }
        }

        return SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final item = _items[index];

            if (item is _AdItem) {
              return const NativeAdWidget();
            }

            final track = item as Map<String, String>;
            final trackIndex = _tracks.indexOf(track);
            bool isPlaying = playingSongId == track['id'];

            // Fallback for unstable IDs: if playingSongId doesn't match, check title
            if (!isPlaying && playingSongId != null) {
              final currentItemTitle = provider.currentTrack;
              if (currentItemTitle != "Live Broadcast" &&
                  track['title'] == currentItemTitle) {
                isPlaying = true;
              }
            }

            final savedIds = provider.allUniqueSongs.map((s) => s.id).toSet();
            final isSaved = savedIds.contains(track['id']);

            return Container(
              decoration: BoxDecoration(
                color: isPlaying
                    ? Colors.white.withOpacity(0.1)
                    : Colors.transparent,
                border: isPlaying
                    ? Border.all(color: theme.primaryColor, width: 2)
                    : null,
              ),
              child: ListTile(
                leading: Text(
                  "${trackIndex + 1}",
                  style: TextStyle(
                    color: isPlaying ? Colors.white : Colors.white54,
                    fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                title: Text(
                  track['title'] ?? 'Unknown',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isPlaying ? theme.primaryColor : Colors.white,
                    fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                subtitle: Text(
                  track['artist'] ?? 'Unknown',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPlaying)
                      Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: provider.isLoading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: theme.primaryColor,
                                ),
                              )
                            : MiniVisualizer(
                                color: theme.primaryColor,
                                width: 20,
                                height: 20,
                                active: isPlayingState,
                              ),
                      ),
                    IconButton(
                      icon: Icon(
                        isSaved ? Icons.check_circle : Icons.add_circle_outline,
                        color: isSaved ? theme.primaryColor : Colors.white54,
                      ),
                      onPressed: () => _showAddSongDialog(track),
                      tooltip: isSaved
                          ? "Already in Library"
                          : "Add to Playlist",
                    ),
                  ],
                ),
                onTap: () => _playTrack(trackIndex),
              ),
            );
          }, childCount: _items.length),
        );
      },
    );
  }

  void _playTrack(int index) {
    if (_tracks.isEmpty) return;
    final provider = Provider.of<RadioProvider>(context, listen: false);

    // Convert to SavedSong
    final songs = _convertToSavedSongs();
    final song = songs[index];
    final playlistId = 'trending_${widget.playlist.id}'; // Fixed: Stable ID

    if (provider.currentPlayingPlaylistId == playlistId) {
      // Optimization: If already playing this playlist (Linear or Shuffled),
      // just jump to the song within the existing context.
      // This preserves the current queue order (e.g. Shuffle).
      final link =
          song.youtubeUrl ?? "ID: ${song.id} (${widget.playlist.provider})";
      LogService().log(
        "TrendingDetails: Selection: Playing song '${song.title}' from existing context. Link: $link",
      );
      provider.playPlaylistSong(song, playlistId);
    } else {
      final link =
          song.youtubeUrl ?? "ID: ${song.id} (${widget.playlist.provider})";
      LogService().log(
        "TrendingDetails: Selection: Loading new context for song '${song.title}' (Playlist: ${widget.playlist.title}). Link: $link",
      );
      // New context: Load the full linear playlist
      final tempPlaylist = Playlist(
        id: playlistId,
        name: widget.playlist.title,
        songs: songs,
        createdAt: DateTime.now(),
      );
      provider.playAdHocPlaylist(tempPlaylist, song.id);
    }
  }

  void _playRandom() {
    if (_tracks.isEmpty) return;
    final provider = Provider.of<RadioProvider>(context, listen: false);

    // Convert to SavedSong
    final songs = _convertToSavedSongs();

    // Shuffle
    songs.shuffle();

    final tempPlaylist = Playlist(
      id: 'trending_${widget.playlist.id}', // Fixed: Stable ID for identification
      name: widget.playlist.title,
      songs: songs,
      createdAt: DateTime.now(),
    );

    provider.playAdHocPlaylist(tempPlaylist, null);
  }

  List<SavedSong> _convertToSavedSongs() {
    return _tracks.map((t) => _trackToSavedSong(t)).toList();
  }

  SavedSong _trackToSavedSong(Map<String, String> t) {
    return SavedSong(
      id: t['id']!.length > 5
          ? t['id']!
          : DateTime.now().millisecondsSinceEpoch.toString() +
                Random().nextInt(1000).toString(),
      title: t['title']!,
      artist: t['artist']!,
      album: t['album']!,
      artUri: t['image'],
      youtubeUrl: t['provider'] == 'YouTube'
          ? "https://youtube.com/watch?v=${t['id']}"
          : null,
      spotifyUrl: t['provider'] == 'Spotify'
          ? "https://open.spotify.com/track/${t['id']}"
          : null,
      provider: t['provider'],
      rawStreamUrl: t['provider'] == 'Audius'
          ? "https://api.audius.co/v1/tracks/${t['id']}/stream?app_name=RadioStreamApp"
          : (t['provider'] == 'Deezer' ? t['preview'] : null),
      dateAdded: DateTime.now(),
    );
  }

  void _showCopyDialog() {
    if (_isLoading) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Still loading tracks...")));
      return;
    }
    if (_tracks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("No tracks to copy")));
      return;
    }

    final provider = Provider.of<RadioProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (context) {
        final playlists = provider.playlists;

        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: Text(
            "Copy Playlist",
            style: TextStyle(
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    "Copy all songs to:",
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: playlists.length + 1,
                    itemBuilder: (ctx, index) {
                      if (index == 0) {
                        return ListTile(
                          leading: const Icon(
                            Icons.add,
                            color: Colors.blueAccent,
                          ),
                          title: const Text(
                            "Create New Playlist",
                            style: TextStyle(color: Colors.blueAccent),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _createNewPlaylist();
                          },
                        );
                      }
                      final p = playlists[index - 1];
                      return ListTile(
                        leading: const Icon(Icons.playlist_play_rounded),
                        title: Text(
                          p.name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _copySongsTo(p.id);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _createNewPlaylist() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: Text(
          "New Playlist",
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
          decoration: InputDecoration(
            labelText: "Playlist Name",
            labelStyle: TextStyle(
              color: Theme.of(
                context,
              ).textTheme.bodyLarge?.color?.withValues(alpha: 0.6),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).dividerColor),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).primaryColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final name = controller.text;
                Navigator.pop(ctx);
                _showProcessingDialog("Creating playlist and copying songs...");

                final provider = Provider.of<RadioProvider>(
                  context,
                  listen: false,
                );

                final songs = _convertToSavedSongs();
                final newPlaylist = await provider.createPlaylist(
                  name,
                  songs: songs,
                );

                // Start background resolution
                provider.resolvePlaylistLinksInBackground(
                  newPlaylist.id,
                  songs,
                );

                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Copied ${songs.length} songs!")),
                  );
                }
              }
            },
            child: Text(
              "Create",
              style: TextStyle(color: Theme.of(context).primaryColor),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copySongsTo(String playlistId) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final songs = _convertToSavedSongs();

    await provider.addSongsToPlaylist(playlistId, songs);

    // Always attempt to resolve links for the added songs in background
    provider.resolvePlaylistLinksInBackground(playlistId, songs);

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Copied ${songs.length} songs!")));
    }
  }

  void _showAddSongDialog(Map<String, String> track) {
    final song = _trackToSavedSong(track);
    final provider = Provider.of<RadioProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (context) {
        final playlists = provider.playlists;

        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: Text(
            "Add to Playlist",
            style: TextStyle(
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    "Add '${song.title}' to:",
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: playlists.length + 1,
                    itemBuilder: (ctx, index) {
                      if (index == 0) {
                        return ListTile(
                          leading: const Icon(
                            Icons.add,
                            color: Colors.blueAccent,
                          ),
                          title: const Text(
                            "Create New Playlist",
                            style: TextStyle(color: Colors.blueAccent),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _createNewPlaylistAndAddSong(song);
                          },
                        );
                      }
                      final p = playlists[index - 1];
                      return ListTile(
                        leading: const Icon(Icons.playlist_add_rounded),
                        title: Text(
                          p.name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _performAddSong(p.id, song);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _createNewPlaylistAndAddSong(SavedSong song) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: Text(
          "New Playlist",
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
          decoration: InputDecoration(
            labelText: "Playlist Name",
            labelStyle: TextStyle(
              color: Theme.of(
                context,
              ).textTheme.bodyLarge?.color?.withValues(alpha: 0.6),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).dividerColor),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).primaryColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final name = controller.text;
                Navigator.pop(ctx);
                _showProcessingDialog("Adding to new playlist...");

                final provider = Provider.of<RadioProvider>(
                  context,
                  listen: false,
                );

                final songs = [song];
                final newPlaylist = await provider.createPlaylist(
                  name,
                  songs: songs,
                );

                // Start background resolution
                provider.resolvePlaylistLinksInBackground(
                  newPlaylist.id,
                  songs,
                );

                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Added '${song.title}'!")),
                  );
                }
              }
            },
            child: Text(
              "Create",
              style: TextStyle(color: Theme.of(context).primaryColor),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _performAddSong(String playlistId, SavedSong song) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    await provider.addSongToPlaylist(playlistId, song);

    // Always resolve link
    provider.resolvePlaylistLinksInBackground(playlistId, [song]);

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Added '${song.title}'!")));
    }
  }

  void _showProcessingDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e1e24),
        content: Row(
          children: [
            const CircularProgressIndicator(color: Colors.redAccent),
            const SizedBox(width: 24),
            Text(message, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
