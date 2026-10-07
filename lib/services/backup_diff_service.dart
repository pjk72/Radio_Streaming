import 'dart:convert';

/// Differences of a single section (e.g. stations, playlists...) between
/// two backup payloads.
class DiffSection {
  final String key;
  final String labelKey;
  final int added;
  final int removed;
  final int changed;
  final List<String> addedLabels;
  final List<String> removedLabels;
  final List<String> changedLabels;

  const DiffSection({
    required this.key,
    required this.labelKey,
    this.added = 0,
    this.removed = 0,
    this.changed = 0,
    this.addedLabels = const [],
    this.removedLabels = const [],
    this.changedLabels = const [],
  });

  bool get hasChanges => added > 0 || removed > 0 || changed > 0;
}

/// Result of comparing two backup payloads.
class BackupDiff {
  final List<DiffSection> sections;

  const BackupDiff(this.sections);

  List<DiffSection> get changes =>
      sections.where((s) => s.hasChanges).toList(growable: false);

  bool get hasChanges => changes.isNotEmpty;
}

class BackupDiffService {
  BackupDiffService._();

  /// Computes the differences between [prev] (older) and [curr] (newer).
  static BackupDiff compute(
    Map<String, dynamic> prev,
    Map<String, dynamic> curr,
  ) {
    final sections = <DiffSection>[
      _objectsDiff(
        key: 'stations',
        labelKey: 'diff_stations',
        prev: prev['stations'],
        curr: curr['stations'],
        labelOf: (m) => '${m['name'] ?? m['id'] ?? ''}',
      ),
      _objectsDiff(
        key: 'playlists',
        labelKey: 'diff_playlists',
        prev: prev['playlists'],
        curr: curr['playlists'],
        labelOf: (m) => '${m['name'] ?? m['id'] ?? ''}',
      ),
      _valuesDiff(
        key: 'favorites',
        labelKey: 'favorites',
        prev: prev['favorites'],
        curr: curr['favorites'],
        labelOf: _stationLabelResolver(prev, curr),
      ),
      _mapDiff(
        key: 'history_metadata',
        labelKey: 'diff_history',
        prev: prev['history_metadata'],
        curr: curr['history_metadata'],
        labelOf: (k, v) => _songLabel(k, v),
      ),
      _mapDiff(
        key: 'user_play_history',
        labelKey: 'diff_history',
        prev: prev['user_play_history'],
        curr: curr['user_play_history'],
        labelOf: (k, _) => _songLabelResolver(prev, curr)(k),
      ),
      _scalarDiff(
        key: 'weekly_play_log',
        labelKey: 'diff_history',
        prev: prev['weekly_play_log'],
        curr: curr['weekly_play_log'],
      ),
      _valuesDiff(
        key: 'recent_songs_order',
        labelKey: 'diff_history',
        prev: prev['recent_songs_order'],
        curr: curr['recent_songs_order'],
        labelOf: _songLabelResolver(prev, curr),
      ),
      _valuesDiff(
        key: 'followed_artists',
        labelKey: 'diff_followed_artists',
        prev: prev['followed_artists'],
        curr: curr['followed_artists'],
      ),
      _valuesDiff(
        key: 'followed_albums',
        labelKey: 'diff_followed_albums',
        prev: prev['followed_albums'],
        curr: curr['followed_albums'],
      ),
      _objectsDiff(
        key: 'promoted_playlists',
        labelKey: 'diff_promoted_playlists',
        prev: prev['promoted_playlists'],
        curr: curr['promoted_playlists'],
        labelOf: (m) => '${m['title'] ?? m['name'] ?? m['id'] ?? ''}',
      ),
      _valuesDiff(
        key: 'invalid_song_ids',
        labelKey: 'diff_invalid_songs',
        prev: prev['invalid_song_ids'],
        curr: curr['invalid_song_ids'],
        labelOf: _songLabelResolver(prev, curr),
      ),
      _ordersDiff(prev: prev, curr: curr),
      _mapDiff(
        key: 'theme_settings',
        labelKey: 'diff_theme',
        prev: prev['theme_settings'],
        curr: curr['theme_settings'],
        labelOf: (k, _) => k,
      ),
      _mapDiff(
        key: 'playback_settings',
        labelKey: 'diff_playback',
        prev: prev['playback_settings'],
        curr: curr['playback_settings'],
        labelOf: (k, _) => k,
      ),
    ];

    return BackupDiff(sections);
  }

