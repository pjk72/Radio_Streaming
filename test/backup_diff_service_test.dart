import 'package:flutter_test/flutter_test.dart';
import 'package:radio_streaming_app/services/backup_diff_service.dart';
import 'package:radio_streaming_app/services/backup_service.dart';

void main() {
  Map<String, dynamic> station(int id, String name) => {
        'id': id,
        'name': name,
        'genre': 'Pop',
        'url': 'http://example.com/$id',
        'icon': null,
        'logo': null,
        'color': '#FFFFFF',
        'category': 'A',
        'countryCode': null,
      };

  Map<String, dynamic> playlist(String id, String name) => {
        'id': id,
        'name': name,
        'songs': <dynamic>[],
        'createdAt': '2026-01-01T00:00:00.000',
        'creator': 'user',
        'customImageUrl': null,
      };

  group('BackupDiffService', () {
    test('identical payloads produce no changes', () {
      final payload = {
        'stations': [station(1, 'Radio One')],
        'playlists': [playlist('p1', 'Chill')],
        'favorites': [1],
      };

      final diff = BackupDiffService.compute(payload, Map.of(payload));

      expect(diff.hasChanges, isFalse);
    });

    test('detects added and removed stations', () {
      final prev = {
        'stations': [station(1, 'Radio One'), station(2, 'Radio Two')],
      };
      final curr = {
        'stations': [station(1, 'Radio One'), station(3, 'Radio Three')],
      };

      final diff = BackupDiffService.compute(prev, curr);
      final stations = diff.changes.singleWhere((s) => s.key == 'stations');

      expect(stations.added, 1);
      expect(stations.removed, 1);
      expect(stations.addedLabels, ['Radio Three']);
      expect(stations.removedLabels, ['Radio Two']);
    });

    test('detects changed stations using their name', () {
      final prev = {
        'stations': [station(1, 'Old Name')],
      };
      final curr = {
        'stations': [station(1, 'New Name')],
      };

      final diff = BackupDiffService.compute(prev, curr);
      final stations = diff.changes.singleWhere((s) => s.key == 'stations');

      expect(stations.changed, 1);
      expect(stations.changedLabels, ['New Name']);
    });

    test('favorites are resolved to station names', () {
      final prev = {
        'stations': [station(1, 'Radio One'), station(2, 'Radio Two')],
        'favorites': [1],
      };
      final curr = {
        'stations': [station(1, 'Radio One'), station(2, 'Radio Two')],
        'favorites': [1, 2],
      };

      final diff = BackupDiffService.compute(prev, curr);
      final favorites = diff.changes.singleWhere((s) => s.key == 'favorites');

      expect(favorites.added, 1);
      expect(favorites.addedLabels, ['Radio Two']);
    });

    test('playlists added and removed are reported with names', () {
      final prev = {
        'playlists': [playlist('p1', 'Chill'), playlist('p2', 'Work')],
      };
      final curr = {
        'playlists': [playlist('p1', 'Chill'), playlist('p3', 'Gym')],
      };

      final diff = BackupDiffService.compute(prev, curr);
      final playlists = diff.changes.singleWhere((s) => s.key == 'playlists');

      expect(playlists.addedLabels, ['Gym']);
      expect(playlists.removedLabels, ['Work']);
    });

    test('settings changes are reported per field', () {
      final prev = {
        'theme_settings': {'theme_id': 'dark', 'custom_primary': 1},
        'playback_settings': {'crossfade_duration': 5},
      };
      final curr = {
        'theme_settings': {'theme_id': 'light', 'custom_primary': 1},
        'playback_settings': {'crossfade_duration': 15},
      };

      final diff = BackupDiffService.compute(prev, curr);

      final theme = diff.changes.singleWhere((s) => s.key == 'theme_settings');
      expect(theme.changed, 1);
      expect(theme.changedLabels, ['theme_id']);

      final playback =
          diff.changes.singleWhere((s) => s.key == 'playback_settings');
      expect(playback.changed, 1);
      expect(playback.changedLabels, ['crossfade_duration']);
    });

    test('order changes are grouped into a single section', () {
      final prev = {
        'station_order': [1, 2],
        'genre_order': ['Pop'],
        'category_order': ['A'],
      };
      final curr = {
        'station_order': [2, 1],
        'genre_order': ['Pop'],
        'category_order': ['A'],
      };

      final diff = BackupDiffService.compute(prev, curr);
      final orders = diff.changes.singleWhere((s) => s.key == 'orders');

      expect(orders.changed, 1);
      expect(orders.changedLabels, ['station_order']);
    });
  });

  group('isBackupPayloadEmpty', () {
    test('empty payload is detected', () {
      expect(
        isBackupPayloadEmpty({
          'stations': <dynamic>[],
          'playlists': <dynamic>[],
          'favorites': <dynamic>[],
          'user_play_history': <String, dynamic>{},
          'history_metadata': <String, dynamic>{},
          'followed_artists': <String>[],
          'followed_albums': <String>[],
          'promoted_playlists': <dynamic>[],
        }),
        isTrue,
      );
    });

    test('payload with stations is not empty', () {
      expect(
        isBackupPayloadEmpty({
          'stations': [station(1, 'Radio One')],
          'playlists': <dynamic>[],
          'favorites': <dynamic>[],
        }),
        isFalse,
      );
    });

    test('payload with only playlists is not empty', () {
      expect(
        isBackupPayloadEmpty({
          'stations': <dynamic>[],
          'playlists': [playlist('p1', 'Chill')],
          'favorites': <dynamic>[],
        }),
        isFalse,
      );
    });
  });
}
