import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:developer' as developer;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

/// Keys that represent the user's actual data inside a backup payload.
const List<String> kBackupCoreKeys = [
  'stations',
  'playlists',
  'favorites',
  'user_play_history',
  'history_metadata',
  'followed_artists',
  'followed_albums',
  'promoted_playlists',
];

/// Returns true when the backup payload carries no user data at all, so an
/// automatic backup would overwrite a valid backup with an empty one.
bool isBackupPayloadEmpty(Map<String, dynamic> data) {
  for (final key in kBackupCoreKeys) {
    final value = data[key];
    if (value is List && value.isNotEmpty) return false;
    if (value is Map && value.isNotEmpty) return false;
  }
  return true;
}

/// Metadata of a single backup version stored on Google Drive.
class BackupVersion {
  final String fileId;
  final int timestamp;
  final String type; // 'auto' | 'manual' | 'unknown'

  const BackupVersion({
    required this.fileId,
    required this.timestamp,
    this.type = 'unknown',
  });
}

class BackupService extends ChangeNotifier {
  // Scopes required for Drive App Data folder
  // Use explicit string validation to avoid type inferrence issues
  static const List<String> _scopes = [
    'https://www.googleapis.com/auth/drive.appdata',
  ];

  static const String latestFilename = 'musicstream_backup.json';
  static const String versionPrefix = 'musicstream_backup_';
  static const int maxVersions = 15;

  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: _scopes);

  GoogleSignInAccount? _currentUser;
  GoogleSignInAccount? get currentUser => _currentUser;

  bool get isSignedIn => _currentUser != null;

  BackupService() {
    debugPrint("BackupService: Initializing...");
    try {
      _googleSignIn.onCurrentUserChanged.listen((account) {
        _currentUser = account;
        notifyListeners();
      });
      debugPrint("BackupService: Listener attached.");
    } catch (e) {
      debugPrint("BackupService: Error attaching listener: $e");
    }
  }

  Future<void> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account != null) {
        _currentUser = account;
        notifyListeners();
      }
    } catch (e) {
      developer.log("Google Sign In Error: $e");
      rethrow;
    }
  }

  Future<void> signInSilently() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        _currentUser = account;
        notifyListeners();
      }
    } catch (e) {
      developer.log("Silent Sign In Error: $e");
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
  }

  Future<drive.DriveApi> _requireApi() async {
    final httpClient = await _googleSignIn.authenticatedClient();
    if (httpClient == null) throw Exception("Failed to authenticate client");
    return drive.DriveApi(httpClient);
  }

  drive.Media _buildMedia(String jsonContent) {
    final bytes = utf8.encode(jsonContent);
    return drive.Media(Future.value(bytes).asStream(), bytes.length);
  }

  /// Uploads backup data (JSON string) to Google Drive App Data folder.
  ///
  /// The latest copy is always stored in [latestFilename] (backward
  /// compatible) and a versioned copy `musicstream_backup_<ts>.json` is
  /// created as well, keeping only the newest [maxVersions] versions.
  Future<void> uploadBackup(
    String jsonContent, {
    String filename = latestFilename,
    String type = 'auto',
    int? timestamp,
  }) async {
    if (_currentUser == null) throw Exception("Not signed in");

    final driveApi = await _requireApi();

    // Search for existing file
    final fileList = await driveApi.files.list(
      spaces: 'appDataFolder',
      q: "name = '$filename' and trashed = false",
    );

    final media = _buildMedia(jsonContent);

    if (fileList.files != null && fileList.files!.isNotEmpty) {
      // Update existing
      final fileId = fileList.files!.first.id!;
      final fileMetadata = drive.File();
      fileMetadata.name = filename;
      fileMetadata.description = type;

      await driveApi.files.update(fileMetadata, fileId, uploadMedia: media);
      developer.log("Backup updated: $fileId");
    } else {
      // Create new
      final fileMetadata = drive.File();
      fileMetadata.name = filename;
      fileMetadata.parents = ['appDataFolder'];
      fileMetadata.description = type;

      await driveApi.files.create(fileMetadata, uploadMedia: media);
      developer.log("Backup created");
    }

    // Versioned copy for the restore history (last 15)
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    try {
      await _createVersion(driveApi, jsonContent, ts, type);
      await _pruneVersions(driveApi);
    } catch (e) {
      // Never fail the whole backup because of history bookkeeping
      developer.log("Backup versioning failed: $e");
    }
  }

  Future<void> _createVersion(
    drive.DriveApi api,
    String jsonContent,
    int ts,
    String type,
  ) async {
    final metadata = drive.File();
    metadata.name = '$versionPrefix$ts.json';
    metadata.parents = ['appDataFolder'];
    metadata.description = type;

    await api.files.create(metadata, uploadMedia: _buildMedia(jsonContent));
    developer.log("Backup version created: ${metadata.name}");
  }

  Future<List<drive.File>> _listVersionFiles(drive.DriveApi api) async {
    final list = await api.files.list(
      spaces: 'appDataFolder',
      q: "name contains '$versionPrefix' and trashed = false",
      pageSize: 100,
      $fields: 'files(id,name,description)',
    );
    return list.files ?? [];
  }

  static int _tsFromVersionName(String name) {
    final raw = name.substring(versionPrefix.length).replaceAll('.json', '');
    return int.tryParse(raw) ?? 0;
  }

  Future<void> _pruneVersions(drive.DriveApi api) async {
    final files = await _listVersionFiles(api);
    if (files.length <= maxVersions) return;

    files.sort((a, b) => _tsFromVersionName(b.name ?? '')
        .compareTo(_tsFromVersionName(a.name ?? '')));

    for (final f in files.skip(maxVersions)) {
      if (f.id == null) continue;
      try {
        await api.files.delete(f.id!);
        developer.log("Backup version pruned: ${f.name}");
      } catch (e) {
        developer.log("Backup prune failed for ${f.name}: $e");
      }
    }
  }

  /// Lists the available backup versions (newest first).
  ///
  /// Falls back to the legacy single file when no versioned copies exist
  /// (e.g. backups created by an older app version).
  Future<List<BackupVersion>> listBackups() async {
    if (_currentUser == null) throw Exception("Not signed in");

    final driveApi = await _requireApi();

    final files = await _listVersionFiles(driveApi);
    final versions = files.where((f) => f.id != null).map((f) {
      return BackupVersion(
        fileId: f.id!,
        timestamp: _tsFromVersionName(f.name ?? ''),
        type: f.description ?? 'unknown',
      );
    }).where((v) => v.timestamp > 0).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    if (versions.isNotEmpty) {
      return versions.take(maxVersions).toList();
    }

    // Fallback: legacy single-file backup
    final latest = await driveApi.files.list(
      spaces: 'appDataFolder',
      q: "name = '$latestFilename' and trashed = false",
      pageSize: 1,
      $fields: 'files(id,description,modifiedTime)',
    );
    final file = latest.files != null && latest.files!.isNotEmpty
        ? latest.files!.first
        : null;
    if (file == null || file.id == null) return [];

    final modified = file.modifiedTime?.millisecondsSinceEpoch ?? 0;
    return [
      BackupVersion(
        fileId: file.id!,
        timestamp: modified,
        type: file.description ?? 'unknown',
      ),
    ];
  }

  /// Uploads backup data (JSON string) to Google Drive App Data folder
  Future<String?> downloadBackup({
    String filename = latestFilename,
  }) async {
    if (_currentUser == null) throw Exception("Not signed in");

    final driveApi = await _requireApi();

    final fileList = await driveApi.files.list(
      spaces: 'appDataFolder',
      q: "name = '$filename' and trashed = false",
    );

    if (fileList.files == null || fileList.files!.isEmpty) {
      return null; // No backup found
    }

    return _downloadById(driveApi, fileList.files!.first.id!);
  }

  /// Downloads a specific backup version by its Drive file id.
  Future<String> downloadBackupById(String fileId) async {
    if (_currentUser == null) throw Exception("Not signed in");
    final driveApi = await _requireApi();
    return _downloadById(driveApi, fileId);
  }

  Future<String> _downloadById(drive.DriveApi api, String fileId) async {
    final media = await api.files.get(
          fileId,
          downloadOptions: drive.DownloadOptions.fullMedia,
        )
        as drive.Media;

    final List<int> dataStore = [];
    await media.stream.forEach((element) {
      dataStore.addAll(element);
    });

    return utf8.decode(dataStore);
  }
}
