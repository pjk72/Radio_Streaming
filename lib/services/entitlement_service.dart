import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'backup_service.dart';
import 'log_service.dart';

class EntitlementService extends ChangeNotifier {
  final BackupService _backupService;

  // The URL where the JSON configuration is hosted.
  // The user can change this to their own Gist/Pastebin/Server URL.
  //final String _configUrl = "https://pjk72.github.io/file.json";
  final String _configUrl =
      "https://gist.github.com/pjk72/f4978bcc3b7518974b5f64dfd19afa2e/raw/file.json";
  final String _localConfigPath = "lib/utils/json/config.json";

  Map<String, dynamic> _config = {};
  Timer? _refreshTimer;
  bool _isLoading = false;
  bool _isUsingLocalConfig = false;

  EntitlementService(this._backupService) {
    _backupService.addListener(_onAuthChanged);
    _startPolling();
    refreshConfig(); // Initial fetch
  }

  bool get isLoading => _isLoading;
  bool get isUsingLocalConfig => _isUsingLocalConfig;

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
        _isUsingLocalConfig = false;
        LogService().log(
          "EntitlementService: Config updated successfully from remote",
        );
        notifyListeners();
      } else {
        await _loadLocalConfig(
          "Remote server returned status ${response.statusCode}",
        );
      }
    } catch (e) {
      await _loadLocalConfig("Failed to fetch remote config: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadLocalConfig(String reason) async {
    try {
      LogService().log(
        "EntitlementService: $reason. Falling back to local config.",
      );
      final String localContent = await rootBundle.loadString(_localConfigPath);
      _config = jsonDecode(localContent);
      _isUsingLocalConfig = true;
      LogService().log("EntitlementService: Local config loaded successfully.");
    } catch (e) {
      LogService().log("EntitlementService: Error loading local config: $e");
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

    final featureData = features[featureKey];

    // Handle both List (old format) and Map (new format with limits)
    List<String> allowedEntities = [];
    if (featureData is List) {
      allowedEntities = List<String>.from(featureData);
    } else if (featureData is Map) {
      // If it's a map, a feature is enabled if the limit is not 0
      featureData.forEach((key, value) {
        if (value is num && value != 0) {
          allowedEntities.add(key.toString());
        } else if (value is! num) {
          // If value is not a number, we assume it's "enabled" if present
          allowedEntities.add(key.toString());
        }
      });
    }

    if (allowedEntities.isEmpty) return false;

    LogService().log(
      "EntitlementService: Checking feature $featureKey for $allowedEntities",
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
        LogService().log("EntitlementService: Checking group $entity");
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

  /// Returns the limit for a feature (e.g., max downloads).
  /// -1: unlimited, 0: disabled, >0: specific count.
  /// If multiple groups match, the highest limit is returned (-1 being highest).
  int getFeatureLimit(String featureKey) {
    if (_config.isEmpty) return 0;

    final features = _config['features'] as Map<String, dynamic>?;
    if (features == null || !features.containsKey(featureKey)) return 0;

    final featureData = features[featureKey];
    if (featureData is! Map) {
      // If it's a list, we assume -1 (unlimited) for everyone in the list
      return isFeatureEnabled(featureKey) ? -1 : 0;
    }

    final Map<String, dynamic> limitsMap = Map<String, dynamic>.from(
      featureData,
    );
    final currentUser = _backupService.currentUser;
    final userEmail = currentUser?.email;
    final groups = _config['groups'] as Map<String, dynamic>?;

    int maxLimit = 0; // Default to blocked

    limitsMap.forEach((entity, limit) {
      int currentLimit = (limit is num)
          ? limit.toInt()
          : (isFeatureEnabled(featureKey) ? -1 : 0);
      bool matches = false;

      if (entity.toLowerCase() == "all") {
        matches = true;
      } else if (userEmail != null) {
        if (entity.toLowerCase() == "all login") {
          matches = true;
        } else if (entity == userEmail) {
          matches = true;
        } else if (groups != null && groups.containsKey(entity)) {
          final groupEmails = List<String>.from(groups[entity] ?? []);
          if (groupEmails.contains(userEmail)) {
            matches = true;
          }
        }
      }

      if (matches) {
        if (currentLimit == -1) {
          maxLimit = -1;
        } else if (maxLimit != -1 && currentLimit > maxLimit) {
          maxLimit = currentLimit;
        }
      }
    });

    return maxLimit;
  }

  @override
  void dispose() {
    _backupService.removeListener(_onAuthChanged);
    _refreshTimer?.cancel();
    super.dispose();
  }
}
