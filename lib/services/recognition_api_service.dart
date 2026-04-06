import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'log_service.dart';

class RecognitionApiService {
  final String _host = 'shazam-song-recognition-api.p.rapidapi.com';
  // Backup key in case Remote Config is unavailable
  final String _defaultApiKey = '65c517cd98mshd509565706f012ep1e49f3jsne80c01e37828';

  static bool _isGlobalRecognizing = false;
  http.Client? _activeClient;

  Future<Map<String, dynamic>?> identifyStream(String streamUrl) async {
    if (_isGlobalRecognizing) {
      LogService().log(
        "RecognitionAPI: Global lock active, ignoring duplicate request.",
      );
      return null;
    }
    _isGlobalRecognizing = true;
    _activeClient = http.Client();
    try {
      final resolvedUrl = await _resolveStreamUrl(streamUrl);
      if (_activeClient == null) return null;
      LogService().log("RecognitionAPI: Resolved URL: $resolvedUrl");

      // 1. Get the best API key based on global usage
      final apiKey = await _getBestApiKey();
      LogService().log("RecognitionAPI: Using key: ${apiKey.substring(0, 8)}...");

      // 2. Download ~3 seconds of the stream (roughly 80KB of mp3)
      final Uint8List? audioData = await _downloadStreamChunk(
        resolvedUrl,
        80 * 1024,
      );

      if (_activeClient == null) return null;
      if (audioData == null || audioData.isEmpty) {
        LogService().log("RecognitionAPI: Failed to download stream chunk.");
        return null;
      }

      // 3. Send MP3 straight to recognition service (Shazam API)
      final uri = Uri.https(_host, '/recognize/file');

      if (_activeClient == null) return null;
      final response = await _activeClient!.post(
        uri,
        headers: {
          'x-rapidapi-key': apiKey,
          'x-rapidapi-host': _host,
          'Content-Type': 'application/octet-stream',
        },
        body: audioData,
      );

      // 4. Update usage in Firestore after attempt (regardless of result)
      _incrementKeyUsage(apiKey);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data; // Return raw recognition JSON (Shazam format)
      } else if (response.statusCode == 429 || 
                 (response.body.toLowerCase().contains("you have exceeded") || 
                  response.body.toLowerCase().contains("quota"))) {
        // DETECT EXHAUSTED CREDITS
        LogService().log("RecognitionAPI [MultiKey]: Key $apiKey EXHAUSTED. Disabling for today.");
        _disableKey(apiKey);
      } else {
        LogService().log(
          "RecognitionAPI HTTP Error: ${response.statusCode} - ${response.body}",
        );
      }
    } catch (e) {
      if (_activeClient != null) {
        LogService().log("RecognitionAPI Exception: $e");
      } else {
        LogService().log("RecognitionAPI Recognition Cancelled.");
      }
    } finally {
      _activeClient?.close();
      _activeClient = null;
      _isGlobalRecognizing = false;
    }
    return null;
  }

  /// Fetches the list of keys from Remote Config and selects the one with the lowest usage in Firestore.
  /// Automatically resets usage and reactivates keys if they haven't been used today.
  Future<String> _getBestApiKey() async {
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      // Fetch keys from Remote Config (parameter: 'shazam_api_keys' as JSON list)
      await remoteConfig.fetchAndActivate().timeout(const Duration(seconds: 5));
      final String keysJson = remoteConfig.getString('shazam_api_keys');
      
      List<String> keys = [_defaultApiKey];
      if (keysJson.isNotEmpty) {
        try {
          final dynamic decoded = jsonDecode(keysJson);
          if (decoded is Map && decoded.containsKey('recognition_key')) {
            final List<dynamic> keyList = decoded['recognition_key'] as List;
            if (keyList.isNotEmpty) {
              keys = keyList.map((e) => e.toString()).toList();
            }
          }
        } catch (_) {}
      }

      if (keys.length == 1) return keys[0];

      // Query Firestore for global usage counts
      final firestore = FirebaseFirestore.instance;
      final snapshot = await firestore.collection('api_keys_usage').get().timeout(const Duration(seconds: 5));
      
      final now = DateTime.now();
      final Map<String, int> usageMap = {};
      final List<String> activeKeys = [];

      for (var key in keys) {
        // Find data for this key if it exists in Firestore
        final doc = snapshot.docs.where((d) => d.id == key).firstOrNull;
        
        if (doc != null) {
          final Map<String, dynamic> data = doc.data();
          final bool isDisabled = data['is_disabled'] ?? false;
          final Timestamp? lastUsedTs = data['last_used'] as Timestamp?;
          final DateTime? lastUsed = lastUsedTs?.toDate();

          // DAILY RESET LOGIC:
          // If the key wasn't used today, or was disabled on a previous day, reactivate and reset count.
          bool isDifferentDay = lastUsed == null || 
                               lastUsed.year != now.year || 
                               lastUsed.month != now.month || 
                               lastUsed.day != now.day;

          if (isDifferentDay) {
            // Reset count for the day and reactivate
            usageMap[key] = 0;
            activeKeys.add(key);
            // Non-blocking update in Firestore to keep it clean
            _resetKeyUsage(key);
          } else if (!isDisabled) {
            // Key is still active from today
            usageMap[key] = (data['count'] as num).toInt();
            activeKeys.add(key);
          } else {
            // Key is explicitly disabled for today - Do not add to activeKeys
            LogService().log("RecognitionAPI [MultiKey]: Key ${key.substring(0, 8)}... skipped (EXHAUSTED).");
          }
        } else {
          // New key never seen before
          usageMap[key] = 0;
          activeKeys.add(key);
        }
      }

      // If all keys are exhausted, fallback to default or first key as desperate attempt
      if (activeKeys.isEmpty) {
        LogService().log("RecognitionAPI [MultiKey]: ALL KEYS EXHAUSTED! Trying first key anyway.");
        return keys[0];
      }

      // Pick the active key with minimum usage
      String bestKey = activeKeys[0];
      int minUsage = usageMap[bestKey] ?? 0;

      for (var key in activeKeys) {
        final usage = usageMap[key] ?? 0;
        if (usage < minUsage) {
          minUsage = usage;
          bestKey = key;
        }
      }

      return bestKey;
    } catch (e) {
      LogService().log("RecognitionAPI [MultiKey]: Error selecting key: $e. Falling back to default.");
      return _defaultApiKey;
    }
  }

  /// Increments the usage counter in Firestore for a specific key.
  void _incrementKeyUsage(String key) {
    try {
      FirebaseFirestore.instance.collection('api_keys_usage').doc(key).set({
        'count': FieldValue.increment(1),
        'last_used': FieldValue.serverTimestamp(),
        'is_disabled': false, // Ensure it stays active while incrementing
      }, SetOptions(merge: true));
    } catch (e) {
      LogService().log("RecognitionAPI [MultiKey]: Failed to increment usage for key: $e");
    }
  }

  /// Disables a key in Firestore until the next day reset.
  void _disableKey(String key) {
    try {
      FirebaseFirestore.instance.collection('api_keys_usage').doc(key).set({
        'is_disabled': true,
        'disabled_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      LogService().log("RecognitionAPI [MultiKey]: Failed to disable key: $e");
    }
  }

  /// Resets usage and reactivates a key for a new day.
  void _resetKeyUsage(String key) {
    try {
      FirebaseFirestore.instance.collection('api_keys_usage').doc(key).set({
        'count': 0,
        'is_disabled': false,
        'last_reset': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      LogService().log("RecognitionAPI [MultiKey]: Failed to reset key: $e");
    }
  }

  void cancel() {
    LogService().log("RecognitionAPI: Cancelling active recognition...");
    _activeClient?.close();
    _activeClient = null;
  }

  Future<Uint8List?> _downloadStreamChunk(String url, int maxSize) async {
    if (_activeClient == null) return null;
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'VLC/3.0.18 LibVLC/3.0.18';

      final response = await _activeClient!
          .send(request)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return null;

      final List<int> buffer = [];
      await for (var chunk in response.stream) {
        if (_activeClient == null) return null;
        buffer.addAll(chunk);
        if (buffer.length >= maxSize) break;
      }
      return Uint8List.fromList(buffer);
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveStreamUrl(String initialUrl) async {
    String currentUrl = initialUrl;
    for (int i = 0; i < 5; i++) {
      if (_activeClient == null) return currentUrl;
      final lower = currentUrl.toLowerCase();

      if (lower.endsWith('.mp3') ||
          lower.endsWith('.aac') ||
          lower.endsWith('.mp4') ||
          lower.endsWith('.ts')) {
        return currentUrl;
      }

      bool isPlaylist =
          lower.contains('.m3u8') ||
          lower.contains('.m3u') ||
          lower.contains('.pls');

      if (!isPlaylist) return currentUrl;

      try {
        final uri = Uri.parse(currentUrl);
        if (_activeClient == null) return currentUrl;

        final response = await _activeClient!.get(uri);
        if (response.statusCode != 200) return currentUrl;

        final body = response.body;
        final lines = body.split('\n');
        String? candidate;

        if (body.contains('[playlist]')) {
          final match = lines.firstWhere(
            (l) => l.toLowerCase().startsWith('file1='),
            orElse: () => '',
          );
          if (match.isNotEmpty) {
            candidate = match.split('=').last.trim();
          }
        } else {
          final validLines = lines
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty && !l.startsWith('#'))
              .toList();
          if (validLines.isNotEmpty) candidate = validLines.last;
        }

        if (candidate != null && candidate.isNotEmpty) {
          if (candidate.startsWith('http')) {
            currentUrl = candidate;
          } else {
            currentUrl = uri.resolve(candidate).toString();
          }
          continue;
        } else {
          return currentUrl;
        }
      } catch (e) {
        return currentUrl;
      }
    }
    return currentUrl;
  }
}
