import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    as ye
    hide Playlist;
import '../services/encryption_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/radio_provider.dart';
import '../services/radio_audio_handler.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import '../providers/language_provider.dart';

import '../services/backup_service.dart';
import '../services/notification_service.dart';
import 'trending_details_screen.dart';
import 'artist_details_screen.dart';
import '../widgets/youtube_popup.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'spotify_login_screen.dart';
import 'local_library_screen.dart';

import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'playlist_screen_duplicates_logic.dart';
import '../widgets/native_ad_widget.dart';
import 'add_song_screen.dart';
import '../services/entitlement_service.dart';

enum MetadataViewMode { playlists, artists, albums }

enum PlaylistSortMode { custom, alphabetical }

enum PlaylistGroupingMode { album, artist, none }

class _AdItem {
  const _AdItem();
}

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen>
    with AutomaticKeepAliveClientMixin {
  String? _selectedPlaylistId;
  String? _selectedArtist;
  String? _selectedArtistDisplay;
  bool _selectedArtistIsGroup = false;
  String? _selectedAlbum;
  String? _selectedAlbumDisplay;
  bool _selectedAlbumIsGroup = false;
  MetadataViewMode _viewMode = MetadataViewMode.playlists;
  PlaylistSortMode _sortMode = PlaylistSortMode.custom;
  PlaylistGroupingMode _groupingMode = PlaylistGroupingMode.none;
  bool _isBulkChecking = false;
  bool _hasShownUpgradeDialog = false;
  bool _sortAlphabetical = false;
  bool _showPlaylistSearch = false;

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

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Check for Upgrade Proposals
    final provider = Provider.of<RadioProvider>(context, listen: true);
    if (provider.upgradeProposals.isNotEmpty && !_hasShownUpgradeDialog) {
      _hasShownUpgradeDialog = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showUpgradeDialog(context, provider);
      });
    }
  }

  void _showUpgradeDialog(BuildContext context, RadioProvider provider) {
    // Creating a local set to track selected proposals.
    // We initiate it with all proposals selected by default.
    final Set<String> selectedProposalIds = provider.upgradeProposals
        .map((p) => "${p.playlistId}_${p.songId}")
        .toSet();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            final proposals = provider.upgradeProposals;
            return AlertDialog(
              backgroundColor: const Color(0xFF1a1a2e),
              title: const Text(
                "Local Files Found",
                style: TextStyle(color: Colors.white),
              ),
              content: Container(
                constraints: const BoxConstraints(maxHeight: 400),
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Found ${proposals.length} songs that are available on your device. Select the ones you want to switch to offline versions for better performance.",
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    // "Select All" / "Deselect All" convenience
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            setState(() {
                              if (selectedProposalIds.length ==
                                  proposals.length) {
                                selectedProposalIds.clear();
                              } else {
                                selectedProposalIds.addAll(
                                  proposals.map(
                                    (p) => "${p.playlistId}_${p.songId}",
                                  ),
                                );
                              }
                            });
                          },
                          child: Text(
                            selectedProposalIds.length == proposals.length
                                ? "Deselect All"
                                : "Select All",
                          ),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12),
                    Expanded(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: proposals.length,
                        separatorBuilder: (_, __) =>
                            const Divider(color: Colors.white12, height: 1),
                        itemBuilder: (context, index) {
                          final p = proposals[index];
                          final uniqueId = "${p.playlistId}_${p.songId}";
                          final isSelected = selectedProposalIds.contains(
                            uniqueId,
                          );

                          return CheckboxListTile(
                            value: isSelected,
                            activeColor: Theme.of(context).primaryColor,
                            checkColor: Colors.white,
                            contentPadding: EdgeInsets.zero,
                            onChanged: (val) {
                              setState(() {
                                if (val == true) {
                                  selectedProposalIds.add(uniqueId);
                                } else {
                                  selectedProposalIds.remove(uniqueId);
                                }
                              });
                            },
                            title: Text(
                              p.songTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              p.songArtist,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            secondary: const Icon(
                              Icons.smartphone_rounded,
                              color: Colors.greenAccent,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    // Clear proposals so we don't ask again this session
                    provider.upgradeProposals.clear();
                  },
                  child: Text(
                    Provider.of<LanguageProvider>(
                      context,
                      listen: false,
                    ).translate('cancel'),
                  ),
                ),
                ElevatedButton(
                  onPressed: selectedProposalIds.isEmpty
                      ? null
                      : () {
                          final toApply = proposals.where((p) {
                            return selectedProposalIds.contains(
                              "${p.playlistId}_${p.songId}",
                            );
                          }).toList();

                          provider.applyUpgrades(toApply);
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    )
                                    .translate('updated_local_files')
                                    .replaceAll(
                                      '{0}',
                                      toApply.length.toString(),
                                    ),
                              ),
                            ),
                          );
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    disabledBackgroundColor: Colors.grey.withValues(alpha: 0.5),
                  ),
                  child: Text(
                    "Update Selected (${selectedProposalIds.length})",
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _showOnlyInvalid = false;
  bool _showOnlyLocal = false;
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
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    if (_selectedPlaylistId != null) {
      final provider = Provider.of<RadioProvider>(context, listen: false);
      try {
        return provider.playlists
            .firstWhere((p) => p.id == _selectedPlaylistId)
            .name;
      } catch (_) {
        return lang.translate('tab_playlists');
      }
    }
    if (_selectedArtist != null) {
      return _selectedArtistDisplay ?? _selectedArtist!;
    }
    if (_selectedAlbum != null) {
      return _selectedAlbumDisplay ?? _selectedAlbum!;
    }
    return lang.translate('tab_library');
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

    if (applyFilter) {
      var filteredSongs = List<SavedSong>.from(playlist.songs);

      if (_showOnlyInvalid) {
        filteredSongs = filteredSongs
            .where((s) => !s.isValid || provider.invalidSongIds.contains(s.id))
            .toList();
      }

      if (_showOnlyLocal) {
        filteredSongs = filteredSongs
            .where((s) => s.localPath != null || s.id.startsWith('local_'))
            .toList();
      }

      if (_sortAlphabetical) {
        filteredSongs.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      }

      return playlist.copyWith(songs: filteredSongs);
    }

    return playlist;
  }

  List<SavedSong> get currentSongList => effectivePlaylist?.songs ?? [];

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
      SnackBar(
        content: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('keep_holding_unlock'),
        ),
        duration: const Duration(milliseconds: 2000),
      ),
    );

    _unlockTimer = Timer(const Duration(milliseconds: 1500), () async {
      await provider.unmarkSongAsInvalid(song.id, playlistId: playlistId);
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('song_unlocked'),
            ),
          ),
        );
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
    bool isLocalPlaylist = false;
    try {
      final p = provider.playlists.firstWhere(
        (element) => element.id == playlistId,
      );
      isLocalPlaylist = (p.creator == 'local');
    } catch (_) {}

    final bool isLocalSong =
        song.localPath != null || song.id.startsWith('local_');
    final bool hideOnline = isLocalPlaylist || isLocalSong;

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
            if (!hideOnline)
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
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            if (!hideOnline) const Divider(color: Colors.white10),
            ListTile(
              leading: const Icon(Icons.refresh_rounded, color: Colors.green),
              title: const Text(
                "Try Again & Unlock",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _testAndUnlockTrack(provider, song, playlistId);
              },
            ),
            if (!hideOnline)
              ListTile(
                leading: const Icon(
                  Icons.lock_open_rounded,
                  color: Colors.green,
                ),
                title: const Text(
                  "Force Unlock",
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await provider.unmarkSongAsInvalid(
                    song.id,
                    playlistId: playlistId,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          Provider.of<LanguageProvider>(
                            context,
                            listen: false,
                          ).translate('song_unlocked'),
                        ),
                      ),
                    );
                  }
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
            if (!hideOnline)
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
                          child: Text(
                            Provider.of<LanguageProvider>(
                              context,
                              listen: false,
                            ).translate('cancel'),
                          ),
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

  Future<void> _testAndUnlockTrack(
    RadioProvider provider,
    SavedSong song,
    String playlistId,
  ) async {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(lang.translate('testing_track'))));

    try {
      bool isLocalPlaylist = false;
      try {
        final p = provider.playlists.firstWhere((p) => p.id == playlistId);
        isLocalPlaylist = p.creator == 'local';
      } catch (_) {}

      final verifySuccess = await _verifyTrack(
        provider,
        song,
        forceLocalOnly: isLocalPlaylist,
        playlistId: playlistId,
      );

      if (verifySuccess) {
        await provider.unmarkSongAsInvalid(song.id, playlistId: playlistId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(lang.translate('test_success_unlocked'))),
          );
        }
      } else {
        if (mounted) {
          final isLocal = song.localPath != null && song.localPath!.isNotEmpty;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isLocal
                    ? lang.translate('verification_failed_local')
                    : lang.translate('verification_failed_link'),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(lang.translate('test_failed_invalid'))),
        );
      }
    }
  }

  Future<bool> _verifyTrack(
    RadioProvider provider,
    SavedSong song, {
    bool forceLocalOnly = false,
    String? playlistId,
  }) async {
    // 1. Local File Check
    if (song.localPath != null && song.localPath!.isNotEmpty) {
      final file = File(song.localPath!);
      if (await file.exists()) return true;
    }

    // NEW: Search for song on device if it's a local track or in a local playlist
    if (playlistId != null &&
        (song.localPath != null ||
            song.id.startsWith('local_') ||
            forceLocalOnly)) {
      final success = await provider.tryFixLocalSongPath(playlistId, song);
      if (success) return true;
    }

    // If it's a local song or we're in a local playlist, don't fall back to online check
    if (forceLocalOnly || song.id.startsWith('local_')) {
      return false;
    }

    // 2. Online Link Check
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
          final yt = ye.YoutubeExplode();
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
        content: Text(
          Provider.of<LanguageProvider>(context, listen: false)
              .translate('checking_invalid_tracks')
              .replaceAll('{0}', invalidSongs.length.toString()),
        ),
      ),
    );

    int unlockedCount = 0;
    bool isLocalPlaylist = false;
    if (playlistId != null) {
      try {
        final p = provider.playlists.firstWhere((p) => p.id == playlistId);
        isLocalPlaylist = p.creator == 'local';
      } catch (_) {}
    }

    for (var song in invalidSongs) {
      if (!mounted) break;
      final success = await _verifyTrack(
        provider,
        song,
        forceLocalOnly: isLocalPlaylist,
        playlistId: playlistId,
      );
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
            Provider.of<LanguageProvider>(context, listen: false)
                .translate('bulk_check_completed')
                .replaceAll('{0}', unlockedCount.toString()),
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
            child: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('close'),
              style: const TextStyle(color: Colors.blue),
            ),
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
            style: TextStyle(
              color: Theme.of(
                context,
              ).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodyLarge?.color,
              fontSize: 14,
            ),
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
    super.build(context);
    final provider = Provider.of<RadioProvider>(context);
    final lang = Provider.of<LanguageProvider>(context);
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

    final bool isLocalPlaylist = rawPlaylist?.creator == 'local';
    final hasLocalSongs =
        isLocalPlaylist ||
        (rawPlaylist?.songs.any(
              (s) => s.localPath != null || s.id.startsWith('local_'),
            ) ??
            false);

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
    final appBarBgColor =
        Theme.of(context).appBarTheme.backgroundColor ??
        Theme.of(context).primaryColor;
    final headerContrastColor = appBarBgColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

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
          if (mode == MetadataViewMode.artists) {
            provider.enrichAllArtists();
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).primaryColor
                : headerContrastColor.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : headerContrastColor.withValues(alpha: 0.5),
            ),
          ),
          child: Text(
            title,
            style: TextStyle(
              color: selected
                  ? (Theme.of(context).primaryColor.computeLuminance() > 0.5
                        ? Colors.black
                        : Colors.white)
                  : headerContrastColor.withValues(alpha: 0.5),
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
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(0),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              // Custom Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: appBarBgColor,
                  borderRadius: BorderRadius.circular(0),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        if (isSelectionActive)
                          IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new_rounded),
                            color: headerContrastColor,
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
                              color: headerContrastColor,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            headerTitle,
                            style: TextStyle(
                              color: headerContrastColor,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (hasLocalSongs || _showOnlyLocal)
                          Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: Tooltip(
                              message: _showOnlyLocal
                                  ? "Show All Songs"
                                  : "Show Local Only",
                              child: IconButton(
                                icon: Icon(
                                  Icons.smartphone_rounded,
                                  color: _showOnlyLocal
                                      ? Theme.of(context).primaryColor
                                      : headerContrastColor,
                                  size: 20,
                                ),
                                style: IconButton.styleFrom(
                                  backgroundColor: _showOnlyLocal
                                      ? Theme.of(
                                          context,
                                        ).primaryColor.withValues(alpha: 0.2)
                                      : null,
                                  padding: const EdgeInsets.all(8),
                                  minimumSize: const Size(36, 36),
                                ),
                                onPressed: () {
                                  setState(() {
                                    _showOnlyLocal = !_showOnlyLocal;
                                  });
                                },
                              ),
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
                                        ? Colors.orangeAccent.withValues(
                                            alpha: 0.15,
                                          )
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
                            icon: Icon(
                              Icons.playlist_play_rounded,
                              size: 32,
                              color: headerContrastColor,
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
                            icon: Icon(
                              Icons.more_vert_rounded,
                              color: headerContrastColor,
                            ),
                            tooltip: "Options",
                            onSelected: (value) {
                              if (value == 'sort') {
                                setState(() {
                                  _sortAlphabetical = !_sortAlphabetical;
                                });
                              } else if (value == 'search') {
                                setState(() {
                                  _showPlaylistSearch = !_showPlaylistSearch;
                                  if (!_showPlaylistSearch) {
                                    _searchController.clear();
                                  }
                                });
                              } else if (value == 'group_album') {
                                setState(
                                  () => _groupingMode =
                                      PlaylistGroupingMode.album,
                                );
                              } else if (value == 'group_artist') {
                                setState(
                                  () => _groupingMode =
                                      PlaylistGroupingMode.artist,
                                );
                              } else if (value == 'group_none') {
                                setState(
                                  () =>
                                      _groupingMode = PlaylistGroupingMode.none,
                                );
                              } else if (value == 'shuffle') {
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
                              // Use onSurface for text to ensure visibility against the menu background
                              final onSurfaceColor = Theme.of(
                                context,
                              ).colorScheme.onSurface;
                              final iconColor =
                                  Theme.of(context).iconTheme.color ??
                                  onSurfaceColor.withValues(alpha: 0.7);
                              final primaryColor = Theme.of(
                                context,
                              ).primaryColor;
                              final lang = Provider.of<LanguageProvider>(
                                context,
                                listen: false,
                              );

                              return [
                                PopupMenuItem(
                                  value: 'sort',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.sort_by_alpha,
                                        color: _sortAlphabetical
                                            ? primaryColor
                                            : iconColor,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        lang.translate('sort_alphabetically'),
                                        style: TextStyle(
                                          color: _sortAlphabetical
                                              ? primaryColor
                                              : onSurfaceColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'search',
                                  child: Row(
                                    children: [
                                      Icon(
                                        _showPlaylistSearch
                                            ? Icons.search_off
                                            : Icons.search,
                                        color: _showPlaylistSearch
                                            ? primaryColor
                                            : iconColor,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        _showPlaylistSearch
                                            ? lang.translate('hide_find')
                                            : lang.translate(
                                                'find_in_playlist',
                                              ),
                                        style: TextStyle(
                                          color: _showPlaylistSearch
                                              ? primaryColor
                                              : onSurfaceColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const PopupMenuDivider(),
                                PopupMenuItem(
                                  enabled: false,
                                  height: 32,
                                  child: Text(
                                    lang.translate('group_by').toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context).hintColor,
                                    ),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'group_album',
                                  height: 48,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.album,
                                        color:
                                            _groupingMode ==
                                                PlaylistGroupingMode.album
                                            ? primaryColor
                                            : iconColor,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        lang.translate('label_album'),
                                        style: TextStyle(
                                          color:
                                              _groupingMode ==
                                                  PlaylistGroupingMode.album
                                              ? primaryColor
                                              : onSurfaceColor,
                                        ),
                                      ),
                                      if (_groupingMode ==
                                          PlaylistGroupingMode.album) ...[
                                        const Spacer(),
                                        Icon(
                                          Icons.check,
                                          size: 16,
                                          color: primaryColor,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'group_artist',
                                  height: 48,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.person,
                                        color:
                                            _groupingMode ==
                                                PlaylistGroupingMode.artist
                                            ? primaryColor
                                            : iconColor,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        lang.translate('label_artist'),
                                        style: TextStyle(
                                          color:
                                              _groupingMode ==
                                                  PlaylistGroupingMode.artist
                                              ? primaryColor
                                              : onSurfaceColor,
                                        ),
                                      ),
                                      if (_groupingMode ==
                                          PlaylistGroupingMode.artist) ...[
                                        const Spacer(),
                                        Icon(
                                          Icons.check,
                                          size: 16,
                                          color: primaryColor,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'group_none',
                                  height: 48,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.list,
                                        color:
                                            _groupingMode ==
                                                PlaylistGroupingMode.none
                                            ? primaryColor
                                            : iconColor,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        lang.translate('none'),
                                        style: TextStyle(
                                          color:
                                              _groupingMode ==
                                                  PlaylistGroupingMode.none
                                              ? primaryColor
                                              : onSurfaceColor,
                                        ),
                                      ),
                                      if (_groupingMode ==
                                          PlaylistGroupingMode.none) ...[
                                        const Spacer(),
                                        Icon(
                                          Icons.check,
                                          size: 16,
                                          color: primaryColor,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const PopupMenuDivider(),
                                PopupMenuItem(
                                  value: 'shuffle',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.shuffle_rounded,
                                        color: provider.isShuffleMode
                                            ? Colors.redAccent
                                            : iconColor,
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        lang.translate('shuffle'),
                                        style: TextStyle(
                                          color: provider.isShuffleMode
                                              ? Colors.redAccent
                                              : onSurfaceColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_selectedPlaylistId != null) ...[
                                  PopupMenuItem(
                                    value: 'duplicates',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.cleaning_services_rounded,
                                          color: iconColor,
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          lang.translate('scan_duplicates'),
                                          style: TextStyle(
                                            color: onSurfaceColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
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
                                                ? lang.translate('processing')
                                                : lang.translate(
                                                    'try_again_unlock_all',
                                                  ),
                                            style: TextStyle(
                                              color: onSurfaceColor,
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
                            color: Theme.of(
                              context,
                            ).appBarTheme.foregroundColor,
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
                              color: Theme.of(
                                context,
                              ).appBarTheme.foregroundColor,
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.add_rounded, size: 28),
                              color: Theme.of(
                                context,
                              ).appBarTheme.foregroundColor,
                              tooltip: "Create Playlist",
                              onPressed: () =>
                                  _showCreatePlaylistDialog(context, provider),
                            ),
                            const SizedBox(width: 8),
                            // Filter Button
                            IconButton(
                              icon: Icon(
                                provider.playlistCreatorFilter.isEmpty
                                    ? Icons.filter_none
                                    : Icons.filter_list_alt,
                                //    color: provider.playlistCreatorFilter.isEmpty
                                //        ? Colors.white54
                                //        : Theme.of(context).primaryColor,
                                color: provider.playlistCreatorFilter.isEmpty
                                    ? Theme.of(
                                        context,
                                      ).appBarTheme.foregroundColor
                                    : Theme.of(context).primaryColor,
                              ),
                              tooltip: "Filter Playlists",
                              onPressed: () =>
                                  _showFilterDialog(context, provider),
                            ),
                          ],
                          if (_viewMode == MetadataViewMode.artists) ...[
                            IconButton(
                              icon: Icon(
                                _showFollowedArtistsOnly
                                    ? Icons.how_to_reg
                                    : Icons.person_add_alt,
                                color: _showFollowedArtistsOnly
                                    ? Theme.of(context).primaryColor
                                    : Theme.of(
                                        context,
                                      ).appBarTheme.foregroundColor,
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
                          ],
                          if (_viewMode == MetadataViewMode.albums)
                            IconButton(
                              icon: Icon(
                                _showFollowedAlbumsOnly
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                color: _showFollowedAlbumsOnly
                                    ? Theme.of(context).primaryColor
                                    : Theme.of(context)
                                          .appBarTheme
                                          .foregroundColor
                                          ?.withValues(alpha: 0.5),
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
                              lang.translate('tab_playlists'),
                              MetadataViewMode.playlists,
                            ),
                            const SizedBox(width: 8),
                            buildModeBtn(
                              lang.translate('tab_artists'),
                              MetadataViewMode.artists,
                            ),
                            const SizedBox(width: 8),
                            buildModeBtn(
                              lang.translate('tab_albums'),
                              MetadataViewMode.albums,
                            ),
                            const SizedBox(width: 8),
                            // Search Bar
                            Expanded(
                              child: Container(
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .scaffoldBackgroundColor
                                      .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).dividerColor.withValues(alpha: 0.5),
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
                    if (isSelectionActive && _showPlaylistSearch)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 4.0,
                        ),
                        child: Container(
                          height: 36,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).scaffoldBackgroundColor.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).dividerColor.withValues(alpha: 0.5),
                            ),
                          ),
                          child: TextField(
                            controller: _searchController,
                            autofocus: true,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).textTheme.bodyMedium?.color,
                              fontSize: 13,
                            ),
                            textAlignVertical: TextAlignVertical.center,
                            decoration: InputDecoration(
                              hintText: "Search in playlist...",
                              hintStyle: TextStyle(
                                color: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.color
                                    ?.withValues(alpha: 0.7),
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
                              suffixIcon: IconButton(
                                icon: Icon(
                                  Icons.close,
                                  color: Theme.of(
                                    context,
                                  ).iconTheme.color?.withValues(alpha: 0.5),
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
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                            ),
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
                            // Also search for missing artworks when refreshing a specific playlist
                            await provider.findMissingArtworks(
                              playlistId: _selectedPlaylistId,
                            );
                          } else {
                            // If artist or album selection, still refresh all?
                            // Or maybe just reload. For now, let's call it without ID.
                            await provider.reloadPlaylists();
                            await provider.findMissingArtworks();
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
                        return RefreshIndicator(
                          onRefresh: () async {
                            await provider.reloadPlaylists();
                            await provider.findMissingArtworks();
                          },
                          child: ListView(
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
                          ),
                        );
                      case MetadataViewMode.artists:
                        return RefreshIndicator(
                          onRefresh: () async {
                            await provider.reloadPlaylists();
                            await provider.findMissingArtworks();
                          },
                          child: _buildArtistsGrid(context, provider, allSongs),
                        );
                      case MetadataViewMode.albums:
                        return RefreshIndicator(
                          onRefresh: () async {
                            await provider.reloadPlaylists();
                            await provider.findMissingArtworks();
                          },
                          child: _buildAlbumsGrid(context, provider, allSongs),
                        );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('playlist_empty'),
          ),
        ),
      );
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
    final hasAnySpotify = provider.playlists.any(
      (p) => p.id.startsWith('spotify_') || p.creator == 'spotify',
    );
    final hasAnyLocal = provider.playlists.any((p) => p.creator == 'local');
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    final entitlements = Provider.of<EntitlementService>(context);
    final canUseSpotify = entitlements.isFeatureEnabled('spotify_integration');
    final canUseLocal = entitlements.isFeatureEnabled('local_library');

    final bool showSpotifyLink =
        _searchQuery.isEmpty && !hasAnySpotify && canUseSpotify;
    final bool showLocalLink =
        _searchQuery.isEmpty && !hasAnyLocal && canUseLocal;

    final int extraCount = (showSpotifyLink ? 1 : 0) + (showLocalLink ? 1 : 0);

    if (playlists.isEmpty && extraCount == 0) {
      return Center(
        child: Text(
          _searchQuery.isEmpty
              ? lang.translate('no_playlists')
              : lang.translate('no_playlists_search'),
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
            final int crossAxisCount = (width / 150).ceil();
            final double itemWidth =
                (width - (crossAxisCount - 1) * 8) / crossAxisCount;
            final double rowHeight = itemWidth; // aspect ratio 1.0

            final int row = playingIndex ~/ crossAxisCount;
            final double rowPosition = row * (rowHeight + 8); // + spacing

            // Center the item
            final double centeredOffset =
                rowPosition - (constraints.maxHeight / 2) + (rowHeight / 2);

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_playlistsScrollController.hasClients) {
                final double maxScroll =
                    _playlistsScrollController.position.maxScrollExtent;
                final double targetOffset = centeredOffset.clamp(
                  0.0,
                  maxScroll > 0 ? maxScroll : centeredOffset,
                );

                _playlistsScrollController.animateTo(
                  targetOffset,
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
              maxCrossAxisExtent: 150,
              childAspectRatio: 1.0,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: playlists.length + extraCount,
            itemBuilder: (context, index) {
              if (index < playlists.length) {
                // Pass null key for static view
                return _buildPlaylistCard(
                  context,
                  provider,
                  playlists[index],
                  null,
                );
              } else {
                int invIdx = index - playlists.length;
                if (showSpotifyLink && invIdx == 0) {
                  return _buildDirectAccessCard(
                    context,
                    provider,
                    lang.translate('connect_spotify'),
                    lang.translate('import_spotify_playlists'),
                    FontAwesomeIcons.spotify,
                    const Color(0xFF1DB954),
                    () => _handleSpotifyLogin(context, provider),
                    const ValueKey('inv_spotify'),
                  );
                } else {
                  return _buildDirectAccessCard(
                    context,
                    provider,
                    lang.translate('local_music'),
                    lang.translate('add_folders_device'),
                    Icons.smartphone_rounded,
                    Colors.orangeAccent,
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LocalLibraryScreen(),
                      ),
                    ),
                    const ValueKey('inv_local'),
                  );
                }
              }
            },
          );
        }

        return ReorderableGridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 150,
            childAspectRatio: 1.0,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: playlists.length + extraCount,
          itemBuilder: (context, index) {
            if (index < playlists.length) {
              final playlist = playlists[index];
              // Use ValueKey for reordering
              return _buildPlaylistCard(
                context,
                provider,
                playlist,
                ValueKey(playlist.id),
              );
            } else {
              int invIdx = index - playlists.length;
              if (showSpotifyLink && invIdx == 0) {
                return _buildDirectAccessCard(
                  context,
                  provider,
                  lang.translate('connect_spotify'),
                  lang.translate('import_spotify_playlists'),
                  FontAwesomeIcons.spotify,
                  const Color(0xFF1DB954),
                  () => _handleSpotifyLogin(context, provider),
                  const ValueKey('inv_spotify'),
                );
              } else {
                return _buildDirectAccessCard(
                  context,
                  provider,
                  lang.translate('local_music'),
                  lang.translate('add_folders_device'),
                  Icons.smartphone_rounded,
                  Colors.orangeAccent,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LocalLibraryScreen(),
                    ),
                  ),
                  const ValueKey('inv_local'),
                );
              }
            }
          },
          onReorder: (oldIndex, newIndex) {
            // Prevent reordering invitation cards
            if (oldIndex >= playlists.length || newIndex >= playlists.length) {
              return;
            }

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
    // 1. Collect up to 4 covers from the first songs
    // We take the first 4 distinct non-empty art URIs if possible,
    // or just the first 4 available to ensure we represent the playlist content.
    final List<String> covers = [];
    final Set<String> seenUris = {};

    for (var song in playlist.songs) {
      if (song.artUri != null && song.artUri!.isNotEmpty) {
        // Normalize the URI to ensure we catch duplicates that might differ only by encoding or whitespace
        final String cleanUri = Uri.decodeFull(song.artUri!).trim();

        if (!seenUris.contains(cleanUri)) {
          seenUris.add(cleanUri);
          covers.add(
            song.artUri!,
          ); // Keep original URI for display to avoid breaking file paths
        }
      }
      if (covers.length >= 4) break;
    }

    // Check if this playlist is currently playing
    bool isPlaylistPlaying =
        provider.isPlaying &&
        (provider.currentPlayingPlaylistId == playlist.id);

    // Filter Logic Check (if searching highlight match?) - Optional logic from before
    if (provider.isPlaying && !isPlaylistPlaying && playlist.songs.isNotEmpty) {
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
      onTap: () async {
        // Check and repair local song links in background
        provider.validateLocalSongsInPlaylist(playlist.id);

        setState(() {
          _selectedPlaylistId = playlist.id;
          _searchController.clear();
          _lastScrolledSongId = null;
        });
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: isPlaylistPlaying
              ? Border.all(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.8),
                  width: 2,
                )
              : null,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withValues(alpha: 0.05),
          boxShadow: isPlaylistPlaying
              ? [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.3),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // BACKGROUND
            Positioned.fill(
              child: covers.isNotEmpty
                  ? _buildCollage(covers)
                  : Image.asset(
                      'assets/empty_playlist.png',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.white.withValues(alpha: 0.1),
                        child: const Center(
                          child: Icon(
                            Icons.broken_image,
                            color: Colors.white54,
                            size: 40,
                          ),
                        ),
                      ),
                    ),
            ),

            // GRADIENT OVERLAY
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.5),
                      Colors.black.withValues(alpha: 0.9),
                    ],
                    stops: const [0.0, 0.5, 0.8, 1.0],
                  ),
                ),
              ),
            ),

            // Source/Type Icon (Top Left)
            if (playlist.id.startsWith('spotify_'))
              const Positioned(
                top: 8,
                left: 8,
                child: FaIcon(
                  FontAwesomeIcons.spotify,
                  color: Color(0xFF1DB954),
                  size: 16,
                ),
              )
            else if (playlist.creator == 'local')
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.smartphone_rounded,
                    color: Colors.orangeAccent,
                    size: 12,
                  ),
                ),
              )
            else if (playlist.id == 'favorites')
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.favorite,
                    color: Colors.pinkAccent,
                    size: 12,
                  ),
                ),
              ),

            // MENU
            Positioned(
              top: 0,
              right: 0,
              child: Material(
                color: Colors.transparent,
                child: PopupMenuButton<String>(
                  icon: Stack(
                    children: [
                      // Shadow
                      Transform.translate(
                        offset: const Offset(1, 1),
                        child: const Icon(
                          Icons.more_vert_rounded,
                          color: Colors.black,
                          size: 18,
                        ),
                      ),
                      // Foreground
                      const Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ],
                  ),
                  color: const Color(0xFF1e1e24),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  itemBuilder: (context) => [
                    if (playlist.id == 'favorites') ...[
                      if (Provider.of<EntitlementService>(
                            context,
                            listen: false,
                          ).getFeatureLimit('download_songs') !=
                          0)
                        PopupMenuItem(
                          value: 'download',
                          child: Row(
                            children: [
                              const Icon(
                                Icons.download_rounded,
                                size: 18,
                                color: Colors.greenAccent,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                ).translate('download'),
                                style: const TextStyle(
                                  color: Colors.greenAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      PopupMenuItem(
                        value: 'clean_all',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.delete_sweep_rounded,
                              size: 18,
                              color: Colors.orangeAccent,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              Provider.of<LanguageProvider>(
                                context,
                                listen: false,
                              ).translate('clean_all'),
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      if (playlist.creator != 'local')
                        PopupMenuItem(
                          value: 'rename',
                          child: Row(
                            children: [
                              const Icon(
                                Icons.edit,
                                size: 18,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                ).translate('rename'),
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      if (playlist.creator != 'local' &&
                          Provider.of<EntitlementService>(
                                context,
                                listen: false,
                              ).getFeatureLimit('download_songs') !=
                              0)
                        PopupMenuItem(
                          value: 'download',
                          child: Row(
                            children: [
                              const Icon(
                                Icons.download_rounded,
                                size: 18,
                                color: Colors.greenAccent,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                ).translate('download'),
                                style: const TextStyle(
                                  color: Colors.greenAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      PopupMenuItem(
                        value: 'copy',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.copy,
                              size: 18,
                              color: Colors.blueAccent,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              Provider.of<LanguageProvider>(
                                context,
                                listen: false,
                              ).translate('copy_to_ellipsis'),
                              style: const TextStyle(color: Colors.blueAccent),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Colors.redAccent,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              Provider.of<LanguageProvider>(
                                context,
                                listen: false,
                              ).translate('delete'),
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                  onSelected: (value) {
                    if (value == 'download') {
                      _downloadPlaylist(context, provider, playlist);
                    } else if (value == 'rename') {
                      _showRenamePlaylistDialog(context, provider, playlist);
                    } else if (value == 'delete') {
                      _showDeletePlaylistDialog(context, provider, playlist);
                    } else if (value == 'copy') {
                      _showCopyPlaylistDialog(context, provider, playlist);
                    } else if (value == 'clean_all') {
                      _showClearFavoritesDialog(context, provider);
                    }
                  },
                ),
              ),
            ),

            // TEXT CONTENT
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    playlist.name.replaceAll('Spotify: ', ''),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: 0.5,
                      shadows: [
                        Shadow(
                          color: Colors.black,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Provider.of<LanguageProvider>(context, listen: false)
                        .translate('songs_count')
                        .replaceAll('{0}', playlist.songs.length.toString()),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 11,
                      shadows: const [
                        Shadow(
                          color: Colors.black,
                          blurRadius: 2,
                          offset: Offset(0, 1),
                        ),
                      ],
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

  Widget _buildCollage(List<String> images) {
    if (images.isEmpty) return const SizedBox();

    if (images.length == 1) {
      return _buildSingleCover(images[0]);
    }

    if (images.length == 2) {
      // 50% split (Horizontal split for side-by-side looks good in square card)
      return Row(
        children: [
          Expanded(child: _buildSingleCover(images[0])),
          Expanded(child: _buildSingleCover(images[1])),
        ],
      );
    }

    if (images.length == 3) {
      // 1 cover 50%, 2 cover 25% each
      return Row(
        children: [
          Expanded(child: _buildSingleCover(images[0])),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _buildSingleCover(images[1])),
                Expanded(child: _buildSingleCover(images[2])),
              ],
            ),
          ),
        ],
      );
    }

    // 4 or more: 2x2 Grid
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildSingleCover(images[0])),
              Expanded(child: _buildSingleCover(images[1])),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildSingleCover(images[2])),
              Expanded(child: _buildSingleCover(images[3])),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSingleCover(String uri) {
    if (uri.isEmpty) {
      return Container(color: Colors.white.withValues(alpha: 0.1));
    }
    if (uri.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: uri,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        httpHeaders: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
        errorWidget: (_, __, ___) => Container(
          color: Colors.white.withValues(alpha: 0.1),
          child: const Center(
            child: Icon(Icons.broken_image, color: Colors.white54, size: 40),
          ),
        ),
        placeholder: (_, __) => Container(
          color: Colors.white.withValues(alpha: 0.1),
          child: const Center(
            child: CircularProgressIndicator(color: Colors.white24),
          ),
        ),
      );
    } else if (uri.startsWith('assets/')) {
      return Image.asset(
        uri,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => Container(
          color: Colors.white.withValues(alpha: 0.1),
          child: const Center(
            child: Icon(Icons.broken_image, color: Colors.white54, size: 40),
          ),
        ),
      );
    } else {
      return Image.file(
        File(uri),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => Container(
          color: Colors.white.withValues(alpha: 0.1),
          child: const Center(
            child: Icon(Icons.broken_image, color: Colors.white54, size: 40),
          ),
        ),
      );
    }
  }

  Future<void> _downloadPlaylist(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
  ) async {
    // Entitlement Check: download_songs
    final entitlements = Provider.of<EntitlementService>(
      context,
      listen: false,
    );
    final int downloadLimit = entitlements.getFeatureLimit('download_songs');

    if (downloadLimit == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('no_permission_download'),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (downloadLimit != -1 && provider.totalDownloadedSongs >= downloadLimit) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(context, listen: false)
                .translate('download_limit_reached')
                .replaceAll('{0}', downloadLimit.toString()),
          ),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }

    // 0. High Data Usage Confirmation
    final bool shouldProceed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1e1e24),
            elevation: 24,
            shadowColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(
                color: Colors.white.withValues(alpha: 0.7),
                width: 1,
              ),
            ),
            title: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.signal_wifi_off_rounded,
                    color: Colors.orangeAccent,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  Provider.of<LanguageProvider>(
                    context,
                    listen: false,
                  ).translate('data_usage_warning'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  Provider.of<LanguageProvider>(
                    context,
                    listen: false,
                  ).translate('data_usage_desc'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 16,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                if (downloadLimit > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: Text(
                      Provider.of<LanguageProvider>(context, listen: false)
                          .translate('remaining_downloads')
                          .replaceAll(
                            '{0}',
                            (downloadLimit - provider.totalDownloadedSongs)
                                .toString(),
                          ),
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.blueAccent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        color: Colors.blueAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          Provider.of<LanguageProvider>(
                            context,
                            listen: false,
                          ).translate('wifi_recommendation'),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            actions: [
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('cancel'),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('continue'),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ) ??
        false;

    if (!shouldProceed) return;

    // 1. Initialize Notifiers BEFORE the dialog so they are ready
    ValueNotifier<String> songTitleNotifier = ValueNotifier("Initializing...");
    ValueNotifier<String> statusNotifier = ValueNotifier("Waiting...");
    ValueNotifier<double> currentFileProgress = ValueNotifier(0.0);
    ValueNotifier<double> totalProgress = ValueNotifier(0.0);
    bool isJobCancelled = false;
    bool isDismissed = false;
    int notificationId = playlist.id.hashCode;

    // Placeholder for saveDir until we determine it
    String currentPath = "Determining Path...";
    ValueNotifier<String> pathNotifier = ValueNotifier(currentPath);

    final cancelSubscription = NotificationService().onCancelDownload.listen((
      id,
    ) {
      if (id == notificationId) {
        isJobCancelled = true;
        statusNotifier.value = "Stopping...";
      }
    });

    // 1. Initial Global Sync: Link any already downloaded duplicates
    await provider.syncAllDownloadStatuses();

    // 2. Show Progress Dialog IMMEDIATELY
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            color: const Color(0xFF1e1e24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Container(
              width: 320,
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "Downloading Playlist",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Song Title
                  ValueListenableBuilder<String>(
                    valueListenable: songTitleNotifier,
                    builder: (context, title, _) {
                      return Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                  const SizedBox(height: 20),

                  // File Progress Bar
                  ValueListenableBuilder<double>(
                    valueListenable: currentFileProgress,
                    builder: (context, progress, _) {
                      return Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Current Song",
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              ValueListenableBuilder<String>(
                                valueListenable: statusNotifier,
                                builder: (context, status, _) => Text(
                                  status,
                                  style: const TextStyle(
                                    color: Colors.greenAccent,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: progress,
                            backgroundColor: Colors.white10,
                            color: Colors.greenAccent,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: 16),

                  // Total Progress Bar
                  Column(
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "Total Progress",
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<double>(
                        valueListenable: totalProgress,
                        builder: (context, progress, _) {
                          return LinearProgressIndicator(
                            value: progress,
                            backgroundColor: Colors.white10,
                            color: Colors.blueAccent,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            isJobCancelled = true;
                            statusNotifier.value = "Stopping...";
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent.withValues(
                              alpha: 0.1,
                            ),
                            foregroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: const BorderSide(color: Colors.redAccent),
                            ),
                          ),
                          icon: const Icon(Icons.stop_rounded, size: 18),
                          label: const Text(
                            "Stop",
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            isDismissed = true;
                            Navigator.pop(ctx);

                            // Trigger initial notification immediately upon hiding
                            NotificationService().showDownloadProgress(
                              id: notificationId,
                              title: playlist.name,
                              subTitle: "Preparing...",
                              progress: 0,
                              maxProgress: playlist.songs.length * 100,
                            );

                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  "Download continuing in background",
                                ),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent.withValues(
                              alpha: 0.1,
                            ),
                            foregroundColor: Colors.blueAccent,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: const BorderSide(color: Colors.blueAccent),
                            ),
                          ),
                          icon: const Icon(
                            Icons.visibility_off_rounded,
                            size: 18,
                          ), // Hide dialog icon
                          label: const Text(
                            "Hide",
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // 3. Perform Async Setup inside a try-catch
    Directory saveDir;
    try {
      if (Platform.isAndroid) {
        await [
          Permission.storage,
          Permission.audio,
        ].request().timeout(const Duration(seconds: 10), onTimeout: () => {});
      }

      String safeName = playlist.name
          .replaceAll(RegExp(r'[^\w\-]'), '_')
          .trim();
      if (safeName.isEmpty) safeName = "playlist_${playlist.id}";

      Directory? fallbackBase;

      if (Platform.isAndroid) {
        saveDir = Directory(
          '/storage/emulated/0/Android/media/com.fazio.musicstream/download/$safeName',
        );
      } else {
        try {
          fallbackBase = await getDownloadsDirectory();
        } catch (_) {}
        fallbackBase ??= await getApplicationDocumentsDirectory();
        saveDir = Directory('${fallbackBase.path}/MusicStream/$safeName');
      }

      if (!saveDir.existsSync()) {
        try {
          await saveDir.create(recursive: true);
        } catch (e) {
          fallbackBase ??= await getApplicationDocumentsDirectory();
          saveDir = Directory('${fallbackBase.path}/MusicStream/$safeName');
          await saveDir.create(recursive: true);
        }
      }

      pathNotifier.value = saveDir.path;
    } catch (e) {
      if (mounted && !isDismissed) Navigator.pop(context);
      return;
    }

    int successCount = 0;
    List<SavedSong> updatedSongs = List.from(playlist.songs);
    bool anyUpdate = false;

    try {
      for (int i = 0; i < updatedSongs.length; i++) {
        if (isJobCancelled) break;

        final song = updatedSongs[i];
        final String progressText =
            "${i + 1}/${updatedSongs.length}: ${song.title}";
        songTitleNotifier.value = progressText;
        statusNotifier.value = "Preparing...";

        if (isDismissed && !isJobCancelled) {
          NotificationService().showDownloadProgress(
            id: notificationId,
            title: playlist.name,
            subTitle: "Song ${i + 1}/${updatedSongs.length}: ${song.title}",
            progress: i * 100,
            maxProgress: updatedSongs.length * 100,
          );
        }
        currentFileProgress.value = 0.0;

        bool isHandled = false;

        // 1. Device Search
        if (song.localPath != null) {
          if (File(song.localPath!).existsSync()) {
            successCount++;
            isHandled = true;
          } else {
            updatedSongs[i] = song.copyWith(forceClearLocalPath: true);
            anyUpdate = true;
            // Persist the clearance immediately
            await provider.updateSongsInPlaylist(playlist.id, updatedSongs);
          }
        }

        if (!isHandled && !isJobCancelled) {
          try {
            final foundOnDevice = await provider
                .findSongOnDevice(song.title, song.artist)
                .timeout(const Duration(seconds: 5));
            if (foundOnDevice != null && File(foundOnDevice).existsSync()) {
              updatedSongs[i] = song.copyWith(localPath: foundOnDevice);
              anyUpdate = true;
              successCount++;
              isHandled = true;
              // Sync this status to all other playlists
              await provider.updateSongDownloadStatusGlobally(updatedSongs[i]);
            }
          } catch (_) {}
        }

        // 2. Internal Cache Check
        if (!isHandled && !isJobCancelled) {
          final hashedId = sha1.convert(utf8.encode(song.id)).toString();
          File? confirmedCache;

          // New check for hashed name and .mst extension
          final mstFile = File('${saveDir.path}/$hashedId.mst');

          // Legacy check for old extension/unhashed
          final safeId = song.id.replaceAll(RegExp(r'[^\w\d_]'), '');
          final m4aFile = File('${saveDir.path}/${safeId}_secure.m4a');
          final webmFile = File('${saveDir.path}/${safeId}_secure.webm');

          if (mstFile.existsSync() && mstFile.lengthSync() > 1024 * 50) {
            confirmedCache = mstFile;
          } else if (m4aFile.existsSync() && m4aFile.lengthSync() > 1024 * 50) {
            confirmedCache = m4aFile;
          } else if (webmFile.existsSync() &&
              webmFile.lengthSync() > 1024 * 50) {
            confirmedCache = webmFile;
          }

          if (confirmedCache != null) {
            updatedSongs[i] = song.copyWith(localPath: confirmedCache.path);
            anyUpdate = true;
            successCount++;
            isHandled = true;
            // Sync this status to all other playlists
            await provider.updateSongDownloadStatusGlobally(updatedSongs[i]);
            // Persist progress
            await provider.updateSongsInPlaylist(playlist.id, updatedSongs);
          }
        }

        // 3. Download
        if (!isHandled) {
          if (isJobCancelled) break;

          // Check limit again before downloading a BRAND NEW song
          if (downloadLimit != -1 &&
              provider.totalDownloadedSongs >= downloadLimit) {
            statusNotifier.value = "Limit Reached";
            if (mounted && !isDismissed) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    "Download limit of $downloadLimit songs reached. Skipping remaining.",
                  ),
                  backgroundColor: Colors.orangeAccent,
                  duration: const Duration(seconds: 3),
                ),
              );
            }
            break; // Stop the entire playlist download if limit reached
          }

          try {
            String? audioUrl = song.youtubeUrl;
            if (audioUrl == null) {
              final links = await provider
                  .resolveLinks(
                    title: song.title,
                    artist: song.artist,
                    spotifyUrl: song.spotifyUrl,
                    youtubeUrl: song.youtubeUrl,
                  )
                  .timeout(const Duration(seconds: 20));
              audioUrl = links['youtube'];
            }

            if (audioUrl != null) {
              if (isJobCancelled) break;

              var videoId = YoutubePlayer.convertUrlToId(audioUrl);
              if (videoId == null && audioUrl.contains('v=')) {
                videoId = audioUrl.split('v=').last.split('&').first;
              }

              if (videoId != null) {
                int retryCount = 0;
                const int maxRetries = 2;
                bool downloadSuccess = false;

                while (retryCount < maxRetries && !downloadSuccess) {
                  if (isJobCancelled) break;

                  try {
                    statusNotifier.value = retryCount == 0
                        ? "Downloading..."
                        : "Retry ${retryCount + 1}...";

                    if (retryCount > 0) {
                      await Future.delayed(const Duration(milliseconds: 500));
                    }
                    if (isJobCancelled) break;

                    final yt = ye.YoutubeExplode();

                    try {
                      final manifest = await yt.videos.streamsClient
                          .getManifest(videoId)
                          .timeout(const Duration(seconds: 40));

                      ye.StreamInfo? audioStreamInfo;

                      final m4aStreams = manifest.audioOnly.where(
                        (s) => s.container.name == 'm4a',
                      );

                      if (m4aStreams.isNotEmpty) {
                        audioStreamInfo = m4aStreams.withHighestBitrate();
                      } else {
                        final muxedStreams = manifest.muxed.where(
                          (s) => s.container.name == 'mp4',
                        );
                        if (muxedStreams.isNotEmpty) {
                          audioStreamInfo = muxedStreams.withHighestBitrate();
                        } else {
                          audioStreamInfo = manifest.audioOnly
                              .withHighestBitrate();
                        }
                      }

                      final hashedId = sha1
                          .convert(utf8.encode(song.id))
                          .toString();
                      final fileName = '$hashedId.mst';
                      final file = File('${saveDir.path}/$fileName');

                      if (await file.exists()) {
                        try {
                          await file.delete();
                        } catch (_) {}
                      }

                      int totalBytes = audioStreamInfo.size.totalBytes;
                      int receivedBytes = 0;
                      int bytesSinceLastUpdate = 0;
                      DateTime lastUpdateTime = DateTime.now();

                      final stream = yt.videos.streamsClient.get(
                        audioStreamInfo,
                      );
                      final iosink = file.openWrite(mode: FileMode.writeOnly);

                      try {
                        await for (final data in stream.timeout(
                          const Duration(seconds: 45),
                        )) {
                          if (isJobCancelled) {
                            throw Exception("CancelledByUser");
                          }

                          iosink.add(EncryptionService().encryptData(data));
                          receivedBytes += data.length;
                          bytesSinceLastUpdate += data.length;

                          final now = DateTime.now();
                          final timeDiff = now
                              .difference(lastUpdateTime)
                              .inMilliseconds;

                          if (bytesSinceLastUpdate > 100 * 1024 ||
                              timeDiff > 500) {
                            double curProgress = 0.0;
                            if (totalBytes > 0) {
                              curProgress = (receivedBytes / totalBytes).clamp(
                                0.0,
                                1.0,
                              );
                            }
                            currentFileProgress.value = curProgress;

                            final speedKbps = timeDiff > 0
                                ? (bytesSinceLastUpdate / 1024) /
                                      (timeDiff / 1000)
                                : 0.0;
                            final speedStr = speedKbps > 1024
                                ? "${(speedKbps / 1024).toStringAsFixed(1)} MB/s"
                                : "${speedKbps.toStringAsFixed(0)} KB/s";

                            statusNotifier.value = "$speedStr";

                            lastUpdateTime = now;
                            bytesSinceLastUpdate = 0;

                            // Update notification progress within the stream
                            if (isDismissed && !isJobCancelled) {
                              final int totalSongs = updatedSongs.length;
                              final int songIndex = i;
                              // Total progress: (current song index * 100) + current song percentage
                              final int overallProgress =
                                  (songIndex * 100) +
                                  (curProgress * 100).toInt();

                              NotificationService().showDownloadProgress(
                                id: notificationId,
                                title: playlist.name,
                                subTitle:
                                    "Song ${i + 1}/$totalSongs: ${song.title} (${(curProgress * 100).toInt()}%)",
                                progress: overallProgress,
                                maxProgress: totalSongs * 100,
                              );
                            }
                          }
                        }
                      } finally {
                        await iosink.flush();
                        await iosink.close();
                      }

                      if (isJobCancelled) {
                        if (await file.exists()) {
                          await file.delete();
                        }
                        break;
                      }

                      final finalLength = await file.length();
                      if (finalLength < 100 * 1024) {
                        throw Exception("File is incomplete.");
                      }

                      // If we resolved the URL dynamically, save it too
                      updatedSongs[i] = song.copyWith(
                        localPath: file.path,
                        youtubeUrl: audioUrl,
                      );
                      anyUpdate = true;
                      successCount++;
                      downloadSuccess = true;
                      // Sync this status to all other playlists
                      await provider.updateSongDownloadStatusGlobally(
                        updatedSongs[i],
                      );
                      // Persist progress immediately so we don't lose it if killed
                      await provider.updateSongsInPlaylist(
                        playlist.id,
                        updatedSongs,
                      );
                    } finally {
                      yt.close();
                    }
                  } catch (e) {
                    if (e.toString().contains("CancelledByUser")) {
                      // Cleanup partial file on cancellation
                      final hashedId = sha1
                          .convert(utf8.encode(song.id))
                          .toString();
                      try {
                        final mstFile = File('${saveDir.path}/$hashedId.mst');
                        if (await mstFile.exists()) await mstFile.delete();
                      } catch (_) {}
                      break; // Break retry loop
                    }
                    retryCount++;
                    if (retryCount >= maxRetries) {
                      // Final failure, cleanup
                      final hashedId = sha1
                          .convert(utf8.encode(song.id))
                          .toString();
                      try {
                        final mstFile = File('${saveDir.path}/$hashedId.mst');
                        if (await mstFile.exists()) await mstFile.delete();
                      } catch (_) {}
                    }
                  }
                }
              }
            }
          } catch (e) {
            // Error solving link
          }
        }

        totalProgress.value = (i + 1) / updatedSongs.length;
        if (isJobCancelled) break;
      }

      if (anyUpdate) {
        await provider.updateSongsInPlaylist(playlist.id, updatedSongs);
      }
    } catch (e) {
      // General error
    } finally {
      if (mounted && !isDismissed) Navigator.pop(context);
      cancelSubscription.cancel();

      if (isJobCancelled) {
        NotificationService().cancel(notificationId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                Provider.of<LanguageProvider>(
                  context,
                  listen: false,
                ).translate('download_cancelled'),
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        if (isDismissed) {
          // Show final completion in notification
          NotificationService().showDownloadProgress(
            id: notificationId,
            title: playlist.name,
            subTitle:
                "Download Complete: $successCount / ${playlist.songs.length}",
            progress: playlist.songs.length * 100,
            maxProgress: playlist.songs.length * 100,
          );
          // Only clear after a delay so they see it's done
          Future.delayed(const Duration(seconds: 5), () {
            NotificationService().cancel(notificationId);
          });
        } else {
          NotificationService().cancel(notificationId);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "Download Complete: $successCount / ${playlist.songs.length}",
              ),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    }
  }

  void _handleSpotifyLogin(BuildContext context, RadioProvider provider) async {
    final url = provider.spotifyService.getLoginUrl();
    final redirect = provider.spotifyService.redirectUri;

    final code = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) =>
            SpotifyLoginScreen(loginUrl: url, redirectUri: redirect),
      ),
    );

    if (code != null) {
      final success = await provider.spotifyService.handleAuthCode(code);
      if (success) {
        provider.notifyListeners();
        // ignore: use_build_context_synchronously
        if (context.mounted) _showSpotifyPlaylistPicker(context, provider);
      }
    }
  }

  void _showSpotifyPlaylistPicker(
    BuildContext context,
    RadioProvider radio,
  ) async {
    // Keep track of selections
    final Set<String> selectedIds = {};
    final List<Map<String, dynamic>> selectedPlaylists = [];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16213e),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return FutureBuilder<List<Map<String, dynamic>>>(
              future: radio.spotifyService.getUserPlaylists(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 300,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError ||
                    !snapshot.hasData ||
                    snapshot.data!.isEmpty) {
                  return const SizedBox(
                    height: 200,
                    child: Center(
                      child: Text(
                        "No playlists found",
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  );
                }

                final playlists = snapshot.data!;
                return DraggableScrollableSheet(
                  initialChildSize: 0.8,
                  minChildSize: 0.5,
                  maxChildSize: 0.95,
                  expand: false,
                  builder: (ctx, scrollController) {
                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "Import Playlist (${playlists.length} found)",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (selectedIds.isNotEmpty)
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      selectedIds.clear();
                                      selectedPlaylists.clear();
                                    });
                                  },
                                  child: Text(
                                    Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    ).translate('clear_selection'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: scrollController,
                            itemCount: playlists.length,
                            itemBuilder: (ctx, index) {
                              final p = playlists[index];
                              final id = p['id'].toString();
                              final isSelected = selectedIds.contains(id);
                              final images = p['images'] as List?;
                              final String? imgUrl =
                                  (images != null && images.isNotEmpty)
                                  ? images[0]['url']
                                  : null;

                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                leading: Stack(
                                  children: [
                                    SizedBox(
                                      width: 50,
                                      height: 50,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: imgUrl != null
                                            ? Image.network(
                                                imgUrl,
                                                width: 50,
                                                height: 50,
                                                fit: BoxFit.cover,
                                              )
                                            : Container(
                                                color: Colors.white10,
                                                child: const Icon(
                                                  Icons.music_note,
                                                  color: Colors.white54,
                                                ),
                                              ),
                                      ),
                                    ),
                                    if (isSelected)
                                      Positioned.fill(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .primaryColor
                                                .withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: const Center(
                                            child: Icon(
                                              Icons.check,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                title: Text(
                                  p['name'],
                                  style: TextStyle(
                                    color: isSelected
                                        ? Theme.of(context).primaryColor
                                        : Colors.white,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                subtitle: Text(
                                  "${p['tracks']['total']} tracks",
                                  style: const TextStyle(color: Colors.white54),
                                ),
                                onTap: () {
                                  setState(() {
                                    if (isSelected) {
                                      selectedIds.remove(id);
                                      selectedPlaylists.removeWhere(
                                        (item) => item['id'] == id,
                                      );
                                    } else {
                                      selectedIds.add(id);
                                      selectedPlaylists.add(p);
                                    }
                                  });
                                },
                              );
                            },
                          ),
                        ),
                        // Action Bar
                        Container(
                          padding: const EdgeInsets.all(16.0),
                          decoration: const BoxDecoration(
                            color: Color(0xFF16213e),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 4,
                                offset: Offset(0, -2),
                              ),
                            ],
                          ),
                          child: SafeArea(
                            child: SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Theme.of(
                                    context,
                                  ).primaryColor,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: selectedIds.isEmpty
                                    ? null
                                    : () async {
                                        Navigator.pop(ctx);

                                        // Process imports
                                        int successCount = 0;
                                        int failCount = 0;

                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              "Importing ${selectedIds.length} playlists...",
                                            ),
                                            duration: const Duration(
                                              seconds: 2,
                                            ),
                                          ),
                                        );

                                        for (var p in selectedPlaylists) {
                                          try {
                                            final success = await radio
                                                .importSpotifyPlaylist(
                                                  p['name'],
                                                  p['id'],
                                                  total:
                                                      p['tracks']['total']
                                                          is int
                                                      ? p['tracks']['total']
                                                      : int.tryParse(
                                                          p['tracks']['total']
                                                              .toString(),
                                                        ),
                                                );
                                            if (success) {
                                              successCount++;
                                            } else {
                                              failCount++;
                                            }
                                          } catch (e) {
                                            failCount++;
                                          }
                                        }

                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                "Import Completed: $successCount imported, $failCount failed.",
                                              ),
                                              backgroundColor: failCount == 0
                                                  ? Colors.green
                                                  : Colors.orange,
                                            ),
                                          );
                                        }
                                      },
                                child: Text(
                                  selectedIds.isEmpty
                                      ? "Select Playlists to Import"
                                      : "Import ${selectedIds.length} Playlists",
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildDirectAccessCard(
    BuildContext context,
    RadioProvider provider,
    String title,
    String subtitle,
    IconData icon,
    Color accentColor,
    VoidCallback onTap,
    Key key,
  ) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accentColor.withValues(alpha: 0.2),
            accentColor.withValues(alpha: 0.1),
          ],
        ),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          hoverColor: accentColor.withValues(alpha: 0.1),
          splashColor: accentColor.withValues(alpha: 0.2),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: FaIcon(icon, color: accentColor, size: 24),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showCopyPlaylistDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist sourcePlaylist,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        final playlists = provider.playlists
            .where((p) => p.id != sourcePlaylist.id)
            .toList();

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
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    "Copy all songs from '${sourcePlaylist.name}' to:",
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: playlists.length + 1, // +1 for "Create New"
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
                            _showCreatePlaylistDialog(context, provider);
                            // Ideally we should pass a callback to create and then copy, but for now simple workflow.
                            // Improvements: Show create dialog, then copy immediately.
                            // Let's keep it simple: "Create New" just opens create dialog. User has to copy after.
                            // Actually, that's bad UX.
                            // Let's implement immediate copy after creation if I can.
                            // Given constraint, I'll just skip 'Create New' magic and rely on user creating it first, OR implement inline creation.
                            // I'll stick to listing existing playlists for now to be safe and robust.
                          },
                        );
                      }
                      final p = playlists[index - 1];
                      return ListTile(
                        leading: Icon(
                          Icons.queue_music,
                          color: Theme.of(context).iconTheme.color,
                        ),
                        title: Text(
                          p.name,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.color,
                          ),
                        ),
                        onTap: () {
                          provider.copyPlaylist(sourcePlaylist.id, p.id);
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    )
                                    .translate('copied_songs_to')
                                    .replaceAll('{0}', p.name),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                Provider.of<LanguageProvider>(
                  context,
                  listen: false,
                ).translate('cancel'),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showClearFavoritesDialog(BuildContext context, RadioProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1e1e24),
        title: const Text(
          "Clear Favorites?",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "Are you sure you want to remove all songs from your Favorites?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('cancel'),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final songIds = provider.playlists
                  .firstWhere((p) => p.id == 'favorites')
                  .songs
                  .map((s) => s.id)
                  .toList();

              if (songIds.isNotEmpty) {
                await provider.removeSongsFromPlaylist('favorites', songIds);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('favorites_cleared'),
                      ),
                    ),
                  );
                }
              }
            },
            child: const Text(
              "Clear All",
              style: TextStyle(color: Colors.orangeAccent),
            ),
          ),
        ],
      ),
    );
  }

  void _showRenamePlaylistDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
  ) {
    if (playlist.id == 'favorites' || playlist.creator == 'local') return;

    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: Text(
          "Rename Playlist",
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (playlist.creator == 'local')
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orangeAccent.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orangeAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "This will rename the folder on your device. Ensure no other apps are using it.",
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodySmall?.color,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            TextField(
              controller: controller,
              style: TextStyle(
                color: Theme.of(context).textTheme.bodyLarge?.color,
              ),
              decoration: InputDecoration(
                hintText: "Playlist Name",
                hintStyle: TextStyle(
                  color: Theme.of(
                    context,
                  ).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                ),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Theme.of(context).dividerColor),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Theme.of(context).primaryColor),
                ),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              "Cancel",
              style: TextStyle(
                color: Theme.of(
                  context,
                ).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
              ),
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
            child: Text(
              "Save",
              style: TextStyle(color: Theme.of(context).primaryColor),
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
        backgroundColor: Theme.of(context).cardColor,
        title: Text(
          "New Playlist",
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
          decoration: InputDecoration(
            labelText: "Playlist Name",
            labelStyle: TextStyle(
              color: Theme.of(
                context,
              ).textTheme.bodyLarge?.color?.withValues(alpha: 0.7),
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
            child: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('cancel'),
            ),
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

  void _showAddSongDialog(BuildContext context, RadioProvider provider) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddSongScreen()),
    );
  }

  void _showFilterDialog(BuildContext context, RadioProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            final entitlements = Provider.of<EntitlementService>(
              context,
              listen: false,
            );
            final lang = Provider.of<LanguageProvider>(context, listen: false);
            final filters = provider.playlistCreatorFilter;
            final isApp = filters.contains('app');
            final isUser = filters.contains('user');
            final isSpotify = filters.contains('spotify');
            final isLocal = filters.contains('local');
            final canUseSpotify = entitlements.isFeatureEnabled(
              'spotify_integration',
            );
            final canUseLocal = entitlements.isFeatureEnabled('local_library');

            return AlertDialog(
              backgroundColor: Theme.of(context).cardColor,
              title: Text(
                lang.translate('filter_playlists'),
                style: TextStyle(
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    title: Text(
                      lang.translate('user_created'),
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodyLarge?.color,
                      ),
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
                    title: Text(
                      lang.translate('app_created'),
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                    ),
                    activeColor: Theme.of(context).primaryColor,
                    value: isApp || filters.isEmpty,
                    onChanged: (val) {
                      provider.togglePlaylistCreatorFilter('app');
                      setState(() {});
                    },
                  ),
                  if (canUseLocal)
                    CheckboxListTile(
                      title: Text(
                        lang.translate('local_device'),
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodyLarge?.color,
                        ),
                      ),
                      subtitle: Text(
                        lang.translate('folders_from_device'),
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                      activeColor: Theme.of(context).primaryColor,
                      value: isLocal || filters.isEmpty,
                      onChanged: (val) {
                        provider.togglePlaylistCreatorFilter('local');
                        setState(() {});
                      },
                    ),
                  if (canUseSpotify)
                    CheckboxListTile(
                      title: Text(
                        lang.translate('spotify_imported'),
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodyLarge?.color,
                        ),
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
                        child: Text(
                          lang.translate('clear_filters'),
                          style: const TextStyle(color: Colors.blueAccent),
                        ),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(lang.translate('done')),
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
            Icon(
              Icons.music_off_rounded,
              size: 64,
              color:
                  Theme.of(context).iconTheme.color?.withValues(alpha: 0.5) ??
                  Colors.white24,
            ),
            SizedBox(height: 16),
            Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('no_songs_found'),
              style: TextStyle(
                color:
                    Theme.of(
                      context,
                    ).textTheme.bodySmall?.color?.withValues(alpha: 0.7) ??
                    Colors.white54,
              ),
            ),
          ],
        ),
      );
    }

    // Grouping Logic
    final List<List<SavedSong>> groupedSongs = [];

    if (_groupingMode == PlaylistGroupingMode.none) {
      // No grouping: Each song is its own group
      for (var song in songs) {
        groupedSongs.add([song]);
      }
    } else if (_groupingMode == PlaylistGroupingMode.artist) {
      // Group by Artist
      final Map<String, List<SavedSong>> groups = {};
      for (var song in songs) {
        final key = song.artist.trim().toLowerCase();
        if (!groups.containsKey(key)) {
          groups[key] = [];
        }
        groups[key]!.add(song);
      }
      groupedSongs.addAll(groups.values);
    } else {
      // Group by Album (Default)
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
    }

    // Logic for Ads: At start, at end, and every 10 songs (including grouped content)
    final List<dynamic> listItems = [];
    if (groupedSongs.isNotEmpty) {
      listItems.add(const _AdItem()); // Initial Ad

      int songCounter = 0;
      for (var group in groupedSongs) {
        final List<dynamic> internalItems = [];
        for (var song in group) {
          songCounter++;
          internalItems.add(song);
          if (songCounter % 10 == 0) {
            internalItems.add(const _AdItem());
          }
        }

        // Pull out trailing ad from group to main list (between cards)
        if (internalItems.isNotEmpty && internalItems.last is _AdItem) {
          internalItems.removeLast();
          if (internalItems.length == 1) {
            listItems.add([
              internalItems.first,
            ]); // Still a list for consistency
          } else {
            listItems.add(internalItems);
          }
          listItems.add(const _AdItem());
        } else {
          if (internalItems.length == 1) {
            listItems.add([internalItems.first]);
          } else {
            listItems.add(internalItems);
          }
        }
      }

      // Final Ad if not already present
      if (listItems.isNotEmpty && listItems.last is! _AdItem) {
        listItems.add(const _AdItem());
      }
    } else {
      listItems.addAll(groupedSongs);
    }

    // Auto-Scroll Logic
    // Find if the currently playing song is in this list
    int scrollIndex = -1;
    String? foundSongId;

    for (int i = 0; i < listItems.length; i++) {
      final item = listItems[i];
      if (item is! List) continue;

      final group = item;
      final match = group.whereType<SavedSong>().firstWhere(
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
      if (listItems.length > 3) {
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
        itemCount: listItems.length,
        itemBuilder: (context, index) {
          final item = listItems[index];

          if (item is _AdItem) {
            return const NativeAdWidget();
          }

          final group = item as List<dynamic>;
          if (group.length == 1 && group.first is SavedSong) {
            return _buildSongItem(
              context,
              provider,
              playlist,
              group.first as SavedSong,
            );
          }
          return _buildAlbumGroup(context, provider, playlist, group);
        },
      );
    }

    return ScrollablePositionedList.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: listItems.length,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      itemBuilder: (context, index) {
        final item = listItems[index];

        if (item is _AdItem) {
          return const NativeAdWidget();
        }

        final group = item as List<dynamic>;

        // If only one song, render strictly as before (Standalone)
        if (group.length == 1 && group.first is SavedSong) {
          return _buildSongItem(
            context,
            provider,
            playlist,
            group.first as SavedSong,
          );
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
    List<dynamic> groupItems,
  ) {
    final List<SavedSong> groupSongs = groupItems
        .whereType<SavedSong>()
        .toList();

    return _AlbumGroupWidget(
      titleOverride: _groupingMode == PlaylistGroupingMode.artist
          ? groupSongs.first.artist
          : null,
      subtitleOverride: _groupingMode == PlaylistGroupingMode.artist
          ? "All Songs"
          : null,
      showFavoritesButton: playlist.id != 'favorites',
      groupItems: groupItems,
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
      isFavoriteOverride: groupSongs.every((s) {
        final favPlaylist = provider.playlists.firstWhere(
          (p) => p.id == 'favorites',
          orElse: () => Playlist(
            id: 'favorites',
            name: 'Favorites',
            songs: [],
            createdAt: DateTime.now(),
          ),
        );
        return favPlaylist.songs.any(
          (fav) =>
              fav.id == s.id ||
              (fav.title == s.title && fav.artist == s.artist),
        );
      }),
      onFavoriteToggle: () async {
        final favPlaylist = provider.playlists.firstWhere(
          (p) => p.id == 'favorites',
          orElse: () => Playlist(
            id: 'favorites',
            name: 'Favorites',
            songs: [],
            createdAt: DateTime.now(),
          ),
        );
        final favIds = favPlaylist.songs.map((s) => s.id).toSet();
        // Also consider title/artist match for robustness
        bool isAlreadyFav(SavedSong s) {
          return favIds.contains(s.id) ||
              favPlaylist.songs.any(
                (fav) => fav.title == s.title && fav.artist == s.artist,
              );
        }

        final allFav = groupSongs.every(isAlreadyFav);

        if (allFav) {
          // Remove all
          final idsToRemove = <String>[];
          for (var s in groupSongs) {
            final favSong = favPlaylist.songs.firstWhere(
              (fav) =>
                  fav.id == s.id ||
                  (fav.title == s.title && fav.artist == s.artist),
              orElse: () => s,
            );
            if (favPlaylist.songs.any(
              (fs) =>
                  fs.id == favSong.id ||
                  (fs.title == favSong.title && fs.artist == favSong.artist),
            )) {
              idsToRemove.add(favSong.id);
            }
          }
          if (idsToRemove.isNotEmpty) {
            await provider.removeSongsFromPlaylist('favorites', idsToRemove);
          }
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  Provider.of<LanguageProvider>(
                    context,
                    listen: false,
                  ).translate('removed_from_favorites'),
                ),
              ),
            );
          }
        } else {
          // Add missing
          final toAdd = groupSongs.where((s) => !isAlreadyFav(s)).toList();
          if (toAdd.isNotEmpty) {
            await provider.bulkToggleFavoriteSongs(toAdd, true);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    Provider.of<LanguageProvider>(
                      context,
                      listen: false,
                    ).translate('added_to_favorites'),
                  ),
                ),
              );
            }
          }
        }
      },
      onRemove: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            title: Text(
              "Delete Album",
              style: TextStyle(
                color: Theme.of(context).textTheme.titleLarge?.color,
              ),
            ),
            content: Text(
              playlist.creator == 'local'
                  ? "Delete '${groupSongs.first.album}' from device?\n(Files will be permanently deleted)"
                  : "Remove '${groupSongs.first.album}' from this playlist?",
              style: TextStyle(
                color: Theme.of(
                  context,
                ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  "Cancel",
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
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
            if (playlist.creator == 'local') {
              for (var s in groupSongs) {
                if (s.localPath == null) continue;
                final f = File(s.localPath!);
                if (await f.exists()) {
                  await f.delete();
                }
              }
            }

            await provider.removeSongsFromPlaylist(playlist.id, songIds);

            if (!provider.playlists.any((p) => p.id == playlist.id)) {
              setState(() {
                _selectedPlaylistId = null;
              });
            }

            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    Provider.of<LanguageProvider>(context, listen: false)
                        .translate('removed_album')
                        .replaceAll('{0}', groupSongs.first.album),
                  ),
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
        final isFirst = index == 1;
        final isLast = index == groupSongs.length;
        return _buildSongItem(
          ctx,
          freshProvider,
          playlist,
          song,
          isGrouped: true,
          groupIndex: index,
          isFirstInGroup: isFirst,
          isLastInGroup: isLast,
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
    bool isFirstInGroup = false,
    bool isLastInGroup = false,
  }) {
    final cardColor = Theme.of(context).cardColor;
    final contrastColor = cardColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

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
    bool isFavorite = favPlaylist.songs.any(
      (s) =>
          s.id == song.id || (s.title == song.title && s.artist == song.artist),
    );

    final isInvalid =
        !song.isValid || provider.invalidSongIds.contains(song.id);

    final isThisSongPlaying =
        provider.isPlaying &&
        (provider.audioOnlySongId == song.id ||
            (song.title.trim().toLowerCase() ==
                    provider.currentTrack.trim().toLowerCase() &&
                song.artist.trim().toLowerCase() ==
                    provider.currentArtist.trim().toLowerCase()));

    return Container(
      margin: isGrouped ? EdgeInsets.zero : const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isInvalid
            ? Theme.of(
                    context,
                  ).textTheme.bodyLarge?.color?.withValues(alpha: 0.7) ??
                  Colors.white.withValues(alpha: 0.7)
            : isThisSongPlaying
            ? Theme.of(context).primaryColor.withValues(
                alpha: 0.25,
              ) // Stronger alpha
            : isGrouped
            ? Colors.transparent
            : Theme.of(context).cardColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.zero,
        border: isThisSongPlaying
            ? Border.all(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.2),
                width: 1.5,
              )
            : null,
      ),

      child: Listener(
        onPointerDown: isInvalid
            ? (_) => _startUnlockTimer(provider, song, playlist.id)
            : null,
        onPointerUp: isInvalid ? (_) => _cancelUnlockTimer() : null,
        onPointerCancel: isInvalid ? (_) => _cancelUnlockTimer() : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
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
              visualDensity: const VisualDensity(horizontal: 0, vertical: -4),
              minVerticalPadding: 0, // Reduce vertical padding

              contentPadding: isGrouped
                  ? const EdgeInsets.all(0)
                  : const EdgeInsets.only(top: 0, left: 8, right: 4, bottom: 0),

              leading: isGrouped
                  ? Container(
                      padding: const EdgeInsets.all(0),
                      width: 32,
                      alignment: Alignment.center,
                      child: Text(
                        "${groupIndex ?? ''}",
                        style: TextStyle(
                          color: contrastColor.withValues(alpha: 0.5),
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
                              builder: (context) => TrendingDetailsScreen(
                                albumName: albumName,
                                artistName: cleanArtist,
                                songName: songTitle,
                              ),
                            ),
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            children: [
                              song.artUri != null
                                  ? CachedNetworkImage(
                                      imageUrl: song.artUri!,
                                      width: 48,
                                      height: 48,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, _, _) => Container(
                                        width: 48,
                                        height: 48,
                                        color: Colors.grey[900],
                                        child: Icon(
                                          Icons.music_note,
                                          color: contrastColor.withValues(
                                            alpha: 0.24,
                                          ),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      width: 48,
                                      height: 48,
                                      color: Colors.grey[900],
                                      child: Icon(
                                        Icons.music_note,
                                        color: contrastColor.withValues(
                                          alpha: 0.24,
                                        ),
                                      ),
                                    ),
                              if (song.localPath != null &&
                                  song.localPath!.isNotEmpty)
                                Positioned(
                                  bottom: 2,
                                  right: 2,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.6,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      song.isDownloaded
                                          ? Icons.file_download_done_rounded
                                          : Icons.smartphone_rounded,
                                      size: 12,
                                      color: song.isDownloaded
                                          ? Colors.greenAccent
                                          : Colors.blueAccent,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
              title: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
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
                                ? Theme.of(context).primaryColor
                                : (isInvalid
                                      ? contrastColor.withValues(alpha: 0.5)
                                      : contrastColor),
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!isGrouped)
                          Padding(
                            padding: const EdgeInsets.only(top: 2.0),
                            child: Text(
                              song.artist,
                              style: TextStyle(
                                color: contrastColor.withValues(alpha: 0.5),
                                fontWeight: FontWeight.normal,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),

                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (playlist.id != 'favorites' && !isInvalid) ...[
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
                                  SnackBar(
                                    content: Text(
                                      Provider.of<LanguageProvider>(
                                        context,
                                        listen: false,
                                      ).translate('removed_from_favorites'),
                                    ),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                              }
                            } else {
                              if (playlist.creator == 'local') {
                                isFavorite = true; // Optimistic update
                                await provider.addSongToPlaylist(
                                  'favorites',
                                  song,
                                );
                              } else {
                                await provider.copySong(
                                  song.id,
                                  playlist.id,
                                  'favorites',
                                );
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).clearSnackBars();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      Provider.of<LanguageProvider>(
                                        context,
                                        listen: false,
                                      ).translate('added_to_favorites'),
                                    ),
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
                                : contrastColor.withValues(alpha: 0.5),
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],

                      _InvalidSongIndicator(
                        songId: song.id,
                        isStaticInvalid: !song.isValid,
                      ),
                      if (!isInvalid) ...[
                        PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert_rounded,
                            color: contrastColor,
                          ),
                          onSelected: (value) async {
                            if (value == 'video') {
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
                                    SnackBar(
                                      content: Text(
                                        Provider.of<LanguageProvider>(
                                          context,
                                          listen: false,
                                        ).translate('youtube_link_not_found'),
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
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        Provider.of<LanguageProvider>(
                                              context,
                                              listen: false,
                                            )
                                            .translate('error_generic')
                                            .replaceAll('{0}', e.toString()),
                                      ),
                                    ),
                                  );
                                }
                              }
                            } else if (value == 'copy') {
                              await _showCopySongDialog(
                                context,
                                provider,
                                playlist,
                                song.id,
                              );
                            } else if (value == 'delete') {
                              bool confirm = true;
                              if (playlist.creator == 'local') {
                                confirm =
                                    await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        backgroundColor: Theme.of(
                                          context,
                                        ).cardColor,
                                        title: Text(
                                          Provider.of<LanguageProvider>(
                                            context,
                                            listen: false,
                                          ).translate('delete_file'),
                                        ),
                                        content: Text(
                                          "Delete '${song.title}' from device?",
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: Text(
                                              Provider.of<LanguageProvider>(
                                                context,
                                                listen: false,
                                              ).translate('cancel'),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: const Text(
                                              "Delete",
                                              style: TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ) ??
                                    false;
                              }

                              if (confirm) {
                                final deletedSong = song;
                                if (playlist.id == 'temp_view') {
                                  provider.removeSongFromLibrary(song.id);
                                  if (mounted) {
                                    ScaffoldMessenger.of(
                                      context,
                                    ).clearSnackBars();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          "Song removed from library",
                                        ),
                                        duration: Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                } else {
                                  if (playlist.creator == 'local' &&
                                      song.localPath != null) {
                                    final f = File(song.localPath!);
                                    if (f.existsSync()) {
                                      f.deleteSync();
                                    }
                                  }
                                  provider.removeFromPlaylist(
                                    playlist.id,
                                    song.id,
                                  );
                                  if (mounted) {
                                    ScaffoldMessenger.of(
                                      context,
                                    ).clearSnackBars();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        backgroundColor: const Color(
                                          0xFF333333,
                                        ),
                                        content: const Text(
                                          "Song removed from playlist",
                                          style: TextStyle(color: Colors.white),
                                        ),
                                        action: SnackBarAction(
                                          label: 'Undo',
                                          textColor: Theme.of(
                                            context,
                                          ).primaryColorLight,
                                          onPressed: () {
                                            provider.restoreSongToPlaylist(
                                              playlist.id,
                                              deletedSong,
                                            );
                                          },
                                        ),

                                        duration: const Duration(seconds: 5),
                                      ),
                                    );
                                  }
                                }
                              }
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'video',
                              child: Row(
                                children: [
                                  const Icon(
                                    FontAwesomeIcons.youtube,
                                    color: Colors.red,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    ).translate('watch_video'),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'copy',
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.content_copy_rounded,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    Provider.of<LanguageProvider>(
                                      context,
                                      listen: false,
                                    ).translate('copy_to'),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                    size: 20,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    "Delete",
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ], // close else...[ and children
                  ),
                ],
              ),
            ),
            if (song.localPath != null &&
                !(song.localPath!.contains('_secure.') ||
                    song.localPath!.endsWith('.mst') ||
                    song.localPath!.contains('offline_music')))
              Padding(
                padding: const EdgeInsets.only(
                  left: 8,
                  bottom: 2,
                  top: 0,
                  right: 2,
                ),
                child: Text(
                  song.localPath!,
                  style: TextStyle(
                    fontSize: 9,
                    color: contrastColor.withValues(alpha: 0.5),
                    fontFamily: 'monospace',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
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
        backgroundColor: Theme.of(context).cardColor,
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
            child: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('cancel'),
            ),
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
    if (p.creator == 'local') {
      return Icon(
        Icons.smartphone_rounded,
        color: Theme.of(context).primaryColor,
        size: 20,
      );
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
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('no_other_playlists'),
          ),
        ),
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
                "Copy to...",
                style: TextStyle(
                  color: Theme.of(context).textTheme.titleLarge?.color,
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
                                SnackBar(
                                  content: Text(
                                    Provider.of<LanguageProvider>(
                                          context,
                                          listen: false,
                                        )
                                        .translate('copied_to')
                                        .replaceAll('{0}', p.name),
                                  ),
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
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('no_other_playlists'),
          ),
        ),
      );
      return false;
    }

    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
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
                style: TextStyle(
                  color: Theme.of(context).textTheme.titleLarge?.color,
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
                                  content: Text(
                                    Provider.of<LanguageProvider>(
                                          context,
                                          listen: false,
                                        )
                                        .translate('copied_album_to')
                                        .replaceAll('{0}', p.name),
                                  ),
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
              style: TextStyle(
                color:
                    Theme.of(
                      context,
                    ).textTheme.bodySmall?.color?.withValues(alpha: 0.7) ??
                    Colors.white54,
              ),
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
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.5),
                  ),
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
                              color: Theme.of(context).cardColor,
                              child: Icon(
                                Icons.music_note,
                                color: Theme.of(
                                  context,
                                ).iconTheme.color?.withValues(alpha: 0.5),
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
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyLarge?.color,
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
                          color: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                        ),
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
                                    : Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color
                                          ?.withValues(alpha: 0.5),
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
                    icon: Icon(
                      Icons.play_circle_fill,
                      color: Theme.of(context).textTheme.bodyLarge?.color,
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
      return Center(
        child: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('no_artists_found'),
          style: const TextStyle(color: Colors.white54),
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
            final int crossAxisCount = (width / 150).ceil();

            final double itemWidth =
                (width - (crossAxisCount - 1) * 8) / crossAxisCount;
            final double rowHeight = itemWidth; // Aspect Ratio 1.0

            final int row = playingIndex ~/ crossAxisCount;
            final double rowPosition = row * (rowHeight + 8);

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
            maxCrossAxisExtent: 150,
            childAspectRatio: 1.0,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final groupKey = groups[index];
            final variants = groupedVariants[groupKey]!;

            String displayArtist;
            String searchArtist;
            bool isGroup;
            int count = 0;
            bool isPlaying =
                provider.isPlaying && (groupKey == playingGroupKey);

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

    if (groups.isEmpty) {
      return Center(
        child: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('no_albums_found'),
          style: const TextStyle(color: Colors.white54),
        ),
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
            final int crossAxisCount = (width / 150).ceil();

            final double itemWidth =
                (width - (crossAxisCount - 1) * 8) / crossAxisCount;
            final double rowHeight = itemWidth; // Aspect Ratio 1.0

            final int row = playingIndex ~/ crossAxisCount;
            final double rowPosition = row * (rowHeight + 8);

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
            maxCrossAxisExtent: 150,
            childAspectRatio: 1.0,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final groupKey = groups[index];
            final variants = groupedAlbums[groupKey]!;

            String displayAlbum;
            String searchAlbum;
            bool isGroup;
            // Use robust index-based check matching the scroll logic
            bool isPlaying = provider.isPlaying && (index == playingIndex);
            SavedSong? displaySong;

            if (variants.length == 1) {
              // Single
              displayAlbum = variants.first;
              searchAlbum = variants.first;
              isGroup = false;
              displaySong = representativeSongs[displayAlbum];
            } else {
              // Group
              searchAlbum = normKeyToDisplay[groupKey]!;
              displayAlbum = "$searchAlbum...";
              isGroup = true;
              // Use first variant for art
              displaySong = representativeSongs[variants.first];
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
                          ).primaryColor.withValues(alpha: 0.2),
                          width: 2,
                        )
                      : null,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: isPlaying
                      ? [
                          BoxShadow(
                            color: Theme.of(
                              context,
                            ).primaryColor.withValues(alpha: 0.2),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    // Background Image
                    Positioned.fill(
                      child: displaySong.artUri != null
                          ? CachedNetworkImage(
                              imageUrl: displaySong.artUri!,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Container(
                                color: Colors.white10,
                                child: const Icon(
                                  Icons.album,
                                  color: Colors.white24,
                                  size: 40,
                                ),
                              ),
                            )
                          : Container(
                              color: Colors.white10,
                              child: const Icon(
                                Icons.album,
                                color: Colors.white24,
                                size: 40,
                              ),
                            ),
                    ),

                    // Gradient Overlay
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.5),
                              Colors.black.withValues(alpha: 0.5),
                            ],
                            stops: const [0.0, 0.4, 0.7, 1.0],
                          ),
                        ),
                      ),
                    ),

                    // Interactive Icons (Top Corners) - Preserving existing interactions
                    Positioned(
                      top: 8,
                      right: 8,
                      child: GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => TrendingDetailsScreen(
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
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
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
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isFollowed ? Icons.bookmark : Icons.bookmark_border,
                            color: isFollowed
                                ? Theme.of(context).primaryColor
                                : Colors.white70,
                            size: 16,
                          ),
                        ),
                      ),
                    ),

                    // Text Content (Bottom)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayAlbum,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              shadows: [
                                Shadow(
                                  color: Colors.black,
                                  blurRadius: 4,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            displaySong.artist,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 11,
                              shadows: const [
                                Shadow(
                                  color: Colors.black,
                                  blurRadius: 2,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                                    shadows: const [
                                      Shadow(
                                        color: Colors.black,
                                        blurRadius: 4,
                                        offset: Offset(0, 1),
                                      ),
                                    ],
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
  final List<dynamic> groupItems;
  final List<SavedSong> groupSongs;
  final Widget Function(BuildContext, SavedSong, int) songBuilder;
  final Future<bool> Function() onMove;
  final Future<bool> Function() onRemove;
  final DismissDirection? dismissDirection;
  final bool showFavoritesButton;
  final bool? isFavoriteOverride;
  final VoidCallback? onFavoriteToggle;
  final String? titleOverride;
  final String? subtitleOverride;

  const _AlbumGroupWidget({
    required this.groupItems,
    required this.groupSongs,
    required this.songBuilder,
    required this.onMove,
    required this.onRemove,
    this.dismissDirection,
    this.showFavoritesButton = true,
    this.isFavoriteOverride,
    this.onFavoriteToggle,
    this.titleOverride,
    this.subtitleOverride,
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
    final albumName = widget.titleOverride ?? firstSong.album;
    final artistName = widget.subtitleOverride ?? firstSong.artist;
    final artUri = firstSong.artUri;

    // Normalize album name for consistency with Grid
    final String normalizedAlbumName = albumName
        .split('(')
        .first
        .trim()
        .split('[')
        .first
        .trim();
    final bool isFollowed =
        widget.isFavoriteOverride ??
        provider.isAlbumFollowed(normalizedAlbumName);

    final isPlayingAlbum =
        provider.isPlaying &&
        !_isExpanded &&
        widget.groupSongs.any(
          (s) =>
              provider.audioOnlySongId == s.id ||
              (s.title.trim().toLowerCase() ==
                      provider.currentTrack.trim().toLowerCase() &&
                  s.artist.trim().toLowerCase() ==
                      provider.currentArtist.trim().toLowerCase()),
        );

    final cardColor = Theme.of(context).cardColor;
    final contrastColor = cardColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isPlayingAlbum
            ? Theme.of(context).primaryColor.withValues(alpha: 0.2)
            : cardColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.zero,
        border: isPlayingAlbum
            ? Border.all(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.2),
                width: 1.5,
              )
            : Border.all(color: contrastColor.withValues(alpha: 0.5)),
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
                padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        // Navigate to Album Details
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => TrendingDetailsScreen(
                              albumName: albumName,
                              artistName: artistName,
                              artworkUrl: artUri,
                            ),
                          ),
                        );
                      },
                      child: Stack(
                        children: [
                          ClipRRect(
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
                                      color: contrastColor.withValues(
                                        alpha: 0.1,
                                      ),
                                      child: Icon(
                                        Icons.album,
                                        color: contrastColor.withValues(
                                          alpha: 0.5,
                                        ),
                                      ),
                                    ),
                                  )
                                : Container(
                                    width: 60,
                                    height: 60,
                                    color: contrastColor.withValues(alpha: 0.5),
                                    child: Icon(
                                      Icons.album,
                                      color: contrastColor.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  ),
                          ),
                          if (widget.groupSongs.first.localPath != null &&
                              widget.groupSongs.first.localPath!.isNotEmpty)
                            Positioned(
                              bottom: 2,
                              right: 2,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  widget.groupSongs.first.isDownloaded
                                      ? Icons.file_download_done_rounded
                                      : Icons.smartphone_rounded,
                                  size: 10,
                                  color: widget.groupSongs.first.isDownloaded
                                      ? Colors.greenAccent
                                      : Colors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            albumName,
                            style: TextStyle(
                              color: contrastColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            artistName,
                            style: TextStyle(
                              color: contrastColor.withValues(alpha: 0.5),
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            "${widget.groupSongs.length} songs",
                            style: TextStyle(
                              color: contrastColor.withValues(alpha: 0.5),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.showFavoritesButton) ...[
                      GestureDetector(
                        onTap: () async {
                          if (widget.onFavoriteToggle != null) {
                            widget.onFavoriteToggle!();
                          } else {
                            provider.toggleFollowAlbum(normalizedAlbumName);
                          }
                        },
                        child: Icon(
                          isFollowed ? Icons.favorite : Icons.favorite_border,
                          color: isFollowed
                              ? Colors.pinkAccent
                              : contrastColor.withValues(alpha: 0.5),
                          size: 24,
                        ),
                      ),
                    ],
                    PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_vert_rounded,
                        color: contrastColor.withValues(alpha: 0.5),
                      ),
                      onSelected: (value) async {
                        if (value == 'copy') {
                          await widget.onMove();
                        } else if (value == 'delete') {
                          await widget.onRemove();
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'copy',
                          child: Row(
                            children: [
                              Icon(Icons.content_copy_rounded, size: 20),
                              SizedBox(width: 8),
                              Text(
                                Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                ).translate('copy_to'),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                                size: 20,
                              ),
                              SizedBox(width: 8),
                              Text(
                                "Delete",
                                style: TextStyle(color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: contrastColor.withValues(alpha: 0.5),
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
              padding: EdgeInsets.only(bottom: 0, top: 0),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.groupItems.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: Colors.white10),
              itemBuilder: (ctx, i) {
                final item = widget.groupItems[i];
                if (item is _AdItem) {
                  return const NativeAdWidget();
                }
                final song = item as SavedSong;
                // Calculate index based on its position in the pure song list
                final songIndex = widget.groupSongs.indexOf(song) + 1;
                return widget.songBuilder(ctx, song, songIndex);
              },
            ),
          ],
        ],
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
      child: Column(
        children: [
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: widget.isPlaying
                      ? [
                          BoxShadow(
                            color: Theme.of(
                              context,
                            ).primaryColor.withValues(alpha: 0.2),
                            blurRadius: 16,
                            spreadRadius: 2,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: widget.isPlaying
                              ? Border.all(
                                  color: Theme.of(context).primaryColor,
                                  width: 3,
                                )
                              : Border.all(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  width: 1,
                                ),
                        ),
                        child: ClipOval(
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
                    ),
                    // Gradient Overlay
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.5),
                              Colors.black.withValues(alpha: 0.5),
                            ],
                            stops: const [0.0, 0.4, 0.7, 1.0],
                          ),
                        ),
                      ),
                    ),

                    // Text Content (Centered Bottom)
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 16,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.customDisplayName ??
                                widget.artist.split('•').first.trim(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              shadows: [
                                Shadow(
                                  color: Colors.black,
                                  blurRadius: 4,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            "${widget.songCount} Songs",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 10,
                              shadows: const [
                                Shadow(
                                  color: Colors.black,
                                  blurRadius: 2,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (widget.isPlaying)
                      Positioned(
                        bottom: 38,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Icon(
                            Icons.equalizer,
                            color: Theme.of(context).primaryColor,
                            size: 16,
                          ),
                        ),
                      ),

                    // Buttons (Top Layer)
                    Positioned(
                      bottom: 4,
                      right: 4,
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
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white24,
                              width: 0.5,
                            ),
                          ),
                          child: const Icon(
                            Icons.info_outline,
                            color: Colors.white,
                            size: 14,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: widget.onToggleFollow,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(alpha: 0.5),
                            border: Border.all(
                              color: Colors.white24,
                              width: 0.5,
                            ),
                          ),
                          child: Icon(
                            widget.isFollowed
                                ? Icons.how_to_reg
                                : Icons.person_add_alt,
                            color: widget.isFollowed
                                ? Theme.of(context).primaryColor
                                : Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
          Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('duplicate_songs'),
            style: TextStyle(color: Colors.white),
          ),
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
                        color: isPlaying
                            ? Colors.redAccent
                            : Theme.of(context).textTheme.bodyLarge?.color,
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
          child: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('close'),
            style: const TextStyle(color: Colors.white54),
          ),
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
                      title: Text(
                        Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('confirm_deletion'),
                        style: const TextStyle(color: Colors.white),
                      ),
                      content: Text(
                        Provider.of<LanguageProvider>(context, listen: false)
                            .translate('remove_count_songs')
                            .replaceAll('{0}', count.toString()),
                        style: const TextStyle(color: Colors.white70),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: Text(
                            Provider.of<LanguageProvider>(
                              context,
                              listen: false,
                            ).translate('cancel'),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: Text(
                            Provider.of<LanguageProvider>(
                              context,
                              listen: false,
                            ).translate('delete'),
                            style: const TextStyle(color: Colors.red),
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
                        SnackBar(
                          content: Text(
                            Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                )
                                .translate('removed_songs')
                                .replaceAll('{0}', count.toString()),
                          ),
                        ),
                      );
                    }
                  }
                },
          icon: const Icon(Icons.delete_outline, color: Colors.white),
          label: Text(
            Provider.of<LanguageProvider>(context, listen: false)
                .translate('delete_selected')
                .replaceAll('{0}', _selectedForRemoval.length.toString()),
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

@Preview()
Widget invalidSongIndicatorPreview() {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Center(
        child: ChangeNotifierProvider(
          create: (_) {
            final backup = BackupService();
            return RadioProvider(
              RadioAudioHandler(),
              backup,
              EntitlementService(backup),
            );
          },
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _InvalidSongIndicator(songId: 'test_1', isStaticInvalid: true),
              SizedBox(width: 16),
              Text('Invalid Song Indicator !!!'),
            ],
          ),
        ),
      ),
    ),
  );
}
