import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'artist_details_screen.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../widgets/player_bar.dart';
import '../models/saved_song.dart';
import '../models/playlist.dart';

class AlbumDetailsScreen extends StatefulWidget {
  final String albumName;
  final String artistName;
  final String? artworkUrl;
  final String? appleMusicUrl;
  final String? songName; // Add optional songName

  const AlbumDetailsScreen({
    super.key,
    required this.albumName,
    required this.artistName,
    this.artworkUrl,
    this.appleMusicUrl,
    this.songName, // Add this
  });

  @override
  State<AlbumDetailsScreen> createState() => _AlbumDetailsScreenState();
}

class _AlbumDetailsScreenState extends State<AlbumDetailsScreen> {
  late Future<Map<String, dynamic>?> _albumInfoFuture;
  Future<List<Map<String, dynamic>>>? _tracksFuture;
  List<Map<String, dynamic>>? _cachedTracks;

  @override
  void initState() {
    super.initState();
    _albumInfoFuture = _fetchAlbumInfo();
  }

  Future<Map<String, dynamic>?> _fetchAlbumInfo() async {
    // 1. Try to lookup by ID if we have an Apple Music URL
    if (widget.appleMusicUrl != null) {
      final id = _extractAlbumId(widget.appleMusicUrl!);
      if (id != null) {
        try {
          final uri = Uri.parse(
            "https://itunes.apple.com/lookup?id=$id&entity=album",
          );
          final response = await http.get(uri);
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data['resultCount'] > 0) {
              return data['results'][0];
            }
          }
        } catch (e) {
          developer.log("Error fetching album info by ID: $e");
        }
      }
    }

    // 2. Fallback to search query using Song Title + Artist (preferred) or Album + Artist
    try {
      String query;
      bool isSongSearch = false;
      // Prefer searching for the specific song to find its album
      if (widget.songName != null && widget.songName!.isNotEmpty) {
        // Artist first (cleaned) + Song Name (cleaned)
        query =
            "${_cleanArtistName(widget.artistName)} ${_cleanTitle(widget.songName!)}";
        isSongSearch = true;
      } else {
        query = "${_cleanArtistName(widget.artistName)} ${widget.albumName}";
      }

      // If searching for a song, we specifically ask for song entities (tracks)
      // Otherwise we look for albums.
      final entityParam = isSongSearch ? "song" : "album";
      final uri = Uri.parse(
        "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=$entityParam&limit=25",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['resultCount'] > 0) {
          final results = List<Map<String, dynamic>>.from(data['results']);
          final inputArtist = widget.artistName.toLowerCase();

          if (isSongSearch) {
            final inputSong = _cleanTitle(widget.songName!).toLowerCase();
            // Find matching song
            for (var result in results) {
              final resultArtist =
                  (result['artistName'] as String?)?.toLowerCase() ?? '';
              final resultTrack = _cleanTitle(
                result['trackName'] as String? ?? '',
              ).toLowerCase();

              final artistMatch =
                  resultArtist.contains(inputArtist) ||
                  inputArtist.contains(resultArtist);
              // Allow fuzzy match for song title too? Or contains?
              final songMatch =
                  resultTrack.contains(inputSong) ||
                  inputSong.contains(resultTrack);

              if (artistMatch && songMatch) {
                return result; // This track result contains collectionName, collectionId etc.
              }
            }
          } else {
            // Album search logic (previous logic)
            final inputAlbum = widget.albumName.toLowerCase();
            for (var result in results) {
              final resultArtist =
                  (result['artistName'] as String?)?.toLowerCase() ?? '';
              final resultAlbum =
                  (result['collectionName'] as String?)?.toLowerCase() ?? '';

              final artistMatch =
                  resultArtist.contains(inputArtist) ||
                  inputArtist.contains(resultArtist);
              final albumMatch =
                  resultAlbum.contains(inputAlbum) ||
                  inputAlbum.contains(resultAlbum);

              if (artistMatch && albumMatch) {
                return result;
              }
            }
          }

          // Fallback: Return first result if no strict match
          // But for song search, if we didn't find the song, the first result might be wrong.
          // However, usually it's the best guess.
          return results[0];
        }
      }
    } catch (e) {
      developer.log("Error fetching album info: $e");
    }
    return null;
  }

  String _cleanArtistName(String name) {
    String cleaned = name;
    // Remove content after dot
    if (cleaned.contains('.')) {
      cleaned = cleaned.split('.').first;
    }
    // Remove content after bullet (•) which appears as %E2%80%A2 in URLs
    if (cleaned.contains('•')) {
      cleaned = cleaned.split('•').first;
    }
    return _cleanTitle(cleaned);
  }

  String _cleanTitle(String title) {
    // Remove text in parentheses and brackets/braces
    // e.g. "Song Name (feat. Artist)" -> "Song Name"
    // e.g. "Song Name [Remix]" -> "Song Name"
    // Use regex to match (...) or [...] non-greedily
    return title.replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '').trim();
  }

  Future<List<Map<String, dynamic>>> _fetchTracks(int collectionId) async {
    try {
      // Add limit=200 to ensure we get all tracks for large albums/compilations
      final uri = Uri.parse(
        "https://itunes.apple.com/lookup?id=$collectionId&entity=song&limit=200",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // The first result is the collection itself, the rest are songs
        final results = List<Map<String, dynamic>>.from(data['results']);

        var tracks = results
            .where((item) => item['wrapperType'] == 'track')
            .toList();

        // Sort by Disc Number then Track Number
        tracks.sort((a, b) {
          int discA = a['discNumber'] ?? 1;
          int discB = b['discNumber'] ?? 1;
          if (discA != discB) return discA.compareTo(discB);

          int trackA = a['trackNumber'] ?? 0;
          int trackB = b['trackNumber'] ?? 0;
          return trackA.compareTo(trackB);
        });

        _cachedTracks = tracks;
        return tracks;
      }
    } catch (e) {
      developer.log("Error fetching tracks: $e");
    }
    return [];
  }

  // --- Playback & Playlist Helpers ---

  void _playTrack(int index) {
    if (_cachedTracks == null || _cachedTracks!.isEmpty) return;
    final provider = Provider.of<RadioProvider>(context, listen: false);

    // Convert to SavedSong
    final songs = _convertToSavedSongs();
    final song = songs[index];
    final playlistId = 'album_${widget.albumName.hashCode}';

    if (provider.currentPlayingPlaylistId == playlistId) {
      provider.playPlaylistSong(song, playlistId);
    } else {
      final tempPlaylist = Playlist(
        id: playlistId,
        name: widget.albumName,
        songs: songs,
        createdAt: DateTime.now(),
      );
      provider.playAdHocPlaylist(tempPlaylist, song.id);
    }
  }

  void _playRandom() {
    if (_cachedTracks == null || _cachedTracks!.isEmpty) return;
    final provider = Provider.of<RadioProvider>(context, listen: false);

    final songs = _convertToSavedSongs();
    songs.shuffle();

    final tempPlaylist = Playlist(
      id: 'album_${widget.albumName.hashCode}',
      name: widget.albumName,
      songs: songs,
      createdAt: DateTime.now(),
    );

    provider.playAdHocPlaylist(tempPlaylist, null);
  }

  List<SavedSong> _convertToSavedSongs() {
    if (_cachedTracks == null) return [];
    return _cachedTracks!.map((t) => _trackToSavedSong(t)).toList();
  }

  SavedSong _trackToSavedSong(Map<String, dynamic> track) {
    // If api lookup hasn't happened yet, we might miss artist/album names in 'track' map for simple tracks
    // But _fetchTracks returns full objects from lookup entity=song
    final trackArtist = track['artistName'] ?? widget.artistName;
    final trackName = track['trackName'] ?? "Unknown Track";
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Fallback image
    final String displayImage = widget.artworkUrl ?? "";

    // Find best distinct image
    String art =
        track['artworkUrl100']?.replaceAll('100x100bb', '600x600bb') ??
        displayImage;

    return SavedSong(
      id:
          track['trackId']?.toString() ??
          "${timestamp}_${track['trackNumber'] ?? 0}",
      title: trackName,
      artist: trackArtist,
      album: widget.albumName,
      artUri: art,
      appleMusicUrl: track['trackViewUrl'],
      dateAdded: DateTime.now(),
      releaseDate: track['releaseDate'],
    );
  }

  void _showCopyDialog() {
    if (_cachedTracks == null || _cachedTracks!.isEmpty) {
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
            "Copy Album",
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

                final provider = Provider.of<RadioProvider>(
                  context,
                  listen: false,
                );
                final songs = _convertToSavedSongs();
                final newPlaylist = await provider.createPlaylist(
                  name,
                  songs: songs,
                );
                provider.resolvePlaylistLinksInBackground(
                  newPlaylist.id,
                  songs,
                );

                if (mounted) {
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
    provider.resolvePlaylistLinksInBackground(playlistId, songs);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Copied ${songs.length} songs!")));
    }
  }

  void _showAddSongDialog(SavedSong song) {
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
                          onTap: () async {
                            Navigator.pop(context);
                            // Inline creation for single song to save space
                            final controller = TextEditingController();
                            await showDialog(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text("New Playlist"),
                                content: TextField(
                                  controller: controller,
                                  autofocus: true,
                                  decoration: const InputDecoration(
                                    labelText: "Name",
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c),
                                    child: const Text("Cancel"),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      if (controller.text.isNotEmpty) {
                                        Navigator.pop(c);
                                        final np = await provider
                                            .createPlaylist(
                                              controller.text,
                                              songs: [song],
                                            );
                                        provider
                                            .resolvePlaylistLinksInBackground(
                                              np.id,
                                              [song],
                                            );
                                        if (mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text("Added!"),
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    child: const Text("Create"),
                                  ),
                                ],
                              ),
                            );
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
                        onTap: () async {
                          Navigator.pop(ctx);
                          await provider.addSongToPlaylist(p.id, song);
                          provider.resolvePlaylistLinksInBackground(p.id, [
                            song,
                          ]);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Added!")),
                            );
                          }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _albumInfoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final albumData = snapshot.data;

          // Fallback image if API fails
          final String displayImage =
              albumData?['artworkUrl100']?.replaceAll(
                '100x100bb',
                '600x600bb',
              ) ??
              widget.artworkUrl ??
              "";

          final String displayName =
              albumData?['collectionName'] ?? widget.albumName;
          final String displayArtist =
              albumData?['artistName'] ?? widget.artistName;
          final String? genre = albumData?['primaryGenreName'];
          final String? copyright = albumData?['copyright'];

          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. Background Image
              if (displayImage.isNotEmpty)
                Image.network(
                  displayImage,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Container(color: Colors.grey[900]),
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
                      Colors.black.withValues(alpha: 0.6),
                      Colors.black.withValues(alpha: 0.9),
                      Colors.black,
                    ],
                  ),
                ),
              ),

              // 4. Content
              // 4. Content (with bottom padding for banner)
              Positioned.fill(
                child: CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
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
                            // Album Art Shadowed
                            Container(
                              width: 200,
                              height: 200,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.5),
                                    blurRadius: 30,
                                    offset: const Offset(0, 15),
                                  ),
                                ],
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: displayImage.isNotEmpty
                                  ? Image.network(
                                      displayImage,
                                      fit: BoxFit.cover,
                                    )
                                  : const Center(
                                      child: Icon(
                                        Icons.album,
                                        size: 80,
                                        color: Colors.white54,
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              displayName,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      GestureDetector(
                                        onTap: () {
                                          // Take the first artist if multiple are listed
                                          String firstArtist = displayArtist;
                                          // Split by common separators: , & / Ft. Feat. Vs.
                                          final separators = [
                                            ',',
                                            '&',
                                            '/',
                                            ' ft.',
                                            ' feat.',
                                            ' vs.',
                                            ' Ft.',
                                            ' Feat.',
                                            ' Vs.',
                                            ' • ',
                                          ];
                                          for (final sep in separators) {
                                            if (firstArtist.contains(sep)) {
                                              firstArtist = firstArtist
                                                  .split(sep)
                                                  .first;
                                            }
                                          }
                                          firstArtist = firstArtist.trim();

                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  ArtistDetailsScreen(
                                                    artistName: firstArtist,
                                                    // Optional: Pass genre if available
                                                    genre: genre,
                                                    fallbackImage: displayImage,
                                                  ),
                                            ),
                                          );
                                        },
                                        child: Text(
                                          displayArtist,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 18,
                                            decoration:
                                                TextDecoration.underline,
                                            decorationColor: Colors.white30,
                                          ),
                                        ),
                                      ),
                                      Builder(
                                        builder: (context) {
                                          final releaseDate =
                                              albumData?['releaseDate']
                                                  as String?;
                                          String? year;
                                          if (releaseDate != null) {
                                            try {
                                              year = DateTime.parse(
                                                releaseDate,
                                              ).year.toString();
                                            } catch (_) {}
                                          }

                                          return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              if (genre != null) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  genre,
                                                  style: TextStyle(
                                                    color: Theme.of(
                                                      context,
                                                    ).primaryColor,
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ],
                                              if (year != null) ...[
                                                const SizedBox(height: 2),
                                                Text(
                                                  year,
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.5),
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),

                            // 3. Action Buttons
                            if (albumData != null) ...[
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // Shuffle Play
                                  ElevatedButton.icon(
                                    onPressed: _playRandom,
                                    icon: Icon(
                                      Icons.shuffle,
                                      color:
                                          Theme.of(context).primaryColor
                                                  .computeLuminance() >
                                              0.5
                                          ? Colors.black
                                          : Colors.white,
                                    ),
                                    label: Text(
                                      "Shuffle Play",
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).primaryColor
                                                    .computeLuminance() >
                                                0.5
                                            ? Colors.black
                                            : Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Theme.of(
                                        context,
                                      ).primaryColor,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(25),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                        vertical: 12,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  // Stop
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.1,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.stop,
                                        color: Colors.white,
                                      ),
                                      onPressed: () {
                                        Provider.of<RadioProvider>(
                                          context,
                                          listen: false,
                                        ).stop();
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  // Copy List
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.1,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.copy,
                                        color: Colors.white,
                                      ),
                                      onPressed: _showCopyDialog,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    // Tracks List
                    if (albumData != null)
                      FutureBuilder<List<Map<String, dynamic>>>(
                        future: _tracksFuture ??= _fetchTracks(
                          albumData['collectionId'],
                        ),
                        builder: (context, trackSnap) {
                          if (trackSnap.connectionState ==
                              ConnectionState.waiting) {
                            return const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(32),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            );
                          }

                          final tracks = trackSnap.data ?? [];
                          if (tracks.isEmpty) {
                            return const SliverToBoxAdapter(
                              child: Center(
                                child: Text(
                                  "No tracks available",
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ),
                            );
                          }

                          return Consumer<RadioProvider>(
                            builder: (context, provider, child) {
                              final currentMediaItem =
                                  provider.audioHandler.mediaItem.value;
                              final playingSongId =
                                  currentMediaItem?.extras?['songId'];
                              final theme = Theme.of(context);
                              final savedSongs = provider.allUniqueSongs;

                              return SliverList(
                                delegate: SliverChildBuilderDelegate((
                                  innerContext,
                                  index,
                                ) {
                                  final track = tracks[index];
                                  final trackName =
                                      track['trackName'] ?? "Unknown Track";
                                  final trackArtist =
                                      track['artistName'] ?? displayArtist;
                                  final trackId = track['trackId']?.toString();

                                  final isPlaying =
                                      playingSongId != null &&
                                      trackId != null &&
                                      playingSongId == trackId;

                                  final isContextTrack =
                                      widget.songName != null &&
                                      _cleanTitle(trackName).toLowerCase() ==
                                          _cleanTitle(
                                            widget.songName!,
                                          ).toLowerCase();

                                  // Check if song is already saved
                                  bool isSaved = false;
                                  if (trackId != null) {
                                    isSaved = savedSongs.any(
                                      (s) => s.id == trackId,
                                    );
                                  }

                                  if (!isSaved) {
                                    // Fallback to name match for safety
                                    final cleanT = _cleanTitle(
                                      trackName,
                                    ).toLowerCase();
                                    final cleanA = _cleanArtistName(
                                      trackArtist,
                                    ).toLowerCase();
                                    isSaved = savedSongs.any(
                                      (s) =>
                                          _cleanTitle(s.title).toLowerCase() ==
                                              cleanT &&
                                          _cleanArtistName(
                                                s.artist,
                                              ).toLowerCase() ==
                                              cleanA,
                                    );
                                  }

                                  return Container(
                                    color: isPlaying
                                        ? Colors.white.withValues(alpha: 0.1)
                                        : Colors.transparent,
                                    child: ListTile(
                                      leading: Text(
                                        "${track['trackNumber'] ?? index + 1}",
                                        style: TextStyle(
                                          color: isPlaying
                                              ? Colors.white
                                              : Colors.white54,
                                          fontWeight:
                                              isPlaying || isContextTrack
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      title: Text(
                                        trackName,
                                        style: TextStyle(
                                          color: isPlaying
                                              ? theme.primaryColor
                                              : (isContextTrack
                                                    ? Colors.redAccent
                                                    : Colors.white),
                                          fontWeight:
                                              isPlaying || isContextTrack
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      subtitle: Text(
                                        trackArtist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isPlaying)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                right: 8.0,
                                              ),
                                              child: Icon(
                                                Icons.equalizer,
                                                color: theme.primaryColor,
                                                size: 20,
                                              ),
                                            ),
                                          if (track['trackTimeMillis'] != null)
                                            Text(
                                              _formatDuration(
                                                track['trackTimeMillis'],
                                              ),
                                              style: const TextStyle(
                                                color: Colors.white38,
                                                fontSize: 12,
                                              ),
                                            ),
                                          const SizedBox(width: 8),
                                          IconButton(
                                            icon: Icon(
                                              isSaved
                                                  ? Icons.check_circle
                                                  : Icons.add_circle_outline,
                                              color: isSaved
                                                  ? theme.primaryColor
                                                  : Colors.white54,
                                              size: 24,
                                            ),
                                            onPressed: () {
                                              final song = _trackToSavedSong(
                                                track,
                                              );
                                              _showAddSongDialog(song);
                                            },
                                          ),
                                        ],
                                      ),
                                      onTap: () => _playTrack(index),
                                    ),
                                  );
                                }, childCount: tracks.length),
                              );
                            },
                          );
                        },
                      )
                    else
                      const SliverToBoxAdapter(child: SizedBox.shrink()),

                    // Copyright / Footer
                    if (copyright != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Text(
                            copyright,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white30,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),

                    // Bottom Padding
                  ],
                ),
              ), // End Positioned.fill
              // 5. Back Button (Fixed)
              Positioned(
                top: 0,
                left: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: CircleAvatar(
                      backgroundColor: Colors.black.withValues(alpha: 0.5),
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
          );
        },
      ),
      bottomNavigationBar: const PlayerBar(),
    );
  }

  String _formatDuration(int millis) {
    final duration = Duration(milliseconds: millis);
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  String? _extractAlbumId(String url) {
    try {
      // Common pattern: .../album/album-name/id...
      // e.g. https://music.apple.com/us/album/hybrid-theory/528436018
      final regex = RegExp(r'\/album\/[^\/]+\/(\d+)');
      final match = regex.firstMatch(url);
      if (match != null) {
        return match.group(1);
      }

      // Check for simple .../album/id... format just in case
      final simpleRegex = RegExp(r'\/album\/(\d+)');
      final simpleMatch = simpleRegex.firstMatch(url);
      if (simpleMatch != null) {
        return simpleMatch.group(1);
      }
    } catch (e) {
      developer.log("Error extracting album ID: $e");
    }
    return null;
  }
}
