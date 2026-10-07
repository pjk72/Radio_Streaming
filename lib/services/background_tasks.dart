import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backup_service.dart';

const String kAutoBackupTask = 'auto_backup_task';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      if (task == kAutoBackupTask) {
        debugPrint("Workmanager: Starting Auto Backup Task");
        return await _performBackgroundBackup();
      }
      return true;
    } catch (e) {
      debugPrint("Workmanager: Unhandled error in task '$task': $e");
      return false;
    }
  });
}

Future<bool> _performBackgroundBackup() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    final frequency = prefs.getString('backup_frequency') ?? 'hourly';
    if (frequency == 'manual') {
      // User chose manual-only backups; background task should not run.
      debugPrint("Workmanager: Backup skipped - frequency is 'manual'.");
      return true;
    }

    final lastBackupTs = prefs.getInt('last_backup_ts') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - lastBackupTs;

    bool due = false;
    if (frequency == 'hourly' && diff >= 3600000) due = true;
    if (frequency == 'daily' && diff >= 86400000) due = true;
    if (frequency == 'weekly' && diff >= 604800000) due = true;

    if (!due) {
      debugPrint("Workmanager: Backup not due yet (diff: $diff ms). Skipping.");
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
    final invalidSongIds = prefs.getStringList('invalid_song_ids');
    final playlistsJson = prefs.getString('playlists_v2');
    final userPlayHistoryJson = prefs.getString('user_play_history');
    final weeklyPlayLogJson = prefs.getString('weekly_play_log');
    final historyMetadataJson = prefs.getString('history_metadata');
    final recentSongsOrder = prefs.getStringList('recent_songs_order');
    final followedArtists = prefs.getStringList('followed_artists');
    final followedAlbums = prefs.getStringList('followed_albums');
    final promotedPlaylistsJson = prefs.getString('promoted_playlists');
    final crossfadeDuration = prefs.getInt('crossfade_duration_v2') ?? 15;

    final data = {
      'stations': stationsJson != null ? jsonDecode(stationsJson) : [],
      'favorites':
          favoritesStr?.map((e) => int.tryParse(e) ?? -1).toList() ?? [],
      'station_order':
          stationOrder?.map((e) => int.tryParse(e) ?? -1).toList() ?? [],
      'genre_order': genreOrder ?? [],
      'category_order': categoryOrder ?? [],
      'invalid_song_ids': invalidSongIds ?? [],
      'playlists': playlistsJson != null ? jsonDecode(playlistsJson) : [],
      'user_play_history':
          userPlayHistoryJson != null ? jsonDecode(userPlayHistoryJson) : {},
      'weekly_play_log':
          weeklyPlayLogJson != null ? jsonDecode(weeklyPlayLogJson) : [],
      'history_metadata':
          historyMetadataJson != null ? jsonDecode(historyMetadataJson) : {},
      'recent_songs_order': recentSongsOrder ?? [],
      'followed_artists': followedArtists ?? [],
      'followed_albums': followedAlbums ?? [],
      'promoted_playlists':
          promotedPlaylistsJson != null ? jsonDecode(promotedPlaylistsJson) : [],
      'theme_settings': {
        'theme_id': prefs.getString('theme_id'),
        'primary_color': prefs.getInt('custom_primary'),
        'custom_primary': prefs.getInt('custom_primary'),
        'custom_bg': prefs.getInt('custom_bg'),
        'custom_card': prefs.getInt('custom_card'),
        'custom_surface': prefs.getInt('custom_surface'),
        'custom_bg_image': prefs.getString('custom_bg_image'),
      },
      'playback_settings': {
        'crossfade_duration': crossfadeDuration,
      },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'version': 3, // Synchronized version with RadioProvider
      'type': 'auto',
    };

    // Never overwrite a valid backup with an empty payload
    if (isBackupPayloadEmpty(data)) {
      debugPrint("Workmanager: Backup skipped - payload is empty.");
      await prefs.setInt('last_backup_ts', now);
      return true;
    }

    await backupService.uploadBackup(jsonEncode(data), type: 'auto');

    await prefs.setInt('last_backup_ts', now);
    await prefs.setString('last_backup_type', 'auto');

    // Record into persistent backup history (last 15)
    final history = prefs.getStringList('backup_history') ?? [];
    history.insert(0, jsonEncode({'ts': now, 'type': 'auto'}));
    if (history.length > 15) history.removeLast();
    await prefs.setStringList('backup_history', history);

    debugPrint("Workmanager: Auto Backup Successful");
    return true;
  } catch (e) {
    debugPrint("Workmanager: Backup Failed: $e");
    return false;
  }
}
