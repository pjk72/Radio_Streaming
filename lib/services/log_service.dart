import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory log buffer used by the debug screen.
///
/// When the app runs on Android Auto, audio_service may execute the
/// [RadioAudioHandler] in a separate background isolate: a plain in-memory
/// buffer would keep the playback logs (preload/crossfade) invisible from the
/// UI. To make those diagnostics available everywhere, the buffer is also
/// mirrored into SharedPreferences and merged back on every flush, so both
/// isolates end up sharing the same recent history.
class LogService {
  static final LogService _instance = LogService._internal();

  factory LogService() {
    return _instance;
  }

  LogService._internal();

  static const String _prefsKey = 'runtime_logs_v1';
  static const int _maxEntries = 200;
  static const int _maxPersistedEntries = 300;

  final ValueNotifier<List<String>> _logs = ValueNotifier([]);
  ValueNotifier<List<String>> get logs => _logs;

  Timer? _flushTimer;
  bool _isFlushing = false;
  bool _isDirty = false;

  void log(String message) {
    if (kDebugMode) {
      debugPrint("[LogService] $message");
    }
    final time = DateTime.now()
        .toIso8601String()
        .split('T')
        .last
        .split('.')
        .first;
    final logEntry = "[$time] $message";

    // Add to list efficiently
    final currentLogs = List<String>.from(_logs.value);
    currentLogs.insert(0, logEntry);
    if (currentLogs.length > _maxEntries) {
      currentLogs.removeLast();
    }
    _logs.value = currentLogs;

    _isDirty = true;
    _scheduleFlush();
  }

  void clear() {
    _logs.value = [];
    _isDirty = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.remove(_prefsKey))
        .catchError((_) => false);
  }

  /// Silently mirrors the buffer to disk and imports entries produced by
  /// another isolate (e.g. the Android Auto audio handler).
  void _scheduleFlush() {
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer(const Duration(seconds: 2), _flush);
  }

  Future<void> _flush() async {
    if (_isFlushing) return;
    _isFlushing = true;
    _isDirty = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = _decode(prefs.getString(_prefsKey));

      // Bring in lines logged by other isolates (background audio handler).
      final merged = _merge(_logs.value, stored);
      if (merged.length != _logs.value.length) {
        _logs.value = merged;
      }

      final toPersist = merged.take(_maxPersistedEntries).toList();
      await prefs.setString(_prefsKey, jsonEncode(toPersist));
    } catch (_) {
      // Logging must never break playback.
    } finally {
      _isFlushing = false;
      if (_isDirty) _scheduleFlush();
    }
  }

  List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Deduplicates and returns the newest-first union of [a] and [b].
  List<String> _merge(List<String> a, List<String> b) {
    if (b.isEmpty) {
      return a.take(_maxEntries).toList();
    }
    final seen = <String>{};
    final combined = <String>[];
    for (final entry in [...a, ...b]) {
      if (seen.add(entry)) combined.add(entry);
    }
    combined.sort((x, y) => _timestamp(y).compareTo(_timestamp(x)));
    return combined.take(_maxEntries).toList();
  }

  String _timestamp(String entry) {
    if (entry.length >= 10 && entry.startsWith('[')) {
      final end = entry.indexOf(']');
      if (end > 1) return entry.substring(1, end);
    }
    return '';
  }
}
