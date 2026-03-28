import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup_service.dart';
import 'log_service.dart';

class EntitlementService extends ChangeNotifier {
  final BackupService _backupService;

  final String _remoteConfigKey = "entitlements_json";
  static const String _cacheConfigKey = "cached_entitlements";
  static const String _cacheUserEmailKey = "cached_user_email";
  static const String _cacheUserNameKey = "cached_user_name";

  Map<String, dynamic> _config = {};
  bool _isLoading = false;
  bool _isUsingCachedConfig = false;
  String? _cachedUserEmail;
  String? _cachedUserName;

  /// Public getters for the cached user info
  String? get cachedUserEmail => _cachedUserEmail;
  String? get cachedUserName => _cachedUserName;

  StreamSubscription? _remoteConfigSubscription;
  StreamSubscription? _connectivitySubscription;

  EntitlementService(this._backupService) {
    _backupService.addListener(_onAuthChanged);
    _loadUserIdentityFromCache();
    _initializeRemoteConfig();
    _setupConnectivityListener();
  }

  Future<void> _loadUserIdentityFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedUserEmail = prefs.getString(_cacheUserEmailKey);
      _cachedUserName = prefs.getString(_cacheUserNameKey);
      // No log or notify here to keep it silent unless config also arrives/fails
    } catch (e) {
      LogService().log("EntitlementService: Error loading user identity: $e");
    }
  }

  void _setupConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      final hasConnection = !results.contains(ConnectivityResult.none);
      if (hasConnection && _isUsingCachedConfig && !_isLoading) {
        LogService().log(
          "EntitlementService: Connection restored. Forcing remote config refresh...",
        );
        refreshConfig();
      }
    });
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
      await _loadCachedConfig("Failed to initialize Remote Config: $e");
    }
  }

  bool get isLoading => _isLoading;
  bool get isUsingCachedConfig => _isUsingCachedConfig;
  bool get isUsingLocalConfig =>
      _isUsingCachedConfig; // For backward compatibility

  void _onAuthChanged() {
    // When login status changes, we update the cache with new user info
    _updateUserCache();
    notifyListeners();
  }

  Future<void> _updateUserCache() async {
    try {
      final user = _backupService.currentUser;
      final prefs = await SharedPreferences.getInstance();
      if (user != null) {
        await prefs.setString(_cacheUserEmailKey, user.email);
        await prefs.setString(_cacheUserNameKey, user.displayName ?? "");
        LogService().log(
          "EntitlementService: User info updated in cache (Logged In).",
        );
      } else {
        // Handle guest/logout by storing explicit "GUEST" value
        await prefs.setString(_cacheUserEmailKey, "GUEST");
        await prefs.setString(_cacheUserNameKey, "GUEST");
        LogService().log(
          "EntitlementService: User info updated in cache (Guest / Logged Out).",
        );
      }

      // Update memory values
      _cachedUserEmail = prefs.getString(_cacheUserEmailKey);
      _cachedUserName = prefs.getString(_cacheUserNameKey);

      _logCachedData();
    } catch (e) {
      LogService().log("EntitlementService: Error updating user cache: $e");
    }
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
      await _loadCachedConfig("Failed to fetch Remote Config: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _updateConfigFromRemote() async {
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      final jsonStr = remoteConfig.getString(_remoteConfigKey);

      if (jsonStr.isNotEmpty) {
        final newConfig = jsonDecode(jsonStr);
        _config = newConfig;
        _isUsingCachedConfig = false;
        notifyListeners();
        LogService().log(
          "EntitlementService: Config updated from Remote Config.",
        );

        // Cache the config and user info
        _cacheConfigAndUser(jsonStr);
      } else {
        // Debug: Print all available keys to see what we actually fetched
        final allKeys = remoteConfig.getAll();
        LogService().log(
          "EntitlementService: ERROR - Key '$_remoteConfigKey' is empty or missing.",
        );
        LogService().log(
          "EntitlementService: All available keys found on this client: ${allKeys.keys.toList()}",
        );

        // Also log sources to see if we are getting real remote data
        allKeys.forEach((key, value) {
          LogService().log("Config Item: $key (Source: ${value.source})");
        });

        await _loadCachedConfig(
          "Remote Config value is empty for key '$_remoteConfigKey'",
        );
      }
    } catch (e) {
      await _loadCachedConfig("Error parsing Remote Config JSON: $e");
    }
  }

  Future<void> _cacheConfigAndUser(String jsonStr) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheConfigKey, jsonStr);
      LogService().log("EntitlementService: Config cached.");

      // Always update user info as well to ensure it's in sync
      await _updateUserCache();
    } catch (e) {
      LogService().log("EntitlementService: Error caching config: $e");
    }
  }

  Future<void> _logCachedData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedConfig = prefs.getString(_cacheConfigKey);
      final cachedEmail = prefs.getString(_cacheUserEmailKey);
      final cachedName = prefs.getString(_cacheUserNameKey);

      // Sync with memory
      _cachedUserEmail = cachedEmail;
      _cachedUserName = cachedName;

      LogService().log("--- CACHE DATA START ---");
      LogService().log("[Cached] Config: ${cachedConfig ?? 'None'}");
      LogService().log("[Cached] User Email: ${cachedEmail ?? 'None'}");
      LogService().log("[Cached] User Name: ${cachedName ?? 'None'}");
      LogService().log("--- CACHE DATA END ---");
    } catch (e) {
      LogService().log("EntitlementService: Error reading cache for log: $e");
    }
  }

  Future<void> _loadCachedConfig(String reason) async {
    try {
      LogService().log(
        "EntitlementService: $reason. Falling back to cached config.",
      );
      final prefs = await SharedPreferences.getInstance();
      final String? cachedContent = prefs.getString(_cacheConfigKey);

      if (cachedContent != null && cachedContent.isNotEmpty) {
        _config = jsonDecode(cachedContent);
        _isUsingCachedConfig = true;
        LogService().log(
          "EntitlementService: Cached config loaded successfully.",
        );
      } else {
        LogService().log("EntitlementService: No cached config available.");
        // If no cache, we might stay empty or handle as error
      }

      // Also ensure memory values for user are updated on config load
      _cachedUserEmail = prefs.getString(_cacheUserEmailKey);
      _cachedUserName = prefs.getString(_cacheUserNameKey);

      notifyListeners();
    } catch (e) {
      LogService().log("EntitlementService: Error loading cached config: $e");
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
    String? userEmail = currentUser?.email;

    // Fallback to cache (for Android Auto or background states where BackupService may be null)
    if (userEmail == null || userEmail.isEmpty) {
      if (_cachedUserEmail != null &&
          _cachedUserEmail != "GUEST" &&
          _cachedUserEmail != "None") {
        userEmail = _cachedUserEmail;
      }
    }

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
    String? userEmail = currentUser?.email;

    // Fallback to cache (for Android Auto or background states where BackupService may be null)
    if (userEmail == null || userEmail.isEmpty) {
      if (_cachedUserEmail != null &&
          _cachedUserEmail != "GUEST" &&
          _cachedUserEmail != "None") {
        userEmail = _cachedUserEmail;
      }
    }

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
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}