  static List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().toList();
  }

  static DiffSection _objectsDiff({
    required String key,
    required String labelKey,
    required dynamic prev,
    required dynamic curr,
    required String Function(Map<String, dynamic> item) labelOf,
  }) {
    final prevMap = {
      for (final m in _asMapList(prev)) '${m['id']}': m,
    };
    final currMap = {
      for (final m in _asMapList(curr)) '${m['id']}': m,
    };

    final addedKeys =
        currMap.keys.where((k) => !prevMap.containsKey(k)).toList();
    final removedKeys =
        prevMap.keys.where((k) => !currMap.containsKey(k)).toList();
    final changedKeys = currMap.keys
        .where((k) =>
            prevMap[k] != null &&
            jsonEncode(prevMap[k]) != jsonEncode(currMap[k]))
        .toList();

    return DiffSection(
      key: key,
      labelKey: labelKey,
      added: addedKeys.length,
      removed: removedKeys.length,
      changed: changedKeys.length,
      addedLabels: [
        for (final k in addedKeys) labelOf(currMap[k]!),
      ],
      removedLabels: [
        for (final k in removedKeys) labelOf(prevMap[k]!),
      ],
      changedLabels: [
        for (final k in changedKeys) labelOf(currMap[k]!),
      ],
    );
  }

  static DiffSection _valuesDiff({
    required String key,
    required String labelKey,
    required dynamic prev,
    required dynamic curr,
    String Function(dynamic value)? labelOf,
  }) {
    final prevList = prev is List ? prev : const [];
    final currList = curr is List ? curr : const [];
    final prevSet = prevList.map((e) => '$e').toSet();
    final currSet = currList.map((e) => '$e').toSet();

    final added = currSet.difference(prevSet).toList();
    final removed = prevSet.difference(currSet).toList();

    String labelOfSafe(dynamic v) {
      if (labelOf == null) return '$v';
      final result = labelOf(v);
      return result.isEmpty ? '$v' : result;
    }

    return DiffSection(
      key: key,
      labelKey: labelKey,
      added: added.length,
      removed: removed.length,
      changed: 0,
      addedLabels: added.map(labelOfSafe).toList(),
      removedLabels: removed.map(labelOfSafe).toList(),
    );
  }

  static DiffSection _mapDiff({
    required String key,
    required String labelKey,
    required dynamic prev,
    required dynamic curr,
    required String Function(String key, dynamic value) labelOf,
  }) {
    final prevMap = prev is Map ? prev : const {};
    final currMap = curr is Map ? curr : const {};

    final added = currMap.keys
        .map((e) => '$e')
        .where((k) => !prevMap.containsKey(k))
        .toList();
    final removed = prevMap.keys
        .map((e) => '$e')
        .where((k) => !currMap.containsKey(k))
        .toList();
    final changed = currMap.keys
        .map((e) => '$e')
        .where((k) =>
            prevMap.containsKey(k) &&
            jsonEncode(prevMap[k]) != jsonEncode(currMap[k]))
        .toList();

    return DiffSection(
      key: key,
      labelKey: labelKey,
      added: added.length,
      removed: removed.length,
      changed: changed.length,
      addedLabels: [
        for (final k in added) labelOf(k, currMap[k]),
      ],
      removedLabels: [
        for (final k in removed) labelOf(k, prevMap[k]),
      ],
      changedLabels: [
        for (final k in changed) labelOf(k, currMap[k]),
      ],
    );
  }

  /// Used when a single scalar/list field simply changed (no ids involved).
  static DiffSection _scalarDiff({
    required String key,
    required String labelKey,
    required dynamic prev,
    required dynamic curr,
  }) {
    final changed =
        jsonEncode(prev ?? const {}) != jsonEncode(curr ?? const {});
    return DiffSection(
      key: key,
      labelKey: labelKey,
      changed: changed ? 1 : 0,
      changedLabels: const [],
    );
  }

  static const List<String> _orderKeys = [
    'station_order',
    'genre_order',
    'category_order',
  ];

  static DiffSection _ordersDiff({
    required Map<String, dynamic> prev,
    required Map<String, dynamic> curr,
  }) {
    final changed = [
      for (final k in _orderKeys)
        if (jsonEncode(prev[k]) != jsonEncode(curr[k])) k,
    ];
    return DiffSection(
      key: 'orders',
      labelKey: 'diff_orders',
      changed: changed.length,
      changedLabels: changed,
    );
  }

  /// Resolves a station id to its display name using both payloads.
  static String Function(dynamic value) _stationLabelResolver(
    Map<String, dynamic> prev,
    Map<String, dynamic> curr,
  ) {
    final names = <String, String>{};
    for (final list in [prev['stations'], curr['stations']]) {
      for (final m in _asMapList(list)) {
        final id = '${m['id']}';
        final name = '${m['name'] ?? ''}';
        if (name.isNotEmpty) names[id] = name;
      }
    }
    return (value) => names['$value'] ?? '';
  }

  /// Resolves a song id to "Title - Artist" using history_metadata.
  static String Function(dynamic value) _songLabelResolver(
    Map<String, dynamic> prev,
    Map<String, dynamic> curr,
  ) {
    final labels = <String, String>{};
    for (final map in [prev['history_metadata'], curr['history_metadata']]) {
      if (map is Map) {
        map.forEach((key, value) {
          if (value is Map) {
            final label = _songLabel('$key', value);
            if (label.isNotEmpty) labels['$key'] = label;
          }
        });
      }
    }
    return (value) => labels['$value'] ?? '';
  }

  static String _songLabel(String key, dynamic value) {
    if (value is! Map) return '';
    final title = '${value['title'] ?? ''}';
    final artist = '${value['artist'] ?? ''}';
    if (title.isEmpty && artist.isEmpty) return '';
    if (title.isEmpty) return artist;
    if (artist.isEmpty) return title;
    return '$title - $artist';
  }
}
