import 'package:flutter/foundation.dart';

class LogService {
  static final LogService _instance = LogService._internal();

  factory LogService() {
    return _instance;
  }

  LogService._internal();

  final ValueNotifier<List<String>> _logs = ValueNotifier([]);
  ValueNotifier<List<String>> get logs => _logs;

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
    if (currentLogs.length > 200) {
      currentLogs.removeLast();
    }
    _logs.value = currentLogs;
  }

  void clear() {
    _logs.value = [];
  }
}
