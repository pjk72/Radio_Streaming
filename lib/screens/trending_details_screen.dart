import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

import '../services/trending_service.dart';
import '../services/spotify_service.dart';
import '../providers/radio_provider.dart';
import '../models/saved_song.dart';
import '../models/playlist.dart';

import '../widgets/player_bar.dart';
import '../widgets/native_ad_widget.dart';
import '../widgets/mini_visualizer.dart';
import '../services/log_service.dart';
import '../providers/language_provider.dart';

class _AdItem {
  const _AdItem();
}

class TrendingDetailsScreen extends StatefulWidget {
  final TrendingPlaylist? playlist;
  // Album Mode Parameters
  final String? albumName;
  final String? artistName;
  final String? artworkUrl;
  final String? appleMusicUrl;
  final String? songName;
  final SavedSong? originalSong;

  const TrendingDetailsScreen({
    super.key,
    this.playlist,
    this.albumName,
    this.artistName,
    this.artworkUrl,
    this.appleMusicUrl,
    this.songName,
    this.originalSong,
  }) : assert(
         playlist != null || albumName != null,
         'Either playlist or albumName must be provided',
       );

  @override
  State<TrendingDetailsScreen> createState() => _TrendingDetailsScreenState();
}

class _TrendingDetailsScreenState extends State<TrendingDetailsScreen> {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  List<SavedSong> _songs = [];
  List<dynamic> _items = [];
  bool _isLoading = true;
  TrendingService? _trendingService;
  SpotifyService? _spotifyService;
  String? _lastScrollSongId;

  // Album specific data
  Map<String, dynamic>? _albumData;

  @override
  void initState() {
    super.initState();
    _fetchContent();
  }

  @override
  void dispose() {
    _trendingService?.dispose();
    super.dispose();
  }

  Future<void> _fetchContent() async {
    if (widget.playlist != null) {
      await _fetchPlaylistTracks();
    } else {
      await _fetchAlbumData();
    }
  }

  Future<void> _fetchPlaylistTracks() async {
    _spotifyService = SpotifyService();
    await _spotifyService!.init();
    _trendingService = TrendingService(_spotifyService!);

    final tracks = await _trendingService!.getPlaylistTracks(widget.playlist!);

    LogService().log(
      "TrendingDetails: Tracks fetched: ${tracks.length} tracks for playlist '${widget.playlist!.title}'",
    );

    if (mounted) {
      setState(() {
        _songs = tracks.map((t) => _trackToSavedSong(t)).toList();
        _isLoading = false;
        _buildItems();
      });
    }
  }

