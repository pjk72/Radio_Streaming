import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'backup_service.dart';
import 'log_service.dart';

class EntitlementService extends ChangeNotifier {
  final BackupService _backupService;

  // The URL where the JSON configuration is hosted.
  // The user can change this to their own Gist/Pastebin/Server URL.
  // "https://pjk72.github.io/Radio_Streaming/docs/json/file.json";
  final String _configUrl = "https://pjk72.github.io/file.json";
  // final String _configUrl = "https://jsonhosting.com/api/json/444b058a";

  Map<String, dynamic> _config = {};
  Timer? _refreshTimer;
  bool _isLoading = false;

  EntitlementService(this._backupService) {
    _backupService.addListener(_onAuthChanged);
    _startPolling();
    refreshConfig(); // Initial fetch
  }

  bool get isLoading => _isLoading;

  void _onAuthChanged() {
    // When login status changes, we might want to re-evaluate UI
    notifyListeners();
  }

  void _startPolling() {
    // Check for updates every 5 minutes to allow "near real-time" interaction
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 15), (timer) {
      refreshConfig();
    });
  }

  Future<void> refreshConfig() async {
    try {
      _isLoading = true;
      final response = await http
          .get(Uri.parse(_configUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final newConfig = jsonDecode(response.body);
        _config = newConfig;
        LogService().log(
          "EntitlementService: Config updated successfully : ${response.body}",
        );
        notifyListeners();
      }
    } catch (e) {
      LogService().log("EntitlementService: Failed to fetch config: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Checks if a feature is enabled for the current user.
  /// featureKey: e.g., 'download_songs', 'recognize_songs'
  bool isFeatureEnabled(String featureKey) {
    if (_config.isEmpty) return false;

    final features = _config['features'] as Map<String, dynamic>?;
    if (features == null || !features.containsKey(featureKey)) {
      return false; // Feature not defined
    }

    final allowedEntities = List<String>.from(features[featureKey] ?? []);
    LogService().log(
      "EntitlementService: Checking feature $allowedEntities"
    );
    // 1. Check "All" (Everyone)
    if (allowedEntities.any((e) => e.toLowerCase() == "all")) {
      return true;
    }

    final currentUser = _backupService.currentUser;
    final userEmail = currentUser?.email;

    // 2. Check "All Login" (Any logged in user)
    if (userEmail != null &&
        allowedEntities.any((e) => e.toLowerCase() == "all login")) {
      return true;
    }

    if (userEmail == null) return false;

    // 3. Check individual email
    if (allowedEntities.contains(userEmail)) {
      return true;
    }

    // 4. Check Groups
    final groups = _config['groups'] as Map<String, dynamic>?;
    if (groups != null) {
      for (final entity in allowedEntities) {
        if (groups.containsKey(entity)) {
          final groupEmails = List<String>.from(groups[entity] ?? []);
          if (groupEmails.contains(userEmail)) {
            return true;
          }
        }
      }
    }

    return false;
  }

  @override
  void dispose() {
    _backupService.removeListener(_onAuthChanged);
    _refreshTimer?.cancel();
    super.dispose();
  }
}
