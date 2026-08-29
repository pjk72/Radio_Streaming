import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_song.dart';
import 'encryption_service.dart';
import 'id3_tag_service.dart';
import 'notification_service.dart';
import 'log_service.dart';

enum MP3ExportGroupingMode {
  artist,
  playlist,
}

class MP3ExportResult {
  final int totalRequested;
  final int successCount;
  final int failureCount;
  final bool wasCancelled;
  final List<String> exportedFilePaths;
  final List<String> exportedSongIds;
  final Map<String, String> exportedSongPaths;
  final List<String> errorMessages;

  MP3ExportResult({
    required this.totalRequested,
    required this.successCount,
    required this.failureCount,
    required this.wasCancelled,
    required this.exportedFilePaths,
    this.exportedSongIds = const [],
    this.exportedSongPaths = const {},
    required this.errorMessages,
  });
}

class MP3ExportService extends ChangeNotifier {
  static final MP3ExportService _instance = MP3ExportService._internal();
  factory MP3ExportService() => _instance;
  MP3ExportService._internal();

  static const String _prefLastFolderKey = 'last_export_mp3_folder';
  static const int _notificationId = 987654;
  static const MethodChannel _mediaScannerChannel =
      MethodChannel('com.antigravity.radio/media_scanner');

  bool _isExporting = false;
  bool _isCancelled = false;
  int _totalCount = 0;
  int _currentProgress = 0;
  int _successCount = 0;
  int _failureCount = 0;
  String _currentSongName = '';
  String _destinationFolder = '';

  bool get isExporting => _isExporting;
  bool get isCancelled => _isCancelled;
  int get totalCount => _totalCount;
  int get currentProgress => _currentProgress;
  int get successCount => _successCount;
  int get failureCount => _failureCount;
  String get currentSongName => _currentSongName;
  String get destinationFolder => _destinationFolder;
  double get progressFraction =>
      _totalCount > 0 ? (_currentProgress / _totalCount).clamp(0.0, 1.0) : 0.0;

  StreamSubscription? _cancelSub;

