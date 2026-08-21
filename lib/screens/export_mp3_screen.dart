import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

import '../models/saved_song.dart';
import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import '../providers/theme_provider.dart';
import '../services/mp3_export_service.dart';
import '../utils/glass_utils.dart';

class ExportMp3Screen extends StatefulWidget {
  const ExportMp3Screen({super.key});

  @override
  State<ExportMp3Screen> createState() => _ExportMp3ScreenState();
}

class _ExportMp3ScreenState extends State<ExportMp3Screen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedSongIds = {};
  String? _selectedFolderPath;
  String _searchQuery = '';
  bool _isLoadingFolder = true;
  bool _isProgressDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _loadInitialFolder();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<String> _getFixedDestinationFolder() async {
    String path;
    if (Platform.isAndroid) {
      path = '/storage/emulated/0/Download/MusicStream';
    } else {
      try {
        final downloadDir = await getDownloadsDirectory();
        if (downloadDir != null) {
          path = '${downloadDir.path}/MusicStream';
        } else {
          final docDir = await getApplicationDocumentsDirectory();
          path = '${docDir.path}/Download/MusicStream';
        }
      } catch (_) {
        final docDir = await getApplicationDocumentsDirectory();
        path = '${docDir.path}/Download/MusicStream';
      }
    }

    final dir = Directory(path);
    if (!dir.existsSync()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {}
    }
    return path;
  }

  Future<void> _loadInitialFolder() async {
    _selectedFolderPath = await _getFixedDestinationFolder();
    if (mounted) {
      setState(() {
        _isLoadingFolder = false;
      });
    }
  }

  List<SavedSong> _getDownloadedSongs(RadioProvider radio) {
    final Map<String, SavedSong> uniqueDownloads = {};

    // Only include songs truly downloaded by the app (isDownloaded is true and file exists)
    // Excludes songs already present on the device storage / imported from local media.
    for (final song in radio.allUniqueSongs) {
      if (song.isDownloaded && song.localPath != null && song.localPath!.isNotEmpty) {
        final file = File(song.localPath!);
        if (file.existsSync()) {
          uniqueDownloads[song.id] = song;
        }
      }
    }

    for (final playlist in radio.playlists) {
      for (final song in playlist.songs) {
        if (song.isDownloaded && song.localPath != null && song.localPath!.isNotEmpty) {
          final file = File(song.localPath!);
          if (file.existsSync()) {
            uniqueDownloads.putIfAbsent(song.id, () => song);
          }
        }
      }
    }

    return uniqueDownloads.values.toList();
  }

  List<SavedSong> _filterSongs(List<SavedSong> allSongs) {
    if (_searchQuery.isEmpty) return allSongs;
    return allSongs.where((song) {
      final titleMatch = song.title.toLowerCase().contains(_searchQuery);
      final artistMatch = song.artist.toLowerCase().contains(_searchQuery);
      final albumMatch = song.album.toLowerCase().contains(_searchQuery);
      return titleMatch || artistMatch || albumMatch;
    }).toList();
  }

  void _selectAll(List<SavedSong> songs) {
    setState(() {
      for (final song in songs) {
        _selectedSongIds.add(song.id);
      }
    });
  }

  void _deselectAll() {
    setState(() {
      _selectedSongIds.clear();
    });
  }

  void _toggleSongSelection(String id) {
    setState(() {
      if (_selectedSongIds.contains(id)) {
        _selectedSongIds.remove(id);
      } else {
        _selectedSongIds.add(id);
      }
    });
  }

  String _formatFileSize(String? filePath) {
    if (filePath == null) return '';
    try {
      final file = File(filePath);
      if (!file.existsSync()) return '';
      final bytes = file.lengthSync();
      if (bytes < 1024 * 1024) {
        return '${(bytes / 1024).toStringAsFixed(1)} KB';
      }
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }

  String _formatDuration(Duration? duration) {
    if (duration == null || duration == Duration.zero) return '';
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _startExport(List<SavedSong> allDownloadedSongs) async {
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    if (_selectedSongIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(lang.translate('export_mp3_no_selection')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    _selectedFolderPath ??= await _getFixedDestinationFolder();

    // Permission check for storage on Android
    if (Platform.isAndroid) {
      try {
        await [
          Permission.storage,
          Permission.audio,
        ].request().timeout(const Duration(seconds: 4), onTimeout: () => {});
      } catch (_) {}
    }

    // Verify directory exists or can be created
    try {
      final destDir = Directory(_selectedFolderPath!);
      if (!destDir.existsSync()) {
        await destDir.create(recursive: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(lang.translate('export_mp3_permission_denied')),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    final selectedSongs = allDownloadedSongs
        .where((s) => _selectedSongIds.contains(s.id))
        .toList();

    final exportService = Mp3ExportService();

    // Show persistent progress modal or initiate export
    _showExportingDialog(context, exportService, selectedSongs);
  }

  void _showExportingDialog(
    BuildContext parentContext,
    Mp3ExportService exportService,
    List<SavedSong> songsToExport,
  ) {
    final lang = Provider.of<LanguageProvider>(parentContext, listen: false);
    final radio = Provider.of<RadioProvider>(parentContext, listen: false);

    // Launch export in background
    exportService
        .exportSongs(
          songs: songsToExport,
          destinationPath: _selectedFolderPath!,
        )
        .then((result) async {
          for (final song in songsToExport) {
            final newExportedPath = result.exportedSongPaths[song.id];
            if (newExportedPath != null && File(newExportedPath).existsSync()) {
              // Assign exported MP3 path: song becomes a "local" song on device
              await radio.updateSongDownloadStatusGlobally(
                song.copyWith(localPath: newExportedPath),
              );
            } else if (result.exportedSongIds.contains(song.id)) {
              await radio.updateSongDownloadStatusGlobally(
                song.copyWith(forceClearLocalPath: true),
              );
            }
          }
          if (mounted) {
            setState(() {
              _selectedSongIds.removeWhere(
                (id) => result.exportedSongIds.contains(id),
              );
            });
            if (_isProgressDialogShowing) {
              _isProgressDialogShowing = false;
              Navigator.of(context, rootNavigator: true).pop();
              _showCompletionDialog(context, result, lang);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Row(
                    children: [
                      const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          lang.translate('export_mp3_completed_desc').replaceAll('{0}', result.successCount.toString()),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  backgroundColor: Colors.green.shade700,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          }
        })
        .catchError((e) {
          if (mounted) {
            if (_isProgressDialogShowing) {
              _isProgressDialogShowing = false;
              Navigator.of(context, rootNavigator: true).pop();
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Export error: $e'),
                backgroundColor: Colors.redAccent,
              ),
            );
          }
        });

    final themeProvider = Provider.of<ThemeProvider>(parentContext, listen: false);
    final isDark = themeProvider.isDarkMode;
    final primaryColor = themeProvider.activePrimaryColor;
    final surfaceColor = themeProvider.activeSurfaceColor;

    _isProgressDialogShowing = true;
    GlassUtils.showGlassDialog(
      context: parentContext,
      barrierDismissible: true,
      builder: (ctx) {
        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) _isProgressDialogShowing = false;
          },
          child: AnimatedBuilder(
            animation: exportService,
            builder: (context, _) {
              final progress = exportService.progressFraction;
              final current = exportService.currentProgress;
              final total = exportService.totalCount;
              final songName = exportService.currentSongName;

              return AlertDialog(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                contentPadding: EdgeInsets.zero,
                content: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primaryColor.withValues(alpha: 0.25),
                        surfaceColor.withValues(alpha: 0.95),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: primaryColor.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: primaryColor.withValues(alpha: 0.2),
                        ),
                        child: Icon(
                          Icons.audio_file_rounded,
                          size: 40,
                          color: primaryColor,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        lang.translate('export_mp3_progress'),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        lang.translate('export_mp3_in_background'),
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 20),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 8,
                          backgroundColor: isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.black.withValues(alpha: 0.1),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            primaryColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '$current / $total',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                          Text(
                            '${(progress * 100).toStringAsFixed(0)}%',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: primaryColor,
                            ),
                          ),
                        ],
                      ),
                      if (songName.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          songName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white.withValues(alpha: 0.85) : Colors.black87,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: isDark ? Colors.white70 : Colors.black87,
                                side: BorderSide(
                                  color: isDark ? Colors.white24 : Colors.black12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 10,
                                ),
                              ),
                              onPressed: () {
                                _isProgressDialogShowing = false;
                                Navigator.of(ctx).pop();
                              },
                              icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                              label: Text(
                                lang.translate('export_mp3_hide_dialog'),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                              side: const BorderSide(color: Colors.redAccent),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                            ),
                            onPressed: () {
                              exportService.cancelExport();
                            },
                            icon: const Icon(Icons.cancel_rounded, size: 18),
                            label: Text(lang.translate('export_mp3_cancel')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _showCompletionDialog(
    BuildContext context,
    Mp3ExportResult result,
    LanguageProvider lang,
  ) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final isDark = themeProvider.isDarkMode;
    final primaryColor = themeProvider.activePrimaryColor;
    final surfaceColor = themeProvider.activeSurfaceColor;

    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          contentPadding: EdgeInsets.zero,
          content: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  primaryColor.withValues(alpha: 0.2),
                  surfaceColor.withValues(alpha: 0.95),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: primaryColor.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.greenAccent.withValues(alpha: 0.2),
                  ),
                  child: const Icon(
                    Icons.check_circle_rounded,
                    size: 48,
                    color: Colors.greenAccent,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  result.wasCancelled
                      ? lang.translate('export_mp3_cancel')
                      : lang.translate('export_mp3_completed'),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  lang
                      .translate('export_mp3_completed_desc')
                      .replaceAll('{0}', result.successCount.toString()),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white.withValues(alpha: 0.8) : Colors.black87,
                  ),
                ),
                if (result.failureCount > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${result.failureCount} failed',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_open_rounded, size: 18, color: Colors.white70),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _selectedFolderPath ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    minimumSize: const Size(double.infinity, 44),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(lang.translate('export_mp3_close')),
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
    final lang = Provider.of<LanguageProvider>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final radio = Provider.of<RadioProvider>(context);
    final isDark = themeProvider.isDarkMode;

    final allDownloadedSongs = _getDownloadedSongs(radio);
    final filteredSongs = _filterSongs(allDownloadedSongs);

    final int selectedCount = _selectedSongIds.length;
    final int totalCount = allDownloadedSongs.length;
    final bool allSelected =
        filteredSongs.isNotEmpty &&
        filteredSongs.every((s) => _selectedSongIds.contains(s.id));

    final primaryColor = themeProvider.activePrimaryColor;
    final surfaceColor = themeProvider.activeSurfaceColor;
    final exportService = Mp3ExportService();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          lang.translate('export_mp3_title'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (filteredSongs.isNotEmpty)
            IconButton(
              tooltip: allSelected
                  ? lang.translate('export_mp3_deselect_all')
                  : lang.translate('export_mp3_select_all'),
              icon: Icon(
                allSelected
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
              ),
              onPressed: () {
                if (allSelected) {
                  _deselectAll();
                } else {
                  _selectAll(filteredSongs);
                }
              },
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(color: Colors.transparent),
        child: Column(
          children: [
            // Search Bar & Filter Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: themeProvider.customBackgroundImageUrl != null
                      ? (isDark
                          ? themeProvider.currentPreset.surfaceColor.withValues(alpha: 0.65)
                          : Colors.white.withValues(alpha: 0.50))
                      : (isDark
                          ? themeProvider.currentPreset.cardColor.withValues(alpha: 0.85)
                          : Colors.white.withValues(alpha: 0.95)),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.black.withValues(alpha: 0.08),
                  ),
                ),
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  decoration: InputDecoration(
                    hintText: lang.translate('export_mp3_search_hint'),
                    hintStyle: TextStyle(
                      color: isDark ? Colors.white38 : Colors.grey.shade600,
                      fontSize: 14,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: isDark ? Colors.white60 : Colors.grey.shade700,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(
                              Icons.clear_rounded,
                              size: 18,
                              color: isDark ? Colors.white60 : Colors.grey.shade700,
                            ),
                            onPressed: () {
                              _searchController.clear();
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
              ),
            ),

            // Active Export Mini Banner (if dialog was minimized)
            AnimatedBuilder(
              animation: exportService,
              builder: (context, _) {
                if (!exportService.isExporting || _isProgressDialogShowing) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      _showExportingDialog(
                        context,
                        exportService,
                        allDownloadedSongs
                            .where((s) => _selectedSongIds.contains(s.id))
                            .toList(),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: primaryColor.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              value: exportService.progressFraction > 0
                                  ? exportService.progressFraction
                                  : null,
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                primaryColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${lang.translate('export_mp3_progress')} (${exportService.currentProgress}/${exportService.totalCount})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                                if (exportService.currentSongName.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    exportService.currentSongName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark ? Colors.white70 : Colors.black54,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.open_in_full_rounded,
                            size: 16,
                            color: primaryColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),

            // Selection Quick Toolbar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).primaryColor.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      '$selectedCount / $totalCount ${lang.translate('export_mp3_selected_count')}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(
                      allSelected ? Icons.check_box_outline_blank : Icons.check_box,
                      size: 16,
                      color: Theme.of(context).primaryColor,
                    ),
                    label: Text(
                      allSelected
                          ? lang.translate('export_mp3_deselect_all')
                          : lang.translate('export_mp3_select_all'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                    onPressed: () {
                      if (allSelected) {
                        _deselectAll();
                      } else {
                        _selectAll(filteredSongs);
                      }
                    },
                  ),
                ],
              ),
            ),

            // Songs List
            Expanded(
              child: allDownloadedSongs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.download_for_offline_outlined,
                            size: 64,
                            color: isDark ? Colors.white24 : Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              lang.translate('export_mp3_no_downloads'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: isDark ? Colors.white54 : Colors.grey.shade600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : filteredSongs.isEmpty
                      ? Center(
                          child: Text(
                            'No matching songs found',
                            style: TextStyle(
                              color: isDark ? Colors.white54 : Colors.grey.shade600,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            4,
                            16,
                            150 + MediaQuery.of(context).padding.bottom,
                          ),
                          itemCount: filteredSongs.length,
                          itemBuilder: (context, index) {
                            final song = filteredSongs[index];
                            final isSelected = _selectedSongIds.contains(song.id);
                            final fileSize = _formatFileSize(song.localPath);
                            final durationStr = _formatDuration(song.duration);

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () => _toggleSongSelection(song.id),
                                  child: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? primaryColor.withValues(alpha: 0.28)
                                          : (themeProvider.customBackgroundImageUrl != null
                                              ? (isDark
                                                  ? themeProvider.currentPreset.surfaceColor.withValues(alpha: 0.20)
                                                  : Colors.white.withValues(alpha: 0.88))
                                              : (isDark
                                                  ? themeProvider.currentPreset.cardColor.withValues(alpha: 0.85)
                                                  : Colors.white.withValues(alpha: 0.95))),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: isSelected
                                            ? primaryColor.withValues(alpha: 0.8)
                                            : (isDark
                                                ? Colors.white.withValues(alpha: 0.12)
                                                : Colors.black.withValues(alpha: 0.08)),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        // Checkbox / Selection Icon
                                        Icon(
                                          isSelected
                                              ? Icons.check_circle_rounded
                                              : Icons.radio_button_unchecked_rounded,
                                          color: isSelected
                                              ? primaryColor
                                              : (isDark
                                                  ? Colors.white38
                                                  : Colors.grey.shade400),
                                          size: 22,
                                        ),
                                        const SizedBox(width: 12),

                                        // Artwork
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(10),
                                          child: SizedBox(
                                            width: 48,
                                            height: 48,
                                            child: song.artUri != null &&
                                                    song.artUri!.isNotEmpty
                                                ? CachedNetworkImage(
                                                    imageUrl: song.artUri!,
                                                    fit: BoxFit.cover,
                                                    errorWidget: (c, u, e) =>
                                                        Container(
                                                      color: Colors.black26,
                                                      child: const Icon(
                                                        Icons.music_note_rounded,
                                                        color: Colors.white54,
                                                      ),
                                                    ),
                                                  )
                                                : Container(
                                                    color: Colors.black26,
                                                    child: const Icon(
                                                      Icons.music_note_rounded,
                                                      color: Colors.white54,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),

                                        // Song Details
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                song.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: isDark
                                                      ? Colors.white
                                                      : Colors.black87,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                song.artist,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: isDark
                                                      ? Colors.white60
                                                      : Colors.grey.shade700,
                                                ),
                                              ),
                                              if (fileSize.isNotEmpty ||
                                                  durationStr.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Row(
                                                  children: [
                                                    if (durationStr.isNotEmpty) ...[
                                                      Icon(
                                                        Icons.schedule_rounded,
                                                        size: 11,
                                                        color: isDark
                                                            ? Colors.white38
                                                            : Colors.grey.shade500,
                                                      ),
                                                      const SizedBox(width: 3),
                                                      Text(
                                                        durationStr,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          color: isDark
                                                              ? Colors.white38
                                                              : Colors.grey.shade500,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                    ],
                                                    if (fileSize.isNotEmpty) ...[
                                                      Icon(
                                                        Icons.save_rounded,
                                                        size: 11,
                                                        color: isDark
                                                            ? Colors.white38
                                                            : Colors.grey.shade500,
                                                      ),
                                                      const SizedBox(width: 3),
                                                      Text(
                                                        fileSize,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          color: isDark
                                                              ? Colors.white38
                                                              : Colors.grey.shade500,
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),

      // Bottom Control Panel: Folder selection + Start button
      bottomSheet: allDownloadedSongs.isEmpty
          ? null
          : Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              decoration: BoxDecoration(
                color: themeProvider.customBackgroundImageUrl != null
                    ? surfaceColor
                    : (isDark
                        ? surfaceColor.withValues(alpha: 0.95)
                        : Colors.white.withValues(alpha: 0.95)),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.08),
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 15,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Destination Folder Bar (Fixed to Download/MusicStream)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.black.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_rounded,
                            size: 22,
                            color: primaryColor,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  lang.translate('export_mp3_destination'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? Colors.white54
                                        : Colors.grey.shade600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _isLoadingFolder
                                      ? 'Loading...'
                                      : (_selectedFolderPath ?? 'Download/MusicStream'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: isDark
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.download_rounded,
                                  size: 13,
                                  color: primaryColor,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Download',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: primaryColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Start Export Button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: selectedCount > 0
                              ? primaryColor
                              : (isDark
                                  ? Colors.white12
                                  : Colors.grey.shade300),
                          foregroundColor: selectedCount > 0
                              ? Colors.white
                              : (isDark
                                  ? Colors.white38
                                  : Colors.grey.shade600),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: selectedCount > 0 ? 4 : 0,
                        ),
                        onPressed: selectedCount > 0
                            ? () => _startExport(allDownloadedSongs)
                            : null,
                        icon: const Icon(Icons.output_rounded, size: 20),
                        label: Text(
                          selectedCount > 0
                              ? '${lang.translate('export_mp3_start')} ($selectedCount)'
                              : lang.translate('export_mp3_start'),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
