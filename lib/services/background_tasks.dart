import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup_service.dart';

const String kAutoBackupTask = 'auto_backup_task';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == kAutoBackupTask) {
      debugPrint("Workmanager: Starting Auto Backup Task");
      return await _performBackgroundBackup();
    }
    return Future.value(true);
  });
}

Future<bool> _performBackgroundBackup() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    final frequency = prefs.getString('backup_frequency') ?? 'manual';
    if (frequency == 'manual') {
      return true;
    }

    final backupService = BackupService();
    // Initialize & Sign In
    try {
      await backupService.signInSilently();
    } catch (e) {
      debugPrint("Workmanager: Sign in error: $e");
      return false;
    }

    if (!backupService.isSignedIn) {
      debugPrint("Workmanager: Backup skipped - Not signed in");
      return Future.value(false);
    }

    // Gather Data
    final stationsJson = prefs.getString('saved_stations');
    final favoritesStr = prefs.getStringList('favorites');
    final stationOrder = prefs.getStringList('station_order');
    final genreOrder = prefs.getStringList('genre_order');
    final categoryOrder = prefs.getStringList('category_order');
    final playlistsJson = prefs.getString('playlists_v2');

    final data = {
      'stations': stationsJson != null ? jsonDecode(stationsJson) : [],
      'favorites':
          favoritesStr?.map((e) => int.tryParse(e) ?? -1).toList() ?? [],
      'station_order':
          stationOrder?.map((e) => int.tryParse(e) ?? -1).toList() ?? [],
      'genre_order': genreOrder ?? [],
      'category_order': categoryOrder ?? [],
      'playlists': playlistsJson != null ? jsonDecode(playlistsJson) : [],
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'version': 1,
      'type': 'auto',
    };

    await backupService.uploadBackup(jsonEncode(data));

    await prefs.setInt('last_backup_ts', DateTime.now().millisecondsSinceEpoch);
    await prefs.setString('last_backup_type', 'auto');

    debugPrint("Workmanager: Auto Backup Successful");
    return true;
  } catch (e) {
    debugPrint("Workmanager: Backup Failed: $e");
    return false;
  }
}
