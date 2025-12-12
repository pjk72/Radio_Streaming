import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

class BackupService extends ChangeNotifier {
  // Scopes required for Drive App Data folder
  // Use explicit string validation to avoid type inferrence issues
  static const List<String> _scopes = [
    'https://www.googleapis.com/auth/drive.appdata',
  ];

  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: _scopes);

  GoogleSignInAccount? _currentUser;
  GoogleSignInAccount? get currentUser => _currentUser;

  bool get isSignedIn => _currentUser != null;

  BackupService() {
    _googleSignIn.onCurrentUserChanged.listen((account) {
      _currentUser = account;
      notifyListeners();
    });
  }

  Future<void> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account != null) {
        _currentUser = account;
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Google Sign In Error: $e");
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
      debugPrint("Silent Sign In Error: $e");
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
  }

  /// Uploads backup data (JSON string) to Google Drive App Data folder
  Future<void> uploadBackup(
    String jsonContent, {
    String filename = "radio_stream_backup.json",
  }) async {
    if (_currentUser == null) throw Exception("Not signed in");

    // Get authenticated HTTP client
    final httpClient = await _googleSignIn.authenticatedClient();
    if (httpClient == null) throw Exception("Failed to authenticate client");

    final driveApi = drive.DriveApi(httpClient);

    // Search for existing file
    final fileList = await driveApi.files.list(
      spaces: 'appDataFolder',
      q: "name = '$filename' and trashed = false",
    );

    final media = drive.Media(
      Future.value(utf8.encode(jsonContent)).asStream(),
      utf8.encode(jsonContent).length,
    );

    if (fileList.files != null && fileList.files!.isNotEmpty) {
      // Update existing
      final fileId = fileList.files!.first.id!;
      final fileMetadata = drive.File();
      fileMetadata.name = filename;

      await driveApi.files.update(fileMetadata, fileId, uploadMedia: media);
      debugPrint("Backup updated: $fileId");
    } else {
      // Create new
      final fileMetadata = drive.File();
      fileMetadata.name = filename;
      fileMetadata.parents = ['appDataFolder'];

      await driveApi.files.create(fileMetadata, uploadMedia: media);
      debugPrint("Backup created");
    }
  }

  /// Downloads backup data from Google Drive
  Future<String?> downloadBackup({
    String filename = "radio_stream_backup.json",
  }) async {
    if (_currentUser == null) throw Exception("Not signed in");

    final httpClient = await _googleSignIn.authenticatedClient();
    if (httpClient == null) throw Exception("Failed to authenticate client");

    final driveApi = drive.DriveApi(httpClient);

    final fileList = await driveApi.files.list(
      spaces: 'appDataFolder',
      q: "name = '$filename' and trashed = false",
    );

    if (fileList.files == null || fileList.files!.isEmpty) {
      return null; // No backup found
    }

    final fileId = fileList.files!.first.id!;
    final media =
        await driveApi.files.get(
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