  Future<String?> getLastExportFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefLastFolderKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLastExportFolder(String path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefLastFolderKey, path);
    } catch (_) {}
  }

  void cancelExport() {
    if (_isExporting) {
      _isCancelled = true;
      LogService().log('MP3ExportService: Export cancelled by user.');
      notifyListeners();
    }
  }

  static String _sanitizeFileName(String name) {
    // Normalize common Unicode punctuation to ASCII equivalents first
    final normalized = name
        .replaceAll('\u2019', "'") // RIGHT SINGLE QUOTATION MARK → apostrophe
        .replaceAll('\u2018', "'") // LEFT SINGLE QUOTATION MARK
        .replaceAll('\u201C', '"') // LEFT DOUBLE QUOTATION MARK
        .replaceAll('\u201D', '"') // RIGHT DOUBLE QUOTATION MARK
        .replaceAll('\u2013', '-') // EN DASH
        .replaceAll('\u2014', '-') // EM DASH
        .replaceAll('\u2026', '...'); // HORIZONTAL ELLIPSIS
    // Replace invalid filesystem characters with underscore
    return normalized
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// More aggressive sanitization for artist/band and playlist folder names:
  /// removes filesystem-illegal chars AND common special characters
  /// like . , & % ! @ # $ ^ ( ) [ ] { } + = ~ ` ' ; : that can cause
  /// issues or create cluttered folder names.
  static String _sanitizeArtistFolderName(String name) {
    return name
        // Remove filesystem-illegal chars
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '')
        // Remove common special/punctuation chars not suitable for folder names
        .replaceAll(RegExp(r"[.,&%!@#\$\^()\[\]{}\+=~`';:]"), '')
        // Collapse multiple spaces/underscores into a single space
        .replaceAll(RegExp(r'[\s_]+'), ' ')
        .trim();
  }


  // In-memory cache for artwork to avoid redundant downloads across exports
  static final Map<String, Uint8List> _coverArtMemoryCache = {};

  /// Fetches cover artwork bytes for the song (if available) with memory cache & short timeout.
  Future<Uint8List?> _fetchCoverArtBytes(SavedSong song) async {
    if (song.artUri == null || song.artUri!.trim().isEmpty) return null;
    final uriStr = song.artUri!.trim();

    if (_coverArtMemoryCache.containsKey(uriStr)) {
      return _coverArtMemoryCache[uriStr];
    }

    // Local file path
    if (uriStr.startsWith('/') ||
        uriStr.startsWith('file://') ||
        uriStr.contains(':\\') ||
        uriStr.contains(':/')) {
      try {
        final filePath = uriStr.replaceFirst('file://', '');
        final file = File(filePath);
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            _coverArtMemoryCache[uriStr] = bytes;
            return bytes;
          }
        }
      } catch (_) {}
    }

    // Remote HTTP / HTTPS image URL
    if (uriStr.startsWith('http://') || uriStr.startsWith('https://')) {
      try {
        final response = await http
            .get(
              Uri.parse(uriStr),
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              },
            )
            .timeout(const Duration(milliseconds: 2000));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          _coverArtMemoryCache[uriStr] = response.bodyBytes;
          return response.bodyBytes;
        }
      } catch (e) {
        LogService().log(
          'MP3ExportService: Could not fetch cover art for ${song.title}: $e',
        );
      }
    }

    return null;
  }

  /// Triggers Android MediaScanner so Android MediaStore immediately registers
  /// the new MP3 file and its ID3 tags.
  static Future<void> _scanMediaFile(String filePath) async {
    if (Platform.isAndroid) {
      try {
        await _mediaScannerChannel.invokeMethod('scanFile', {'path': filePath});
      } catch (_) {}
    }
  }

  static Future<bool> _exportSingleSongWorker({
    required SavedSong song,
    required String sourcePath,
    required Directory targetSubDir,
    required String baseName,
    Uint8List? coverArtBytes,
    required Function(String exportedPath) onExportSuccess,
  }) async {
    try {
      final sourceFile = File(sourcePath);

      if (!sourceFile.existsSync()) {
        return false;
      }

      // Read source file and decrypt
      final rawBytes = await sourceFile.readAsBytes();

      if (rawBytes.isEmpty) {
        return false;
      }

      final decryptedBytes = EncryptionService().encryptData(rawBytes);

      // 1. Sanitize base name
      String cleanBase = _sanitizeFileName(baseName);
      if (cleanBase.isEmpty) cleanBase = 'Track_${song.id}';

      if (!targetSubDir.existsSync()) {
        targetSubDir.createSync(recursive: true);
      }

      final String detectedExt = Id3TagService.detectAudioExtension(decryptedBytes);
      bool exportSucceeded = false;
      String finalExportedPath = '';

      // 2. ULTRA-FAST PATH (< 10ms): If source is already M4A, MP3, FLAC, or WAV, tag in-memory directly
      final bool isDirectAudioFormat = (detectedExt == '.m4a' ||
          detectedExt == '.mp4' ||
          detectedExt == '.mp3' ||
          detectedExt == '.flac' ||
          detectedExt == '.wav');

      if (isDirectAudioFormat) {
        final extToUse = (detectedExt == '.mp4') ? '.m4a' : detectedExt;
        final destFile = File('${targetSubDir.path}/$cleanBase$extToUse');
        final taggedAudioBytes = Id3TagService().injectMetadata(
          audioBytes: decryptedBytes,
          song: song,
          coverArtBytes: coverArtBytes,
        );

        await destFile.writeAsBytes(taggedAudioBytes, flush: true);
        if (await destFile.exists() && await destFile.length() > 0) {
          exportSucceeded = true;
          finalExportedPath = destFile.path;
          LogService().log(
            'MP3ExportService: Fast direct audio export completed: ${destFile.path}',
          );
        }
      }

      // 3. On Android: Hardware-accelerated transcode for raw formats (WebM/Opus) via native MediaCodec + MediaMuxer (~200ms)
      if (!exportSucceeded && Platform.isAndroid) {
        File? tempDecryptedFile;
        try {
          // Write decrypted audio to app-internal cache dir (always accessible, no permission needed)
          final tempDir = await getTemporaryDirectory();
          tempDecryptedFile = File(
            '${tempDir.path}/temp_exp_${DateTime.now().millisecondsSinceEpoch}_${song.id}.tmp',
          );
          await tempDecryptedFile.writeAsBytes(decryptedBytes);

          // Determine the subfolder name from the targetSubDir path
          final subFolderName = targetSubDir.path.split(Platform.pathSeparator).last;

          String yearVal = '';
          if (song.releaseDate != null && song.releaseDate!.trim().isNotEmpty) {
            final match = RegExp(r'\b(19\d\d|20\d\d)\b').firstMatch(song.releaseDate!.trim());
            yearVal = match != null ? match.group(0)! : song.releaseDate!.trim();
          } else {
            yearVal = song.dateAdded.year.toString();
          }

          // Kotlin returns the final exported path (String) or null on failure
          final String? resultPath = await _mediaScannerChannel.invokeMethod<String?>(
            'convertToMP3',
            {
              'inputPath': tempDecryptedFile.path,
              'fileName': '$cleanBase.m4a',
              'subFolder': subFolderName,
              'title': song.title.trim(),
              'artist': song.artist.trim(),
              'album': song.album.trim(),
              'year': yearVal,
              'bitrate': 192,
            },
          );

          if (resultPath != null && resultPath.isNotEmpty) {
            final resultFile = File(resultPath);
            if (await resultFile.exists()) {
              // Inject iTunes metadata tags into the transcoded container
              try {
                final transcodedBytes = await resultFile.readAsBytes();
                final taggedTranscoded = Id3TagService().injectMetadata(
                  audioBytes: transcodedBytes,
                  song: song,
                  coverArtBytes: coverArtBytes,
                );
                await resultFile.writeAsBytes(taggedTranscoded, flush: true);
              } catch (_) {}

              exportSucceeded = true;
              finalExportedPath = resultPath;
              LogService().log(
                'MP3ExportService: Hardware transcode completed: $resultPath',
              );
            }
          }
        } catch (transcodeErr) {
          LogService().log(
            'MP3ExportService: Hardware transcode error: $transcodeErr, falling back to direct format write',
          );
        } finally {
          try {
            if (tempDecryptedFile != null && await tempDecryptedFile.exists()) {
              await tempDecryptedFile.delete();
            }
          } catch (_) {}
        }
      }

      // 4. Fallback: Write directly in native container format
      if (!exportSucceeded) {
        final destFile = File('${targetSubDir.path}/$cleanBase$detectedExt');

        final taggedAudioBytes = Id3TagService().injectMetadata(
          audioBytes: decryptedBytes,
          song: song,
          coverArtBytes: coverArtBytes,
        );

        await destFile.writeAsBytes(
          taggedAudioBytes,
          flush: true,
        );

        if (await destFile.exists() && await destFile.length() > 0) {
          exportSucceeded = true;
          finalExportedPath = destFile.path;
        }
      }

      if (exportSucceeded && finalExportedPath.isNotEmpty) {
        await _scanMediaFile(finalExportedPath);

        try {
          await sourceFile.delete();
          LogService().log(
            'MP3ExportService: Export completed successfully. Source deleted: $sourcePath',
          );
        } catch (e) {
          LogService().log(
            'MP3ExportService: Export completed but source deletion failed: $e',
          );
        }

        onExportSuccess(finalExportedPath);
        return true;
      }
    } catch (e) {
      debugPrint(
        'MP3ExportService _exportSingleSongWorker error: $e | song: ${song.title}',
      );
    }

    return false;
  }

  /// Exports selected songs to non-encrypted audio files (MP3 / MP3) in destination directory
  /// with full metadata tags & cover art, ensuring compatibility with all external media players.
  Future<MP3ExportResult> exportSongs({
    required List<SavedSong> songs,
    required String destinationPath,
    MP3ExportGroupingMode groupingMode = MP3ExportGroupingMode.artist,
    Map<String, String>? songPlaylistNames,
    Function(int current, int total, String songName)? onProgress,
  }) async {
    if (_isExporting) {
      throw StateError('An export task is already running.');
    }

    _isExporting = true;
    _isCancelled = false;
    _totalCount = songs.length;
    _currentProgress = 0;
    _successCount = 0;
    _failureCount = 0;
    _currentSongName = '';
    _destinationFolder = destinationPath;
    notifyListeners();

    await saveLastExportFolder(destinationPath);

    final destDir = Directory(destinationPath);
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    // Subscribe to notification cancel action
    _cancelSub?.cancel();
    _cancelSub = NotificationService().onCancelDownload.listen((id) {
      if (id == _notificationId) {
        cancelExport();
      }
    });

    final List<String> exportedPaths = [];
    final List<String> exportedSongIds = [];
    final Map<String, String> exportedSongPaths = {};
    final List<String> errors = [];

    try {
      for (int i = 0; i < songs.length; i++) {
        if (_isCancelled) {
          LogService().log('MP3ExportService: Stopping loop due to cancellation.');
          break;
        }

        final song = songs[i];
        final String displayName = '${song.artist} - ${song.title}'.trim();
        _currentSongName = displayName.isNotEmpty ? displayName : song.title;
        _currentProgress = i + 1;
        notifyListeners();

        onProgress?.call(_currentProgress, _totalCount, _currentSongName);

        // Update notification
        try {
          await NotificationService().showExportProgress(
            id: _notificationId,
            title: 'Exporting: $_currentSongName',
            progress: _currentProgress,
            maxProgress: _totalCount,
            subTitle: '$_currentProgress/$_totalCount',
          );
        } catch (_) {}

        try {
          if (song.localPath == null || song.localPath!.isEmpty) {
            throw Exception('Local file path is missing for song: ${song.title}');
          }

          final sourceFile = File(song.localPath!);
          if (!await sourceFile.exists()) {
            throw Exception('Source file not found on disk: ${song.localPath}');
          }

          // Determine target subfolder based on grouping mode
          Directory targetSubDir;
          if (groupingMode == MP3ExportGroupingMode.playlist) {
            String rawPlaylist = (songPlaylistNames != null ? songPlaylistNames[song.id] : null) ?? 'Playlist';
            String cleanPlaylist = _sanitizeArtistFolderName(rawPlaylist.trim());
            if (cleanPlaylist.isEmpty || cleanPlaylist == '.' || cleanPlaylist == '..') {
              cleanPlaylist = 'Playlist';
            }
            targetSubDir = Directory('${destDir.path}/Playlist/$cleanPlaylist');
          } else {
            // Group by Artist
            String rawArtist = song.artist.trim();
            String cleanArtist = _sanitizeArtistFolderName(rawArtist);
            if (cleanArtist.isEmpty || cleanArtist == '.' || cleanArtist == '..') {
              cleanArtist = 'Unknown Artist';
            }
            targetSubDir = Directory('${destDir.path}/Artist/$cleanArtist');
          }

          // Create target subdirectory
          try {
            if (!await targetSubDir.exists()) {
              await targetSubDir.create(recursive: true);
            }
          } catch (dirError) {
            throw Exception(
              'Impossibile creare la cartella di destinazione: ${targetSubDir.path} — $dirError',
            );
          }

          // Determine clean filename
          String artistPart = song.artist.trim();
          String titlePart = song.title.trim();
          String baseName = artistPart.isNotEmpty ? '$artistPart - $titlePart' : titlePart;
          if (baseName.isEmpty) baseName = 'Track_${song.id}';

          // Fetch cover art if available
          final coverArtBytes = await _fetchCoverArtBytes(song);

          // Decrypt, tag with appropriate metadata (iTunes for MP3, ID3 for MP3), and write file
          String? writtenFilePath;
          final bool success = await _exportSingleSongWorker(
            song: song,
            sourcePath: sourceFile.path,
            targetSubDir: targetSubDir,
            baseName: baseName,
            coverArtBytes: coverArtBytes,
            onExportSuccess: (path) {
              writtenFilePath = path;
            },
          );

          if (success && writtenFilePath != null && File(writtenFilePath!).existsSync()) {
            exportedPaths.add(writtenFilePath!);
            exportedSongIds.add(song.id);
            exportedSongPaths[song.id] = writtenFilePath!;
            _successCount++;
          } else {
            throw Exception('Exported audio file is empty or could not be verified.');
          }
        } catch (e) {
          LogService().log('MP3ExportService: Error exporting song ${song.title}: $e');
          errors.add('${song.title}: $e');
          _failureCount++;
        }

        // Slight micro-delay to let UI thread breathe and stay responsive
        await Future.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      _cancelSub?.cancel();
      _cancelSub = null;
      try {
        await NotificationService().clearNotification(_notificationId);
      } catch (_) {}

      _isExporting = false;
      notifyListeners();
    }

    final bool wasCancelled = _isCancelled;
    _isCancelled = false;

    return MP3ExportResult(
      totalRequested: _totalCount,
      successCount: _successCount,
      failureCount: _failureCount,
      wasCancelled: wasCancelled,
      exportedFilePaths: exportedPaths,
      exportedSongIds: exportedSongIds,
      exportedSongPaths: exportedSongPaths,
      errorMessages: errors,
    );
  }
}
