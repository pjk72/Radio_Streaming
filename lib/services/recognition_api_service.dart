import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'log_service.dart';

class RecognitionApiService {
  final String _host = 'shazam-song-recognition-api.p.rapidapi.com';
  // Backup key in case Remote Config is unavailable
  final String _defaultApiKey =
      '65c517cd98mshd509565706f012ep1e49f3jsne80c01e37828';

  // New API constants (Soluzione 2)
  static const String _apiUrl2 =
      "https://shazam-music-recognition1.p.rapidapi.com/api/recognize";
  static const String _apiHost2 = "shazam-music-recognition1.p.rapidapi.com";
  static const String _apiKey2 =
      "937107fc2fmsh3f14e2e149d183cp1a7b28jsn5745ab269835";

  static bool _isGlobalRecognizing = false;
  http.Client? _activeClient;

  static final ValueNotifier<bool> isShazamDisabled = ValueNotifier<bool>(false);

  static Future<void> checkKeysAvailability() async {
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      final String keysJson = remoteConfig.getString('shazam_api_keys');
      List<String> keys2 = ['937107fc2fmsh3f14e2e149d183cp1a7b28jsn5745ab269835'];
      
      if (keysJson.isNotEmpty) {
        try {
          final dynamic decoded = jsonDecode(keysJson);
          if (decoded is Map) {
            if (decoded.containsKey('recognition_key_2')) {
              final List<dynamic> k2 = decoded['recognition_key_2'] as List;
              if (k2.isNotEmpty) keys2 = k2.map((e) => e.toString()).toList();
            }
          }
        } catch (_) {}
      }
      
      final firestore = FirebaseFirestore.instance;
      final snapshot = await firestore
          .collection('api_keys_usage')
          .get()
          .timeout(const Duration(seconds: 5));
          
      final now = DateTime.now();
      bool anyActive = false;
      
      void checkList(List<String> keys, int solIndex) {
        for (var key in keys) {
          final doc = snapshot.docs.where((d) => d.id == key).firstOrNull;
          if (doc == null) {
            anyActive = true; 
            continue;
          }
          final data = doc.data();
          final bool isDisabled = data['is_disabled_$solIndex'] ?? false;
          final Timestamp? lastUsedTs = data['last_used_$solIndex'] as Timestamp?;
          final DateTime? lastUsed = lastUsedTs?.toDate();
          
          final Timestamp? disabledAtTs = data['disabled_at_$solIndex'] as Timestamp?;
          final DateTime? disabledAt = disabledAtTs?.toDate();

          DateTime? mostRecentActivity = lastUsed;
          if (disabledAt != null && (mostRecentActivity == null || disabledAt.isAfter(mostRecentActivity))) {
            mostRecentActivity = disabledAt;
          }
          
          bool isDifferentDay = mostRecentActivity == null ||
              mostRecentActivity.year != now.year ||
              mostRecentActivity.month != now.month ||
              mostRecentActivity.day != now.day;
              
          if (isDifferentDay || !isDisabled) {
            anyActive = true;
          }
        }
      }
      
      // Il radar del microfono poggia solo sulla soluzione 2. 
      // Ignoriamo lo stato della soluzione 1 per disabilitare il bottone visivo
      checkList(keys2, 2);
      
      isShazamDisabled.value = !anyActive;
    } catch (e) {
      LogService().log("RecognitionAPI [InitCheck]: Error $e");
    }
  }

  Future<Map<String, dynamic>?> identifyFromAudioBytes(Uint8List audioData) async {
    _activeClient = http.Client();
    try {
      LogService().log("RecognitionAPI: Identifying from microphone bytes...");
      
      final result = await _trySolutionWithRetry(2, audioData);
      return result;
    } catch (e) {
      LogService().log("RecognitionAPI Exception (Microphone): $e");
    } finally {
      _activeClient?.close();
      _activeClient = null;
    }
    return null;
  }

  Future<Map<String, dynamic>?> identifyStream(
    String streamUrl, {
    String strategy = "soluzione 2",
  }) async {
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
      Map<String, dynamic>? result;

      if (strategy == "soluzione 1") {
        result = await _trySolutionWithRetry(1, audioData);
      } else if (strategy == "soluzione 2") {
        result = await _trySolutionWithRetry(2, audioData);
      } else {
        // "entrambi"
        result = await _trySolutionWithRetry(1, audioData);
        if (result == null || result['error'] == 'key_exhausted') {
          LogService().log(
            "RecognitionAPI: ALL Soluzione 1 keys exhausted. Falling back to Soluzione 2 directly.",
          );
          result = await _trySolutionWithRetry(2, audioData);
        }
      }
      
      if (result != null && result['error'] == 'key_exhausted') {
         return null;
      }
      
      return result;
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

  Future<Map<String, dynamic>?> _runSolution1(
    Uint8List audioData,
    String apiKey,
  ) async {
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

    // Update usage in Firestore after attempt (regardless of result)
    _incrementKeyUsage(apiKey, 1);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);

      // Inject is_exact_offset: true for Solution 1 matches to enable UI tracking
      if (data is Map<String, dynamic> &&
          data['matches'] != null &&
          data['matches'] is List) {
        for (var m in (data['matches'] as List)) {
          if (m is Map<String, dynamic> &&
              m.containsKey('offset') &&
              m['offset'] != null) {
            m['is_exact_offset'] = true;
          }
        }
      }
      return data;
    } else if (response.statusCode == 429 || response.statusCode == 401 || response.statusCode == 403 ||
        (response.body.toLowerCase().contains("you have exceeded") ||
            response.body.toLowerCase().contains("quota") ||
            response.body.toLowerCase().contains("invalid") ||
            response.body.toLowerCase().contains("unauthorized"))) {
      LogService().log(
          "RecognitionAPI [MultiKey 1]: Key ${apiKey.substring(0, 8)}... EXHAUSTED/INVALID. Disabling for today.",
      );
      await _disableKey(apiKey, 1);
      // Eseguiamo il check in background, non blocchiamo il return
      checkKeysAvailability();
      return {'error': 'key_exhausted'};
    } else {
      LogService().log(
        "RecognitionAPI [Soluzione 1] HTTP Error: ${response.statusCode} - ${response.body}",
      );
    }
    return null;
  }
  
  Future<Map<String, dynamic>?> _trySolutionWithRetry(int solutionIndex, Uint8List audioData) async {
    List<String> ignoredKeys = [];
    while (true) {
      final configKeyName = solutionIndex == 1 ? 'recognition_key_1' : 'recognition_key_2';
      final defaultKey = solutionIndex == 1 ? _defaultApiKey : _apiKey2;
      
      final selection = await _getBestApiKey(configKeyName, defaultKey, solutionIndex, ignoredKeys);
      
      if (selection['allExhausted'] == true) {
         return null;
      }
      
      final apiKey = selection['key'];
      final result = solutionIndex == 1 ? await _runSolution1(audioData, apiKey) : await _runSolution2(audioData, apiKey);
      
      if (result != null && result['error'] == 'key_exhausted') {
         ignoredKeys.add(apiKey); // Will retry since loop doesn't break
      } else {
         return result;
      }
    }
  }

  Future<Map<String, dynamic>?> _runSolution2(
    Uint8List audioData,
    String apiKey,
  ) async {
    if (_activeClient == null) return null;

    var request = http.MultipartRequest('POST', Uri.parse(_apiUrl2));

    request.headers.addAll({
      "x-rapidapi-host": _apiHost2,
      "x-rapidapi-key": apiKey,
    });

    request.files.add(
      http.MultipartFile.fromBytes('audio', audioData, filename: "sample.mp3"),
    );

    try {
      final streamedResponse = await _activeClient!.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        LogService().log("RecognitionAPI [Soluzione 2] Result: $result");

        // Update usage in Firestore for Solution 2 key
        _incrementKeyUsage(apiKey, 2);

        // Remap to match the old format expected by RadioProvider: { "track": { ... } }
        if (result['data'] != null &&
            result['data']['matches'] != null &&
            (result['data']['matches'] as List).isNotEmpty) {
          final firstMatch = result['data']['matches'][0];
          if (firstMatch['track'] != null) {
            // Map the matches array to guarantee the presence of 'offset'
            // thus preventing 'null as num' exception in RadioAudioHandler.
            final mappedMatches = (result['data']['matches'] as List).map((m) {
              final newMatch = Map<String, dynamic>.from(m);
              if (!newMatch.containsKey('offset') ||
                  newMatch['offset'] == null) {
                newMatch['offset'] = 0; // Fallback to 0
                newMatch['is_exact_offset'] = false;
              } else {
                newMatch['is_exact_offset'] = true;
              }
              return newMatch;
            }).toList();

            return {'track': firstMatch['track'], 'matches': mappedMatches};
          }
        }

        // Fallback in case the new API unexpectedly returns the old structure
        if (result.containsKey('track')) {
          return result;
        }

        return null;
      } else if (response.statusCode == 429 || response.statusCode == 404 || 
                 response.statusCode == 401 || response.statusCode == 403 ||
          (response.body.toLowerCase().contains("you have exceeded") ||
              response.body.toLowerCase().contains("quota") ||
              response.body.toLowerCase().contains("not found") ||
              response.body.toLowerCase().contains("invalid") ||
              response.body.toLowerCase().contains("unauthorized"))) {
        LogService().log(
          "RecognitionAPI [Soluzione 2 MultiKey]: Key ${apiKey.substring(0, 8)}... EXHAUSTED/INVALID (or 404). Disabling for today.",
        );
        await _disableKey(apiKey, 2);
        // Eseguiamo il check in background, non blocchiamo il return
        checkKeysAvailability();
        return {'error': 'key_exhausted'};
      } else {
        LogService().log(
          "RecognitionAPI [Soluzione 2] HTTP Error: ${response.statusCode} - ${response.body}",
        );
        return null;
      }
    } catch (e) {
      LogService().log("RecognitionAPI [Soluzione 2] Exception: $e");
      return null;
    }
  }

  /// Fetches the list of keys from Remote Config and selects the one with the lowest usage in Firestore.
  /// Automatically resets usage and reactivates keys if they haven't been used today.
  Future<Map<String, dynamic>> _getBestApiKey(
    String configKeyName,
    String defaultKey,
    int solutionIndex,
    [List<String> ignoredSessionKeys = const []]
  ) async {
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      // Fetch keys from Remote Config (parameter: 'shazam_api_keys' as JSON list)
      await remoteConfig.fetchAndActivate().timeout(const Duration(seconds: 5));
      final String keysJson = remoteConfig.getString('shazam_api_keys');

      List<String> keys = [defaultKey];
      if (keysJson.isNotEmpty) {
        try {
          final dynamic decoded = jsonDecode(keysJson);
          if (decoded is Map && decoded.containsKey(configKeyName)) {
            final List<dynamic> keyList = decoded[configKeyName] as List;
            if (keyList.isNotEmpty) {
              keys = keyList.map((e) => e.toString()).toList();
            }
          }
        } catch (_) {}
      }

      // Note: We no longer return early here to ensure we check Firestore status even for a single key

      // Query Firestore for global usage counts
      final firestore = FirebaseFirestore.instance;
      final snapshot = await firestore
          .collection('api_keys_usage')
          .get()
          .timeout(const Duration(seconds: 5));

      final now = DateTime.now();
      final Map<String, int> usageMap = {};
      final List<String> activeKeys = [];

      for (var key in keys) {
        if (ignoredSessionKeys.contains(key)) continue;

        // Find data for this key if it exists in Firestore
        final doc = snapshot.docs.where((d) => d.id == key).firstOrNull;

        if (doc != null) {
          final Map<String, dynamic> data = doc.data();
          final bool isDisabled = data['is_disabled_$solutionIndex'] ?? false;
          final Timestamp? lastUsedTs =
              data['last_used_$solutionIndex'] as Timestamp?;
          final DateTime? lastUsed = lastUsedTs?.toDate();

          final Timestamp? disabledAtTs = data['disabled_at_$solutionIndex'] as Timestamp?;
          final DateTime? disabledAt = disabledAtTs?.toDate();

          DateTime? mostRecentActivity = lastUsed;
          if (disabledAt != null && (mostRecentActivity == null || disabledAt.isAfter(mostRecentActivity))) {
            mostRecentActivity = disabledAt;
          }

          // DAILY RESET LOGIC:
          // If the key wasn't used today, or was disabled on a previous day, reactivate and reset count.
          bool isDifferentDay =
              mostRecentActivity == null ||
              mostRecentActivity.year != now.year ||
              mostRecentActivity.month != now.month ||
              mostRecentActivity.day != now.day;

          if (isDifferentDay) {
            // Reset count for the day and reactivate
            usageMap[key] = 0;
            activeKeys.add(key);
            // Non-blocking update in Firestore to keep it clean
            _resetKeyUsage(key, solutionIndex);
          } else if (!isDisabled) {
            // Key is still active from today
            usageMap[key] =
                (data['count_$solutionIndex'] as num?)?.toInt() ?? 0;
            activeKeys.add(key);
          } else {
            // Key is explicitly disabled for today - Do not add to activeKeys
            LogService().log(
              "RecognitionAPI [MultiKey $solutionIndex]: Key ${key.substring(0, 8)}... skipped (EXHAUSTED).",
            );
          }
        } else {
          // New key never seen before
          usageMap[key] = 0;
          activeKeys.add(key);
        }
      }

      // If all keys are exhausted, fallback to default or first key as desperate attempt
      if (activeKeys.isEmpty) {
        LogService().log(
          "RecognitionAPI [MultiKey $solutionIndex]: ALL KEYS EXHAUSTED!",
        );
        return {'key': keys[0], 'allExhausted': true};
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

      return {'key': bestKey, 'allExhausted': false};
    } catch (e) {
      LogService().log(
        "RecognitionAPI [MultiKey]: Error selecting key: $e. Falling back to default.",
      );
      return {'key': _defaultApiKey, 'allExhausted': false};
    }
  }

  /// Increments the usage counter in Firestore for a specific key.
  void _incrementKeyUsage(String key, int solutionIndex) {
    try {
      FirebaseFirestore.instance.collection('api_keys_usage').doc(key).set({
        'count_$solutionIndex': FieldValue.increment(1),
        'last_used_$solutionIndex': FieldValue.serverTimestamp(),
        'is_disabled_$solutionIndex':
            false, // Ensure it stays active while incrementing
      }, SetOptions(merge: true));
    } catch (e) {
      LogService().log(
        "RecognitionAPI [MultiKey $solutionIndex]: Failed to increment usage for key: $e",
      );
    }
  }

  /// Disables a key in Firestore until the next day reset.
  Future<void> _disableKey(String key, int solutionIndex) async {
    try {
      await FirebaseFirestore.instance.collection('api_keys_usage').doc(key).set({
        'is_disabled_$solutionIndex': true,
        'disabled_at_$solutionIndex': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      LogService().log(
        "RecognitionAPI [MultiKey $solutionIndex]: Failed to disable key: $e",
      );
    }
  }

  /// Resets usage and reactivates a key for a new day.
  void _resetKeyUsage(String key, int solutionIndex) {
    try {
      FirebaseFirestore.instance.collection('api_keys_usage').doc(key).set({
        'count_$solutionIndex': 0,
        'is_disabled_$solutionIndex': false,
        'last_reset_$solutionIndex': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      LogService().log(
        "RecognitionAPI [MultiKey $solutionIndex]: Failed to reset key: $e",
      );
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
