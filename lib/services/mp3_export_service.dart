import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_song.dart';
import 'encryption_service.dart';
import 'notification_service.dart';
import 'log_service.dart';

class Mp3ExportResult {
  final int totalRequested;
  final int successCount;
  final int failureCount;
  final bool wasCancelled;
  final List<String> exportedFilePaths;
  final List<String> exportedSongIds;
  final Map<String, String> exportedSongPaths;
  final List<String> errorMessages;

  Mp3ExportResult({
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

class Mp3ExportService extends ChangeNotifier {
  static final Mp3ExportService _instance = Mp3ExportService._internal();
  factory Mp3ExportService() => _instance;
  Mp3ExportService._internal();

  static const String _prefLastFolderKey = 'last_export_mp3_folder';
  static const int _notificationId = 987654;

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
      LogService().log('Mp3ExportService: Export cancelled by user.');
      notifyListeners();
    }
  }

  String _sanitizeFileName(String name) {
    // Replace invalid characters for filesystems
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  File _getUniqueDestinationFile(Directory dir, String baseName, String ext) {
    String cleanBase = _sanitizeFileName(baseName);
    if (cleanBase.isEmpty) cleanBase = 'Audio';
    
    File file = File('${dir.path}/$cleanBase$ext');
    int counter = 1;
    while (file.existsSync()) {
      file = File('${dir.path}/$cleanBase ($counter)$ext');
      counter++;
    }
    return file;
  }

  static Future<bool> _exportSingleSongWorker(String sourcePath, String destPath) async {
    try {
      final sourceFile = File(sourcePath);
      if (!sourceFile.existsSync()) return false;

      final rawBytes = await sourceFile.readAsBytes();
      if (rawBytes.isEmpty) return false;

      final decryptedBytes = EncryptionService().encryptData(rawBytes);

      final destFile = File(destPath);
      if (!destFile.parent.existsSync()) {
        destFile.parent.createSync(recursive: true);
      }

      await destFile.writeAsBytes(decryptedBytes, flush: true);

      if (destFile.existsSync() && destFile.lengthSync() > 0) {
        try {
          if (sourceFile.existsSync()) {
            await sourceFile.delete();
          }
        } catch (_) {}
        return true;
      }
    } catch (e) {
      debugPrint('Mp3ExportService _exportSingleSongWorker error: $e');
    }
    return false;
  }

  /// Exports selected songs to non-encrypted MP3 files in destination directory,
  /// and deletes the original encrypted downloaded song files from disk upon successful export.
  Future<Mp3ExportResult> exportSongs({
    required List<SavedSong> songs,
    required String destinationPath,
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
          LogService().log('Mp3ExportService: Stopping loop due to cancellation.');
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

          // Determine clean filename
          String artistPart = song.artist.trim();
          String titlePart = song.title.trim();
          String baseName = artistPart.isNotEmpty ? '$artistPart - $titlePart' : titlePart;
          if (baseName.isEmpty) baseName = 'Track_${song.id}';

          final destFile = _getUniqueDestinationFile(destDir, baseName, '.mp3');

          // Decrypt and write file directly (dart:io is already async, no need for extra isolate)
          final bool success = await _exportSingleSongWorker(
            sourceFile.path,
            destFile.path,
          );

          if (success && await destFile.exists() && await destFile.length() > 0) {
            exportedPaths.add(destFile.path);
            exportedSongIds.add(song.id);
            exportedSongPaths[song.id] = destFile.path;
            _successCount++;
          } else {
            throw Exception('Exported MP3 file is empty or could not be verified');
          }
        } catch (e) {
          LogService().log('Mp3ExportService: Error exporting song ${song.title}: $e');
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

    return Mp3ExportResult(
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
