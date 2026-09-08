import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    as ye
    hide Playlist;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/radio_provider.dart';
import '../services/radio_audio_handler.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import '../providers/language_provider.dart';

import '../services/backup_service.dart';
import 'trending_details_screen.dart';
import 'artist_details_screen.dart';
import '../widgets/youtube_popup.dart';
import '../widgets/local_video_popup.dart';
import '../services/encryption_service.dart';
import '../services/log_service.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'local_library_screen.dart';
import 'song_metadata_details_screen.dart';

import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'playlist_screen_duplicates_logic.dart';
import '../widgets/native_ad_widget.dart';
import '../widgets/player_bar.dart';
import 'add_song_screen.dart';
import '../services/entitlement_service.dart';
import '../utils/glass_utils.dart';
import '../utils/artist_merge_utils.dart';
import '../services/download_service.dart';

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
  StreamSubscription? _enrichmentSub;
  bool _isShowingSyncDialog = false;
  List<MergeSuggestion>? _cachedArtistMergeSuggestions;
  String _artistMergeCacheKey = '';
  bool _isCalculatingArtistMerges = false;

  List<MergeSuggestion>? _cachedAlbumMergeSuggestions;
  String _albumMergeCacheKey = '';
  bool _isCalculatingAlbumMerges = false;
  static const String _dismissedArtistMergesKey = 'dismissed_artist_merges';
  static const String _dismissedAlbumMergesKey = 'dismissed_album_merges';
  final Set<String> _dismissedMergePairs = {};
  final Set<String> _dismissedAlbumMergePairs = {};
  bool _modeSwitchPending = false;

  @override
  void initState() {
    super.initState();
    _loadFilterState();
    _loadDismissedMergePairs();
    _loadDismissedAlbumMergePairs();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });

    _enrichmentSub = Provider.of<RadioProvider>(context, listen: false)
        .onEnrichmentComplete
        .listen((completion) {
          if (!_isShowingSyncDialog && completion.failCount > 0) {
            _isShowingSyncDialog = true;
            _showSyncCompleteDialog(completion);
          }
        });
  }

  void _showSyncCompleteDialog(EnrichmentCompletion completion) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(
          lang.translate('sync_complete_title'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          lang
              .translate('sync_complete_msg')
              .replaceAll('{0}', completion.playlistName)
              .replaceAll('{1}', completion.successCount.toString())
              .replaceAll('{2}', completion.failCount.toString()),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _isShowingSyncDialog = false;
            },
            child: Text(lang.translate('close')),
          ),
        ],
      ),
    );
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

  /// Per-playlist scan: called when a playlist is opened.
  /// Looks for offline files on the device that match online-only songs
  /// in this specific playlist. Shows the upgrade dialog only if new matches
  /// are found that the user hasn't already dismissed.
  Future<void> _scanAndShowLocalMatchesForPlaylist(String playlistId) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final proposals = await provider.scanForLocalUpgradesForPlaylist(playlistId);
    if (!mounted) return;
    if (proposals.isNotEmpty) {
      // Small delay so the UI settles after switching playlist
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      _showUpgradeDialog(context, provider);
    }
  }

  static String _formatProposalDuration(Duration? d) {
    if (d == null || d.inSeconds <= 0) return '';
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  static String _formatProposalSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _getProposalExtension(String path) {
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex != -1 && dotIndex < path.length - 1) {
      final ext = path.substring(dotIndex + 1);
      if (ext.length <= 5 && !ext.contains('/') && !ext.contains('\\')) {
        return ext.toUpperCase();
      }
    }
    return '';
  }

  static String _getProposalParentFolder(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length >= 2) {
      return segments[segments.length - 2];
    }
    return '';
  }

  void _showUpgradeDialog(BuildContext context, RadioProvider provider) {
    // Creating a local set to track selected proposals.

    // We initiate it with all proposals selected by default.
    final Set<String> selectedProposalIds = provider.upgradeProposals
        .map((p) => "${p.playlistId}_${p.songId}")
        .toSet();
    final Set<String> neverShowAgainIds = {};

    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            final lang = Provider.of<LanguageProvider>(context, listen: false);
            final proposals = provider.upgradeProposals;
            return AlertDialog(
              surfaceTintColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 24),
              title: Text(
                lang.translate('local_files_found'),
                style: const TextStyle(color: Colors.white),
              ),
              content: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.75,
                  maxWidth: MediaQuery.of(context).size.width,
                ),
                width: MediaQuery.of(context).size.width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lang
                          .translate('local_files_desc')
                          .replaceAll('{0}', proposals.length.toString()),
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      lang.translate('never_ask_again_song_desc'),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (neverShowAgainIds.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.redAccent.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Text(
                              '${neverShowAgainIds.length} ${lang.translate('never_ask_badge')}',
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        else
                          const SizedBox.shrink(),
                        Builder(
                          builder: (context) {
                            final availableProposals = proposals.where(
                              (p) => !neverShowAgainIds.contains(
                                "${p.playlistId}_${p.songId}",
                              ),
                            );
                            final bool isAllSelected =
                                availableProposals.isNotEmpty &&
                                availableProposals.every(
                                  (p) => selectedProposalIds.contains(
                                    "${p.playlistId}_${p.songId}",
                                  ),
                                );
                            return TextButton(
                              onPressed: () {
                                setState(() {
                                  if (isAllSelected) {
                                    selectedProposalIds.clear();
                                  } else {
                                    for (var p in availableProposals) {
                                      selectedProposalIds.add(
                                        "${p.playlistId}_${p.songId}",
                                      );
                                    }
                                  }
                                });
                              },
                              child: Text(
                                isAllSelected
                                    ? lang.translate('deselect_all')
                                    : lang.translate('select_all'),
                                style: const TextStyle(
                                  color: Colors.blueAccent,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12),
                    Expanded(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: proposals.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final p = proposals[index];
                          final uniqueId = "${p.playlistId}_${p.songId}";
                          final isNeverShowAgain = neverShowAgainIds.contains(
                            uniqueId,
                          );
                          final isSelected = selectedProposalIds.contains(
                            uniqueId,
                          );

                          return Container(
                            decoration: BoxDecoration(
                              color: isNeverShowAgain
                                  ? Colors.redAccent.withValues(alpha: 0.08)
                                  : (isSelected
                                      ? Theme.of(context)
                                          .primaryColor
                                          .withValues(alpha: 0.16)
                                      : Colors.white.withValues(alpha: 0.04)),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isNeverShowAgain
                                    ? Colors.redAccent.withValues(alpha: 0.4)
                                    : (isSelected
                                        ? Theme.of(context)
                                            .primaryColor
                                            .withValues(alpha: 0.5)
                                        : Colors.white.withValues(alpha: 0.09)),
                                width: isSelected ? 1.4 : 1.0,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Checkbox aligned to top
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Checkbox(
                                      value: isSelected && !isNeverShowAgain,
                                      activeColor: Theme.of(context).primaryColor,
                                      checkColor: Colors.white,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                      onChanged: isNeverShowAgain
                                          ? null
                                          : (val) {
                                              setState(() {
                                                if (val == true) {
                                                  selectedProposalIds.add(
                                                    uniqueId,
                                                  );
                                                } else {
                                                  selectedProposalIds.remove(
                                                    uniqueId,
                                                  );
                                                }
                                              });
                                            },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  // Song & Offline Details
                                  Expanded(
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      onTap: isNeverShowAgain
                                          ? null
                                          : () {
                                              setState(() {
                                                if (isSelected) {
                                                  selectedProposalIds.remove(
                                                    uniqueId,
                                                  );
                                                } else {
                                                  selectedProposalIds.add(
                                                    uniqueId,
                                                  );
                                                }
                                              });
                                            },
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // 1. ONLINE SONG SECTION
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 5,
                                                  vertical: 1.5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.blueAccent
                                                      .withValues(alpha: 0.18),
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                  border: Border.all(
                                                    color: Colors.blueAccent
                                                        .withValues(alpha: 0.35),
                                                    width: 0.8,
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const Icon(
                                                      Icons.cloud_outlined,
                                                      size: 10,
                                                      color: Colors.blueAccent,
                                                    ),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      lang.translate(
                                                        'online_track',
                                                      ),
                                                      style: const TextStyle(
                                                        color:
                                                            Colors.blueAccent,
                                                        fontSize: 9,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Icon(
                                                Icons.queue_music_rounded,
                                                size: 11,
                                                color: isNeverShowAgain
                                                    ? Colors.white24
                                                    : Theme.of(context)
                                                        .primaryColor,
                                              ),
                                              const SizedBox(width: 3),
                                              Flexible(
                                                child: Text(
                                                  p.playlistName.isNotEmpty
                                                      ? p.playlistName
                                                      : 'Playlist',
                                                  style: TextStyle(
                                                    color: isNeverShowAgain
                                                        ? Colors.white24
                                                        : Theme.of(context)
                                                            .primaryColor
                                                            .withValues(
                                                              alpha: 0.9,
                                                            ),
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (isNeverShowAgain) ...[
                                                const SizedBox(width: 4),
                                                Text(
                                                  '(${lang.translate('never_ask_badge')})',
                                                  style: const TextStyle(
                                                    color: Colors.redAccent,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            p.songTitle,
                                            style: TextStyle(
                                              color: isNeverShowAgain
                                                  ? Colors.white38
                                                  : Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              decoration: isNeverShowAgain
                                                  ? TextDecoration.lineThrough
                                                  : null,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          if (p.songArtist.isNotEmpty) ...[
                                            const SizedBox(height: 1),
                                            Text(
                                              p.songArtist,
                                              style: TextStyle(
                                                color: isNeverShowAgain
                                                    ? Colors.white24
                                                    : Colors.white70,
                                                fontSize: 11,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],

                                          // 2. REPLACEMENT CONNECTOR
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 6,
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Divider(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.1),
                                                    height: 1,
                                                    thickness: 0.8,
                                                  ),
                                                ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                  ),
                                                  child: Icon(
                                                    Icons.arrow_downward_rounded,
                                                    size: 12,
                                                    color: isNeverShowAgain
                                                        ? Colors.white24
                                                        : Theme.of(context)
                                                            .primaryColor,
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Divider(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.1),
                                                    height: 1,
                                                    thickness: 0.8,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                          // 3. OFFLINE FILE DETAILS (Card)
                                          Builder(
                                            builder: (context) {
                                              final fileName =
                                                  p.localDisplayName ??
                                                      p.localPath
                                                          .split('/')
                                                          .last
                                                          .split('\\')
                                                          .last;
                                              final ext =
                                                  _getProposalExtension(
                                                p.localPath,
                                              );
                                              final parentFolder =
                                                  _getProposalParentFolder(
                                                p.localPath,
                                              );
                                              final durStr =
                                                  _formatProposalDuration(
                                                p.localDuration,
                                              );
                                              final sizeStr =
                                                  _formatProposalSize(
                                                p.localSize,
                                              );
                                              final hasLocalTags =
                                                  (p.localTitle != null &&
                                                          p.localTitle!
                                                              .isNotEmpty) ||
                                                      (p.localArtist != null &&
                                                          p.localArtist!
                                                              .isNotEmpty &&
                                                          p.localArtist !=
                                                              '<unknown>');

                                              return Container(
                                                padding: const EdgeInsets.all(8),
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withValues(
                                                    alpha: 0.28,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                  border: Border.all(
                                                    color: isNeverShowAgain
                                                        ? Colors.white
                                                            .withValues(
                                                              alpha: 0.05,
                                                            )
                                                        : Colors.tealAccent
                                                            .withValues(
                                                              alpha: 0.2,
                                                            ),
                                                    width: 0.8,
                                                  ),
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    // Header: Offline match indicator + format badge
                                                    Row(
                                                      children: [
                                                        Icon(
                                                          Icons
                                                              .download_done_rounded,
                                                          size: 12,
                                                          color: isNeverShowAgain
                                                              ? Colors.white30
                                                              : Colors
                                                                  .tealAccent,
                                                        ),
                                                        const SizedBox(width: 4),
                                                        Text(
                                                          lang.translate(
                                                            'offline_match',
                                                          ),
                                                          style: TextStyle(
                                                            color: isNeverShowAgain
                                                                ? Colors.white30
                                                                : Colors
                                                                    .tealAccent,
                                                            fontSize: 10,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                        ),
                                                        const Spacer(),
                                                        if (ext.isNotEmpty)
                                                          Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 4,
                                                              vertical: 1,
                                                            ),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: Colors.white
                                                                  .withValues(
                                                                alpha: 0.09,
                                                              ),
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                4,
                                                              ),
                                                            ),
                                                            child: Text(
                                                              ext,
                                                              style:
                                                                  const TextStyle(
                                                                color: Colors
                                                                    .white70,
                                                                fontSize: 9,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                letterSpacing:
                                                                    0.5,
                                                              ),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 5),

                                                    // File name
                                                    Row(
                                                      children: [
                                                        Icon(
                                                          Icons
                                                              .audio_file_outlined,
                                                          size: 12,
                                                          color: isNeverShowAgain
                                                              ? Colors.white24
                                                              : Colors.white60,
                                                        ),
                                                        const SizedBox(width: 4),
                                                        Expanded(
                                                          child: Text(
                                                            fileName,
                                                            style: TextStyle(
                                                              color:
                                                                  isNeverShowAgain
                                                                      ? Colors
                                                                          .white38
                                                                      : Colors
                                                                          .white,
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w500,
                                                            ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ),
                                                      ],
                                                    ),

                                                    // ID3 Tag info (Title / Artist if available)
                                                    if (hasLocalTags) ...[
                                                      const SizedBox(height: 3),
                                                      Row(
                                                        children: [
                                                          Icon(
                                                            Icons.tag_rounded,
                                                            size: 11,
                                                            color: isNeverShowAgain
                                                                ? Colors.white24
                                                                : Colors
                                                                    .tealAccent
                                                                    .withValues(
                                                                  alpha: 0.7,
                                                                ),
                                                          ),
                                                          const SizedBox(
                                                            width: 4,
                                                          ),
                                                          Expanded(
                                                            child: Text(
                                                              "${p.localTitle ?? ''}${p.localArtist != null && p.localArtist!.isNotEmpty && p.localArtist != '<unknown>' ? ' • ${p.localArtist}' : ''}",
                                                              style: TextStyle(
                                                                color: isNeverShowAgain
                                                                    ? Colors
                                                                        .white24
                                                                    : Colors
                                                                        .white
                                                                        .withValues(
                                                                      alpha:
                                                                          0.75,
                                                                    ),
                                                                fontSize: 10.5,
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ],

                                                    // Parent Folder / Path info
                                                    if (parentFolder
                                                        .isNotEmpty) ...[
                                                      const SizedBox(height: 3),
                                                      Tooltip(
                                                        message: p.localPath,
                                                        child: Row(
                                                          children: [
                                                            const Icon(
                                                              Icons
                                                                  .folder_open_rounded,
                                                              size: 11,
                                                              color: Colors
                                                                  .white38,
                                                            ),
                                                            const SizedBox(
                                                              width: 4,
                                                            ),
                                                            Expanded(
                                                              child: Text(
                                                                "../$parentFolder/$fileName",
                                                                style:
                                                                    const TextStyle(
                                                                  color: Colors
                                                                      .white38,
                                                                  fontSize: 9.5,
                                                                ),
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ],

                                                    // Metadata badges (Duration, File Size, Album)
                                                    if (durStr.isNotEmpty ||
                                                        sizeStr.isNotEmpty ||
                                                        (p.localAlbum != null &&
                                                            p.localAlbum!
                                                                .isNotEmpty &&
                                                            p.localAlbum !=
                                                                '<unknown>')) ...[
                                                      const SizedBox(height: 6),
                                                      Wrap(
                                                        spacing: 6,
                                                        runSpacing: 4,
                                                        children: [
                                                          if (durStr.isNotEmpty)
                                                            Container(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                horizontal: 5,
                                                                vertical: 2,
                                                              ),
                                                              decoration:
                                                                  BoxDecoration(
                                                                color: Colors
                                                                    .white
                                                                    .withValues(
                                                                  alpha: 0.07,
                                                                ),
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                  4,
                                                                ),
                                                              ),
                                                              child: Row(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  const Icon(
                                                                    Icons
                                                                        .access_time_rounded,
                                                                    size: 9,
                                                                    color: Colors
                                                                        .white60,
                                                                  ),
                                                                  const SizedBox(
                                                                    width: 3,
                                                                  ),
                                                                  Text(
                                                                    durStr,
                                                                    style:
                                                                        const TextStyle(
                                                                      color: Colors
                                                                          .white70,
                                                                      fontSize:
                                                                          9.5,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          if (sizeStr
                                                              .isNotEmpty)
                                                            Container(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                horizontal: 5,
                                                                vertical: 2,
                                                              ),
                                                              decoration:
                                                                  BoxDecoration(
                                                                color: Colors
                                                                    .white
                                                                    .withValues(
                                                                  alpha: 0.07,
                                                                ),
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                  4,
                                                                ),
                                                              ),
                                                              child: Row(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  const Icon(
                                                                    Icons
                                                                        .sd_storage_outlined,
                                                                    size: 9,
                                                                    color: Colors
                                                                        .white60,
                                                                  ),
                                                                  const SizedBox(
                                                                    width: 3,
                                                                  ),
                                                                  Text(
                                                                    sizeStr,
                                                                    style:
                                                                        const TextStyle(
                                                                      color: Colors
                                                                          .white70,
                                                                      fontSize:
                                                                          9.5,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          if (p.localAlbum !=
                                                                  null &&
                                                              p.localAlbum!
                                                                  .isNotEmpty &&
                                                              p.localAlbum !=
                                                                  '<unknown>')
                                                            Container(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                horizontal: 5,
                                                                vertical: 2,
                                                              ),
                                                              decoration:
                                                                  BoxDecoration(
                                                                color: Colors
                                                                    .white
                                                                    .withValues(
                                                                  alpha: 0.07,
                                                                ),
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                  4,
                                                                ),
                                                              ),
                                                              child: Row(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  const Icon(
                                                                    Icons
                                                                        .album_outlined,
                                                                    size: 9,
                                                                    color: Colors
                                                                        .white60,
                                                                  ),
                                                                  const SizedBox(
                                                                    width: 3,
                                                                  ),
                                                                  Flexible(
                                                                    child: Text(
                                                                      p.localAlbum!,
                                                                      style:
                                                                          const TextStyle(
                                                                        color: Colors
                                                                            .white70,
                                                                        fontSize:
                                                                            9.5,
                                                                      ),
                                                                      maxLines:
                                                                          1,
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                    ),
                                                                  ),
                                                                ],
                                                             ),
                                                            ),
                                                        ],
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  // Button to toggle "Do not show this comparison again"
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: IconButton(
                                      tooltip: isNeverShowAgain
                                          ? lang.translate('cancel')
                                          : lang.translate(
                                              'never_ask_again_song',
                                            ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 34,
                                        minHeight: 34,
                                      ),
                                      icon: Icon(
                                        isNeverShowAgain
                                            ? Icons.visibility_off_rounded
                                            : Icons.visibility_off_outlined,
                                        color: isNeverShowAgain
                                            ? Colors.redAccent
                                            : Colors.white38,
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          if (isNeverShowAgain) {
                                            neverShowAgainIds.remove(uniqueId);
                                            selectedProposalIds.add(uniqueId);
                                          } else {
                                            neverShowAgainIds.add(uniqueId);
                                            selectedProposalIds.remove(uniqueId);
                                          }
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

              actionsAlignment: (neverShowAgainIds.isNotEmpty || selectedProposalIds.isNotEmpty)
                  ? MainAxisAlignment.spaceBetween
                  : MainAxisAlignment.end,
              actions: [
                if (neverShowAgainIds.isNotEmpty)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    icon: const Icon(Icons.visibility_off_rounded, size: 16),
                    label: Text(
                      Provider.of<LanguageProvider>(
                        context,
                        listen: false,
                      ).translate('confirm'),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () async {
                      final toIgnore = proposals.where((p) {
                        final uId = "${p.playlistId}_${p.songId}";
                        return neverShowAgainIds.contains(uId);
                      }).toList();
                      if (toIgnore.isNotEmpty) {
                        await provider.ignoreUpgradeProposals(toIgnore);
                      }
                      provider.upgradeProposals.clear();
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              Provider.of<LanguageProvider>(
                                context,
                                listen: false,
                              ).translate('never_ask_saved').replaceAll(
                                '{0}',
                                toIgnore.length.toString(),
                              ),
                            ),
                          ),
                        );
                      }
                    },
                  )
                else if (selectedProposalIds.isNotEmpty)
                  ElevatedButton(
                    onPressed: () {
                      final toApply = proposals.where((p) {
                        final uId = "${p.playlistId}_${p.songId}";
                        return selectedProposalIds.contains(uId) &&
                            !neverShowAgainIds.contains(uId);
                      }).toList();

                      final toIgnore = proposals.where((p) {
                        final uId = "${p.playlistId}_${p.songId}";
                        return neverShowAgainIds.contains(uId) ||
                            !selectedProposalIds.contains(uId);
                      }).toList();

                      provider.applyUpgrades(toApply, ignored: toIgnore);
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
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    child: Text(
                      Provider.of<LanguageProvider>(context, listen: false)
                          .translate('update'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                  },
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
            .getDisplayName(lang.translate);
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

  /// Returns formatted total duration of the currently selected playlist
  String get headerDuration {
    final playlist = rawEffectivePlaylist;
    if (playlist == null) return '';
    final total = playlist.songs.fold<Duration>(
      Duration.zero,
      (sum, s) => sum + (s.duration ?? Duration.zero),
    );
    if (total == Duration.zero) return '';
    final h = total.inHours;
    final m = total.inMinutes.remainder(60);
    final s = total.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2,'0')}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2,'0')}s';
    return '${s}s';
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

  bool get hasInvalidSongs {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    return rawEffectivePlaylist?.songs.any(
          (s) => !s.isValid || provider.invalidSongIds.contains(s.id),
        ) ??
        false;
  }

  bool get hasLocalSongs {
    final rawPlaylist = rawEffectivePlaylist;
    return (rawPlaylist?.creator == 'local') ||
        (rawPlaylist?.songs.any(
              (s) => s.localPath != null || s.id.startsWith('local_'),
            ) ??
            false);
  }

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
    _enrichmentSub?.cancel();
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
        (song.localPath != null &&
            song.localPath!.isNotEmpty &&
            File(song.localPath!).existsSync()) ||
        song.id.startsWith('local_');
    final bool hideOnline = isLocalPlaylist || isLocalSong;

    GlassUtils.showGlassBottomSheet(
      context: context,
      isScrollControlled: false,
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
            Material(
              color: Colors.black.withValues(alpha: 0.001),
              child: ListTile(
                leading: const Icon(Icons.refresh_rounded, color: Colors.green),
                title: Text(
                  Provider.of<LanguageProvider>(
                    context,
                    listen: false,
                  ).translate('try_again_unlock_all'),
                  style: const TextStyle(color: Colors.greenAccent),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _testAndUnlockTrack(provider, song, playlistId);
                },
              ),
            ),
            if (!hideOnline)
              Material(
                color: Colors.black.withValues(alpha: 0.001),
                child: ListTile(
                  leading: const Icon(
                    Icons.lock_open_rounded,
                    color: Colors.green,
                  ),
                  title: Text(
                    Provider.of<LanguageProvider>(
                      context,
                      listen: false,
                    ).translate('force_unlock'),
                    style: const TextStyle(color: Colors.orangeAccent),
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
              ),
            Material(
              color: Colors.black.withValues(alpha: 0.001),
              child: ListTile(
                leading: const Icon(
                  Icons.info_outline,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  Provider.of<LanguageProvider>(
                    context,
                    listen: false,
                  ).translate('view_song_details'),
                  style: const TextStyle(color: Colors.blueAccent),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSongDetailsDialog(context, song, provider: provider, playlistId: playlistId);
                },
              ),
            ),
            if (!hideOnline)
              Material(
                color: Colors.black.withValues(alpha: 0.001),
                child: ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: Text(
                    Provider.of<LanguageProvider>(
                      context,
                      listen: false,
                    ).translate('remove_from_library'),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    _confirmRemoveSong(context, provider, song, playlistId);
                  },
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemoveSong(
    BuildContext context,
    RadioProvider provider,
    SavedSong song,
    String playlistId,
  ) async {
    final confirmed = await GlassUtils.showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF222222),
        title: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('remove_song'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('remove_song_desc'),
          style: const TextStyle(color: Colors.white70),
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
            child: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('delete'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      provider.removeSongFromLibrary(song.id);
    }
  }

  void _showQRScanner(BuildContext context, RadioProvider provider) async {
    final status = await Permission.camera.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      if (mounted) {
        final lang = Provider.of<LanguageProvider>(context, listen: false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(lang.translate('permission_camera_denied'))),
        );
      }
      return;
    }

    if (!mounted) return;

    // Tiny delay to ensure the OS permission update is fully recognized by the camera driver
    await Future.delayed(const Duration(milliseconds: 250));

    if (context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (ctx) {
            bool processed = false;
            return _QRScannerScreen(
              onCodeDetected: (qrData) async {
                if (processed) return;
                processed = true;

                Navigator.pop(ctx);
                final data = qrData.trim();

                bool success = false;
                // Handle Cloud Tokens vs Song Deep Links vs Legacy Base64
                if (data.startsWith('http') ||
                    data.startsWith('musicstream://')) {
                  final uri = Uri.tryParse(data);
                  if (uri != null) {
                    success = await provider.handleExternalUri(uri);
                  }
                } else {
                  // Legacy Base64 protocol
                  success = await provider.importSharedPlaylist(data);
                }

                if (context.mounted) {
                  final lang = Provider.of<LanguageProvider>(
                    context,
                    listen: false,
                  );

                  if (success) {
                    GlassUtils.showGlassDialog(
                      context: context,
                      builder: (dialogCtx) => AlertDialog(
                        backgroundColor: const Color(0xFF1a1a2e),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        title: Text(
                          lang.translate('success'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        content: Text(
                          lang.translate('imported_playlist'),
                          style: const TextStyle(color: Colors.white70),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            child: Text(
                              lang.translate('close'),
                              style: const TextStyle(color: Colors.blueAccent),
                            ),
                          ),
                        ],
                      ),
                    );
                  } else {
                    GlassUtils.showGlassDialog(
                      context: context,
                      builder: (dialogCtx) => AlertDialog(
                        backgroundColor: const Color(0xFF1a1a2e),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        title: Text(
                          lang.translate('qr_scan_error'),
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        content: Text(
                          lang.translate('qr_scan_invalid'),
                          style: const TextStyle(color: Colors.white70),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            child: Text(
                              lang.translate('close'),
                              style: const TextStyle(color: Colors.blueAccent),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                }
              },
            );
          },
        ),
      );
    }
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
            youtubeUrl: song.youtubeUrl,
            appleMusicUrl: song.appleMusicUrl,
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

  void _showSongDetailsDialog(BuildContext context, SavedSong initialSong,
      {RadioProvider? provider, String? playlistId}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SongMetadataDetailsScreen(
          initialSong: initialSong,
          provider: provider,
          playlistId: playlistId,
        ),
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
    final allPlaylists = provider.playlists;

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

      // Apply Global Library Filters (Local / Invalid)
      if (_showOnlyLocal) {
        displayPlaylists = displayPlaylists
            .where(
              (p) => p.songs.any(
                (s) => s.localPath != null || s.id.startsWith('local_'),
              ),
            )
            .toList();
      }
      if (_showOnlyInvalid) {
        displayPlaylists = displayPlaylists
            .where(
              (p) => p.songs.any(
                (s) => !s.isValid || provider.invalidSongIds.contains(s.id),
              ),
            )
            .toList();
      }
    }

    // Apply Global Library Filters to allSongs (used for Artist/Album views)
    List<SavedSong> filteredAllSongs = allSongs;
    if (_showOnlyLocal) {
      filteredAllSongs = filteredAllSongs
          .where((s) => s.localPath != null || s.id.startsWith('local_'))
          .toList();
    }
    if (_showOnlyInvalid) {
      filteredAllSongs = filteredAllSongs
          .where((s) => !s.isValid || provider.invalidSongIds.contains(s.id))
          .toList();
    }
    const appBarBgColor = Colors.transparent;
    final headerContrastColor =
        Theme.of(context).textTheme.bodyLarge?.color ?? Colors.white;
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;
    final iconColor =
        Theme.of(context).iconTheme.color ??
        onSurfaceColor.withValues(alpha: 0.7);
    final primaryColor = Theme.of(context).primaryColor;

    // Helper for Mode Button
    Widget buildModeBtn(String title, MetadataViewMode mode) {
      final bool selected = _viewMode == mode;
      return GestureDetector(
        onTap: () async {
          if (_viewMode == mode || _modeSwitchPending) return;
          setState(() {
            _modeSwitchPending = true;
          });
          // Yield to event loop so CircularProgressIndicator mounts and spins fluidly
          await Future.delayed(const Duration(milliseconds: 120));
          if (!mounted) return;
          setState(() {
            _viewMode = mode;
            _modeSwitchPending = false;
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
            color: Colors.transparent,
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
                    // Small title above buttons (when active)
                    if (isSelectionActive)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: 4,
                          left: 16,
                          right: 16,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (_selectedPlaylistId != null && provider.enrichingPlaylists.contains(_selectedPlaylistId))
                              Padding(
                                padding: const EdgeInsets.only(right: 8.0),
                                child: _SpinningSyncIcon(
                                  size: 14,
                                  color: headerContrastColor.withValues(alpha: 0.7),
                                ),
                              ),
                            Flexible(
                              child: Text(
                                headerTitle,
                                style: TextStyle(
                                  color: headerContrastColor.withValues(alpha: 0.7),
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (headerDuration.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: headerContrastColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.schedule_rounded, size: 11, color: headerContrastColor.withValues(alpha: 0.6)),
                                    const SizedBox(width: 3),
                                    Text(
                                      headerDuration,
                                      style: TextStyle(
                                        color: headerContrastColor.withValues(alpha: 0.6),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                    Row(
                      children: [
                        if (isSelectionActive)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                              ),
                            ],
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: provider.isSyncingMetadata
                                ? _SpinningSyncIcon(
                                    size: 20,
                                    color: headerContrastColor,
                                  )
                                : Icon(
                                    _viewMode == MetadataViewMode.artists
                                        ? Icons.people
                                        : _viewMode == MetadataViewMode.albums
                                        ? Icons.album
                                        : Icons.collections_bookmark_rounded,
                                    color: headerContrastColor,
                                  ),
                          ),

                        // Case 1: Library Title (anchored to the left icon)
                        if (!isSelectionActive)
                          Padding(
                            padding: const EdgeInsets.only(
                              left: 8.0,
                              right: 8.0,
                            ),
                            child: Text(
                              headerTitle,
                              style: TextStyle(
                                color: headerContrastColor,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                            ),
                          ),

                        // Case 2: Prominent Play All Button (Anchored to the left in Selection Mode)
                        if (isSelectionActive)
                        Expanded(
                          child:Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: ElevatedButton.icon(
                              onPressed: () =>
                                  _handleAction('play_all', fromMenu: false),
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                              ),
                              label: Text(
                                lang.translate('play_all'),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryColor,
                                foregroundColor:
                                    primaryColor.computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 0,
                                ),
                                elevation: 0,
                                visualDensity: VisualDensity.compact,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Scrollable section for all other Icons (Pins + Status Indicators)
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              reverse: true, // Priority to right-alignment
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Status Indicators (Selection Mode only)
                                  if (isSelectionActive) ...[
                                    if (hasLocalSongs)
                                      GestureDetector(
                                        onTap: () =>
                                            _handleAction('toggle_local'),
                                        behavior: HitTestBehavior.opaque,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                            left: 4,
                                          ),
                                          child: Icon(
                                            Icons.folder_rounded,
                                            color: _showOnlyLocal
                                                ? Theme.of(context).primaryColor
                                                : headerContrastColor
                                                      .withValues(alpha: 0.5),
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                    if (hasInvalidSongs)
                                      GestureDetector(
                                        onTap: () =>
                                            _handleAction('toggle_invalid'),
                                        behavior: HitTestBehavior.opaque,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                            left: 2,
                                          ),
                                          child: Icon(
                                            Icons.warning_rounded,
                                            color: _showOnlyInvalid
                                                ? Colors.orangeAccent
                                                : headerContrastColor
                                                      .withValues(alpha: 0.5),
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                    if (_isBulkChecking)
                                      const Padding(
                                        padding: EdgeInsets.only(right: 8.0),
                                        child: SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.greenAccent,
                                          ),
                                        ),
                                      ),
                                  ],

                                  // Pinned Actions (Library or Selection pins)
                                  ...(isSelectionActive
                                          ? provider.pinnedPlaylistActions
                                          : provider.pinnedLibraryActions)
                                      .where(
                                        (id) =>
                                            id != 'play_all' &&
                                            _isActionVisible(id),
                                      )
                                      .take(5)
                                      .map(
                                        (id) => _buildHeaderActionButton(
                                          id,
                                          headerContrastColor,
                                        ),
                                      ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Consolidated 3-dot menu (Always fixed on right)
                        IconButton(
                          icon: Icon(
                            Icons.more_vert_rounded,
                            color: headerContrastColor,
                            size: 20,
                          ),
                          padding: const EdgeInsets.all(4),
                          tooltip: lang.translate('settings'),
                          onPressed: () => _showHeaderMenu(
                            context,
                            provider,
                            lang,
                            headerContrastColor,
                            primaryColor,
                            iconColor,
                            onSurfaceColor,
                          ),
                        ),

                        const SizedBox(width: 8),
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
                                    hintText: lang.translate('search'),
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
                              hintText: lang.translate('find_in_playlist'),
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
                    const SizedBox(height: 2),
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
                          // Artificial delay to ensure spinner is visible as requested
                          final startTime = DateTime.now();
                          final provider = Provider.of<RadioProvider>(
                            context,
                            listen: false,
                          );

                          if (_selectedPlaylistId != null) {
                            // Call background refresh that checks local file structure and video links
                            provider.refreshPlaylistInBackground(
                              _selectedPlaylistId!,
                            );
                            await provider.reloadPlaylists();
                          } else {
                            await provider.reloadPlaylists();
                            provider.findMissingArtworks();
                          }

                          // Ensure at least 800ms of visibility
                          final elapsed = DateTime.now()
                              .difference(startTime)
                              .inMilliseconds;
                          if (elapsed < 800) {
                            await Future.delayed(
                              Duration(milliseconds: 800 - elapsed),
                            );
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
                      return _buildGlobalSearchResults(
                        context,
                        provider,
                        allPlaylists,
                      );
                    }

                    if (_modeSwitchPending) {
                      final loadingLang = Provider.of<LanguageProvider>(
                        context,
                        listen: false,
                      );
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Theme.of(context).primaryColor,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              loadingLang.translate('loading'),
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 13,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    switch (_viewMode) {
                      case MetadataViewMode.playlists:
                        return RefreshIndicator(
                          onRefresh: () async {
                            provider.reloadPlaylists();
                            provider.findMissingArtworks();
                          },
                          child: ListView(
                            controller: _playlistsScrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            key: const PageStorageKey('playlists_list'),
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
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
                            provider.reloadPlaylists();
                            provider.findMissingArtworks();
                          },
                          child: Column(
                            children: [
                              _buildMergeBanner(
                                context,
                                provider,
                                filteredAllSongs,
                              ),
                              Expanded(
                                child: _buildArtistsGrid(
                                  context,
                                  provider,
                                  filteredAllSongs,
                                ),
                              ),
                            ],
                          ),
                        );
                      case MetadataViewMode.albums:
                        return RefreshIndicator(
                          onRefresh: () async {
                            provider.reloadPlaylists();
                            provider.findMissingArtworks();
                          },
                          child: Column(
                            children: [
                              _buildMergeBanner(
                                context,
                                provider,
                                filteredAllSongs,
                                isAlbum: true,
                              ),
                              Expanded(
                                child: _buildAlbumsGrid(
                                  context,
                                  provider,
                                  filteredAllSongs,
                                ),
                              ),
                            ],
                          ),
                        );
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        // QR PREPARATION SPINNER OVERLAY (Non-blocking)
        if (provider.isPreparingQR &&
            provider.preparingPlaylist != null &&
            !provider.isSilentPreparation)
          Positioned(
            top: MediaQuery.of(context).padding.top + 80,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.5),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.3),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      lang.translate('sharing_cloud_prepping'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
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
    final hasAnyLocal = provider.playlists.any((p) => p.creator == 'local');
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    final entitlements = Provider.of<EntitlementService>(
      context,
      listen: false,
    );
    final canUseLocal = entitlements.isFeatureEnabled('local_library');

    final bool showLocalLink =
        _searchQuery.isEmpty && !hasAnyLocal && canUseLocal;

    final int extraCount = (showLocalLink ? 1 : 0);

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
                final double safeMax = maxScroll > 0
                    ? maxScroll
                    : (centeredOffset > 0 ? centeredOffset : 0.0);
                final double targetOffset = centeredOffset.clamp(0.0, safeMax);

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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
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
                return _buildDirectAccessCard(
                  context,
                  provider,
                  lang.translate('local_music'),
                  lang.translate('add_folders_device'),
                  Icons.folder_rounded,
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
            },
          );
        }

        return ReorderableGridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
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
              return _buildDirectAccessCard(
                context,
                provider,
                lang.translate('local_music'),
                lang.translate('add_folders_device'),
                Icons.folder_rounded,
                Colors.orangeAccent,
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LocalLibraryScreen()),
                ),
                const ValueKey('inv_local'),
              );
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

        final isNewSelection = _selectedPlaylistId != playlist.id;

        setState(() {
          if (isNewSelection) {
            _selectedPlaylistId = playlist.id;
            _showOnlyInvalid = false;
            _showOnlyLocal = false;
            // TRIGGER PROACTIVE RESOLUTION
            if (_selectedPlaylistId != null) {
              final pl = Provider.of<RadioProvider>(context, listen: false)
                  .playlists
                  .firstWhere(
                    (p) => p.id == _selectedPlaylistId,
                    orElse: () => playlist,
                  );
              Provider.of<RadioProvider>(
                context,
                listen: false,
              ).proactiveResolvePlaylist(pl);
            }
          }
          _searchController.clear();
          _lastScrolledSongId = null;
        });

        // Scan for local offline files that can be linked to online songs
        // Only when switching to a new playlist
        if (isNewSelection) {
          _scanAndShowLocalMatchesForPlaylist(playlist.id);
        }
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
                      'assets/empty_playlist.webp',
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
            if (playlist.creator == 'local')
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.folder_rounded,
                    color: Theme.of(context).primaryColor,
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

            // Background Enrichment Indicator (Animated Sync Icon)
            if (provider.enrichingPlaylists.contains(playlist.id))
              Positioned(
                top: 8,
                right: 32, // Offset from menu button
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _SpinningSyncIcon(),
                      const SizedBox(width: 4),
                      Text(
                        "${playlist.songs.where((s) => s.artUri != null && s.artUri!.isNotEmpty).length}/${playlist.songs.length}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // MENU
            Positioned(
              top: 0,
              right: 0,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
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
                  onPressed: () =>
                      _showPlaylistMenu(context, provider, playlist),
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
                    playlist.name,
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
                  child: Icon(icon, color: accentColor, size: 22),
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
                  style: const TextStyle(
                    color: Color(0xFFE6E0E9),
                    fontSize: 11,
                    height: 1.4,
                    leadingDistribution: TextLeadingDistribution.even,
                    decoration: TextDecoration.none,
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
    GlassUtils.showGlassDialog(
      context: context,
      builder: (dialogCtx) {
        final lang = Provider.of<LanguageProvider>(context, listen: false);
        final playlists = provider.playlists
            .where((p) => p.id != sourcePlaylist.id)
            .toList();

        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(
            lang.translate('copy_playlist'),
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
                    "${lang.translate('copy_songs_to')} ${sourcePlaylist.name}",
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
                        return Material(
                          color: Colors.black.withValues(alpha: 0.001),
                          child: ListTile(
                            leading: const Icon(
                              Icons.add,
                              color: Colors.blueAccent,
                            ),
                            title: Text(
                              lang.translate('create_new_playlist'),
                              style: const TextStyle(color: Colors.blueAccent),
                            ),
                            onTap: () {
                              Navigator.pop(dialogCtx);
                              _showCreatePlaylistDialog(
                                context,
                                provider,
                                initialSongs: sourcePlaylist.songs,
                              );
                            },
                          ),
                        );
                      }
                      final p = playlists[index - 1];
                      return Material(
                        color: Colors.black.withValues(alpha: 0.001),
                        child: ListTile(
                          leading: SizedBox(
                            width: 24,
                            height: 24,
                            child: Center(child: _buildDialogIcon(context, p)),
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
                            Navigator.pop(dialogCtx);
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
              onPressed: () => Navigator.pop(dialogCtx),
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
    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('clear_favorites'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('clear_favorites_desc'),
          style: const TextStyle(color: Colors.white70),
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
    GlassUtils.showGlassDialog(
      context: context,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
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

  void _showCreatePlaylistDialog(
    BuildContext context,
    RadioProvider provider, {
    List<SavedSong>? initialSongs,
  }) {
    final TextEditingController nameController = TextEditingController();
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(
          lang.translate('new_playlist'),
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
          decoration: InputDecoration(
            labelText: lang.translate('playlist_name'),
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
          ElevatedButton(
            onPressed: () async {
              final playlistName = nameController.text.trim();
              if (playlistName.isNotEmpty) {
                Navigator.pop(ctx);
                final newPlaylist = await provider.createPlaylist(
                  playlistName,
                  songs: initialSongs != null
                      ? List<SavedSong>.from(initialSongs)
                      : null,
                );
                if (initialSongs != null && initialSongs.isNotEmpty) {
                  provider.resolvePlaylistLinksInBackground(
                    newPlaylist.id,
                    initialSongs,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          lang
                              .translate('copied_songs_to')
                              .replaceAll('{0}', playlistName),
                        ),
                      ),
                    );
                  }
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Text(
              lang.translate('create'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showPlaylistMenu(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
  ) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    final dLimit = Provider.of<EntitlementService>(
      context,
      listen: false,
    ).getFeatureLimit('download_songs');
    final bool isEligible = dLimit != 0 || dLimit == -99;

    GlassUtils.showGlassBottomSheet(
      context: context,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (playlist.id == 'favorites') ...[
                if (isEligible)
                  _buildMenuItem(
                    context,
                    icon: Icons.download_rounded,
                    label: lang.translate('download'),
                    color: Colors.greenAccent,
                    onTap: () {
                      Navigator.pop(ctx);
                      downloadPlaylist(context, provider, playlist);
                    },
                  ),
                _buildMenuItem(
                  context,
                  icon: Icons.cleaning_services_rounded,
                  label: lang.translate('clean_all'),
                  color: Colors.orangeAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showClearFavoritesDialog(context, provider);
                  },
                ),
                _buildMenuItem(
                  context,
                  icon: Icons.share_rounded,
                  label: lang.translate('share_playlist'),
                  color: Colors.blueAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showSharePlaylistDialog(context, provider, playlist);
                  },
                ),
              ] else ...[
                if (playlist.creator != 'local')
                  _buildMenuItem(
                    context,
                    icon: Icons.edit_rounded,
                    label: lang.translate('rename'),
                    color: Colors.blueAccent,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showRenamePlaylistDialog(context, provider, playlist);
                    },
                  ),
                if (isEligible && playlist.creator != 'local')
                  _buildMenuItem(
                    context,
                    icon: Icons.download_rounded,
                    label: lang.translate('download'),
                    color: Colors.greenAccent,
                    onTap: () {
                      Navigator.pop(ctx);
                      downloadPlaylist(context, provider, playlist);
                    },
                  ),
                _buildMenuItem(
                  context,
                  icon: Icons.copy_rounded,
                  label: lang.translate('copy_to_ellipsis'),
                  color: Colors.purpleAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showCopyPlaylistDialog(context, provider, playlist);
                  },
                ),
                _buildMenuItem(
                  context,
                  icon: Icons.share_rounded,
                  label: lang.translate('share_playlist'),
                  color: Colors.orangeAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showSharePlaylistDialog(context, provider, playlist);
                  },
                ),
                _buildMenuItem(
                  context,
                  icon: Icons.delete_forever_rounded,
                  label: lang.translate('delete'),
                  color: Colors.redAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showDeletePlaylistDialog(context, provider, playlist);
                  },
                ),
              ],
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  Future<void> _shareSong(SavedSong song) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    GlassUtils.showGlassDialog(
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
            youtubeUrl: song.youtubeUrl,
            appleMusicUrl: song.appleMusicUrl,
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => <String, String>{},
          );

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      String deepLink = '';
      var youtubeLink = links['youtube'] ?? song.youtubeUrl;
      if (youtubeLink == null || youtubeLink.isEmpty) {
        youtubeLink = await provider.searchYoutubeVideo(
          song.title,
          song.artist,
        );
      }
      String videoId = '';
      if (youtubeLink != null && youtubeLink.isNotEmpty) {
        final vId = YoutubePlayer.convertUrlToId(youtubeLink);
        if (vId != null) videoId = vId;
      }

      final baseUrl = 'https://pjk72.github.io/musicstream/share.html';
      final encodedTitle = Uri.encodeComponent(song.title);
      final encodedArtist = Uri.encodeComponent(song.artist);
      final encodedAlbum = Uri.encodeComponent(song.album);
      final encodedArt = song.artUri != null
          ? Uri.encodeComponent(song.artUri!)
          : '';

      deepLink =
          '$baseUrl?type=song&id=$videoId&title=$encodedTitle&artist=$encodedArtist&album=$encodedAlbum&artUri=$encodedArt';

      String youtubeLinkStr = videoId.isNotEmpty
          ? 'https://youtu.be/$videoId'
          : (youtubeLink ?? '');

      final rawText = lang.translate('share_song_text');
      final String text = rawText
          .replaceAll('{0}', youtubeLinkStr)
          .replaceAll('{1}', song.title)
          .replaceAll('{2}', song.artist)
          .replaceAll('{3}', deepLink);

      if (!mounted) return;
      _showFinalSongQRDialog(context, song, deepLink, text);
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      debugPrint('Error sharing: $e');
    }
  }

  Future<void> _deleteSong(SavedSong song, Playlist playlist) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    bool confirm = true;
    if (playlist.creator == 'local') {
      confirm =
          await GlassUtils.showGlassDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              surfaceTintColor: Colors.transparent,
              title: Text(
                lang.translate('delete_file'),
                style: const TextStyle(color: Colors.white),
              ),
              content: Text(
                lang
                    .translate('delete_from_device_confirm')
                    .replaceAll('{0}', song.title),
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(lang.translate('cancel')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    lang.translate('delete'),
                    style: const TextStyle(color: Colors.red),
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
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(lang.translate('song_removed_from_library')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (playlist.creator == 'local' && song.localPath != null) {
          final f = File(song.localPath!);
          if (f.existsSync()) {
            f.deleteSync();
          }
        }
        provider.removeFromPlaylist(playlist.id, song.id);
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                lang.translate('song_removed_from_playlist'),
                style: const TextStyle(color: Colors.white),
              ),
              action: SnackBarAction(
                label: lang.translate('undo'),
                textColor: Theme.of(context).primaryColorLight,
                onPressed: () {
                  provider.restoreSongToPlaylist(playlist.id, deletedSong);
                },
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    }
  }

  void _showSongMenu(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
    SavedSong song,
  ) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    GlassUtils.showGlassBottomSheet(
      context: context,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Theme(
            data: Theme.of(context).copyWith(
              scrollbarTheme: ScrollbarThemeData(
                thumbVisibility: WidgetStateProperty.all(true),
                thumbColor: WidgetStateProperty.all(Colors.white54),
                thickness: WidgetStateProperty.all(4),
                radius: const Radius.circular(10),
              ),
            ),
            child: Scrollbar(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (song.isFilePresent)
                _buildMenuItem(
                  context,
                  icon: Icons.check_circle_rounded,
                  label: lang.translate('download'),
                  color: Theme.of(context).primaryColor,
                  onTap: () {},
                )
              else
                _buildMenuItem(
                  context,
                  icon: Icons.download_rounded,
                  label: lang.translate('download'),
                  color: Theme.of(context).primaryColor,
                  onTap: () {
                    Navigator.pop(ctx);
                    final tempPlaylist = Playlist(
                      id: 'temp_download_${song.id}',
                      name: song.title,
                      songs: [song],
                      createdAt: DateTime.now(),
                    );
                    downloadPlaylist(context, provider, tempPlaylist);
                  },
                ),
              _buildMenuItem(
                context,
                icon: Icons.share_rounded,
                label: lang.translate('share'),
                color: Colors.orangeAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _shareSong(song);
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.play_circle_outline_rounded,
                label: lang.translate('watch_video'),
                color: Colors.redAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _launchSongVideo(song);
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.copy_rounded,
                label: lang.translate('copy_to'),
                color: Colors.blueAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _showCopySongDialog(context, provider, playlist, song.id);
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.move_to_inbox_rounded,
                label: lang.translate('move_to'),
                color: Colors.purpleAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _showMoveSongDialog(context, provider, playlist, song.id);
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.info_outline_rounded,
                label: lang.translate('view_song_details'),
                color: Colors.tealAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _showSongDetailsDialog(context, song, provider: provider, playlistId: playlist.id);
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.delete_outline_rounded,
                label: lang.translate('delete'),
                color: Colors.redAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteSong(song, playlist);
                },
              ),
              const SizedBox(height: 10),
            ],
          ),
          ),
          ),
          ),
        );
      },
    );
  }

  void _showHeaderMenu(
    BuildContext context,
    RadioProvider provider,
    LanguageProvider lang,
    Color headerContrastColor,
    Color primaryColor,
    Color iconColor,
    Color onSurfaceColor,
  ) {
    GlassUtils.showGlassBottomSheet(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            Widget buildHeaderMenuItem({
              required String id,
              required IconData icon,
              required String label,
              required Color color,
              bool enabled = true,
            }) {
              final pinnedList = isSelectionActive
                  ? provider.pinnedPlaylistActions
                  : provider.pinnedLibraryActions;
              final isPinned = pinnedList.contains(id);

              return _buildMenuItem(
                context,
                icon: icon,
                label: label,
                color: color,
                enabled: enabled,
                trailing: provider.isPinningMode
                    ? Icon(
                        isPinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 18,
                        color: isPinned ? primaryColor : Colors.white24,
                      )
                    : null,
                onTap: () {
                  if (provider.isPinningMode) {
                    setModalState(() {
                      _handleAction(id, fromMenu: true);
                    });
                  } else {
                    Navigator.pop(ctx);
                    _handleAction(id, fromMenu: true);
                  }
                },
              );
            }

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Theme(
                data: Theme.of(context).copyWith(
                  scrollbarTheme: ScrollbarThemeData(
                    thumbVisibility: WidgetStateProperty.all(true),
                    thumbColor: WidgetStateProperty.all(Colors.white54),
                    thickness: WidgetStateProperty.all(4),
                    radius: const Radius.circular(10),
                  ),
                ),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    _buildMenuItem(
                      context,
                      icon: provider.isPinningMode
                          ? Icons.edit_off_rounded
                          : Icons.edit_rounded,
                      label: provider.isPinningMode
                          ? lang.translate('stop_customizing')
                          : lang.translate('customize_header'),
                      color: primaryColor,
                      onTap: () {
                        final bool currentlyPinning = provider.isPinningMode;
                        _handleAction('toggle_pin_mode', fromMenu: true);
                        if (currentlyPinning) {
                          // Stopping customization -> Close the menu
                          Navigator.pop(ctx);
                        } else {
                          // Starting customization -> Stay open and refresh
                          setModalState(() {});
                        }
                      },
                    ),
                    const Divider(color: Colors.white10),
                    if (isSelectionActive) ...[
                      buildHeaderMenuItem(
                        id: 'play_all',
                        icon: Icons.playlist_play_rounded,
                        label: lang.translate('play_all'),
                        color: Colors.greenAccent,
                      ),
                      if (isSelectionActive &&
                          (effectivePlaylist == null ||
                              effectivePlaylist!.id == 'favorites' ||
                              effectivePlaylist!.creator != 'local') &&
                          (Provider.of<EntitlementService>(
                                    context,
                                    listen: false,
                                  ).getFeatureLimit('download_songs') !=
                                  0 ||
                              Provider.of<EntitlementService>(
                                    context,
                                    listen: false,
                                  ).getFeatureLimit('download_songs') ==
                                  -99))
                        buildHeaderMenuItem(
                          id: 'download',
                          icon: Icons.download_rounded,
                          label: lang.translate('download'),
                          color: Colors.blueAccent,
                        ),
                      if (effectivePlaylist != null &&
                          effectivePlaylist!.creator != 'local')
                        buildHeaderMenuItem(
                          id: 'share_playlist',
                          icon: Icons.share_rounded,
                          label: lang.translate('share_playlist'),
                          color: Colors.orangeAccent,
                        ),
                      const Divider(color: Colors.white10),
                      buildHeaderMenuItem(
                        id: 'sort',
                        icon: Icons.sort_by_alpha,
                        label: lang.translate('sort_alphabetically'),
                        color: _sortAlphabetical
                            ? primaryColor
                            : Colors.white70,
                      ),
                      buildHeaderMenuItem(
                        id: 'search',
                        icon: _showPlaylistSearch
                            ? Icons.search_off
                            : Icons.search,
                        label: _showPlaylistSearch
                            ? lang.translate('hide_find')
                            : lang.translate('find_in_playlist'),
                        color: _showPlaylistSearch
                            ? primaryColor
                            : Colors.white70,
                      ),
                      const Divider(color: Colors.white10),
                      Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            lang.translate('group_by').toUpperCase(),
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white38,
                            ),
                          ),
                        ),
                      ),
                      buildHeaderMenuItem(
                        id: 'group_album',
                        icon: Icons.album,
                        label: lang.translate('label_album'),
                        color: _groupingMode == PlaylistGroupingMode.album
                            ? primaryColor
                            : Colors.white70,
                      ),
                      buildHeaderMenuItem(
                        id: 'group_artist',
                        icon: Icons.person,
                        label: lang.translate('label_artist'),
                        color: _groupingMode == PlaylistGroupingMode.artist
                            ? primaryColor
                            : Colors.white70,
                      ),
                      buildHeaderMenuItem(
                        id: 'group_none',
                        icon: Icons.list,
                        label: lang.translate('none'),
                        color: _groupingMode == PlaylistGroupingMode.none
                            ? primaryColor
                            : Colors.white70,
                      ),
                      const Divider(color: Colors.white10),
                      buildHeaderMenuItem(
                        id: 'shuffle',
                        icon: Icons.shuffle_rounded,
                        label: lang.translate('shuffle'),
                        color: provider.isShuffleMode
                            ? primaryColor
                            : Colors.white70,
                      ),
                      if (_selectedPlaylistId != null)
                        buildHeaderMenuItem(
                          id: 'duplicates',
                          icon: Icons.cleaning_services_rounded,
                          label: lang.translate('scan_duplicates'),
                          color: Colors.cyanAccent,
                        ),
                      if (hasInvalidSongs || _showOnlyInvalid)
                        buildHeaderMenuItem(
                          id: 'bulk_check',
                          icon: Icons.playlist_add_check_circle_rounded,
                          label: lang.translate('try_again_unlock_all'),
                          color: Colors.greenAccent,
                          enabled: !_isBulkChecking,
                        ),
                    ] else ...[
                      buildHeaderMenuItem(
                        id: 'search_add_song',
                        icon: Icons.library_music_rounded,
                        label: lang.translate('search_add_song'),
                        color: Colors.blueAccent,
                      ),
                      if (_viewMode == MetadataViewMode.playlists) ...[
                        buildHeaderMenuItem(
                          id: 'create_playlist',
                          icon: Icons.add_rounded,
                          label: lang.translate('create_playlist_tooltip'),
                          color: Colors.greenAccent,
                        ),
                        buildHeaderMenuItem(
                          id: 'scan_qr',
                          icon: Icons.qr_code_scanner_rounded,
                          label: lang.translate('scan_qr'),
                          color: Colors.orangeAccent,
                        ),
                        buildHeaderMenuItem(
                          id: 'sort_mode',
                          icon: _sortMode == PlaylistSortMode.custom
                              ? Icons.sort
                              : Icons.sort_by_alpha,
                          label: _sortMode == PlaylistSortMode.custom
                              ? lang.translate('custom_order_tooltip')
                              : lang.translate('alphabetical_order_tooltip'),
                          color: Colors.white70,
                        ),
                      ],
                      if (_viewMode == MetadataViewMode.artists)
                        buildHeaderMenuItem(
                          id: 'toggle_artists',
                          icon: _showFollowedArtistsOnly
                              ? Icons.how_to_reg
                              : Icons.person_add_alt,
                          label: lang.translate('followed_artists_only'),
                          color: _showFollowedArtistsOnly
                              ? primaryColor
                              : Colors.white70,
                        ),
                      if (_viewMode == MetadataViewMode.albums)
                        buildHeaderMenuItem(
                          id: 'toggle_albums',
                          icon: _showFollowedAlbumsOnly
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                          label: lang.translate('followed_albums_only'),
                          color: _showFollowedAlbumsOnly
                              ? primaryColor
                              : Colors.white70,
                        ),
                      if (hasLocalSongs || _showOnlyLocal)
                        buildHeaderMenuItem(
                          id: 'toggle_local',
                          icon: Icons.folder_rounded,
                          label: lang.translate('filter_local_device'),
                          color: _showOnlyLocal ? primaryColor : Colors.white70,
                        ),
                      if (hasInvalidSongs || _showOnlyInvalid)
                        buildHeaderMenuItem(
                          id: 'toggle_invalid',
                          icon: Icons.warning_rounded,
                          label: lang.translate('filter_invalid_tracks'),
                          color: _showOnlyInvalid
                              ? Colors.orangeAccent
                              : Colors.white70,
                        ),
                    ],
                    const SizedBox(height: 10),
                  ],
                ),
              ),
              ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool enabled = true,
    Widget? trailing,
  }) {
    final effectiveColor = enabled ? color : color.withValues(alpha: 0.3);
    return Material(
      color: Colors.black.withValues(alpha: 0.001),
      child: ListTile(
        enabled: enabled,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: effectiveColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: effectiveColor, size: 20),
        ),
        title: Text(
          label,
          style: TextStyle(color: effectiveColor, fontWeight: FontWeight.w500),
        ),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }

  Future<void> _launchSongVideo(SavedSong song) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    GlassUtils.showGlassDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: Colors.redAccent),
      ),
    );

    // 1. PRIORITY: Check for local downloaded or exported video
    if (song.localPath != null && song.localPath!.trim().isNotEmpty) {
      final localFilePath = song.localPath!.trim();
      File localFile = File(localFilePath);

      // Handle URL-encoded paths if needed
      if (!localFile.existsSync() && localFilePath.contains('%')) {
        try {
          final decoded = Uri.decodeFull(localFilePath);
          final decodedFile = File(decoded);
          if (decodedFile.existsSync()) {
            localFile = decodedFile;
          }
        } catch (_) {}
      }

      if (localFile.existsSync()) {
        final lowerPath = localFile.path.toLowerCase();
        // Check if the file is known to be pure audio (mp3, aac, flac, wav, ogg, etc.)
        final bool isPureAudioFormat = lowerPath.endsWith('.mp3') ||
            lowerPath.endsWith('.aac') ||
            lowerPath.endsWith('.flac') ||
            lowerPath.endsWith('.wav') ||
            lowerPath.endsWith('.ogg') ||
            lowerPath.endsWith('.opus');

        if (!isPureAudioFormat) {
          File? videoFileToPlay;
          File? tempFileToDelete;
          VideoPlayerController? localController;

          try {
            final bool isEncrypted = lowerPath.contains('_secure') ||
                lowerPath.endsWith('.mst') ||
                lowerPath.contains('offline_music');

            if (isEncrypted) {
              final decrypted = await EncryptionService()
                  .decryptToTempFile(localFile.path, targetExtension: '.mp4')
                  .timeout(const Duration(seconds: 4));
              if (decrypted.existsSync() && decrypted.lengthSync() > 0) {
                videoFileToPlay = decrypted;
                tempFileToDelete = decrypted;
              }
            } else {
              videoFileToPlay = localFile;
            }

            if (videoFileToPlay != null) {
              localController = VideoPlayerController.file(videoFileToPlay);
              await localController.initialize().timeout(const Duration(seconds: 3));

              // Verify that the media actually contains a video stream
              if (localController.value.isInitialized &&
                  localController.value.size.width > 0 &&
                  localController.value.size.height > 0) {
                if (!mounted) {
                  localController.dispose();
                  tempFileToDelete?.delete().catchError((_) => tempFileToDelete!);
                  return;
                }

                // Dismiss loading spinner dialog
                Navigator.of(context, rootNavigator: true).pop();

                // Pause background radio audio playback
                provider.pause();

                if (!mounted) return;
                GlassUtils.showGlassDialog(
                  context: context,
                  builder: (_) => LocalVideoPopup(
                    controller: localController!,
                    tempFileToDeleteOnDispose: tempFileToDelete,
                    songId: song.id,
                    songName: song.title,
                    artistName: song.artist,
                    albumName: song.album,
                    artworkUrl: song.artUri,
                    genre: song.genre,
                    releaseDate: song.releaseDate,
                  ),
                );
                return;
              } else {
                LogService().log(
                  "Local file for '${song.title}' has no video stream. Falling back to YouTube.",
                );
                await localController.dispose();
                localController = null;
                tempFileToDelete?.delete().catchError((_) => tempFileToDelete!);
              }
            }
          } catch (localErr) {
            LogService().log(
              "Local video playback attempt failed for '${song.title}': $localErr. Falling back to YouTube.",
            );
            if (localController != null) {
              try {
                await localController.dispose();
              } catch (_) {}
            }
            if (tempFileToDelete != null) {
              try {
                if (tempFileToDelete.existsSync()) {
                  tempFileToDelete.delete().catchError((_) => tempFileToDelete!);
                }
              } catch (_) {}
            }
          }
        }
      }
    }

    // 2. FALLBACK: Fast direct YouTube resolution for local and streaming songs
    try {
      String? url = song.youtubeUrl;

      // If no direct YouTube URL, search YouTube directly
      if (url == null || url.isEmpty) {
        url = await provider
            .searchYoutubeVideo(song.title, song.artist)
            .timeout(const Duration(seconds: 6));
      }

      // If still not found, try resolveLinks as deep fallback
      if (url == null || url.isEmpty) {
        try {
          final links = await provider
              .resolveLinks(
                title: song.title,
                artist: song.artist,
                youtubeUrl: song.youtubeUrl,
                appleMusicUrl: song.appleMusicUrl,
              )
              .timeout(const Duration(seconds: 4));
          url = links['youtube'];
        } catch (_) {}
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      if (url != null && url.isNotEmpty) {
        final videoId = YoutubePlayer.convertUrlToId(url);
        if (videoId != null) {
          provider.pause();
          if (!mounted) return;
          GlassUtils.showGlassDialog(
            context: context,
            builder: (_) => YouTubePopup(
              videoId: videoId,
              songId: song.id,
              songName: song.title,
              artistName: song.artist,
              albumName: song.album,
              artworkUrl: song.artUri,
              genre: song.genre,
              releaseDate: song.releaseDate,
            ),
          );
        } else {
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(lang.translate('youtube_link_not_found'))),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lang.translate('error_generic').replaceAll('{0}', e.toString()),
            ),
          ),
        );
      }
    }
  }

  void _showAddSongDialog(BuildContext context, RadioProvider provider) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddSongScreen()),
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: listItems.length,
        itemBuilder: (context, index) {
          final item = listItems[index];

          if (item is _AdItem) {
            return NativeAdWidget();
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: listItems.length,
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      itemBuilder: (context, index) {
        final item = listItems[index];

        if (item is _AdItem) {
          return NativeAdWidget();
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
        final confirmed = await GlassUtils.showGlassDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            surfaceTintColor: Colors.transparent,
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
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    Provider.of<LanguageProvider>(context, listen: false)
                        .translate('removed_album')
                        .replaceAll('{0}', groupSongs.first.album),
                    style: const TextStyle(color: Colors.white),
                  ),
                  action: SnackBarAction(
                    label: Provider.of<LanguageProvider>(context, listen: false)
                        .translate('undo'),
                    textColor: Theme.of(context).primaryColorLight,
                    onPressed: () {
                      provider.restoreSongsToPlaylist(
                        playlist.id,
                        groupSongs,
                        playlistName: playlist.name,
                      );
                    },
                  ),
                  duration: const Duration(seconds: 5),
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

    final lang = Provider.of<LanguageProvider>(context, listen: false);

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

    final isSyncing =
        song.artist == lang.translate('syncing_yt') ||
        song.artist == "SINC_METADATA";

    // A song is considered incomplete if any of these metadata fields is missing
    final bool hasIncompleteMetadata =
        (song.artUri == null || song.artUri!.isEmpty) ||
        song.title.trim().isEmpty ||
        song.artist.trim().isEmpty ||
        song.album.trim().isEmpty ||
        (song.genre == null || song.genre!.trim().isEmpty) ||
        song.duration == null ||
        (song.releaseDate == null || song.releaseDate!.trim().isEmpty);

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Container(
      margin: isGrouped ? EdgeInsets.zero : const EdgeInsets.only(bottom: 6),
      child: Material(
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
            ? Colors.black.withValues(
                alpha: 0.001,
              ) // nearly transparent, passes solid-material assertion
            : Theme.of(context).cardColor.withValues(alpha: 0.5),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.zero,
            border: isThisSongPlaying
                ? Border.all(
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.2),
                    width: 1.5,
                  )
                : null,
          ),
          child: Opacity(
            opacity: isSyncing ? 0.5 : 1.0,
            child: IgnorePointer(
              ignoring: isSyncing,
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
                      dense: true,
                      onTap: isSyncing
                          ? null
                          : isInvalid
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
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: 0,
                      ),
                      minVerticalPadding: 0, // Reduce vertical padding

                      contentPadding: isGrouped
                          ? const EdgeInsets.all(0)
                          : const EdgeInsets.only(
                              top: 0,
                              left: 0,
                              right: 0,
                              bottom: 0,
                            ),

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
                              child: _DoubleTapSpinnerWrapper(
                                onDoubleTap: () async {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        Provider.of<LanguageProvider>(
                                          context,
                                          listen: false,
                                        ).translate('fetching_metadata'),
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                  await provider.findMissingArtworks(
                                    playlistId: playlist.id,
                                    songIdToSync: song.id,
                                    explicitSong: song,
                                  );
                                },
                                onTap: () {
                                  var albumName = song.album.trim();
                                  // Clean song title: remove content in parentheses/brackets for better search
                                  var songTitle = song.title
                                      .replaceAll(
                                        RegExp(r'[\(\[].*?[\)\]]'),
                                        '',
                                      )
                                      .trim();

                                  // Filter artist name: keep only text before '•'
                                  var cleanArtist = song.artist
                                      .split('•')
                                      .first
                                      .trim();
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          TrendingDetailsScreen(
                                            albumName: albumName,
                                            artistName: cleanArtist,
                                            songName: songTitle,
                                            artworkUrl: song.artUri,
                                            originalSong: song,
                                          ),
                                    ),
                                  );
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Stack(
                                    children: [
                                      song.artUri != null
                                          ? Container(
                                              width: 55,
                                              height: 60,
                                              color: Colors.white.withValues(
                                                alpha: 0.0,
                                              ),
                                              child: CachedNetworkImage(
                                                imageUrl: song.artUri!,
                                                fit: BoxFit.fitHeight,
                                              errorWidget: (_, _, _) =>
                                                  Container(
                                                    width: 55,
                                                    height: 60,
                                                    color: Colors.grey[900],
                                                    child: Icon(
                                                      Icons.music_note,
                                                      color: contrastColor
                                                          .withValues(
                                                            alpha: 0.24,
                                                          ),
                                                    ),
                                                  ),
                                              ),
                                            )
                                          : song.artist == "SINC_METADATA"
                                          ? Container(
                                              width: 80,
                                              height: 80,
                                              color: Colors.grey[900],
                                              child: const Center(
                                                child: SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color:
                                                            Colors.blueAccent,
                                                      ),
                                                ),
                                              ),
                                            )
                                          : Container(
                                              width: 55,
                                              height: 80,
                                              color: Colors.grey[900],
                                              child: Icon(
                                                Icons.music_note,
                                                color: contrastColor.withValues(
                                                  alpha: 0.24,
                                                ),
                                              ),
                                            ),
                                      if (song.localPath != null &&
                                          song.localPath!.isNotEmpty &&
                                          File(song.localPath!).existsSync())
                                        Positioned(
                                          bottom: 1,
                                          right: 5,
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
                                                  ? Icons
                                                        .file_download_done_rounded
                                                  : Icons.folder_rounded,
                                              size: 12,
                                              color: song.isDownloaded
                                                  ? Colors.greenAccent
                                                  : Theme.of(context).primaryColor
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          title: Stack(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (song.artist == "SINC_METADATA")
                                      Row(
                                        children: [
                                          const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.blueAccent,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            lang.translate('fetching_metadata'),
                                            style: TextStyle(
                                              color: contrastColor.withValues(alpha: 0.6),
                                              fontSize: 14,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                        ],
                                      )
                                    else
                                      SizedBox(
                                        width: double.infinity,
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
                                      ),

                                    if (!isGrouped)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 2.0,
                                          right: 70,
                                        ),
                                        child: Text(
                                          song.artist == "SINC_METADATA"
                                              ? lang.translate('syncing_yt')
                                              : song.artist,
                                          style: TextStyle(
                                            color: contrastColor.withValues(alpha: 0.5),
                                            fontWeight: FontWeight.normal,
                                            fontSize: 13,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ) 
                                    else 
                                      SizedBox(height: 18),
                                    if (song.genre != null ||
                                        song.duration != null ||
                                        song.album.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 0.0),
                                        child: SizedBox(
                                          width: double.infinity,
                                          child: Row(
                                            children: [
                                              if (song.duration != null)
                                                Text(
                                                  "${song.duration!.inHours > 0 ? '${song.duration!.inHours}:' : ''}${song.duration!.inMinutes.remainder(60).toString().padLeft(song.duration!.inHours > 0 ? 2 : 1, '0')}:${song.duration!.inSeconds.remainder(60).toString().padLeft(2, '0')}",
                                                  style: TextStyle(
                                                    color:
                                                        contrastColor.withValues(alpha: 0.6),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),

                                              if (song.duration != null &&
                                                  song.album.isNotEmpty &&
                                                  !isGrouped)
                                                Text(
                                                  " • ",
                                                  style: TextStyle(
                                                    color:
                                                        contrastColor.withValues(alpha: 0.5),
                                                    fontSize: 12,
                                                  ),
                                                ),

                                              if (!isGrouped && song.album.isNotEmpty)
                                                Expanded(
                                                  flex: 4,
                                                  child: SizedBox(
                                                    height: 16,
                                                    child: PlayerBar.buildMarqueeText(
                                                      song.album,
                                                      TextStyle(
                                                        color:
                                                            contrastColor.withValues(alpha: 0.6),
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                ),

                                              if (song.genre != null &&
                                                  song.genre!.isNotEmpty)
                                                Text(
                                                  " • ",
                                                  style: TextStyle(
                                                    color:
                                                        contrastColor.withValues(alpha: 0.5),
                                                    fontSize: 12,
                                                  ),
                                                ),

                                              if (song.genre != null &&
                                                  song.genre!.isNotEmpty)
                                                Text(
                                                  song.genre ?? '',
                                                  textAlign: TextAlign.end,
                                                  style: TextStyle(
                                                    color:
                                                        contrastColor.withValues(alpha: 0.6),
                                                    fontSize: 12,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                              Positioned(
                                top: 0,
                                bottom: 0,
                                right: 0,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (playlist.id != 'favorites' &&
                                        !isInvalid &&
                                        !isSyncing) ...[
                                      GestureDetector(
                                        onTap: () async {
                                          if (isFavorite) {
                                            final favSongId = favPlaylist.songs
                                                .firstWhere(
                                                  (s) =>
                                                      s.id == song.id ||
                                                      (s.title == song.title &&
                                                          s.artist == song.artist),
                                                  orElse: () => song,
                                                )
                                                .id;

                                            await provider.removeFromPlaylist(
                                              'favorites',
                                              favSongId,
                                            );

                                            if (context.mounted) {
                                              ScaffoldMessenger.of(context)
                                                  .clearSnackBars();

                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    Provider.of<LanguageProvider>(
                                                      context,
                                                      listen: false,
                                                    ).translate(
                                                      'removed_from_favorites',
                                                    ),
                                                  ),
                                                  duration:
                                                      const Duration(seconds: 1),
                                                ),
                                              );
                                            }
                                          } else {
                                            if (playlist.creator == 'local') {
                                              isFavorite = true;

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
                                              ScaffoldMessenger.of(context)
                                                  .clearSnackBars();

                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    Provider.of<LanguageProvider>(
                                                      context,
                                                      listen: false,
                                                    ).translate(
                                                      'added_to_favorites',
                                                    ),
                                                  ),
                                                  duration:
                                                      const Duration(seconds: 1),
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

                                    if (!isInvalid &&
                                        !isSyncing) ...[
                                      IconButton(
                                        tooltip: lang.translate(
                                          'view_song_details',
                                        ),
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 32,
                                          minHeight: 32,
                                        ),
                                        iconSize: 20,
                                        icon: Icon(
                                          Icons.info_outline,
                                          color: hasIncompleteMetadata
                                              ? Theme.of(context).primaryColor
                                              : contrastColor.withValues(alpha: 0.7),
                                        ),
                                        onPressed: () => _showSongDetailsDialog(
                                          context,
                                          song,
                                          provider: provider,
                                          playlistId: playlist.id,
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          Icons.more_vert_rounded,
                                          color: contrastColor,
                                        ),
                                        onPressed: () => _showSongMenu(
                                          context,
                                          provider,
                                          playlist,
                                          song,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
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
                          left: 2,
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
            ),
          ),
        ),
      ),
    ),
      ],
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

    // If the song has incomplete metadata (same condition that shows the
    // corner triangle badge), silently fetch the missing data in the background.
    final bool hasIncompleteMetadata =
        (song.artUri == null || song.artUri!.isEmpty) ||
        song.title.trim().isEmpty ||
        song.artist.trim().isEmpty ||
        song.album.trim().isEmpty ||
        (song.genre == null || song.genre!.trim().isEmpty) ||
        song.duration == null ||
        (song.releaseDate == null || song.releaseDate!.trim().isEmpty);

    if (hasIncompleteMetadata) {
      provider.findMissingArtworks(
        playlistId: playlistId,
        songIdToSync: song.id,
        explicitSong: song,
      );
    }
  }

  void _showDeletePlaylistDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
  ) {
    if (playlist.id == 'favorites') return; // Cannot delete favorites
    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('delete_playlist_title'),
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('delete_playlist_desc').replaceAll('{0}', playlist.name),
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
            child: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('delete'),
              style: const TextStyle(color: Colors.redAccent),
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
    if (p.creator == 'local') {
      return Icon(
        Icons.folder_rounded,
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
                Provider.of<LanguageProvider>(
                  context,
                  listen: false,
                ).translate('copy_to_title'),
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
                        (p) => Material(
                          color: Colors.black.withValues(alpha: 0.001),
                          child: ListTile(
                            leading: SizedBox(
                              width: 24,
                              height: 24,
                              child: Center(
                                child: _buildDialogIcon(context, p),
                              ),
                            ),
                            title: Text(
                              p.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            onTap: () {
                              provider.copySong(
                                songId,
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
                                          .translate('copied_to')
                                          .replaceAll('{0}', p.name),
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
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

  Future<bool> _showMoveSongDialog(
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
            ).translate('no_other_playlists_to_move'),
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
                Provider.of<LanguageProvider>(
                  context,
                  listen: false,
                ).translate('move_to'),
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
                        (p) => Material(
                          color: Colors.black.withValues(alpha: 0.001),
                          child: ListTile(
                            leading: SizedBox(
                              width: 24,
                              height: 24,
                              child: Center(
                                child: _buildDialogIcon(context, p),
                              ),
                            ),
                            title: Text(
                              p.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            onTap: () {
                              provider.moveSong(
                                songId,
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
                                          .translate('moved_to')
                                          .replaceAll('{0}', p.name),
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
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
                        (p) => Material(
                          color: Colors.black.withValues(alpha: 0.001),
                          child: ListTile(
                            leading: SizedBox(
                              width: 24,
                              height: 24,
                              child: Center(
                                child: _buildDialogIcon(context, p),
                              ),
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
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    // 1. Filter Playlists by name
    final matchedPlaylists = allPlaylists
        .where((p) => p.name.toLowerCase().contains(_searchQuery))
        .toList();

    // 2. Find matches across the 3 categories
    final List<Map<String, dynamic>> matchedSongs = [];
    final List<SavedSong> matchedArtists = [];
    final List<SavedSong> matchedAlbums = [];
    final Set<String> seenSongIds = {}; // Prevent duplicates

    for (var p in allPlaylists) {
      for (var s in p.songs) {
        if (!seenSongIds.contains(s.id)) {
          seenSongIds.add(s.id);

          if (s.title.toLowerCase().contains(_searchQuery)) {
            matchedSongs.add({'playlist': p, 'song': s});
          }
          if (s.artist.toLowerCase().contains(_searchQuery)) {
            matchedArtists.add(s);
          }
          if (s.album.toLowerCase().contains(_searchQuery)) {
            matchedAlbums.add(s);
          }
        }
      }
    }

    if (matchedPlaylists.isEmpty &&
        matchedSongs.isEmpty &&
        matchedArtists.isEmpty &&
        matchedAlbums.isEmpty) {
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 60),
      children: [
        if (matchedSongs.isNotEmpty) ...[
          Text(
            lang.translate('tab_songs'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: matchedSongs.length,
            itemBuilder: (context, index) {
              final item = matchedSongs[index];
              final SavedSong song = item['song'];
              final Playlist playlist = item['playlist'];

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.zero,
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.5),
                  ),
                ),
                child: Material(
                  color: Colors.black.withValues(alpha: 0.001),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 0,
                    ),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.zero,
                      child: song.artUri != null
                          ? Container(
                              width: 72,
                              height: 72,
                              color: Colors.black,
                              child: CachedNetworkImage(
                                imageUrl: song.artUri!,
                                fit: BoxFit.contain,
                                errorWidget: (_, __, ___) => Container(
                                  width: 72,
                                  height: 72,
                                  color: Theme.of(context).cardColor,
                                  child: Icon(
                                    Icons.music_note,
                                    color: Theme.of(context).iconTheme.color?.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            )
                          : Container(
                              width: 72,
                              height: 72,
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
                            color: Theme.of(context).textTheme.bodyMedium?.color
                                ?.withValues(alpha: 0.7),
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
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
        if (matchedPlaylists.isNotEmpty) ...[
          Text(
            lang.translate('tab_playlists'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          _buildPlaylistsGrid(context, provider, matchedPlaylists),
          const SizedBox(height: 24),
        ],
        if (matchedArtists.isNotEmpty) ...[
          Text(
            lang.translate('tab_artists'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          _buildArtistsGrid(context, provider, matchedArtists, isSearch: true),
          const SizedBox(height: 24),
        ],
        if (matchedAlbums.isNotEmpty) ...[
          Text(
            lang.translate('tab_albums'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          _buildAlbumsGrid(context, provider, matchedAlbums, isSearch: true),
          const SizedBox(height: 24),
        ],
      ],
    );
  }

  String _dismissPairKey(String a, String b) {
    final pair = [a, b]..sort();
    return '${pair[0]}\u0001${pair[1]}';
  }

  Future<void> _loadDismissedMergePairs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_dismissedArtistMergesKey) ?? const [];
    if (!mounted) return;
    setState(() {
      _dismissedMergePairs.addAll(saved);
    });
  }

  Future<void> _loadDismissedAlbumMergePairs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_dismissedAlbumMergesKey) ?? const [];
    if (!mounted) return;
    setState(() {
      _dismissedAlbumMergePairs.addAll(saved);
    });
  }

  Future<void> _persistDismissedMerge(String source, String target) async {
    final key = _dismissPairKey(
      MergeUtils.artistGroupingKey(source),
      MergeUtils.artistGroupingKey(target),
    );
    _dismissedMergePairs.add(key);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_dismissedArtistMergesKey) ?? const [];
    final updated = {...saved, key}.toList();
    await prefs.setStringList(_dismissedArtistMergesKey, updated);
  }

  Future<void> _persistDismissedAlbumMerge(String source, String target) async {
    final key = _dismissPairKey(
      MergeUtils.albumGroupingKey(source),
      MergeUtils.albumGroupingKey(target),
    );
    _dismissedAlbumMergePairs.add(key);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_dismissedAlbumMergesKey) ?? const [];
    final updated = {...saved, key}.toList();
    await prefs.setStringList(_dismissedAlbumMergesKey, updated);
  }

  List<MergeSuggestion> _mergeSuggestions(
    List<SavedSong> songs, {
    bool isAlbum = false,
  }) {
    final grouping = isAlbum
        ? MergeUtils.albumGroupingKey
        : MergeUtils.artistGroupingKey;
    final dismissedSet =
        isAlbum ? _dismissedAlbumMergePairs : _dismissedMergePairs;
    final distinct =
        songs.map((s) => (isAlbum ? s.album : s.artist).trim())
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final List<String> artistDistinct;
    if (isAlbum) {
      artistDistinct = songs
          .map((s) => s.artist.trim())
          .where((a) => a.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
    } else {
      artistDistinct = const <String>[];
    }
    final dismissedKey = (dismissedSet.toList()..sort()).join(';');
    final key =
        '${isAlbum ? 'album:' : 'artist:'}${distinct.join('\u0001')}'
        '|${artistDistinct.join('\u0001')}|$dismissedKey';

    if (isAlbum) {
      if (key == _albumMergeCacheKey && _cachedAlbumMergeSuggestions != null) {
        return _cachedAlbumMergeSuggestions!;
      }
      if (!_isCalculatingAlbumMerges) {
        _isCalculatingAlbumMerges = true;
        Future.microtask(() {
          final suggestions = MergeUtils.findMergeSuggestions(
            songs.map((s) => s.album),
            groupingKey: grouping,
            companions: songs.map((s) => s.artist),
            companionWeight: 0.35,
          )
              .where((s) {
            final pairKey = _dismissPairKey(
              grouping(s.source),
              grouping(s.target),
            );
            return !dismissedSet.contains(pairKey);
          })
              .toList();
          if (mounted) {
            setState(() {
              _cachedAlbumMergeSuggestions = suggestions;
              _albumMergeCacheKey = key;
              _isCalculatingAlbumMerges = false;
            });
          }
        });
      }
      return _cachedAlbumMergeSuggestions ?? const <MergeSuggestion>[];
    } else {
      if (key == _artistMergeCacheKey && _cachedArtistMergeSuggestions != null) {
        return _cachedArtistMergeSuggestions!;
      }
      if (!_isCalculatingArtistMerges) {
        _isCalculatingArtistMerges = true;
        Future.microtask(() {
          final suggestions = MergeUtils.findMergeSuggestions(
            songs.map((s) => s.artist),
            groupingKey: grouping,
            companions: null,
            companionWeight: 0.0,
          )
              .where((s) {
            final pairKey = _dismissPairKey(
              grouping(s.source),
              grouping(s.target),
            );
            return !dismissedSet.contains(pairKey);
          })
              .toList();
          if (mounted) {
            setState(() {
              _cachedArtistMergeSuggestions = suggestions;
              _artistMergeCacheKey = key;
              _isCalculatingArtistMerges = false;
            });
          }
        });
      }
      return _cachedArtistMergeSuggestions ?? const <MergeSuggestion>[];
    }
  }

  Widget _buildMergeBanner(
    BuildContext context,
    RadioProvider provider,
    List<SavedSong> allSongs, {
    bool isAlbum = false,
  }) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    final suggestions = _mergeSuggestions(allSongs, isAlbum: isAlbum);
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final prefix = isAlbum ? 'album' : 'artist';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: Theme.of(context).primaryColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _showMergeDialog(
            context,
            provider,
            suggestions,
            lang,
            isAlbum: isAlbum,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.merge_type_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lang
                            .translate('${prefix}_merge_banner')
                            .replaceAll('{0}', suggestions.length.toString()),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lang.translate('${prefix}_merge_banner_desc'),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.keyboard_arrow_right_rounded,
                  color: Colors.white54,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMergeDialog(
    BuildContext context,
    RadioProvider provider,
    List<MergeSuggestion> suggestions,
    LanguageProvider lang, {
    bool isAlbum = false,
  }) {
    final prefix = isAlbum ? 'album' : 'artist';
    final grouping = isAlbum
        ? MergeUtils.albumGroupingKey
        : MergeUtils.artistGroupingKey;
    String tr(String suffix) => lang.translate('${prefix}_merge_$suffix');
    String withArtist(String name, String? artist) {
      if (isAlbum && artist != null && artist.trim().isNotEmpty) {
        return '$name — $artist';
      }
      return name;
    }

    // Pre-calculate sample tracks for quick context
    final Map<String, List<String>> sampleTracksBySource = {};
    final Map<String, List<String>> sampleTracksByTarget = {};
    for (var s in suggestions) {
      if (isAlbum) {
        sampleTracksBySource[s.source] = _allSongs
            .where((song) =>
                song.album.trim().toLowerCase() ==
                s.source.trim().toLowerCase())
            .map((song) => song.title)
            .where((t) => t.isNotEmpty)
            .toSet()
            .take(2)
            .toList();
        sampleTracksByTarget[s.target] = _allSongs
            .where((song) =>
                song.album.trim().toLowerCase() ==
                s.target.trim().toLowerCase())
            .map((song) => song.title)
            .where((t) => t.isNotEmpty)
            .toSet()
            .take(2)
            .toList();
      } else {
        sampleTracksBySource[s.source] = _allSongs
            .where((song) =>
                song.artist.trim().toLowerCase() ==
                s.source.trim().toLowerCase())
            .map((song) => song.title)
            .where((t) => t.isNotEmpty)
            .toSet()
            .take(2)
            .toList();
        sampleTracksByTarget[s.target] = _allSongs
            .where((song) =>
                song.artist.trim().toLowerCase() ==
                s.target.trim().toLowerCase())
            .map((song) => song.title)
            .where((t) => t.isNotEmpty)
            .toSet()
            .take(2)
            .toList();
      }
    }

    final Map<MergeSuggestion, int> directionByIndex = {};
    final Set<MergeSuggestion> selected = Set.of(suggestions);
    final Set<String> neverShowAgainPairKeys = {};

    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, dialogSetState) {
            return AlertDialog(
              surfaceTintColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 24),
              title: Row(
                children: [
                  Icon(
                    isAlbum ? Icons.album_rounded : Icons.person_rounded,
                    color: Theme.of(context).primaryColor,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr('title'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.75,
                  maxWidth: MediaQuery.of(context).size.width,
                ),
                width: MediaQuery.of(context).size.width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr('desc'),
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      lang.translate('never_ask_again_song_desc'),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (neverShowAgainPairKeys.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color:
                                    Colors.redAccent.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Text(
                              '${neverShowAgainPairKeys.length} ${lang.translate('never_ask_badge')}',
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        else
                          const SizedBox.shrink(),
                        Builder(
                          builder: (context) {
                            final availableSuggestions = suggestions.where(
                              (s) => !neverShowAgainPairKeys.contains(
                                _dismissPairKey(
                                  grouping(s.source),
                                  grouping(s.target),
                                ),
                              ),
                            );
                            final bool isAllSelected =
                                availableSuggestions.isNotEmpty &&
                                availableSuggestions
                                    .every((s) => selected.contains(s));
                            return TextButton(
                              onPressed: () {
                                dialogSetState(() {
                                  if (isAllSelected) {
                                    selected.clear();
                                  } else {
                                    for (var s in availableSuggestions) {
                                      selected.add(s);
                                    }
                                  }
                                });
                              },
                              child: Text(
                                isAllSelected
                                    ? lang.translate('deselect_all')
                                    : lang.translate('select_all'),
                                style: const TextStyle(
                                  color: Colors.blueAccent,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12),
                    Expanded(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: suggestions.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final s = suggestions[index];
                          final pairKey = _dismissPairKey(
                            grouping(s.source),
                            grouping(s.target),
                          );
                          final isNeverShowAgain =
                              neverShowAgainPairKeys.contains(pairKey);
                          final isSelected =
                              selected.contains(s) && !isNeverShowAgain;
                          final int direction = directionByIndex[s] ?? 0;
                          final sampleSourceTracks =
                              sampleTracksBySource[s.source] ?? const [];
                          final sampleTargetTracks =
                              sampleTracksByTarget[s.target] ?? const [];

                          return Container(
                            decoration: BoxDecoration(
                              color: isNeverShowAgain
                                  ? Colors.redAccent.withValues(alpha: 0.08)
                                  : (isSelected
                                      ? Theme.of(context)
                                          .primaryColor
                                          .withValues(alpha: 0.16)
                                      : Colors.white.withValues(alpha: 0.04)),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isNeverShowAgain
                                    ? Colors.redAccent.withValues(alpha: 0.4)
                                    : (isSelected
                                        ? Theme.of(context)
                                            .primaryColor
                                            .withValues(alpha: 0.5)
                                        : Colors.white.withValues(alpha: 0.09)),
                                width: isSelected ? 1.4 : 1.0,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Leading Checkbox (aligned to top)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Checkbox(
                                      value: isSelected,
                                      activeColor:
                                          Theme.of(context).primaryColor,
                                      checkColor: Colors.white,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                      onChanged: isNeverShowAgain
                                          ? null
                                          : (val) {
                                              dialogSetState(() {
                                                if (val == true) {
                                                  selected.add(s);
                                                } else {
                                                  selected.remove(s);
                                                }
                                              });
                                            },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  // Central Expanded Content
                                  Expanded(
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      onTap: isNeverShowAgain
                                          ? null
                                          : () {
                                              dialogSetState(() {
                                                if (isSelected) {
                                                  selected.remove(s);
                                                } else {
                                                  selected.add(s);
                                                }
                                              });
                                            },
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // 1. SOURCE VARIANT (Variante 1)
                                          Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 5,
                                                  vertical: 1.5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.blueAccent
                                                      .withValues(alpha: 0.18),
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                  border: Border.all(
                                                    color: Colors.blueAccent
                                                        .withValues(
                                                      alpha: 0.35,
                                                    ),
                                                    width: 0.8,
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      isAlbum
                                                          ? Icons.album_outlined
                                                          : Icons.person_outline,
                                                      size: 10,
                                                      color: Colors.blueAccent,
                                                    ),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      isAlbum
                                                          ? 'Album (A)'
                                                          : 'Artista (A)',
                                                      style: const TextStyle(
                                                        color: Colors.blueAccent,
                                                        fontSize: 9,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              // Track count badge
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 5,
                                                  vertical: 1.5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.08),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const Icon(
                                                      Icons.music_note_rounded,
                                                      size: 9,
                                                      color: Colors.white70,
                                                    ),
                                                    const SizedBox(width: 2),
                                                    Text(
                                                      '${s.sourceCount} ${lang.translate('song_singular')}${s.sourceCount > 1 ? 'i' : ''}',
                                                      style: const TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 9.5,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (isNeverShowAgain) ...[
                                                const SizedBox(width: 6),
                                                Text(
                                                  '(${lang.translate('never_ask_badge')})',
                                                  style: const TextStyle(
                                                    color: Colors.redAccent,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          // Source Name
                                          Text(
                                            withArtist(
                                              s.source,
                                              s.sourceArtist,
                                            ),
                                            style: TextStyle(
                                              color: isNeverShowAgain
                                                  ? Colors.white38
                                                  : Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              decoration: isNeverShowAgain
                                                  ? TextDecoration.lineThrough
                                                  : null,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          // Sample tracks from source
                                          if (sampleSourceTracks
                                              .isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              '${lang.translate('sample_tracks_label')} "${sampleSourceTracks.join('", "')}"',
                                              style: TextStyle(
                                                color: isNeverShowAgain
                                                    ? Colors.white24
                                                    : Colors.white60,
                                                fontSize: 10.5,
                                                fontStyle: FontStyle.italic,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],

                                          // 2. CONNECTOR ROW (Divider + Similarity Badge + Arrow)
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 6,
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Divider(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.1),
                                                    height: 1,
                                                    thickness: 0.8,
                                                  ),
                                                ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                  ),
                                                  child: Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: Theme.of(context)
                                                          .primaryColor
                                                          .withValues(
                                                            alpha: 0.2,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        10,
                                                      ),
                                                      border: Border.all(
                                                        color: Theme.of(context)
                                                            .primaryColor
                                                            .withValues(
                                                              alpha: 0.4,
                                                            ),
                                                        width: 0.8,
                                                      ),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          Icons.merge_type_rounded,
                                                          size: 10,
                                                          color: Theme.of(context)
                                                              .primaryColor,
                                                        ),
                                                        const SizedBox(width: 3),
                                                        Text(
                                                          '${s.similarity.round()}% similarità',
                                                          style: TextStyle(
                                                            color:
                                                                Theme.of(context)
                                                                    .primaryColor,
                                                            fontSize: 9.5,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Divider(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.1),
                                                    height: 1,
                                                    thickness: 0.8,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                          // 3. TARGET VARIANT (Variante 2 - Card scura)
                                          Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.28,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              border: Border.all(
                                                color: isNeverShowAgain
                                                    ? Colors.white.withValues(
                                                        alpha: 0.05,
                                                      )
                                                    : Colors.tealAccent
                                                        .withValues(alpha: 0.2),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                // Header: Icon + Type + Song count
                                                Row(
                                                  children: [
                                                    Icon(
                                                      isAlbum
                                                          ? Icons.album_rounded
                                                          : Icons.person_rounded,
                                                      size: 12,
                                                      color: isNeverShowAgain
                                                          ? Colors.white30
                                                          : Colors.tealAccent,
                                                    ),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      isAlbum
                                                          ? 'Album (B)'
                                                          : 'Artista (B)',
                                                      style: TextStyle(
                                                        color: isNeverShowAgain
                                                            ? Colors.white30
                                                            : Colors.tealAccent,
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                    const Spacer(),
                                                    Container(
                                                      padding:
                                                          const EdgeInsets
                                                              .symmetric(
                                                        horizontal: 5,
                                                        vertical: 1.5,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: Colors.white
                                                            .withValues(
                                                          alpha: 0.08,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(4),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          const Icon(
                                                            Icons
                                                                .music_note_rounded,
                                                            size: 9,
                                                            color:
                                                                Colors.white70,
                                                          ),
                                                          const SizedBox(width: 2),
                                                          Text(
                                                            '${s.targetCount} ${lang.translate('song_singular')}${s.targetCount > 1 ? 'i' : ''}',
                                                            style:
                                                                const TextStyle(
                                                              color:
                                                                  Colors.white70,
                                                              fontSize: 9.5,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  withArtist(
                                                    s.target,
                                                    s.targetArtist,
                                                  ),
                                                  style: TextStyle(
                                                    color: isNeverShowAgain
                                                        ? Colors.white38
                                                        : Colors.white,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                if (sampleTargetTracks
                                                    .isNotEmpty) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    '${lang.translate('sample_tracks_label')} "${sampleTargetTracks.join('", "')}"',
                                                    style: TextStyle(
                                                      color: isNeverShowAgain
                                                          ? Colors.white24
                                                          : Colors.white60,
                                                      fontSize: 10.5,
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),

                                          // 4. INTERACTIVE VISUAL DIRECTION SELECTOR (Sistema visuale compatto a icone)
                                          if (isSelected) ...[
                                            const SizedBox(height: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 7,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(alpha: 0.35),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: Colors.white.withValues(alpha: 0.12),
                                                  width: 0.8,
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Row(
                                                    children: [
                                                      const Icon(
                                                        Icons.drive_file_rename_outline_rounded,
                                                        size: 13,
                                                        color: Colors.white60,
                                                      ),
                                                      const SizedBox(width: 5),
                                                      Expanded(
                                                        child: Text(
                                                          lang.translate('keep_final_name'),
                                                          style: const TextStyle(
                                                            color: Colors.white70,
                                                            fontSize: 10.5,
                                                            fontWeight: FontWeight.w600,
                                                            letterSpacing: 0.2,
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 7),
                                                  Row(
                                                    children: [
                                                      // Opzione A (Variante A - Blu)
                                                      Expanded(
                                                        child: InkWell(
                                                          borderRadius: BorderRadius.circular(8),
                                                          onTap: () {
                                                            dialogSetState(() {
                                                              directionByIndex[s] = 1;
                                                            });
                                                          },
                                                          child: AnimatedContainer(
                                                            duration: const Duration(milliseconds: 150),
                                                            padding: const EdgeInsets.symmetric(
                                                              vertical: 7,
                                                              horizontal: 8,
                                                            ),
                                                            decoration: BoxDecoration(
                                                              color: direction == 1
                                                                  ? Colors.blueAccent.withValues(alpha: 0.22)
                                                                  : Colors.white.withValues(alpha: 0.04),
                                                              borderRadius: BorderRadius.circular(8),
                                                              border: Border.all(
                                                                  color: direction == 1
                                                                      ? Colors.blueAccent
                                                                      : Colors.white.withValues(alpha: 0.12),
                                                                width: direction == 1 ? 1.5 : 1.0,
                                                              ),
                                                            ),
                                                            child: Row(
                                                              mainAxisAlignment: MainAxisAlignment.center,
                                                              children: [
                                                                Icon(
                                                                  direction == 1
                                                                      ? Icons.check_circle_rounded
                                                                      : Icons.radio_button_unchecked,
                                                                  size: 14,
                                                                  color: direction == 1
                                                                      ? Colors.blueAccent
                                                                      : Colors.white38,
                                                                ),
                                                                const SizedBox(width: 5),
                                                                Flexible(
                                                                  child: Text(
                                                                    isAlbum ? 'Album (A)' : 'Artista (A)',
                                                                    style: TextStyle(
                                                                      color: direction == 1
                                                                          ? Colors.blueAccent
                                                                          : Colors.white60,
                                                                      fontSize: 11,
                                                                      fontWeight: direction == 1
                                                                          ? FontWeight.bold
                                                                          : FontWeight.w500,
                                                                    ),
                                                                    maxLines: 1,
                                                                    overflow: TextOverflow.ellipsis,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      // Freccia di direzione interattiva / indicatore visivo di merge
                                                      Padding(
                                                        padding: const EdgeInsets.symmetric(horizontal: 6),
                                                        child: InkWell(
                                                          borderRadius: BorderRadius.circular(16),
                                                          onTap: () {
                                                            dialogSetState(() {
                                                              directionByIndex[s] = direction == 0 ? 1 : 0;
                                                            });
                                                          },
                                                          child: Container(
                                                            padding: const EdgeInsets.all(6),
                                                            decoration: BoxDecoration(
                                                              color: direction == 0
                                                                  ? Colors.tealAccent.withValues(alpha: 0.15)
                                                                  : Colors.blueAccent.withValues(alpha: 0.15),
                                                              shape: BoxShape.circle,
                                                              border: Border.all(
                                                                color: direction == 0
                                                                    ? Colors.tealAccent.withValues(alpha: 0.5)
                                                                    : Colors.blueAccent.withValues(alpha: 0.5),
                                                                width: 0.8,
                                                              ),
                                                            ),
                                                            child: Icon(
                                                              direction == 0
                                                                  ? Icons.arrow_forward_rounded
                                                                  : Icons.arrow_back_rounded,
                                                              size: 14,
                                                              color: direction == 0
                                                                  ? Colors.tealAccent
                                                                  : Colors.blueAccent,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      // Opzione B (Variante B - Teal)
                                                      Expanded(
                                                        child: InkWell(
                                                          borderRadius: BorderRadius.circular(8),
                                                          onTap: () {
                                                            dialogSetState(() {
                                                              directionByIndex[s] = 0;
                                                            });
                                                          },
                                                          child: AnimatedContainer(
                                                            duration: const Duration(milliseconds: 150),
                                                            padding: const EdgeInsets.symmetric(
                                                              vertical: 7,
                                                              horizontal: 8,
                                                            ),
                                                            decoration: BoxDecoration(
                                                              color: direction == 0
                                                                  ? Colors.tealAccent.withValues(alpha: 0.22)
                                                                  : Colors.white.withValues(alpha: 0.04),
                                                              borderRadius: BorderRadius.circular(8),
                                                              border: Border.all(
                                                                color: direction == 0
                                                                    ? Colors.tealAccent
                                                                    : Colors.white.withValues(alpha: 0.12),
                                                                width: direction == 0 ? 1.5 : 1.0,
                                                              ),
                                                            ),
                                                            child: Row(
                                                              mainAxisAlignment: MainAxisAlignment.center,
                                                              children: [
                                                                Icon(
                                                                  direction == 0
                                                                      ? Icons.check_circle_rounded
                                                                      : Icons.radio_button_unchecked,
                                                                  size: 14,
                                                                  color: direction == 0
                                                                      ? Colors.tealAccent
                                                                      : Colors.white38,
                                                                ),
                                                                const SizedBox(width: 5),
                                                                Flexible(
                                                                  child: Text(
                                                                    isAlbum ? 'Album (B)' : 'Artista (B)',
                                                                    style: TextStyle(
                                                                      color: direction == 0
                                                                          ? Colors.tealAccent
                                                                          : Colors.white60,
                                                                      fontSize: 11,
                                                                      fontWeight: direction == 0
                                                                          ? FontWeight.bold
                                                                          : FontWeight.w500,
                                                                    ),
                                                                    maxLines: 1,
                                                                    overflow: TextOverflow.ellipsis,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  // Trailing visibility_off button
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: IconButton(
                                      tooltip: isNeverShowAgain
                                          ? lang.translate('cancel')
                                          : lang.translate(
                                              'never_ask_again_song',
                                            ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 34,
                                        minHeight: 34,
                                      ),
                                      icon: Icon(
                                        isNeverShowAgain
                                            ? Icons.visibility_off_rounded
                                            : Icons.visibility_off_outlined,
                                        color: isNeverShowAgain
                                            ? Colors.redAccent
                                            : Colors.white38,
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        dialogSetState(() {
                                          if (isNeverShowAgain) {
                                            neverShowAgainPairKeys
                                                .remove(pairKey);
                                            selected.add(s);
                                          } else {
                                            neverShowAgainPairKeys
                                                .add(pairKey);
                                            selected.remove(s);
                                          }
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actionsAlignment: (neverShowAgainPairKeys.isNotEmpty || selected.isNotEmpty)
                  ? MainAxisAlignment.spaceBetween
                  : MainAxisAlignment.end,
              actions: [
                if (neverShowAgainPairKeys.isNotEmpty)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    icon: const Icon(Icons.visibility_off_rounded, size: 16),
                    label: Text(
                      lang.translate('confirm'),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: () async {
                      for (final s in suggestions) {
                        final pairKey = _dismissPairKey(
                          grouping(s.source),
                          grouping(s.target),
                        );
                        if (neverShowAgainPairKeys.contains(pairKey)) {
                          if (isAlbum) {
                            _dismissedAlbumMergePairs.add(pairKey);
                            await _persistDismissedAlbumMerge(
                              s.source,
                              s.target,
                            );
                          } else {
                            _dismissedMergePairs.add(pairKey);
                            await _persistDismissedMerge(s.source, s.target);
                          }
                        }
                      }
                      if (isAlbum) {
                        _cachedAlbumMergeSuggestions = _cachedAlbumMergeSuggestions
                            ?.where((s) {
                          final pairKey = _dismissPairKey(
                            grouping(s.source),
                            grouping(s.target),
                          );
                          return !neverShowAgainPairKeys.contains(pairKey);
                        }).toList();
                        _albumMergeCacheKey = '';
                      } else {
                        _cachedArtistMergeSuggestions = _cachedArtistMergeSuggestions
                            ?.where((s) {
                          final pairKey = _dismissPairKey(
                            grouping(s.source),
                            grouping(s.target),
                          );
                          return !neverShowAgainPairKeys.contains(pairKey);
                        }).toList();
                        _artistMergeCacheKey = '';
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        setState(() {});
                        _showSnack(
                          lang.translate('never_ask_saved').replaceAll(
                            '{0}',
                            neverShowAgainPairKeys.length.toString(),
                          ),
                          Colors.orangeAccent,
                        );
                      }
                    },
                  )
                else if (selected.isNotEmpty)
                  ElevatedButton(
                    onPressed: () async {
                      var total = 0;
                      for (final s in suggestions) {
                        if (!selected.contains(s)) continue;
                        final dir = directionByIndex[s] ?? 0;
                        final source = dir == 0 ? s.source : s.target;
                        final target = dir == 0 ? s.target : s.source;
                        total += isAlbum
                            ? await provider.mergeAlbum(source, target)
                            : await provider.mergeArtist(source, target);
                      }
                      if (isAlbum) {
                        _cachedAlbumMergeSuggestions = null;
                        _albumMergeCacheKey = '';
                      } else {
                        _cachedArtistMergeSuggestions = null;
                        _artistMergeCacheKey = '';
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        setState(() {});
                        _showSnack(
                          tr('done').replaceAll('{0}', total.toString()),
                          Colors.green,
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    child: Text(
                      lang.translate('merge_action'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                  },
                  child: Text(lang.translate('cancel')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showSnack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: color,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Widget _buildArtistsGrid(
    BuildContext context,
    RadioProvider provider,
    List<SavedSong> allSongs, {
    bool isSearch = false,
  }) {
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
        if (!isSearch && playingIndex != -1) {
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
                  final double safeMax = maxScroll > 0
                      ? maxScroll
                      : (centeredOffset > 0 ? centeredOffset : 0.0);
                  final double targetOffset = centeredOffset.clamp(
                    0.0,
                    safeMax,
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
          shrinkWrap: isSearch,
          physics: isSearch
              ? const NeverScrollableScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          controller: isSearch ? null : _artistsScrollController,
          key: isSearch ? null : const PageStorageKey('artists_grid'),
          padding: isSearch
              ? EdgeInsets.zero
              : const EdgeInsets.fromLTRB(16, 0, 16, 80),
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
                  _showOnlyInvalid = false;
                  _showOnlyLocal = false;

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
    List<SavedSong> allSongs, {
    bool isSearch = false,
  }) {
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
        if (!isSearch && playingIndex != -1) {
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
                  final double safeMax = maxScroll > 0
                      ? maxScroll
                      : (centeredOffset > 0 ? centeredOffset : 0.0);
                  final double targetOffset = centeredOffset.clamp(
                    0.0,
                    safeMax,
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
          shrinkWrap: isSearch,
          physics: isSearch
              ? const NeverScrollableScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          controller: isSearch ? null : _albumsScrollController,
          key: isSearch ? null : const PageStorageKey('albums_grid'),
          padding: isSearch
              ? EdgeInsets.zero
              : const EdgeInsets.fromLTRB(16, 0, 16, 80),
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
                  _showOnlyInvalid = false;
                  _showOnlyLocal = false;

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
                          ? Container(
                              color: Colors.black,
                              child: CachedNetworkImage(
                                  imageUrl: displaySong.artUri!,
                                  fit: BoxFit.contain,
                              errorWidget: (_, __, ___) => Container(
                                color: Colors.white10,
                                child: const Icon(
                                  Icons.album,
                                  color: Colors.white24,
                                ),
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

  void _showSharePlaylistDialog(
    BuildContext context,
    RadioProvider provider,
    Playlist playlist,
  ) {
    // Start background preparation
    provider.startQRPreparation(playlist, (deepLink) {
      if (!context.mounted) return;

      // AUTO-SHOW the dialog when ready!
      _showFinalQRDialog(context, playlist, deepLink);

      // Optional SnackBar confirmation
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('playlist_ready_share'),
          ),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  void _showFinalQRDialog(
    BuildContext context,
    Playlist playlist,
    String deepLink,
  ) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    final provider = Provider.of<RadioProvider>(context, listen: false);

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    GlassUtils.showGlassDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16),
        backgroundColor: const Color(0xFF1a1a2e),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: double.maxFinite,
          constraints: BoxConstraints(
            maxWidth: 500,
            minWidth: MediaQuery.of(context).size.width * 0.9,
          ),
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "${lang.translate('share')} ${lang.translate('playlist')}",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                playlist.name,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 16,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                lang
                    .translate('songs_count')
                    .replaceAll('{0}', playlist.songs.length.toString()),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (deepLink.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Colors.redAccent,
                        size: 48,
                      ),
                      SizedBox(height: 16),
                      Text(
                        lang.translate('no_yt_songs_found'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: deepLink,
                    version: QrVersions.auto,
                    size: MediaQuery.of(context).size.width - 96,
                    gapless: false,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                  ),
                ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      lang.translate('cancel'),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  _buildShareIconBtn(
                    context: context,
                    icon: Icons.copy,
                    label: lang.translate('copy'),
                    color: Colors.blueAccent,
                    onPressed: deepLink.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: deepLink));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(lang.translate('link_copied')),
                              ),
                            );
                          },
                  ),
                  _buildShareIconBtn(
                    context: context,
                    icon: Icons.share,
                    label: lang.translate('share'),
                    color: Colors.orangeAccent,
                    onPressed: deepLink.isEmpty
                        ? null
                        : () {
                            provider.sharePlaylistText(playlist, deepLink);
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });
  }

  void _showFinalSongQRDialog(
    BuildContext context,
    SavedSong song,
    String deepLink,
    String shareText,
  ) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    GlassUtils.showGlassDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16),
        backgroundColor: const Color(0xFF1a1a2e),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: double.maxFinite,
          constraints: BoxConstraints(
            maxWidth: 500,
            minWidth: MediaQuery.of(context).size.width * 0.9,
          ),
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                lang.translate('share_song'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "${song.title} - ${song.artist}",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 16,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 24),
              if (deepLink.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.redAccent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.redAccent,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        lang.translate('no_yt_songs_found'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: deepLink,
                    version: QrVersions.auto,
                    size: MediaQuery.of(context).size.width - 96,
                    gapless: false,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                  ),
                ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      lang.translate('cancel'),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  _buildShareIconBtn(
                    context: context,
                    icon: Icons.copy,
                    label: lang.translate('copy'),
                    color: Colors.blueAccent,
                    onPressed: deepLink.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: deepLink));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(lang.translate('link_copied')),
                              ),
                            );
                          },
                  ),
                  _buildShareIconBtn(
                    context: context,
                    icon: Icons.share,
                    label: lang.translate('share'),
                    color: Colors.orangeAccent,
                    onPressed: deepLink.isEmpty
                        ? null
                        : () {
                            SharePlus.instance.share(
                              ShareParams(text: shareText),
                            );
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });
  }

  // Helper for consistent small QR dialog action buttons
  Widget _buildShareIconBtn({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onPressed,
          icon: Icon(icon, color: color, size: 24),
          style: IconButton.styleFrom(
            backgroundColor: color.withValues(alpha: 0.1),
            padding: const EdgeInsets.all(12),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: color, fontSize: 10)),
      ],
    );
  }

  Widget _buildHeaderActionButton(String actionId, Color color) {
    IconData? icon;
    final provider = Provider.of<RadioProvider>(context, listen: false);

    switch (actionId) {
      case 'play_all':
        icon = Icons.playlist_play_rounded;
        break;
      case 'download':
        final dLimit = Provider.of<EntitlementService>(
          context,
          listen: false,
        ).getFeatureLimit('download_songs');
        if (isSelectionActive &&
            (effectivePlaylist == null ||
                effectivePlaylist!.id == 'favorites' ||
                effectivePlaylist!.creator != 'local') &&
            (dLimit != 0 || dLimit == -99)) {
          icon = Icons.download_rounded;
        }
        break;
      case 'share_playlist':
        if (effectivePlaylist != null &&
            effectivePlaylist!.creator != 'local') {
          icon = Icons.share_rounded;
        }
        break;
      case 'shuffle':
        icon = Icons.shuffle_rounded;
        color = provider.isShuffleMode ? Theme.of(context).primaryColor : color;
        break;
      case 'sort':
        icon = Icons.sort_by_alpha;
        color = _sortAlphabetical ? Theme.of(context).primaryColor : color;
        break;
      case 'search':
        icon = Icons.search;
        color = _showPlaylistSearch ? Theme.of(context).primaryColor : color;
        break;
      case 'duplicates':
        if (_selectedPlaylistId != null) icon = Icons.cleaning_services_rounded;
        break;
      case 'bulk_check':
        if (hasInvalidSongs || _showOnlyInvalid) {
          if (_isBulkChecking)
            return const SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          icon = Icons.playlist_add_check_circle_rounded;
        }
        break;
      case 'search_add_song':
        icon = Icons.library_music_rounded;
        break;
      case 'create_playlist':
        if (_viewMode == MetadataViewMode.playlists) icon = Icons.add_rounded;
        break;
      case 'scan_qr':
        if (_viewMode == MetadataViewMode.playlists)
          icon = Icons.qr_code_scanner_rounded;
        break;
      case 'sort_mode':
        if (_viewMode == MetadataViewMode.playlists)
          icon = _sortMode == PlaylistSortMode.custom
              ? Icons.sort
              : Icons.sort_by_alpha;
        break;
      case 'toggle_artists':
        if (_viewMode == MetadataViewMode.artists)
          icon = _showFollowedArtistsOnly
              ? Icons.how_to_reg
              : Icons.person_add_alt;
        break;
      case 'toggle_albums':
        if (_viewMode == MetadataViewMode.albums)
          icon = _showFollowedAlbumsOnly
              ? Icons.bookmark
              : Icons.bookmark_border;
        break;
      case 'toggle_local':
        if (hasLocalSongs || _showOnlyLocal) icon = Icons.smartphone_rounded;
        color = _showOnlyLocal ? Theme.of(context).primaryColor : color;
        break;
      case 'toggle_invalid':
        if (hasInvalidSongs || _showOnlyInvalid) icon = Icons.warning_rounded;
        color = _showOnlyInvalid ? Colors.orangeAccent : color;
        break;
    }
    if (icon == null) return const SizedBox.shrink();

    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      icon: Icon(icon, color: color, size: 20),
      tooltip: _getTooltipForAction(actionId),
      onPressed: () => _handleAction(actionId, fromMenu: false),
    );
  }

  bool _isActionVisible(String actionId) {
    switch (actionId) {
      case 'play_all':
      case 'sort':
      case 'search':
      case 'shuffle':
      case 'search_add_song':
        return true;
      case 'download':
        final dLimit = Provider.of<EntitlementService>(
          context,
          listen: false,
        ).getFeatureLimit('download_songs');
        // Visible if selection is active AND (not local playlist OR Artist/Album view)
        return isSelectionActive &&
            (effectivePlaylist == null ||
                effectivePlaylist!.id == 'favorites' ||
                effectivePlaylist!.creator != 'local') &&
            (dLimit != 0 || dLimit == -99);
      case 'share_playlist':
        return effectivePlaylist != null &&
            effectivePlaylist!.creator != 'local';
      case 'duplicates':
        return _selectedPlaylistId != null;
      case 'bulk_check':
      case 'toggle_invalid':
        return hasInvalidSongs || _showOnlyInvalid;
      case 'create_playlist':
      case 'scan_qr':
      case 'sort_mode':
        return _viewMode == MetadataViewMode.playlists;
      case 'toggle_artists':
        return _viewMode == MetadataViewMode.artists;
      case 'toggle_albums':
        return _viewMode == MetadataViewMode.albums;
      case 'toggle_local':
        return hasLocalSongs || _showOnlyLocal;
      default:
        return false;
    }
  }

  String _getTooltipForAction(String actionId) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    switch (actionId) {
      case 'play_all':
        return lang.translate('play_all');
      case 'download':
        return lang.translate('download');
      case 'share_playlist':
        return lang.translate('share_playlist');
      case 'sort':
        return lang.translate('sort_alphabetically');
      case 'search':
        return lang.translate('find_in_playlist');
      case 'shuffle':
        return lang.translate('shuffle');
      case 'duplicates':
        return lang.translate('scan_duplicates');
      case 'bulk_check':
        return lang.translate('try_again_unlock_all');
      case 'search_add_song':
        return lang.translate('search_add_song');
      case 'create_playlist':
        return lang.translate('create_playlist_tooltip');
      case 'scan_qr':
        return lang.translate('scan_qr');
      case 'sort_mode':
        return lang.translate('alphabetical_order_tooltip');
      case 'toggle_artists':
        return lang.translate('followed_artists_only');
      case 'toggle_albums':
        return lang.translate('followed_albums_only');
      case 'toggle_local':
        return lang.translate('filter_local_device');
      case 'toggle_invalid':
        return lang.translate('filter_invalid_tracks');
      default:
        return '';
    }
  }

  void _handleAction(String rawActionId, {bool fromMenu = false}) {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    if (rawActionId == 'toggle_pin_mode') {
      final newMode = !provider.isPinningMode;
      provider.setPinningMode(newMode);
      return;
    }

    final String actionId = rawActionId.startsWith('pin_')
        ? rawActionId.substring(4)
        : rawActionId;

    if (provider.isPinningMode) {
      // Toggle Pin
      final list = isSelectionActive
          ? provider.pinnedPlaylistActions
          : provider.pinnedLibraryActions;
      if (list.contains(actionId)) {
        provider.togglePinnedAction(actionId, !isSelectionActive);
      } else {
        int visibleCount = list.where((id) => _isActionVisible(id)).length;
        if (visibleCount < 5) {
          provider.togglePinnedAction(actionId, !isSelectionActive);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(lang.translate('max_pinned_reached')),
              duration: const Duration(seconds: 1),
            ),
          );
        }
      }
      return;
    }

    final currentSongs = this.currentSongList;

    switch (actionId) {
      case 'play_all':
        if (_selectedPlaylistId != null && effectivePlaylist != null) {
          _playPlaylist(provider, effectivePlaylist!);
        } else if (currentSongs.isNotEmpty) {
          _playSongs(provider, currentSongs, headerTitle);
        }
        break;
      case 'download':
        if (effectivePlaylist != null) {
          downloadPlaylist(context, provider, effectivePlaylist!);
        }
        break;
      case 'share_playlist':
        if (effectivePlaylist != null) {
          _showSharePlaylistDialog(context, provider, effectivePlaylist!);
        }
        break;
      case 'sort':
        setState(() => _sortAlphabetical = !_sortAlphabetical);
        break;
      case 'search':
        setState(() {
          _showPlaylistSearch = !_showPlaylistSearch;
          if (!_showPlaylistSearch) _searchController.clear();
        });
        break;
      case 'group_album':
        setState(() => _groupingMode = PlaylistGroupingMode.album);
        break;
      case 'group_artist':
        setState(() => _groupingMode = PlaylistGroupingMode.artist);
        break;
      case 'group_none':
        setState(() => _groupingMode = PlaylistGroupingMode.none);
        break;
      case 'shuffle':
        provider.toggleShuffle();
        break;
      case 'duplicates':
        if (effectivePlaylist != null) {
          scanForDuplicates(context, provider, effectivePlaylist!);
        }
        break;
      case 'bulk_check':
        _processAllInvalidTracks(provider, currentSongs, _selectedPlaylistId);
        break;
      case 'search_add_song':
        _showAddSongDialog(context, provider);
        break;
      case 'create_playlist':
        _showCreatePlaylistDialog(context, provider);
        break;
      case 'scan_qr':
        _showQRScanner(context, provider);
        break;
      case 'sort_mode':
        setState(() {
          _sortMode = (_sortMode == PlaylistSortMode.custom)
              ? PlaylistSortMode.alphabetical
              : PlaylistSortMode.custom;
        });
        break;
      case 'toggle_artists':
        setState(() => _showFollowedArtistsOnly = !_showFollowedArtistsOnly);
        _persistArtistFilter(_showFollowedArtistsOnly);
        break;
      case 'toggle_albums':
        setState(() => _showFollowedAlbumsOnly = !_showFollowedAlbumsOnly);
        _persistAlbumFilter(_showFollowedAlbumsOnly);
        break;
      case 'toggle_local':
        setState(() => _showOnlyLocal = !_showOnlyLocal);
        break;
      case 'toggle_invalid':
        setState(() => _showOnlyInvalid = !_showOnlyInvalid);
        break;
    }
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
                padding: const EdgeInsets.fromLTRB(2, 2, 6, 2),
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
                            borderRadius: BorderRadius.circular(4),
                            child: artUri != null
                                ? Container(
                                    width: 55,
                                    height: 55,
                                    color: Colors.black,
                                    child: CachedNetworkImage(
                                        imageUrl: artUri,
                                        fit: BoxFit.fitHeight,
                                        errorWidget: (_, __, ___) => Container(
                                          width: 55,
                                          height: 55,
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
                              widget.groupSongs.first.localPath!.isNotEmpty &&
                              File(widget.groupSongs.first.localPath!).existsSync())
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
                                      : Icons.folder_rounded,
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
                      surfaceTintColor: Colors.transparent,
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
                                Provider.of<LanguageProvider>(
                                  context,
                                  listen: false,
                                ).translate('delete'),
                                style: const TextStyle(color: Colors.red),
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
                  return NativeAdWidget();
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
            Provider.of<LanguageProvider>(context, listen: false)
                .translate('found_duplicates_count')
                .replaceAll('{0}', widget.duplicates.length.toString()),
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

                  return Material(
                    color: Colors.black.withValues(alpha: 0.001),
                    child: ListTile(
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
                            widget.provider.stopYoutubeAudio();
                          } else {
                            widget.provider.playPlaylistSong(
                              song,
                              widget.playlist.id,
                            );
                          }
                        },
                      ),
                      title: Text(
                        "Duplicato ${idx + 1} • ${song.duration?.toString().split('.').first ?? '--:--'}",
                        style: const TextStyle(color: Colors.white70),
                      ),
                      trailing: Checkbox(
                        value: isSelected,
                        checkColor: Colors.black,
                        activeColor: Theme.of(context).primaryColor,
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
                  final confirm = await GlassUtils.showGlassDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      surfaceTintColor: Colors.transparent,
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

class _QRScannerScreen extends StatefulWidget {
  final Function(String) onCodeDetected;
  const _QRScannerScreen({required this.onCodeDetected});

  @override
  State<_QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<_QRScannerScreen> {
  final MobileScannerController controller = MobileScannerController();
  bool _isProcessing = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(lang.translate('scan_qr')),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: MobileScanner(
        controller: controller,
        onDetect: (capture) {
          if (_isProcessing) return;

          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            final String? code = barcode.rawValue;
            if (code != null) {
              _isProcessing = true;
              controller.stop();
              widget.onCodeDetected(code);
              return;
            }
          }
        },
      ),
    );
  }
}

class _SpinningSyncIcon extends StatefulWidget {
  final double size;
  final Color color;
  const _SpinningSyncIcon({this.size = 10, this.color = Colors.white});

  @override
  State<_SpinningSyncIcon> createState() => _SpinningSyncIconState();
}

class _SpinningSyncIconState extends State<_SpinningSyncIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(Icons.sync_rounded, color: widget.color, size: widget.size),
    );
  }
}

class _DoubleTapSpinnerWrapper extends StatefulWidget {
  final Widget child;
  final Future<void> Function() onDoubleTap;
  final VoidCallback onTap;

  const _DoubleTapSpinnerWrapper({
    Key? key,
    required this.child,
    required this.onDoubleTap,
    required this.onTap,
  }) : super(key: key);

  @override
  State<_DoubleTapSpinnerWrapper> createState() => _DoubleTapSpinnerWrapperState();
}

class _DoubleTapSpinnerWrapperState extends State<_DoubleTapSpinnerWrapper> {
  bool _isFetching = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: () async {
        if (_isFetching) return;
        setState(() {
          _isFetching = true;
        });
        await widget.onDoubleTap();
        if (mounted) {
          setState(() {
            _isFetching = false;
          });
        }
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          widget.child,
          if (_isFetching)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  color: Colors.black54,
                  child: const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.blueAccent
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