  Future<void> _fetchAlbumData() async {
    // Fetch album info
    _albumData = await _fetchAlbumInfo();

    // Fetch tracks if we have collection ID
    if (_albumData != null && _albumData!['collectionId'] != null) {
      final albumTracks = await _fetchAlbumTracks(
        _albumData!['collectionId'],
        artist: _albumData!['artistName'] ?? widget.artistName,
        album: _albumData!['collectionName'] ?? widget.albumName,
      );
      _songs = albumTracks.map((t) => _trackToSavedSong(t)).toList();

      // Inject the original song to preserve its YouTube ID and URL
      if (widget.originalSong != null) {
        int matchIndex = _songs.indexWhere((s) {
          final n1 = _normalize(s.title);
          final n2 = _normalize(widget.originalSong!.title);
          // Check for significant overlap or exact match
          return n1 == n2 ||
              (n1.length > 5 && n2.contains(n1)) ||
              (n2.length > 5 && n1.contains(n2));
        });
        if (matchIndex != -1) {
          _songs[matchIndex] = widget.originalSong!;
        } else {
          _songs.insert(0, widget.originalSong!);
        }
      }
    } else if (widget.originalSong != null || widget.songName != null) {
      // Fallback: If album not found but we have a specific song name, try to find just that song's "album"
      if (_songs.isEmpty && widget.songName != null) {
        final query = "${widget.artistName} ${widget.songName}";
        final uri = Uri.parse(
          "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=song&limit=1",
        );
        try {
          final res = await http.get(uri);
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            if (data['resultCount'] > 0) {
              final track = data['results'][0];
              _songs = [_trackToSavedSong(track)];
              if (_albumData == null) _albumData = track;
            }
          }
        } catch (_) {}
      }

      if (_songs.isEmpty && widget.originalSong != null) {
        _songs = [widget.originalSong!];
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
        _buildItems();
      });
    }
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

    // 2. Fallback to search query
    try {
      // Clean names: remove suffixes like (feat. ...), [Deluxe Edition], etc.
      String cleanArtist = widget.artistName ?? "";
      String cleanAlbum = widget.albumName ?? "";
      String cleanSong = widget.songName ?? "";

      final cleanupRegex = RegExp(r'\(.*?\)|\[.*?\]| - .*');
      cleanArtist = cleanArtist.replaceAll(cleanupRegex, '').trim();
      cleanAlbum = cleanAlbum.replaceAll(cleanupRegex, '').trim();
      cleanSong = cleanSong.replaceAll(cleanupRegex, '').trim();

      // Priority 1: Exact Artist + Album
      if (cleanArtist.isNotEmpty && cleanAlbum.isNotEmpty) {
        final query = "$cleanArtist $cleanAlbum";
        final uri = Uri.parse(
          "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=album&limit=1",
        );
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['resultCount'] > 0) return data['results'][0];
        }
      }

      // Priority 2: Artist + Song (finding the album containing the song)
      if (cleanArtist.isNotEmpty && cleanSong.isNotEmpty) {
        final query = "$cleanArtist $cleanSong";
        final uri = Uri.parse(
          "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=song&limit=1",
        );
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['resultCount'] > 0) return data['results'][0];
        }
      }
    } catch (e) {
      developer.log("Error fetching album info: $e");
    }
    return null;
  }

  String? _extractAlbumId(String url) {
    final regex = RegExp(r'/id(\d+)');
    final match = regex.firstMatch(url);
    return match?.group(1);
  }

  String _normalize(String s) {
    return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
  }

  Future<List<Map<String, dynamic>>> _fetchAlbumTracks(
    int collectionId, {
    String? artist,
    String? album,
  }) async {
    try {
      // 1. Try lookup by ID (accurate track ordering)
      final lookupUri = Uri.parse(
        "https://itunes.apple.com/lookup?id=$collectionId&entity=song&limit=200",
      );
      final response = await http.get(lookupUri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = List<Map<String, dynamic>>.from(data['results']);

        var tracks = results
            .where((item) => item['wrapperType'] == 'track')
            .toList();

        if (tracks.isNotEmpty) {
          tracks.sort((a, b) {
            int discA = a['discNumber'] ?? 1;
            int discB = b['discNumber'] ?? 1;
            if (discA != discB) return discA.compareTo(discB);

            int trackA = a['trackNumber'] ?? 0;
            int trackB = b['trackNumber'] ?? 0;
            return trackA.compareTo(trackB);
          });
          return tracks;
        }
      }

      // 2. Fallback to name-based search if lookup returned no tracks
      // (Common for non-US content in US storefront)
      if (artist != null && album != null) {
        final query = "$artist $album";
        final searchUri = Uri.parse(
          "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=song&limit=100",
        );
        final searchRes = await http.get(searchUri);
        if (searchRes.statusCode == 200) {
          final sData = jsonDecode(searchRes.body);
          final sResults = List<Map<String, dynamic>>.from(sData['results']);

          // Filter tracks belonging to this album (by name or ID)
          // AND ensure the artist name matches to avoid covers/tributes
          var sTracks = sResults.where((item) {
            if (item['wrapperType'] != 'track') return false;

            // 1. Check Artist Match (CRITICAL for covers/tributes)
            final String? tArtist = item['artistName'];
            final String normTargetArtist = _normalize(artist);
            final String normTrackArtist = _normalize(tArtist ?? '');

            // Only allow if the track artist contains the target artist or vice versa
            if (!normTrackArtist.contains(normTargetArtist) &&
                !normTargetArtist.contains(normTrackArtist)) {
              return false;
            }

            // 2. Check Album Match
            if (item['collectionId'] == collectionId) return true;

            final String? cName = item['collectionName'];
            if (cName != null) {
              final String normA = _normalize(album);
              final String normB = _normalize(cName);
              return normA == normB || normB.contains(normA);
            }
            return false;
          }).toList();

          if (sTracks.isNotEmpty) {
            // DE-DUPLICATE: Sometimes search returns the same song from different sources
            final Map<String, Map<String, dynamic>> uniqueTracks = {};
            for (var t in sTracks) {
              final key = _normalize(t['trackName'] ?? '');
              // Keep the one with trackId if available, or just the first one found
              if (!uniqueTracks.containsKey(key)) {
                uniqueTracks[key] = t;
              }
            }

            final finalTracks = uniqueTracks.values.toList();
            finalTracks.sort((a, b) {
              int discA = a['discNumber'] ?? 1;
              int discB = b['discNumber'] ?? 1;
              if (discA != discB) return discA.compareTo(discB);
              int trackA = a['trackNumber'] ?? 0;
              int trackB = b['trackNumber'] ?? 0;
              return trackA.compareTo(trackB);
            });
            return finalTracks;
          }
        }
      }
    } catch (e) {
      developer.log("Error fetching tracks: $e");
    }
    return [];
  }

  void _buildItems() {
    _items = [];
    if (_songs.isNotEmpty) {
      _items.add(const _AdItem()); // Ad at start
      for (int i = 0; i < _songs.length; i++) {
        _items.add(_songs[i]);
        if ((i + 1) % 10 == 0 && (i + 1) < _songs.length) {
          _items.add(const _AdItem()); // Ad every 10 songs
        }
      }
      _items.add(const _AdItem()); // Ad at end
    }
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(context);
    // Extract metadata
    String mainImage = "";
    String title = "";
    String subtitle = "";

    if (widget.playlist != null) {
      mainImage = widget.playlist!.imageUrls.isNotEmpty
          ? widget.playlist!.imageUrls.first
          : '';
      title = widget.playlist!.title;
    } else {
      mainImage =
          widget.artworkUrl ??
          _albumData?['artworkUrl100']?.replaceAll('100x100bb', '600x600bb') ??
          "";
      title = _albumData?['collectionName'] ?? widget.albumName ?? "";
      subtitle = _albumData?['artistName'] ?? widget.artistName ?? "";
    }

    // Determine Item Count
    // Index 0 is ALWAYS Header.
    // If loading: Index 1 is Loader. Total 2.
    // If empty: Index 1 is "No tracks". Total 2.
    // Else: Index 1..N are _items. Total _items.length + 1.
    int itemCount = 1;
    if (_isLoading) {
      itemCount += 1;
    } else if (_items.isEmpty) {
      itemCount += 1;
    } else {
      itemCount += _items.length;
    }

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
                  Colors.black.withValues(alpha: 0.6),
                  Colors.black.withValues(alpha: 0.9),
                  Colors.black,
                ],
              ),
            ),
          ),

          // 3. Content List
          Positioned.fill(
            child: Consumer<RadioProvider>(
              builder: (context, provider, child) {
                // Check auto-scroll
                _checkAutoScroll(provider);

                return ScrollablePositionedList.builder(
                  itemCount: itemCount,
                  itemScrollController: _itemScrollController,
                  itemPositionsListener: _itemPositionsListener,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.only(
                    bottom: 100,
                  ), // Space for player/nav
                  itemBuilder: (context, index) {
                    // Header
                    if (index == 0) {
                      return _buildHeader(
                        context,
                        mainImage,
                        title,
                        subtitle,
                        langProvider,
                      );
                    }

                    // Content
                    if (_isLoading) {
                      return const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    if (_items.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 50),
                        child: Center(
                          child: Text(
                            langProvider.translate('no_tracks_found'),
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ),
                      );
                    }

                    // Map index back to item index
                    final itemIndex = index - 1;
                    if (itemIndex >= _items.length)
                      return const SizedBox.shrink();

                    return _buildListItem(
                      context,
                      itemIndex,
                      provider,
                      langProvider,
                    );
                  },
                );
              },
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
                  backgroundColor: Colors.black.withValues(alpha: 0.5),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: langProvider.translate('back'),
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

  void _checkAutoScroll(RadioProvider provider) {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    final playingSongId =
        provider.currentSongId ??
        provider.audioHandler.mediaItem.value?.extras?['songId'];

    // Auto-scroll logic
    if (playingSongId != null &&
        playingSongId != _lastScrollSongId &&
        !_isLoading &&
        _items.isNotEmpty) {
      final index = _items.indexWhere((item) {
        if (item is! SavedSong) return false;
        if (item.id == playingSongId) return true;

        // Fallback for unstable IDs
        final currentItemTitle = provider.currentTrack;
        if (currentItemTitle != langProvider.translate('live_broadcast') &&
            item.title == currentItemTitle) {
          return true;
        }
        return false;
      });

      if (index != -1) {
        _lastScrollSongId = playingSongId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Scroll to index + 1 (Header is 0)
          // alignment: 0.5 centers the item
          if (_itemScrollController.isAttached) {
            _itemScrollController.scrollTo(
              index: index + 1,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOut,
              alignment: 0.5,
            );
          }
        });
      }
    }
  }

  Widget _buildHeader(
    BuildContext context,
    String mainImage,
    String title,
    String subtitle,
    LanguageProvider langProvider,
  ) {
    return Padding(
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
                  color: Colors.black.withValues(alpha: 0.5),
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
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
          ],

          const SizedBox(height: 24),

          // Actions Row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _playRandom,
                icon: const Icon(Icons.shuffle, size: 18),
                label: Text(langProvider.translate('shuffle_play')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor:
                      Theme.of(context).primaryColor.computeLuminance() > 0.5
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
                  Provider.of<RadioProvider>(context, listen: false).stop();
                },
                tooltip: langProvider.translate('stop'),
              ),
              IconButton(
                icon: Icon(
                  Icons.copy_all,
                  color: _isLoading || _songs.isEmpty
                      ? Colors.white24
                      : Colors.orangeAccent,
                  size: 30,
                ),
                onPressed: _isLoading || _songs.isEmpty
                    ? null
                    : _showCopyDialog,
                tooltip: langProvider.translate('copy_list'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildListItem(
    BuildContext context,
    int index,
    RadioProvider provider,
    LanguageProvider langProvider,
  ) {
    final item = _items[index];

    if (item is _AdItem) {
      return const NativeAdWidget();
    }

    final track = item as SavedSong;
    final trackIndex = _songs.indexOf(track);
    final trackId = track.id;

    final playingSongId =
        provider.currentSongId ??
        provider.audioHandler.mediaItem.value?.extras?['songId'];

    bool isPlaying = playingSongId == trackId;

    // Fallback for unstable IDs: if playingSongId doesn't match, check title
    if (!isPlaying && playingSongId != null) {
      final currentItemTitle = provider.currentTrack;
      if (currentItemTitle != langProvider.translate('live_broadcast') &&
          track.title == currentItemTitle) {
        isPlaying = true;
      }
    }

    final theme = Theme.of(context);
    final isPlayingState = provider.audioHandler.playbackState.value.playing;

    // Pre-calculate saved songs for list performance
    final savedIds = provider.allUniqueSongs.map((s) => s.id).toSet();
    final savedKeys = provider.allUniqueSongs
        .map((s) => "${_normalize(s.title)}|${_normalize(s.artist)}")
        .toSet();

    final trackTitle = track.title;
    final trackArtist = track.artist;
    final trackKey = "${_normalize(trackTitle)}|${_normalize(trackArtist)}";

    final isSaved = savedIds.contains(trackId) || savedKeys.contains(trackKey);

    return Container(
      decoration: BoxDecoration(
        color: isPlaying
            ? Colors.white.withValues(alpha: 0.1)
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
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isPlaying ? theme.primaryColor : Colors.white,
            fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          track.artist,
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
                isSaved
                    ? Icons.playlist_add_check_rounded
                    : Icons.add_circle_outline,
                color: isSaved ? theme.primaryColor : Colors.white54,
              ),
              onPressed: () => _showAddSongDialog(track),
              tooltip: isSaved
                  ? langProvider.translate('already_in_library')
                  : langProvider.translate('add_to_playlist'),
            ),
          ],
        ),
        onTap: () => _playTrack(trackIndex),
      ),
    );
  }

  void _playTrack(int index) {
    if (_songs.isEmpty) return;
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final song = _songs[index];

    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    String playlistId;
    String playlistName;

    if (widget.playlist != null) {
      playlistId = 'trending_${widget.playlist!.id}';
      playlistName = widget.playlist!.title;
    } else {
      playlistId = 'album_${widget.albumName.hashCode}';
      playlistName = widget.albumName ?? langProvider.translate('tab_albums');
    }

    LogService().log(
      "TrendingDetails: Selection: '${song.title}' from '$playlistName'",
    );

    // Simple play: always load the playlist context to ensure sequential playback works
    final tempPlaylist = Playlist(
      id: playlistId,
      name: playlistName,
      songs: _songs,
      createdAt: DateTime.now(),
    );
    provider.playAdHocPlaylist(tempPlaylist, song.id);
  }

  void _playRandom() {
    if (_songs.isEmpty) return;
    final provider = Provider.of<RadioProvider>(context, listen: false);

    // Copy and Shuffle
    final shuffledSongs = List<SavedSong>.from(_songs)..shuffle();

    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    String playlistId;
    String playlistName;

    if (widget.playlist != null) {
      playlistId = 'trending_${widget.playlist!.id}';
      playlistName = widget.playlist!.title;
    } else {
      playlistId = 'album_${widget.albumName.hashCode}';
      playlistName = widget.albumName ?? langProvider.translate('tab_albums');
    }

    final tempPlaylist = Playlist(
      id: playlistId,
      name: playlistName,
      songs: shuffledSongs,
      createdAt: DateTime.now(),
    );

    provider.playAdHocPlaylist(tempPlaylist, null);
  }

  SavedSong _trackToSavedSong(Map<String, dynamic> t) {
    if (widget.playlist != null) {
      String songId = t['id'] ?? '';
      if (songId.length < 3) {
        songId =
            "hash_${_normalize(t['title'] ?? '')}_${_normalize(t['artist'] ?? '')}";
      }

      final lang = Provider.of<LanguageProvider>(context, listen: false);
      return SavedSong(
        id: songId,
        title: t['title'] ?? lang.translate('unknown'),
        artist: t['artist'] ?? lang.translate('unknown_artist'),
        album: t['album'] ?? lang.translate('unknown_album'),
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
            : null,
        dateAdded: DateTime.now(),
      );
    } else {
      final lang = Provider.of<LanguageProvider>(context, listen: false);
      final trackArtist =
          t['artistName'] ??
          widget.artistName ??
          lang.translate('unknown_artist');
      final trackName = t['trackName'] ?? lang.translate('unknown_track');

      return SavedSong(
        id:
            t['trackId']?.toString() ??
            "${DateTime.now().millisecondsSinceEpoch}_${t['trackNumber'] ?? 0}",
        title: trackName,
        artist: trackArtist,
        album: widget.albumName ?? lang.translate('unknown_album'),
        artUri:
            t['artworkUrl100']?.replaceAll('100x100bb', '600x600bb') ??
            widget.artworkUrl ??
            "",
        appleMusicUrl: t['trackViewUrl'],
        dateAdded: DateTime.now(),
        releaseDate: t['releaseDate'],
      );
    }
  }

  void _showCopyDialog() {
    if (_isLoading) {
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(langProvider.translate('loading_tracks'))),
      );
      return;
    }
    if (_songs.isEmpty) {
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(langProvider.translate('no_tracks_to_copy'))),
      );
      return;
    }

    final provider = Provider.of<RadioProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (context) {
        final playlists = provider.playlists;

        final langProvider = Provider.of<LanguageProvider>(
          context,
          listen: false,
        );
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: Text(
            langProvider.translate('copy_playlist'),
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
                    langProvider.translate('copy_songs_to'),
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
                          title: Text(
                            langProvider.translate('create_new_playlist'),
                            style: const TextStyle(color: Colors.blueAccent),
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
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodyLarge?.color,
                          ),
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
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: Text(
          langProvider.translate('new_playlist'),
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
          decoration: InputDecoration(
            labelText: langProvider.translate('playlist_name'),
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
            child: Text(langProvider.translate('cancel')),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final name = controller.text;
                Navigator.pop(ctx);
                _showProcessingDialog(
                  langProvider.translate('adding_to_playlist'),
                );

                final provider = Provider.of<RadioProvider>(
                  context,
                  listen: false,
                );

                final songs = _songs;
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
                    SnackBar(
                      content: Text(
                        langProvider
                            .translate('songs_copied')
                            .replaceAll('{0}', songs.length.toString()),
                      ),
                    ),
                  );
                }
              }
            },
            child: Text(
              langProvider.translate('create'),
              style: TextStyle(color: Theme.of(context).primaryColor),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copySongsTo(String playlistId) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final songs = _songs;

    await provider.addSongsToPlaylist(playlistId, songs);

    // Always attempt to resolve links for the added songs in background
    provider.resolvePlaylistLinksInBackground(playlistId, songs);

    if (mounted) {
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            langProvider
                .translate('songs_copied')
                .replaceAll('{0}', songs.length.toString()),
          ),
        ),
      );
    }
  }

  void _showAddSongDialog(SavedSong song) {
    final provider = Provider.of<RadioProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (context) {
        final playlists = provider.playlists;

        final langProvider = Provider.of<LanguageProvider>(
          context,
          listen: false,
        );
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: Text(
            langProvider.translate('add_to_playlist'),
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
                    "${langProvider.translate('add_to_playlist')} '${song.title}' to:",
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
                          title: Text(
                            langProvider.translate('create_new_playlist'),
                            style: const TextStyle(color: Colors.blueAccent),
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
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodyLarge?.color,
                          ),
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
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: Text(
          langProvider.translate('new_playlist'),
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
          decoration: InputDecoration(
            labelText: langProvider.translate('playlist_name'),
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
            child: Text(langProvider.translate('cancel')),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final name = controller.text;
                Navigator.pop(ctx);
                _showProcessingDialog(
                  langProvider.translate('adding_to_playlist'),
                );

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
                    SnackBar(
                      content: Text(
                        langProvider
                            .translate('song_added')
                            .replaceAll('{0}', song.title),
                      ),
                    ),
                  );
                }
              }
            },
            child: Text(
              langProvider.translate('create'),
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
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            langProvider.translate('song_added').replaceAll('{0}', song.title),
          ),
        ),
      );
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
