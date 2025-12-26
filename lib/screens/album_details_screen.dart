import 'dart:convert';
import 'dart:ui';
import 'dart:developer' as developer;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'artist_details_screen.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../providers/radio_provider.dart';
import '../widgets/youtube_popup.dart';
import '../models/saved_song.dart';
import '../services/music_metadata_service.dart';

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
  String _selectedProvider = 'youtube'; // Default provider
  int? _selectedTrackIndex; // Track index to highlight

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

        return tracks;
      }
    } catch (e) {
      developer.log("Error fetching tracks: $e");
    }
    return [];
  }

  Widget _buildProviderIcon(IconData icon, Color color, String providerId) {
    final isSelected = _selectedProvider == providerId;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedProvider = providerId;
          });
        },
        borderRadius: BorderRadius.circular(50),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected ? color.withOpacity(0.2) : Colors.transparent,
            shape: BoxShape.circle,
            border: isSelected
                ? Border.all(color: color.withOpacity(0.5), width: 2)
                : Border.all(color: Colors.transparent, width: 2),
          ),
          child: FaIcon(
            icon,
            color: isSelected ? color : Colors.white.withOpacity(0.3),
            size: 24,
          ),
        ),
      ),
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
                      Colors.black.withOpacity(0.6),
                      Colors.black.withOpacity(0.9),
                      Colors.black,
                    ],
                  ),
                ),
              ),

              // 4. Content
              CustomScrollView(
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
                                  color: Colors.black.withOpacity(0.5),
                                  blurRadius: 30,
                                  offset: const Offset(0, 15),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: displayImage.isNotEmpty
                                ? Image.network(displayImage, fit: BoxFit.cover)
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                          decoration: TextDecoration.underline,
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
                                                      .withOpacity(0.5),
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
                          // Provider Selector
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildProviderIcon(
                                  FontAwesomeIcons.youtube,
                                  Colors.red,
                                  'youtube',
                                ),
                                const SizedBox(width: 24),
                                _buildProviderIcon(
                                  FontAwesomeIcons.spotify,
                                  Colors.green,
                                  'spotify',
                                ),
                                const SizedBox(width: 24),
                                _buildProviderIcon(
                                  FontAwesomeIcons.apple,
                                  Colors.white,
                                  'apple',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "Select provider to play tracks",
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.4),
                              fontSize: 10,
                            ),
                          ),
                          if (albumData != null) ...[
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: () async {
                                final tracks = await _fetchTracks(
                                  albumData['collectionId'],
                                );
                                if (tracks.isEmpty) return;

                                if (!context.mounted) return;
                                final provider = Provider.of<RadioProvider>(
                                  context,
                                  listen: false,
                                );
                                int addedCount = 0;

                                for (var track in tracks) {
                                  final trackArtist =
                                      track['artistName'] ?? displayArtist;
                                  final trackName =
                                      track['trackName'] ?? "Unknown Track";

                                  final song = SavedSong(
                                    id:
                                        track['trackId']?.toString() ??
                                        DateTime.now().millisecondsSinceEpoch
                                            .toString(),
                                    title: trackName,
                                    artist: trackArtist,
                                    album: displayName,
                                    artUri: displayImage,
                                    appleMusicUrl: track['trackViewUrl'],
                                    dateAdded: DateTime.now(),
                                    releaseDate: albumData['releaseDate'],
                                  );

                                  await provider.addFoundSongToGenre(
                                    SongSearchResult(
                                      song: song,
                                      genre: genre ?? "Mix",
                                    ),
                                  );
                                  addedCount++;
                                }

                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        "Added $addedCount songs to ${genre ?? "Mix"}",
                                      ),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(
                                Icons.playlist_add,
                                color: Colors.black,
                              ),
                              label: const Text(
                                "Add All to Playlist",
                                style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.greenAccent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // Tracks List
                  if (albumData != null)
                    FutureBuilder<List<Map<String, dynamic>>>(
                      future: _fetchTracks(albumData['collectionId']),
                      builder: (context, trackSnap) {
                        if (trackSnap.connectionState ==
                            ConnectionState.waiting) {
                          return const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(child: CircularProgressIndicator()),
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

                        return SliverList(
                          delegate: SliverChildBuilderDelegate((
                            innerContext,
                            index,
                          ) {
                            final track = tracks[index];
                            final trackName =
                                track['trackName'] ?? "Unknown Track";
                            // For artist, use track artist or album artist
                            final trackArtist =
                                track['artistName'] ?? displayArtist;

                            final isSelected = _selectedTrackIndex == index;

                            final isContextTrack =
                                widget.songName != null &&
                                _cleanTitle(trackName).toLowerCase() ==
                                    _cleanTitle(widget.songName!).toLowerCase();

                            // Check if song is already saved
                            final provider = Provider.of<RadioProvider>(
                              context,
                            );

                            bool isSaved = false;
                            String? existingPlaylistId;
                            String? existingSongId;

                            final cleanTrackTitle = _cleanTitle(
                              trackName,
                            ).toLowerCase();
                            final cleanTrackArtist = _cleanArtistName(
                              trackArtist,
                            ).toLowerCase();

                            for (var p in provider.playlists) {
                              if (isSaved) break;
                              for (var s in p.songs) {
                                final sTitle = _cleanTitle(
                                  s.title,
                                ).toLowerCase();
                                final sArtist = _cleanArtistName(
                                  s.artist,
                                ).toLowerCase();
                                if (sTitle == cleanTrackTitle &&
                                    sArtist == cleanTrackArtist) {
                                  isSaved = true;
                                  existingPlaylistId = p.id;
                                  existingSongId = s.id;
                                  break;
                                }
                              }
                            }

                            return Container(
                              color: isSelected
                                  ? Colors.white.withOpacity(0.1)
                                  : Colors.transparent,
                              child: ListTile(
                                leading: Text(
                                  "${track['trackNumber'] ?? index + 1}",
                                  style: TextStyle(
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.white54,
                                    fontWeight: isSelected || isContextTrack
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                title: Text(
                                  trackName,
                                  style: TextStyle(
                                    color: isContextTrack
                                        ? Colors.redAccent
                                        : Colors.white,
                                    fontWeight: isSelected || isContextTrack
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
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
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        color: isSaved
                                            ? Colors.redAccent
                                            : Colors.white54,
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        if (isSaved) {
                                          if (existingPlaylistId != null &&
                                              existingSongId != null) {
                                            provider.removeFromPlaylist(
                                              existingPlaylistId,
                                              existingSongId,
                                            );
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  "Removed '$trackName' from playlists",
                                                ),
                                              ),
                                            );
                                          }
                                        } else {
                                          final song = SavedSong(
                                            id:
                                                track['trackId']?.toString() ??
                                                DateTime.now()
                                                    .millisecondsSinceEpoch
                                                    .toString(),
                                            title: trackName,
                                            artist: trackArtist,
                                            album: displayName,
                                            artUri: displayImage,
                                            appleMusicUrl:
                                                track['trackViewUrl'],
                                            dateAdded: DateTime.now(),
                                            releaseDate:
                                                albumData['releaseDate'],
                                          );

                                          provider.addFoundSongToGenre(
                                            SongSearchResult(
                                              song: song,
                                              genre: genre ?? "Mix",
                                            ),
                                          );

                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                "Added '$trackName' to ${genre ?? "Mix"}",
                                              ),
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  ],
                                ),
                                onTap: () async {
                                  setState(() {
                                    _selectedTrackIndex = index;
                                  });

                                  final provider = Provider.of<RadioProvider>(
                                    context,
                                    listen: false,
                                  );

                                  // Show loading
                                  if (!mounted) return;
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
                                    final searchTitle = _cleanTitle(trackName);
                                    final links = await provider
                                        .resolveLinks(
                                          title: searchTitle,
                                          artist: trackArtist,
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
                                    ).pop(); // Dismiss loading
                                    String? url;

                                    if (_selectedProvider == 'youtube') {
                                      String? videoUrl = links['youtube'];
                                      String? videoId;

                                      if (videoUrl != null) {
                                        videoId = YoutubePlayer.convertUrlToId(
                                          videoUrl,
                                        );
                                        // Fallback manual extraction if library fails
                                        if (videoId == null) {
                                          final regExp = RegExp(
                                            r'[?&]v=([^&#]+)',
                                          );
                                          final match = regExp.firstMatch(
                                            videoUrl,
                                          );
                                          if (match != null) {
                                            videoId = match.group(1);
                                          }
                                        }
                                      }
                                      if (videoId != null) {
                                        provider.pause();
                                        if (mounted) {
                                          await showDialog(
                                            context: context,
                                            builder: (_) => YouTubePopup(
                                              videoId: videoId!,
                                              songName: trackName,
                                              artistName: trackArtist,
                                              albumName: displayName,
                                              artworkUrl: displayImage,
                                            ),
                                          );
                                        }
                                        return; // Done
                                      } else if (videoUrl != null) {
                                        // Valid URL but not an ID we can extract (e.g. channel link?), launch external
                                        await launchUrl(
                                          Uri.parse(videoUrl),
                                          mode: LaunchMode.externalApplication,
                                        );
                                        return;
                                      } else {
                                        // No link found
                                        if (mounted) {
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
                                        return;
                                      }
                                    }

                                    // Other providers
                                    if (_selectedProvider == 'spotify') {
                                      url = links['spotify'];
                                      url ??=
                                          "https://open.spotify.com/search/${Uri.encodeComponent("$trackArtist - $searchTitle")}";
                                    } else if (_selectedProvider == 'apple') {
                                      url =
                                          links['appleMusic'] ??
                                          track['trackViewUrl'];
                                      url ??=
                                          "https://music.apple.com/search?term=${Uri.encodeComponent("$trackArtist - $searchTitle")}";
                                    }

                                    if (url != null && url.isNotEmpty) {
                                      await launchUrl(
                                        Uri.parse(url),
                                        mode: LaunchMode.externalApplication,
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
                                  } finally {
                                    if (mounted) {
                                      setState(() {
                                        _selectedTrackIndex = null;
                                      });
                                    }
                                  }
                                },
                              ),
                            );
                          }, childCount: tracks.length),
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
                  const SliverPadding(padding: EdgeInsets.only(bottom: 50)),
                ],
              ),

              // 3. Back Button (Moved to top of stack Z-order)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  color: Colors.white,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withOpacity(0.2),
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          );
        },
      ),
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
