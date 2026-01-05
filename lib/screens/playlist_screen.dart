import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Playlist;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/radio_provider.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import '../services/backup_service.dart';
import 'album_details_screen.dart';
import 'artist_details_screen.dart';
import '../widgets/youtube_popup.dart';
import '../utils/genre_mapper.dart';
import '../services/music_metadata_service.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'playlist_screen_duplicates_logic.dart';

enum MetadataViewMode { playlists, artists, albums }

enum PlaylistSortMode { custom, alphabetical }

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
  PlaylistSortMode _sortMode = PlaylistSortMode.custom;
  bool _isBulkChecking = false;
  bool _showOnlyInvalid = false;
  bool _showFollowedArtistsOnly = false;
  bool _showFollowedAlbumsOnly = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Scrolling
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  String? _lastScrolledSongId; // To prevent scroll loops

  // Category Scrolling
  final ScrollController _playlistsScrollController = ScrollController();
  final ScrollController _artistsScrollController = ScrollController();
  final ScrollController _albumsScrollController = ScrollController();
  String? _lastScrolledCategoryItem; // To prevent scroll loops in category view

  // --- Getters for Selection State ---

  bool get isSelectionActive =>
      _selectedPlaylistId != null ||
      _selectedArtist != null ||
      _selectedAlbum != null;

  String get headerTitle {
    if (_selectedPlaylistId != null) {
      final provider = Provider.of<RadioProvider>(context, listen: false);
      try {
        return provider.playlists
            .firstWhere((p) => p.id == _selectedPlaylistId)
            .name;
      } catch (_) {
        return "Playlist";
      }
    }
    if (_selectedArtist != null) {
      return _selectedArtistDisplay ?? _selectedArtist!;
    }
    if (_selectedAlbum != null) {
      return _selectedAlbumDisplay ?? _selectedAlbum!;
    }
    return "Library";
  }

  /// Helper to access all songs across playlists (for creating ad-hoc playlists)
  List<SavedSong> get _allSongs {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final Set<String> uniqueIds = {};
    final List<SavedSong> songs = [];
    for (var playlist in provider.playlists) {
      for (var song in playlist.songs) {
        if (uniqueIds.add(song.id)) {
          songs.add(song);
        }
      }
    }
    return songs;
  }

  Playlist? get effectivePlaylist => _getEffectivePlaylist(applyFilter: true);
  Playlist? get rawEffectivePlaylist =>
      _getEffectivePlaylist(applyFilter: false);

  Playlist? _getEffectivePlaylist({required bool applyFilter}) {
    final provider = Provider.of<RadioProvider>(context, listen: false);

    Playlist? playlist;
    if (_selectedPlaylistId != null) {
      try {
        playlist = provider.playlists.firstWhere(
          (p) => p.id == _selectedPlaylistId,
        );
      } catch (_) {
        // Fallback if playlist not found
        playlist = Playlist(
          id: 'error',
          name: 'Error',
          songs: [],
          createdAt: DateTime.now(),
        );
      }
    } else if (_selectedArtist != null) {
      final songs = _allSongs.where((s) {
        if (_selectedArtistIsGroup) {
          // Normalize to match grouping logic
          String norm = s.artist
              .split('•')
              .first
              .trim()
              .split(RegExp(r'[,&/]'))
              .first
              .trim()
              .toLowerCase();
          return norm == _selectedArtist;
        }
        return s.artist == _selectedArtist;
      }).toList();

      playlist = Playlist(
        id: 'temp_artist_$_selectedArtist',
        name: _selectedArtistDisplay ?? _selectedArtist!,
        songs: songs,
        createdAt: DateTime.now(),
      );
    } else if (_selectedAlbum != null) {
      final songs = _allSongs.where((s) {
        if (_selectedAlbumIsGroup) {
          // Normalize to match grouping logic
          String norm = s.album
              .split('(')
              .first
              .trim()
              .split('[')
              .first
              .trim()
              .toLowerCase();
          return norm == _selectedAlbum;
        }
        return s.album == _selectedAlbum;
      }).toList();

      playlist = Playlist(
        id: 'temp_album_$_selectedAlbum',
        name: _selectedAlbumDisplay ?? _selectedAlbum!,
        songs: songs,
        createdAt: DateTime.now(),
      );
    }

    if (playlist == null) return null;

    if (applyFilter && _showOnlyInvalid) {
      final filteredSongs = playlist.songs
          .where((s) => !s.isValid || provider.invalidSongIds.contains(s.id))
          .toList();
      return Playlist(
        id: playlist.id,
        name: playlist.name,
        songs: filteredSongs,
        createdAt: playlist.createdAt,
      );
    }

    return playlist;
  }

  List<SavedSong> get currentSongList => effectivePlaylist?.songs ?? [];

  @override
  void initState() {
    super.initState();
    _loadFilterState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
  }

  Future<void> _loadFilterState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showFollowedArtistsOnly =
          prefs.getBool('filter_followed_artists') ?? false;
      _showFollowedAlbumsOnly =
          prefs.getBool('filter_followed_albums') ?? false;
    });
  }

  Future<void> _persistArtistFilter(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('filter_followed_artists', value);
  }

  Future<void> _persistAlbumFilter(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('filter_followed_albums', value);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _playlistsScrollController.dispose();
    _artistsScrollController.dispose();
    _albumsScrollController.dispose();
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

    _unlockTimer = Timer(const Duration(milliseconds: 1500), () async {
      await provider.unmarkSongAsInvalid(song.id, playlistId: playlistId);
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Song unlocked!")));
        HapticFeedback.mediumImpact();
      }
    });
  }

  void _showInvalidTrackOptions(
    BuildContext context,
    RadioProvider provider,
    SavedSong song,
    String playlistId,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                    size: 40,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "Track Problematic",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.title,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white10),
            ListTile(
              leading: const Icon(Icons.refresh_rounded, color: Colors.green),
              title: const Text(
                "Try Again & Unlock",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _testAndUnlockTrack(context, provider, song, playlistId);
              },
            ),
            ListTile(
              leading: const Icon(
                FontAwesomeIcons.youtube,
                color: Color(0xFFFF0000),
                size: 18,
              ),
              title: const Text(
                "Search on YouTube",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showYouTubeSearch(context, provider, song);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline, color: Colors.blueAccent),
              title: const Text(
                "View Song Details",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showSongDetailsDialog(context, song);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: Colors.redAccent,
              ),
              title: const Text(
                "Remove from Library",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF222222),
                    title: const Text(
                      "Remove Song",
                      style: TextStyle(color: Colors.white),
                    ),
                    content: const Text(
                      "Remove this song from your library permanently?",
                      style: TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text("Cancel"),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          "Remove",
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  provider.removeSongFromLibrary(song.id);
                }
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _showYouTubeSearch(
    BuildContext context,
    RadioProvider provider,
    SavedSong song,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: Colors.redAccent),
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
          .timeout(const Duration(seconds: 10));

      var url = links['youtube'] ?? song.youtubeUrl;

      // FALLBACK: If SongLink API found nothing, use internal YouTube search engine
      if (url == null || url.contains('search_query')) {
        final yt = YoutubeExplode();
        try {
          final query = "${song.title} ${song.artist.split('•').first.trim()}";
          final searchList = await yt.search.search(query);
          if (searchList.isNotEmpty) {
            url = searchList.first.url;
          }
        } catch (_) {
          // ignore search errors
        } finally {
          yt.close();
        }
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      if (url != null) {
        var videoId = YoutubePlayer.convertUrlToId(url);
        if (videoId == null && url.length == 11) videoId = url;

        if (videoId != null) {
          final String vid = videoId;
          provider.pause();
          showDialog(
            context: context,
            builder: (_) => YouTubePopup(
              videoId: vid,
              songName: song.title,
              artistName: song.artist,
              albumName: song.album,
              artworkUrl: song.artUri,
            ),
          );
        } else {
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No YouTube results found")),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    }
  }

  Future<void> _testAndUnlockTrack(
    BuildContext context,
    RadioProvider provider,
    SavedSong song,
    String playlistId,
  ) async {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Testing track...")));

    try {
      final verifySuccess = await _verifyTrack(provider, song);

      if (verifySuccess) {
        await provider.unmarkSongAsInvalid(song.id, playlistId: playlistId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Success! Track verified and unlocked."),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Verification failed: Link still problematic."),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Test failed. Keeping as invalid.")),
        );
      }
    }
  }

  Future<bool> _verifyTrack(RadioProvider provider, SavedSong song) async {
    try {
      final links = await provider
          .resolveLinks(
            title: song.title,
            artist: song.artist,
            spotifyUrl: song.spotifyUrl,
            youtubeUrl: song.youtubeUrl,
          )
          .timeout(const Duration(seconds: 10));

      final candidateUrl = links['youtube'] ?? song.youtubeUrl;
      if (candidateUrl != null) {
        var videoId = YoutubePlayer.convertUrlToId(candidateUrl);
        if (videoId == null && candidateUrl.length == 11)
          videoId = candidateUrl;

        if (videoId != null) {
          final yt = YoutubeExplode();
          try {
            await yt.videos.get(videoId).timeout(const Duration(seconds: 10));
            return true;
          } catch (_) {
            return false;
          } finally {
            yt.close();
          }
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _processAllInvalidTracks(
    RadioProvider provider,
    List<SavedSong> songs,
    String? playlistId,
  ) async {
    final invalidSongs = songs.where((s) {
      return !s.isValid || provider.invalidSongIds.contains(s.id);
    }).toList();

    if (invalidSongs.isEmpty) return;

    setState(() => _isBulkChecking = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Checking ${invalidSongs.length} invalid tracks..."),
      ),
    );

    int unlockedCount = 0;
    for (var song in invalidSongs) {
      if (!mounted) break;
      final success = await _verifyTrack(provider, song);
      if (success) {
        await provider.unmarkSongAsInvalid(song.id, playlistId: playlistId);
        unlockedCount++;
      }
    }

    if (mounted) {
      setState(() {
        _isBulkChecking = false;
        if (unlockedCount == invalidSongs.length) {
          _showOnlyInvalid = false;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Bulk Check Completed: $unlockedCount tracks fixed/unlocked.",
          ),
        ),
      );
    }
  }

  void _showSongDetailsDialog(BuildContext context, SavedSong song) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          "Song Details",
          style: TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailItem("Title", song.title),
              _detailItem("Artist", song.artist),
              _detailItem("Album", song.album),
              _detailItem("ID", song.id),
              _detailItem("Date Added", song.dateAdded.toString()),
              if (song.youtubeUrl != null)
                _detailItem("YouTube URL", song.youtubeUrl!),
              if (song.spotifyUrl != null)
                _detailItem("Spotify URL", song.spotifyUrl!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close", style: TextStyle(color: Colors.blue)),
          ),
        ],
      ),
    );
  }

  Widget _detailItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    );
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
    // Use filtered playlists as the source of truth for the list view
    final allPlaylists = provider.filteredPlaylists;

    // Aggregate all songs from all playlists (deduplicated by ID) for "All Songs" views
    final Set<String> uniqueIds = {};
    final List<SavedSong> allSongs = [];
    for (var playlist in provider.playlists) {
      for (var song in playlist.songs) {
        if (uniqueIds.add(song.id)) {
          allSongs.add(song);
        }
      }
    }

    // Use rawEffectivePlaylist to check for invalid songs so the menu option
    // remains visible even if the current filtered view is empty (preventing "trap").
    final rawPlaylist = rawEffectivePlaylist;
    final hasInvalidSongs =
        rawPlaylist?.songs.any(
          (s) => !s.isValid || provider.invalidSongIds.contains(s.id),
        ) ??
        false;

    final currentSongs = currentSongList;

    // 4. Filter Playlists by Search (only if view mode is playlists and no selection)
    // NOTE: We use the natural order from provider (User Defined) for playlists
    // 4. Filter Playlists by Search (only if view mode is playlists and no selection)
    // NOTE: sorting alphabetically as requested
    // 4. Filter Playlists by Search
    // 4. Filter Playlists by Search or Sort
    List<Playlist> displayPlaylists;
    if (_searchQuery.isNotEmpty) {
      displayPlaylists = allPlaylists
          .where((p) => p.name.toLowerCase().contains(_searchQuery))
          .toList();
      // Always sort search results alphabetically for easier finding
      displayPlaylists.sort((a, b) {
        if (a.id == 'favorites') return -1;
        if (b.id == 'favorites') return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    } else {
      if (_sortMode == PlaylistSortMode.alphabetical) {
        displayPlaylists = List<Playlist>.from(allPlaylists)
          ..sort((a, b) {
            if (a.id == 'favorites') return -1;
            if (b.id == 'favorites') return 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
      } else {
        // Custom order (Manual)
        // Ensure Favorites is visually first if manual order gets messed up,
        // but typically provider order handles this naturally if favorites is index 0.
        // We trust the provider list order for Custom, assuming Favorites is kept at top there.
        displayPlaylists = allPlaylists;
      }
    }

    // Helper for Mode Button
    Widget buildModeBtn(String title, MetadataViewMode mode) {
      final bool selected = _viewMode == mode;
      return GestureDetector(
        onTap: () {
          setState(() {
            _viewMode = mode;
            _searchController.clear();
            _lastScrolledSongId = null;
            _lastScrolledCategoryItem = null;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).primaryColor
                : Colors.white.withOpacity(0.1),
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
            color: Colors.black.withOpacity(0.2),
            borderRadius: BorderRadius.circular(0),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              // Custom Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(0),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        if (isSelectionActive)
                          IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new_rounded),
                            color: Colors.white,
                            onPressed: () {
                              FocusManager.instance.primaryFocus?.unfocus();
                              setState(() {
                                _selectedPlaylistId = null;
                                _selectedArtist = null;
                                _selectedAlbum = null;
                                _searchController.clear();
                                _lastScrolledSongId = null;
                              });
                            },
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Icon(
                              _viewMode == MetadataViewMode.artists
                                  ? Icons.people
                                  : _viewMode == MetadataViewMode.albums
                                  ? Icons.album
                                  : Icons.collections_bookmark_rounded,
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
                        if (hasInvalidSongs || _showOnlyInvalid)
                          if (!_isBulkChecking)
                            Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: Tooltip(
                                message: _showOnlyInvalid
                                    ? "Show All Songs"
                                    : "Show Invalid Only",
                                child: IconButton(
                                  icon: Icon(
                                    _showOnlyInvalid
                                        ? Icons.warning_rounded
                                        : Icons.warning_amber_rounded,
                                    color: Colors.orangeAccent,
                                    size: 20,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: _showOnlyInvalid
                                        ? Colors.orangeAccent.withOpacity(0.15)
                                        : null,
                                    padding: const EdgeInsets.all(8),
                                    minimumSize: const Size(36, 36),
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _showOnlyInvalid = !_showOnlyInvalid;
                                    });
                                  },
                                ),
                              ),
                            ),
                        if (isSelectionActive) ...[
                          if (_isBulkChecking)
                            const Padding(
                              padding: EdgeInsets.only(right: 16.0),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.greenAccent,
                                ),
                              ),
                            ),
                          IconButton(
                            icon: const Icon(
                              Icons.playlist_play_rounded,
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
                          PopupMenuButton<String>(
                            icon: const Icon(
                              Icons.more_vert_rounded,
                              color: Colors.white,
                            ),
                            tooltip: "Options",
                            onSelected: (value) {
                              if (value == 'shuffle') {
                                provider.toggleShuffle();
                              } else if (value == 'duplicates') {
                                scanForDuplicates(
                                  context,
                                  provider,
                                  effectivePlaylist!,
                                );
                              } else if (value == 'bulk_check') {
                                _processAllInvalidTracks(
                                  provider,
                                  currentSongs,
                                  _selectedPlaylistId,
                                );
                              }
                            },
                            itemBuilder: (context) {
                              return [
                                PopupMenuItem(
                                  value: 'shuffle',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.shuffle_rounded,
                                        color: provider.isShuffleMode
                                            ? Colors.redAccent
                                            : Colors.grey,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        "Shuffle",
                                        style: TextStyle(
                                          color: provider.isShuffleMode
                                              ? Colors.redAccent
                                              : Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_selectedPlaylistId != null)
                                  const PopupMenuItem(
                                    value: 'duplicates',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.cleaning_services_rounded,
                                          color: Colors.white,
                                        ),
                                        SizedBox(width: 12),
                                        Text(
                                          "Scan Duplicates",
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (hasInvalidSongs || _showOnlyInvalid) ...[
                                  if (hasInvalidSongs)
                                    PopupMenuItem(
                                      value: 'bulk_check',
                                      enabled: !_isBulkChecking,
                                      child: Row(
                                        children: [
                                          if (_isBulkChecking)
                                            const SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          else
                                            const Icon(
                                              Icons
                                                  .playlist_add_check_circle_rounded,
                                              color: Colors.greenAccent,
                                            ),
                                          const SizedBox(width: 12),
                                          Text(
                                            _isBulkChecking
                                                ? "Processing..."
                                                : "Try Again & Unlock All",
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ];
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
                          if (_viewMode == MetadataViewMode.playlists) ...[
                            IconButton(
                              onPressed: () {
                                setState(() {
                                  if (_sortMode == PlaylistSortMode.custom) {
                                    _sortMode = PlaylistSortMode.alphabetical;
                                  } else {
                                    _sortMode = PlaylistSortMode.custom;
                                  }
                                });
                              },
                              icon: Icon(
                                _sortMode == PlaylistSortMode.custom
                                    ? Icons.sort
                                    : Icons.sort_by_alpha,
                              ),
                              tooltip: _sortMode == PlaylistSortMode.custom
                                  ? "Custom Order (Drag to Reorder)"
                                  : "Alphabetical Order",
                              color: Colors.white,
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
                            // Filter Button
                            IconButton(
                              icon: Icon(
                                provider.playlistCreatorFilter.isEmpty
                                    ? Icons.filter_list_off_rounded
                                    : Icons.filter_list_alt,
                                color: provider.playlistCreatorFilter.isEmpty
                                    ? Colors.white54
                                    : Theme.of(context).primaryColor,
                              ),
                              tooltip: "Filter Playlists",
                              onPressed: () =>
                                  _showFilterDialog(context, provider),
                            ),
                          ],
                          if (_viewMode == MetadataViewMode.artists)
                            IconButton(
                              icon: Icon(
                                _showFollowedArtistsOnly
                                    ? Icons.how_to_reg
                                    : Icons.person_add_alt,
                                color: _showFollowedArtistsOnly
                                    ? Colors.greenAccent
                                    : Colors.white,
                                size: 24,
                              ),
                              tooltip: _showFollowedArtistsOnly
                                  ? "Show All Artists"
                                  : "Show Followed Only",
                              onPressed: () {
                                setState(() {
                                  _showFollowedArtistsOnly =
                                      !_showFollowedArtistsOnly;
                                });
                                _persistArtistFilter(_showFollowedArtistsOnly);
                              },
                            ),
                          if (_viewMode == MetadataViewMode.albums)
                            IconButton(
                              icon: Icon(
                                _showFollowedAlbumsOnly
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                color: _showFollowedAlbumsOnly
                                    ? Colors.greenAccent
                                    : Colors.white,
                                size: 24,
                              ),
                              tooltip: _showFollowedAlbumsOnly
                                  ? "Show All Albums"
                                  : "Show Bookmarked Only",
                              onPressed: () {
                                setState(() {
                                  _showFollowedAlbumsOnly =
                                      !_showFollowedAlbumsOnly;
                                });
                                _persistAlbumFilter(_showFollowedAlbumsOnly);
                              },
                            ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                    if (!isSelectionActive)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8.0,
                          vertical: 2.0,
                        ),
                        child: Row(
                          children: [
                            buildModeBtn(
                              "Playlist",
                              MetadataViewMode.playlists,
                            ),
                            const SizedBox(width: 8),
                            buildModeBtn("Artists", MetadataViewMode.artists),
                            const SizedBox(width: 8),
                            buildModeBtn("Albums", MetadataViewMode.albums),
                            const SizedBox(width: 8),
                            // Search Bar
                            Expanded(
                              child: Container(
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).cardColor,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).dividerColor.withValues(alpha: 0.1),
                                  ),
                                ),
                                child: TextField(
                                  controller: _searchController,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium?.color,
                                    fontSize: 13,
                                  ),
                                  textAlignVertical: TextAlignVertical.center,
                                  decoration: InputDecoration(
                                    hintText: "Search...",
                                    hintStyle: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.color
                                          ?.withValues(alpha: 0.5),
                                      fontSize: 12,
                                    ),
                                    isDense: true,
                                    prefixIcon: Icon(
                                      Icons.search,
                                      color: Theme.of(
                                        context,
                                      ).iconTheme.color?.withValues(alpha: 0.5),
                                      size: 16,
                                    ),
                                    prefixIconConstraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    suffixIcon:
                                        _searchController.text.isNotEmpty
                                        ? IconButton(
                                            icon: Icon(
                                              Icons.close,
                                              color: Theme.of(context)
                                                  .iconTheme
                                                  .color
                                                  ?.withValues(alpha: 0.5),
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
                            ),
                          ],
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
                          _searchQuery.isEmpty
                              ? currentSongList
                              : currentSongList
                                    .where(
                                      (s) =>
                                          s.title.toLowerCase().contains(
                                            _searchQuery,
                                          ) ||
                                          s.artist.toLowerCase().contains(
                                            _searchQuery,
                                          ) ||
                                          s.album.toLowerCase().contains(
                                            _searchQuery,
                                          ),
                                    )
                                    .toList(),
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
                          controller: _playlistsScrollController,
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

    // Find playing index for auto-scroll
    int playingIndex = -1;
    for (int i = 0; i < playlists.length; i++) {
      final p = playlists[i];
      // Logic from card builder
      bool isPlaying = provider.currentPlayingPlaylistId == p.id;
      if (!isPlaying && p.songs.isNotEmpty) {
        isPlaying = p.songs.any(
          (s) =>
              provider.audioOnlySongId == s.id ||
              (s.title.trim().toLowerCase() ==
                      provider.currentTrack.trim().toLowerCase() &&
                  s.artist.trim().toLowerCase() ==
                      provider.currentArtist.trim().toLowerCase()),
        );
      }
      if (isPlaying) {
        playingIndex = i;
        break;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (playingIndex != -1) {
          final uniqueKey = "playlist_${playlists[playingIndex].id}";
          if (_lastScrolledCategoryItem != uniqueKey) {
            _lastScrolledCategoryItem = uniqueKey;
            // Calculate position
            final double width = constraints.maxWidth - 32; // minus padding
            final int crossAxisCount = (width / 200).ceil();
            final double itemWidth =
                (width - (crossAxisCount - 1) * 16) / crossAxisCount;
            final double rowHeight = itemWidth; // aspect ratio 1.0

            final int row = playingIndex ~/ crossAxisCount;
            final double offset = row * (rowHeight + 16); // + spacing

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_playlistsScrollController.hasClients) {
                _playlistsScrollController.animateTo(
                  offset,
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOut,
                );
              }
            });
          }
        }

        // If searching, OR if in alphabetical mode, use static GridView (no reorder)
        if (_searchQuery.isNotEmpty ||
            _sortMode == PlaylistSortMode.alphabetical) {
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
              // Pass null key for static view
              return _buildPlaylistCard(
                context,
                provider,
                playlists[index],
                null,
              );
            },
          );
        }

        return ReorderableGridView.builder(
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
            // Use ValueKey for reordering
            return _buildPlaylistCard(
              context,
              provider,
              playlist,
              ValueKey(playlist.id),
            );
          },
          onReorder: (oldIndex, newIndex) {
            // Prevent moving Favorites (Index 0)
            final bool isFavorites = playlists[oldIndex].id == 'favorites';
            if (isFavorites) return;

            // Prevent moving above Favorites (Index 0 assumption)
            if (newIndex == 0) newIndex = 1;

            provider.reorderPlaylists(oldIndex, newIndex);
          },
        );
      },
    );
  }

  Widget _buildPlaylistCard(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
    Key? key,
  ) {
    // Determine image
    String? bgImage;
    if (playlist.id == 'favorites') {
      bgImage = GenreMapper.getGenreImage("Favorites");
    } else {
      bgImage = GenreMapper.getGenreImage(playlist.name);
    }

    // Check if this playlist is currently playing
    bool isPlaylistPlaying = provider.currentPlayingPlaylistId == playlist.id;

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
      key: key,
      onTap: () {
        setState(() {
          _selectedPlaylistId = playlist.id;
          _searchController.clear();
          _lastScrolledSongId = null;
        });
      },
      // Long press is reserved for drag-and-drop
      borderRadius: BorderRadius.circular(16),
      child: Container(
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: isPlaylistPlaying
              ? Border.all(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.8),
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
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
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
                        color: Colors.black.withOpacity(0.6),
                        colorBlendMode: BlendMode.darken,
                        errorWidget: (context, url, error) {
                          return Container(
                            color: Colors.white.withOpacity(0.1),
                          );
                        },
                      )
                    : Image.asset(
                        bgImage,
                        fit: BoxFit.cover,
                        color: Colors.black.withOpacity(0.6),
                        colorBlendMode: BlendMode.darken,
                      ),
              ),
            Positioned(
              right: -10,
              bottom: -10,
              child: Icon(
                playlist.id == 'favorites'
                    ? Icons.favorite
                    : (playlist.id.startsWith('spotify_')
                          ? Icons.music_note
                          : Icons.music_note),
                size: 80,
                color: Colors.white.withOpacity(0.1),
              ),
            ),
            if (playlist.id.startsWith('spotify_'))
              const Positioned(
                top: 12,
                left: 12,
                child: FaIcon(
                  FontAwesomeIcons.spotify,
                  color: Color(0xFF1DB954),
                  size: 20,
                ),
              )
            else if (playlist.id == 'favorites' || playlist.creator == 'app')
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/icon.png',
                      width: 24,
                      height: 24,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              )
            else
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child:
                        Provider.of<BackupService>(
                              context,
                            ).currentUser?.photoUrl !=
                            null
                        ? Image.network(
                            Provider.of<BackupService>(
                              context,
                            ).currentUser!.photoUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey[800],
                              child: const Icon(
                                Icons.person,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          )
                        : Container(
                            color: Colors.grey[800],
                            child: const Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                  ),
                ),
              ),
            // MORE OPTIONS MENU
            if (playlist.id != 'favorites')
              Positioned(
                top: 0,
                right: 0,
                child: Material(
                  color: Colors.transparent,
                  child: PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      color: Colors.white60,
                      size: 20,
                    ),
                    color: const Color(0xFF1e1e24),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: Row(
                          children: [
                            Icon(Icons.edit, size: 18, color: Colors.white),
                            SizedBox(width: 8),
                            Text(
                              "Rename",
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Colors.redAccent,
                            ),
                            SizedBox(width: 8),
                            Text(
                              "Delete",
                              style: TextStyle(color: Colors.redAccent),
                            ),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'rename') {
                        _showRenamePlaylistDialog(context, provider, playlist);
                      } else if (value == 'delete') {
                        _showDeletePlaylistDialog(context, provider, playlist);
                      }
                    },
                  ),
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
                    playlist.name.replaceAll('Spotify: ', ''),
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
                      color: Colors.white.withOpacity(0.7),
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
  }

  void _showRenamePlaylistDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
  ) {
    if (playlist.id == 'favorites') return;

    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1e1e24),
        title: const Text(
          "Rename Playlist",
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
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.purpleAccent),
            ),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancel",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                provider.renamePlaylist(playlist.id, name);
                Navigator.pop(context);
              }
            },
            child: const Text(
              "Save",
              style: TextStyle(color: Colors.purpleAccent),
            ),
          ),
        ],
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context, RadioProvider provider) {
    final TextEditingController nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          "New Playlist",
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: "Playlist Name",
            labelStyle: TextStyle(color: Colors.white60),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF6c5ce7)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                provider.createPlaylist(nameController.text);
                Navigator.pop(ctx);
              }
            },
            child: const Text(
              "Create",
              style: TextStyle(color: Color(0xFF6c5ce7)),
            ),
          ),
        ],
      ),
    );
  }

  void _showFilterDialog(BuildContext context, RadioProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            final filters = provider.playlistCreatorFilter;
            final isApp = filters.contains('app');
            final isUser = filters.contains('user');
            final isSpotify = filters.contains('spotify');

            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              title: const Text(
                "Filter Playlists",
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    title: const Text(
                      "User Created",
                      style: TextStyle(color: Colors.white),
                    ),
                    activeColor: Theme.of(context).primaryColor,
                    value:
                        isUser ||
                        filters.isEmpty, // Show checked if empty (all)
                    onChanged: (val) {
                      provider.togglePlaylistCreatorFilter('user');
                      setState(() {});
                    },
                  ),
                  CheckboxListTile(
                    title: const Text(
                      "App Created (Favorites/Genres)",
                      style: TextStyle(color: Colors.white),
                    ),
                    activeColor: Theme.of(context).primaryColor,
                    value: isApp || filters.isEmpty,
                    onChanged: (val) {
                      provider.togglePlaylistCreatorFilter('app');
                      setState(() {});
                    },
                  ),
                  CheckboxListTile(
                    title: const Text(
                      "Spotify Imported",
                      style: TextStyle(color: Colors.white),
                    ),
                    activeColor: Theme.of(context).primaryColor,
                    value: isSpotify || filters.isEmpty,
                    onChanged: (val) {
                      provider.togglePlaylistCreatorFilter('spotify');
                      setState(() {});
                    },
                  ),
                  if (filters.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: TextButton(
                        onPressed: () {
                          provider.clearPlaylistCreatorFilter();
                          Navigator.pop(ctx);
                        },
                        child: const Text(
                          "Clear Filters (Show All)",
                          style: TextStyle(color: Colors.blueAccent),
                        ),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Done"),
                ),
              ],
            );
          },
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

    // Auto-Scroll Logic
    // Find if the currently playing song is in this list
    int scrollIndex = -1;
    String? foundSongId;

    for (int i = 0; i < groupedSongs.length; i++) {
      final group = groupedSongs[i];
      final match = group.firstWhere(
        (s) {
          final isPlaying =
              provider.audioOnlySongId == s.id ||
              (s.title.trim().toLowerCase() ==
                      provider.currentTrack.trim().toLowerCase() &&
                  s.artist.trim().toLowerCase() ==
                      provider.currentArtist.trim().toLowerCase());
          return isPlaying;
        },
        orElse: () => SavedSong(
          id: '',
          title: '',
          artist: '',
          album: '',
          dateAdded: DateTime.now(),
        ),
      );

      if (match.id.isNotEmpty) {
        scrollIndex = i;
        foundSongId = match.id;
        break;
      }
    }

    if (scrollIndex != -1 &&
        foundSongId != null &&
        foundSongId != _lastScrolledSongId) {
      _lastScrolledSongId = foundSongId;

      // Only scroll if we have enough items to warrant positioning
      // This prevents single items from being pushed down by alignment
      if (groupedSongs.length > 3) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_itemScrollController.isAttached) {
            _itemScrollController.scrollTo(
              index: scrollIndex,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOut,
              alignment: 0.3, // Top-third of screen
            );
          }
        });
      }
    }

    if (scrollIndex == -1) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: groupedSongs.length,
        itemBuilder: (context, index) {
          final group = groupedSongs[index];
          if (group.length == 1) {
            return _buildSongItem(context, provider, playlist, group.first);
          }
          return _buildAlbumGroup(context, provider, playlist, group);
        },
      );
    }

    return ScrollablePositionedList.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: groupedSongs.length,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
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
      showFavoritesButton: playlist.id != 'favorites',
      groupSongs: groupSongs,
      dismissDirection:
          (playlist.id.startsWith('temp_artist_') ||
              playlist.id.startsWith('temp_album_'))
          ? DismissDirection.none
          : (playlist.id == 'favorites'
                ? DismissDirection.endToStart
                : DismissDirection.horizontal),
      onMove: () async {
        final result = await _showCopyAlbumDialog(
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
    // Check if song is in favorites
    final favPlaylist = provider.playlists.firstWhere(
      (p) => p.id == 'favorites',
      orElse: () => Playlist(
        id: 'favorites',
        name: 'Favorites',
        songs: [],
        createdAt: DateTime.now(),
      ),
    );
    final isFavorite = favPlaylist.songs.any(
      (s) =>
          s.id == song.id || (s.title == song.title && s.artist == song.artist),
    );

    final isInvalid =
        !song.isValid || provider.invalidSongIds.contains(song.id);

    return Dismissible(
      key: Key(song.id),
      direction:
          (playlist.id.startsWith('temp_artist_') ||
              playlist.id.startsWith('temp_album_'))
          ? DismissDirection.none
          : (playlist.id == 'favorites'
                ? DismissDirection.endToStart
                : DismissDirection.horizontal),
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
          await _showCopySongDialog(context, provider, playlist, song.id);
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
              ? Colors.white.withOpacity(0.02)
              : (provider.audioOnlySongId == song.id ||
                    (song.title.trim().toLowerCase() ==
                            provider.currentTrack.trim().toLowerCase() &&
                        song.artist.trim().toLowerCase() ==
                            provider.currentArtist.trim().toLowerCase()))
              ? Colors.redAccent.withOpacity(0.25) // Stronger alpha
              : isGrouped
              ? Colors.transparent
              : Theme.of(context).cardColor.withValues(alpha: 0.5),
          borderRadius: BorderRadius.zero,
          border:
              (provider.audioOnlySongId == song.id ||
                  (song.title.trim().toLowerCase() ==
                          provider.currentTrack.trim().toLowerCase() &&
                      song.artist.trim().toLowerCase() ==
                          provider.currentArtist.trim().toLowerCase()))
              ? Border.all(color: Colors.redAccent.withOpacity(0.8), width: 1.5)
              : null,
        ),
        child: Listener(
          onPointerDown: isInvalid
              ? (_) => _startUnlockTimer(provider, song, playlist.id)
              : null,
          onPointerUp: isInvalid ? (_) => _cancelUnlockTimer() : null,
          onPointerCancel: isInvalid ? (_) => _cancelUnlockTimer() : null,
          child: ListTile(
            onTap: isInvalid
                ? () => _showInvalidTrackOptions(
                    context,
                    provider,
                    song,
                    playlist.id,
                  )
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
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 0)
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
                      if (playlist.id != 'favorites') ...[
                        GestureDetector(
                          onTap: () async {
                            if (isFavorite) {
                              await provider.removeFromPlaylist(
                                'favorites',
                                song.id,
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).clearSnackBars();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text("Removed from Favorites"),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }
                            } else {
                              await provider.copySong(
                                song.id,
                                playlist.id,
                                'favorites',
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).clearSnackBars();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text("Added to Favorites"),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }
                            }
                          },
                          child: Icon(
                            isFavorite ? Icons.favorite : Icons.favorite_border,
                            color: isFavorite
                                ? Colors.pinkAccent
                                : Colors.white54,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 24),
                      ],

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
                                    builder: (_) => YouTubePopup(
                                      videoId: videoId,
                                      songName: song.title,
                                      artistName: song.artist,
                                      albumName: song.album,
                                      artworkUrl: song.artUri,
                                    ),
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
                        color: Colors.white.withOpacity(0.5),
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
                                  color: Colors.white.withOpacity(0.9),
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
                              if (playlist.id != 'favorites') ...[
                                GestureDetector(
                                  onTap: () async {
                                    if (isFavorite) {
                                      await provider.removeFromPlaylist(
                                        'favorites',
                                        song.id,
                                      );
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).clearSnackBars();
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              "Removed from Favorites",
                                            ),
                                            duration: Duration(seconds: 1),
                                          ),
                                        );
                                      }
                                    } else {
                                      // Copy to favorites
                                      await provider.copySong(
                                        song.id,
                                        playlist.id,
                                        'favorites',
                                      );
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).clearSnackBars();
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text("Added to Favorites"),
                                            duration: Duration(seconds: 1),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  child: Icon(
                                    isFavorite
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: isFavorite
                                        ? Colors.pinkAccent
                                        : Colors.white54,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 20),
                              ],
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
                                          builder: (_) => YouTubePopup(
                                            videoId: videoId,
                                            songName: song.title,
                                            artistName: song.artist,
                                            albumName: song.album,
                                            artworkUrl: song.artUri,
                                          ),
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

  Widget _buildDialogIcon(BuildContext context, Playlist p) {
    if (p.id.startsWith('spotify_')) {
      return const FaIcon(FontAwesomeIcons.spotify, color: Color(0xFF1DB954));
    }
    if (p.creator == 'app' || p.id == 'favorites') {
      return ClipOval(
        child: Image.asset(
          'assets/icon.png',
          width: 24,
          height: 24,
          fit: BoxFit.cover,
        ),
      );
    }
    // User
    try {
      final backupService = Provider.of<BackupService>(context, listen: false);
      final photoUrl = backupService.currentUser?.photoUrl;

      if (photoUrl != null) {
        return ClipOval(
          child: Image.network(
            photoUrl,
            width: 24,
            height: 24,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.person, color: Colors.white),
          ),
        );
      }
    } catch (_) {}

    return const Icon(Icons.person, color: Colors.white);
  }

  Future<bool> _showCopySongDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist currentPlaylist,
    String songId,
  ) async {
    final others = provider.playlists
        .where((p) => p.id != currentPlaylist.id && p.id != 'favorites')
        .toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No other playlists to copy to.")),
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
                "Copy to...",
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
                          leading: SizedBox(
                            width: 24,
                            height: 24,
                            child: Center(child: _buildDialogIcon(context, p)),
                          ),
                          title: Text(
                            p.name,
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () {
                            provider.copySong(songId, currentPlaylist.id, p.id);
                            Navigator.pop(ctx, true);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Copied to ${p.name}")),
                              );
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

  Future<bool> _showCopyAlbumDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist currentPlaylist,
    List<SavedSong> groupSongs,
  ) async {
    final others = provider.playlists
        .where((p) => p.id != currentPlaylist.id && p.id != 'favorites')
        .toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No other playlists to copy to.")),
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
                "Copy ${groupSongs.first.album} to...",
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
                          leading: SizedBox(
                            width: 24,
                            height: 24,
                            child: Center(child: _buildDialogIcon(context, p)),
                          ),
                          title: Text(
                            p.name,
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () {
                            final songIds = groupSongs
                                .map((s) => s.id)
                                .toList();
                            provider.copySongs(
                              songIds,
                              currentPlaylist.id,
                              p.id,
                            );
                            Navigator.pop(ctx, true);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text("Copied album to ${p.name}"),
                                ),
                              );
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
          final theme = Theme.of(context);
          return AlertDialog(
            backgroundColor: theme.cardColor,
            title: Text(
              "Add Song",
              style: TextStyle(
                color: theme.textTheme.titleLarge?.color,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Search by Song Name, Artist, or Album",
                    style: TextStyle(
                      color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                      fontSize: 12,
                    ),
                  ),
                  TextField(
                    controller: controller,
                    style: TextStyle(color: theme.textTheme.bodyMedium?.color),
                    decoration: InputDecoration(
                      hintText: "Enter search term...",
                      hintStyle: TextStyle(
                        color: theme.textTheme.bodyMedium?.color?.withOpacity(
                          0.4,
                        ),
                      ),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (controller.text.isNotEmpty)
                            IconButton(
                              icon: Icon(
                                Icons.close,
                                color: theme.iconTheme.color?.withOpacity(0.7),
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
                            icon: Icon(
                              Icons.search,
                              color: theme.iconTheme.color?.withOpacity(0.7),
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
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                          color: theme.dividerColor.withOpacity(0.3),
                        ),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: theme.primaryColor),
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
                    SizedBox(
                      height: 100,
                      child: Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                            theme.primaryColor,
                          ),
                        ),
                      ),
                    )
                  else if (hasSearched && results.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        "No results found.",
                        style: TextStyle(
                          color: theme.textTheme.bodySmall?.color?.withOpacity(
                            0.5,
                          ),
                        ),
                      ),
                    )
                  else if (results.isNotEmpty)
                    Flexible(
                      child: SizedBox(
                        height: 500,
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: results.length,
                          separatorBuilder: (_, __) => Divider(
                            color: theme.dividerColor.withOpacity(0.1),
                          ),
                          itemBuilder: (context, index) {
                            final item = results[index];
                            final s = item.song;
                            final isSelected = selectedItems.contains(item);

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              selected: isSelected,
                              selectedTileColor: theme.primaryColor.withOpacity(
                                0.1,
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
                                            color: theme.dividerColor
                                                .withOpacity(0.1),
                                            child: Icon(
                                              Icons.music_note,
                                              color: theme.iconTheme.color
                                                  ?.withOpacity(0.5),
                                            ),
                                          ),
                                        )
                                      : Container(
                                          width: 50,
                                          height: 50,
                                          color: theme.dividerColor.withOpacity(
                                            0.1,
                                          ),
                                          child: Icon(
                                            Icons.music_note,
                                            color: theme.iconTheme.color
                                                ?.withOpacity(0.5),
                                          ),
                                        ),
                                ),
                              ),
                              title: Text(
                                s.title,
                                style: TextStyle(
                                  color: theme.textTheme.titleMedium?.color,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                "${s.artist}",
                                style: TextStyle(
                                  color: theme.textTheme.bodyMedium?.color
                                      ?.withOpacity(0.7),
                                ),
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
                                activeColor: theme.primaryColor,
                                checkColor: Colors.white,
                                side: BorderSide(
                                  color: theme.dividerColor.withOpacity(0.5),
                                ),
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
                  icon: const Icon(Icons.add, color: Colors.white),
                  label: Text(
                    "Add (${selectedItems.length})",
                    style: const TextStyle(color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
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
                  color: Theme.of(context).cardColor.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.zero,
                  border: Border.all(color: Colors.white12),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.zero,
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

  static const double _kGridScrollStride = 300.0;

  int _calculateGridColumnCount(double width) {
    // Strategy: (available + spacing) / (maxExtent + spacing)
    // Using 300 as the stride based on user preference for scroll positioning
    int crossAxisCount = ((width + 12) / _kGridScrollStride).ceil();
    return crossAxisCount < 1 ? 1 : crossAxisCount;
  }

  Widget _buildArtistsGrid(
    BuildContext context,
    RadioProvider provider,
    List<SavedSong> allSongs,
  ) {
    // Grouping Logic
    final Map<String, Set<String>> groupedVariants = {};
    final Map<String, String> normKeyToDisplay = {};
    final Map<String, SavedSong> representativeSongs = {}; // Store rep song
    final Map<String, String> songIdToGroupKey = {}; // Map song ID to group key

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

      songIdToGroupKey[s.id] = key; // Store mapping

      if (!groupedVariants.containsKey(key)) {
        groupedVariants[key] = {};
        normKeyToDisplay[key] = norm;
      }
      groupedVariants[key]!.add(raw);

      // Store representative song for artwork fallback
      if (!representativeSongs.containsKey(key)) {
        representativeSongs[key] = s;
      }
    }

    final groups = groupedVariants.keys.toList()
      ..sort((a, b) => a.compareTo(b));

    if (_showFollowedArtistsOnly) {
      groups.removeWhere((key) {
        final display = normKeyToDisplay[key];
        return display == null || !provider.isArtistFollowed(display);
      });
    }

    if (groups.isEmpty) {
      return const Center(
        child: Text(
          "No artists found",
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    // Pre-calculate counts
    final Map<String, int> artistCounts = {};
    for (var s in allSongs) {
      artistCounts[s.artist] = (artistCounts[s.artist] ?? 0) + 1;
    }

    // Determine valid Playing Group Key based on Song ID logic
    String? playingGroupKey = songIdToGroupKey[provider.audioOnlySongId];

    if (playingGroupKey == null && provider.currentArtist.isNotEmpty) {
      // Fallback: Use provider strings if ID lookup failed
      String raw = provider.currentArtist;
      String norm = raw
          .split('•')
          .first
          .trim()
          .split(RegExp(r'[,&/]'))
          .first
          .trim();
      playingGroupKey = norm.toLowerCase();
    }

    final int playingIndex = playingGroupKey != null
        ? groups.indexOf(playingGroupKey)
        : -1;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (playingIndex != -1) {
          final uniqueKey = "artist_${groups[playingIndex]}";
          if (_lastScrolledCategoryItem != uniqueKey) {
            _lastScrolledCategoryItem = uniqueKey;

            // Calculate offset
            // Calculate offset with robust column count logic matching SliverGridDelegateWithMaxCrossAxisExtent
            final double width = constraints.maxWidth - 32;
            final int crossAxisCount = _calculateGridColumnCount(width);

            final double itemWidth =
                (width - (crossAxisCount - 1) * 12) / crossAxisCount;
            final double rowHeight = itemWidth / 0.8; // Aspect Ratio 0.8

            final int row = playingIndex ~/ crossAxisCount;
            final double rowPosition = row * (rowHeight + 12);

            // Center the item: Target Position - Half Screen + Half Item
            final double centeredOffset =
                rowPosition - (constraints.maxHeight / 2) + (rowHeight / 2);

            WidgetsBinding.instance.addPostFrameCallback((_) {
              Future.delayed(const Duration(milliseconds: 100), () {
                if (_artistsScrollController.hasClients) {
                  // Safe to access position here
                  final double maxScroll =
                      _artistsScrollController.position.maxScrollExtent;
                  final double targetOffset = centeredOffset.clamp(
                    0.0,
                    maxScroll > 0 ? maxScroll : centeredOffset,
                  );

                  _artistsScrollController.animateTo(
                    targetOffset,
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeInOut,
                  );
                }
              });
            });
          }
        }

        return GridView.builder(
          controller: _artistsScrollController,
          key: const PageStorageKey('artists_grid'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 0.8,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final groupKey = groups[index];
            final variants = groupedVariants[groupKey]!;

            String displayArtist;
            String searchArtist;
            bool isGroup;
            int count = 0;
            bool isPlaying = (groupKey == playingGroupKey);

            if (variants.length == 1) {
              // Single
              displayArtist = variants.first;
              searchArtist = variants.first;
              isGroup = false;
              count = artistCounts[displayArtist] ?? 0;
            } else {
              // Group
              searchArtist = normKeyToDisplay[groupKey]!;
              displayArtist = "$searchArtist...";
              isGroup = true;

              for (var v in variants) {
                count += artistCounts[v] ?? 0;
              }
            }

            final bool isFollowed = provider.isArtistFollowed(searchArtist);
            final SavedSong? repSong = representativeSongs[groupKey];

            return _ArtistGridItem(
              artist: searchArtist,
              customDisplayName: displayArtist,
              fallbackImageUrl: repSong?.artUri,
              songCount: count,
              isPlaying: isPlaying,
              isFollowed: isFollowed,
              onToggleFollow: () {
                provider.toggleFollowArtist(searchArtist);
              },
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
                  _lastScrolledSongId = null;
                });
              },
            );
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
    final Map<String, SavedSong> representativeSongs = {};
    final Map<String, String> songIdToGroupKey = {}; // Map song ID to group key

    for (var s in allSongs) {
      if (s.album.isEmpty) continue;
      String raw = s.album;
      // Normalization: Remove (Deluxe), [Live], etc.
      String norm = raw.split('(').first.trim().split('[').first.trim();
      String key = norm.toLowerCase();

      songIdToGroupKey[s.id] = key; // Store mapping

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

    if (_showFollowedAlbumsOnly) {
      groups.removeWhere((key) {
        final display = normKeyToDisplay[key];
        return display == null || !provider.isAlbumFollowed(display);
      });
    }

    // Determine valid Playing Group Key based on Song ID logic
    String? playingGroupKey = songIdToGroupKey[provider.audioOnlySongId];

    if (playingGroupKey == null && provider.currentAlbum.isNotEmpty) {
      // Fallback
      String raw = provider.currentAlbum;
      String norm = raw.split('(').first.trim().split('[').first.trim();
      playingGroupKey = norm.toLowerCase();
    }

    final int playingIndex = playingGroupKey != null
        ? groups.indexOf(playingGroupKey)
        : -1;

    // Pre-calculate counts
    final Map<String, int> albumCounts = {};
    for (var s in allSongs) {
      albumCounts[s.album] = (albumCounts[s.album] ?? 0) + 1;
    }

    if (groups.isEmpty) {
      return const Center(
        child: Text("No albums found", style: TextStyle(color: Colors.white54)),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (playingIndex != -1) {
          final uniqueKey = "album_${groups[playingIndex]}";
          if (_lastScrolledCategoryItem != uniqueKey) {
            _lastScrolledCategoryItem = uniqueKey;

            // Calculate offset
            // Calculate offset with robust column count logic matching SliverGridDelegateWithMaxCrossAxisExtent
            final double width = constraints.maxWidth - 32;
            final int crossAxisCount = _calculateGridColumnCount(width);

            final double itemWidth =
                (width - (crossAxisCount - 1) * 12) / crossAxisCount;
            final double rowHeight = itemWidth / 0.8; // Aspect Ratio 0.8

            final int row = playingIndex ~/ crossAxisCount;
            final double rowPosition = row * (rowHeight + 12);

            // Center the item
            final double centeredOffset =
                rowPosition - (constraints.maxHeight / 2) + (rowHeight / 2);

            WidgetsBinding.instance.addPostFrameCallback((_) {
              Future.delayed(const Duration(milliseconds: 100), () {
                if (_albumsScrollController.hasClients) {
                  // Re-calculate maxScroll here to be safe after layout
                  final double maxScroll =
                      _albumsScrollController.position.maxScrollExtent;
                  final double targetOffset = centeredOffset.clamp(
                    0.0,
                    maxScroll > 0 ? maxScroll : centeredOffset,
                  );

                  _albumsScrollController.animateTo(
                    targetOffset,
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeInOut,
                  );
                }
              });
            });
          }
        }

        return GridView.builder(
          controller: _albumsScrollController,
          key: const PageStorageKey('albums_grid'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            childAspectRatio: 0.8,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final groupKey = groups[index];
            final variants = groupedAlbums[groupKey]!;

            String displayAlbum;
            String searchAlbum;
            bool isGroup;
            int count = 0;
            // Use robust index-based check matching the scroll logic
            bool isPlaying = (index == playingIndex);
            SavedSong? displaySong;

            if (variants.length == 1) {
              // Single
              displayAlbum = variants.first;
              searchAlbum = variants.first;
              isGroup = false;
              displaySong = representativeSongs[displayAlbum];

              count = albumCounts[displayAlbum] ?? 0;
            } else {
              // Group
              searchAlbum = normKeyToDisplay[groupKey]!;
              displayAlbum = "$searchAlbum...";
              isGroup = true;
              // Use first variant for art
              displaySong = representativeSongs[variants.first];

              for (var v in variants) {
                count += albumCounts[v] ?? 0;
              }
            }

            if (displaySong == null) return const SizedBox();

            final String normalizedAlbumName = searchAlbum
                .split('(')
                .first
                .trim()
                .split('[')
                .first
                .trim();
            final bool isFollowed = provider.isAlbumFollowed(
              normalizedAlbumName,
            );

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
                  _lastScrolledSongId = null;
                });
              },
              child: Container(
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: isPlaying
                      ? Border.all(
                          color: Theme.of(
                            context,
                          ).primaryColor.withValues(alpha: 0.8),
                          width: 2,
                        )
                      : Border.all(color: Colors.white12),
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: isPlaying
                      ? [
                          BoxShadow(
                            color: Theme.of(
                              context,
                            ).primaryColor.withValues(alpha: 0.4),
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
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
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
                          Positioned(
                            top: 8,
                            right: 8,
                            child: GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => AlbumDetailsScreen(
                                      albumName: searchAlbum,
                                      artistName: displaySong!.artist,
                                      artworkUrl: displaySong.artUri,
                                      appleMusicUrl: displaySong.appleMusicUrl,
                                    ),
                                  ),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.5),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white24,
                                    width: 0.5,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.info_outline,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 8,
                            left: 8,
                            child: GestureDetector(
                              onTap: () {
                                provider.toggleFollowAlbum(normalizedAlbumName);
                              },
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.5),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white24,
                                    width: 0.5,
                                  ),
                                ),
                                child: Icon(
                                  isFollowed
                                      ? Icons.bookmark
                                      : Icons.bookmark_border,
                                  color: isFollowed
                                      ? Colors.greenAccent
                                      : Colors.white,
                                  size: 16,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayAlbum,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).textTheme.titleMedium?.color,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            displaySong.artist,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).textTheme.bodyMedium?.color,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "$count ${count == 1 ? 'song' : 'songs'}",
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall?.color,
                              fontSize: 10,
                            ),
                          ),
                          if (isPlaying) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  Icons.equalizer,
                                  color: Theme.of(context).primaryColor,
                                  size: 12,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  "PLAYING",
                                  style: TextStyle(
                                    color: Theme.of(context).primaryColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
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
  final bool showFavoritesButton;

  const _AlbumGroupWidget({
    required this.groupSongs,
    required this.songBuilder,
    required this.onMove,
    required this.onRemove,
    this.dismissDirection,
    this.showFavoritesButton = true,
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

    // Normalize album name for consistency with Grid
    final String normalizedAlbumName = albumName
        .split('(')
        .first
        .trim()
        .split('[')
        .first
        .trim();
    final bool isFollowed = provider.isAlbumFollowed(normalizedAlbumName);

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
          borderRadius: BorderRadius.zero,
        ),
        padding: const EdgeInsets.only(left: 24),
        child: const Icon(Icons.drive_file_move_outline, color: Colors.white),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.red,
          borderRadius: BorderRadius.zero,
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
              ? Theme.of(context).primaryColor.withValues(alpha: 0.05)
              : Theme.of(context).cardColor.withValues(alpha: 0.5),
          borderRadius: BorderRadius.zero,
          border: isPlayingAlbum
              ? Border.all(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.6),
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
                borderRadius: BorderRadius.zero,
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
                      if (widget.showFavoritesButton) ...[
                        GestureDetector(
                          onTap: () async {
                            provider.toggleFollowAlbum(normalizedAlbumName);
                          },
                          child: Icon(
                            isFollowed ? Icons.favorite : Icons.favorite_border,
                            color: isFollowed
                                ? Colors.pinkAccent
                                : Colors.white54,
                            size: 24,
                          ),
                        ),
                      ],
                      const SizedBox(width: 16),
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
  final String? fallbackImageUrl;
  final int songCount;
  final VoidCallback onTap;
  final bool isPlaying;
  final bool isFollowed;
  final VoidCallback onToggleFollow;

  const _ArtistGridItem({
    required this.artist,
    this.customDisplayName,
    this.fallbackImageUrl,
    required this.songCount,
    required this.onTap,
    this.isPlaying = false,
    required this.isFollowed,
    required this.onToggleFollow,
  });

  @override
  State<_ArtistGridItem> createState() => _ArtistGridItemState();
}

class _ArtistGridItemState extends State<_ArtistGridItem> {
  String? _imageUrl;

  @override
  void initState() {
    super.initState();
    // Initialize with fallback immediately
    _imageUrl = widget.fallbackImageUrl;
    _fetchImage();
  }

  @override
  void didUpdateWidget(covariant _ArtistGridItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist != widget.artist) {
      // proper reset on change
      setState(() {
        _imageUrl = widget.fallbackImageUrl;
      });
      _fetchImage();
    }
  }

  Future<void> _fetchImage() async {
    if (!mounted) return;
    try {
      final provider = Provider.of<RadioProvider>(context, listen: false);
      final image = await provider.fetchArtistImage(widget.artist);

      if (mounted && image != null) {
        setState(() {
          _imageUrl = image;
        });
      }
    } catch (e) {
      // Ignore errors
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
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.8),
                  width: 2,
                )
              : Border.all(color: Colors.white12),
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          boxShadow: widget.isPlaying
              ? [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.4),
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
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
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
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ArtistDetailsScreen(
                              artistName: widget.artist,
                              artistImage: _imageUrl,
                            ),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 0.5),
                        ),
                        child: const Icon(
                          Icons.arrow_forward_ios_rounded,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: GestureDetector(
                      onTap: widget.onToggleFollow,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 0.5),
                        ),
                        child: Icon(
                          widget.isFollowed
                              ? Icons.how_to_reg
                              : Icons.person_add_alt,
                          color: widget.isFollowed
                              ? Colors.greenAccent
                              : Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ],
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
                    style: TextStyle(
                      color: Theme.of(context).textTheme.titleMedium?.color,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    "${widget.songCount} Songs",
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodySmall?.color,
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

class _DuplicateResolutionDialog extends StatefulWidget {
  final Playlist playlist;
  final List<List<SavedSong>> duplicates;
  final RadioProvider provider;

  const _DuplicateResolutionDialog({
    required this.playlist,
    required this.duplicates,
    required this.provider,
  });

  @override
  State<_DuplicateResolutionDialog> createState() =>
      _DuplicateResolutionDialogState();
}

class _DuplicateResolutionDialogState
    extends State<_DuplicateResolutionDialog> {
  final Set<String> _selectedForRemoval = {};
  // Track playing state just for UI feedback if needed, currently provider handles it.

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1a1a2e),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Duplicate Songs", style: TextStyle(color: Colors.white)),
          const SizedBox(height: 4),
          Text(
            "Found ${widget.duplicates.length} sets of duplicates",
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 500, // Fixed height or flexible
        child: ListView.separated(
          itemCount: widget.duplicates.length,
          separatorBuilder: (_, __) => const Divider(color: Colors.white12),
          itemBuilder: (ctx, index) {
            final group = widget.duplicates[index];
            final first = group.first;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    "${first.title} - ${first.artist}",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ...group.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final song = entry.value;
                  final isSelected = _selectedForRemoval.contains(song.id);
                  final isPlaying = widget.provider.audioOnlySongId == song.id;

                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 16, right: 0),
                    leading: IconButton(
                      icon: Icon(
                        isPlaying
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                        color: isPlaying ? Colors.redAccent : Colors.white,
                      ),
                      onPressed: () {
                        if (isPlaying) {
                          widget.provider.pause();
                        } else {
                          widget.provider.playPlaylistSong(
                            song,
                            widget.playlist.id,
                          );
                        }
                      },
                      tooltip: "Test Play",
                    ),
                    title: Text(
                      "Copy ${idx + 1}",
                      style: const TextStyle(color: Colors.white70),
                    ),
                    subtitle: Text(
                      "Added: ${song.dateAdded.year}-${song.dateAdded.month.toString().padLeft(2, '0')}-${song.dateAdded.day.toString().padLeft(2, '0')}",
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                    trailing: Checkbox(
                      value: isSelected,
                      activeColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.white54),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedForRemoval.add(song.id);
                          } else {
                            _selectedForRemoval.remove(song.id);
                          }
                        });
                      },
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Close", style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton.icon(
          onPressed: _selectedForRemoval.isEmpty
              ? null
              : () async {
                  final count = _selectedForRemoval.length;
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      backgroundColor: const Color(0xFF222222),
                      title: const Text(
                        "Confirm Deletion",
                        style: TextStyle(color: Colors.white),
                      ),
                      content: Text(
                        "Remove $count selected songs from playlist?",
                        style: const TextStyle(color: Colors.white70),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text("Cancel"),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text(
                            "Delete",
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    await widget.provider.removeSongsFromPlaylist(
                      widget.playlist.id,
                      _selectedForRemoval.toList(),
                    );
                    if (context.mounted) {
                      Navigator.pop(context); // Close main dialog
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Removed $count songs.")),
                      );
                    }
                  }
                },
          icon: const Icon(Icons.delete_outline, color: Colors.white),
          label: Text(
            "Delete Selected (${_selectedForRemoval.length})",
            style: const TextStyle(color: Colors.white),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            disabledBackgroundColor: Colors.white12,
          ),
        ),
      ],
    );
  }
}
