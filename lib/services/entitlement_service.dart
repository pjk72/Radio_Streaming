import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'backup_service.dart';
import 'log_service.dart';

class EntitlementService extends ChangeNotifier {
  final BackupService _backupService;

  final String _localConfigPath = "lib/utils/json/config.json";
  final String _remoteConfigKey = "entitlements_json";

  Map<String, dynamic> _config = {};
  bool _isLoading = false;
  bool _isUsingLocalConfig = false;
  StreamSubscription? _remoteConfigSubscription;

  EntitlementService(this._backupService) {
    _backupService.addListener(_onAuthChanged);
    _initializeRemoteConfig();
  }

  Future<void> _initializeRemoteConfig() async {
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;

      // Configure Remote Config
      await remoteConfig.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 10),
          minimumFetchInterval: kDebugMode
              ? const Duration(seconds: 0)
              : const Duration(minutes: 5), // Near real-time
        ),
      );

      // Initial fetch and activate
      await refreshConfig();

      // Listen for real-time updates (available in firebase_remote_config ^5.x.x)
      _remoteConfigSubscription = remoteConfig.onConfigUpdated.listen((
        event,
      ) async {
        LogService().log(
          "EntitlementService: Real-time update received from Remote Config.",
        );
        await remoteConfig.activate();
        await _updateConfigFromRemote();
      });
    } catch (e) {
      await _loadLocalConfig("Failed to initialize Remote Config: $e");
    }
  }

  bool get isLoading => _isLoading;
  bool get isUsingLocalConfig => _isUsingLocalConfig;

  void _onAuthChanged() {
    // When login status changes, we might want to re-evaluate UI
    notifyListeners();
  }

  Future<void> refreshConfig() async {
    try {
      _isLoading = true;
      notifyListeners();

      final remoteConfig = FirebaseRemoteConfig.instance;
      final bool updated = await remoteConfig.fetchAndActivate();
      LogService().log(
        "EntitlementService: Remote Config fetchAndActivate completed. Updated: $updated",
      );
      await _updateConfigFromRemote();
    } catch (e) {
      await _loadLocalConfig("Failed to fetch Remote Config: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _updateConfigFromRemote() async {
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      final jsonStr = remoteConfig.getString(_remoteConfigKey);

      LogService().log(
        "EntitlementService: Raw config string for key '$_remoteConfigKey': ${jsonStr.isEmpty ? '(empty)' : '${jsonStr.length} chars'}",
      );

      if (jsonStr.isNotEmpty) {
        final newConfig = jsonDecode(jsonStr);
        _config = newConfig;
        _isUsingLocalConfig = false;
        notifyListeners();
        LogService().log(
          "EntitlementService: Config updated from Remote Config.",
        );
      } else {
        // Debug: Print all available keys to see what we actually fetched
        final allKeys = remoteConfig.getAll();
        LogService().log(
          "EntitlementService: Key '$_remoteConfigKey' not found. Available keys: ${allKeys.keys.toList()}",
        );

        await _loadLocalConfig(
          "Remote Config value is empty for key '$_remoteConfigKey'",
        );
      }
    } catch (e) {
      await _loadLocalConfig("Error parsing Remote Config JSON: $e");
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
    _remoteConfigSubscription?.cancel();
    super.dispose();
  }
}
