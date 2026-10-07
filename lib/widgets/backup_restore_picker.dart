import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../providers/language_provider.dart';
import '../providers/radio_provider.dart';
import '../services/backup_diff_service.dart';
import '../services/backup_service.dart';
import '../utils/glass_utils.dart';

/// Opens the restore picker dialog and returns the selected backup version
/// (or null when the user cancels).
Future<BackupVersion?> showBackupRestorePicker({
  required BuildContext context,
  required RadioProvider radio,
  required LanguageProvider langProvider,
}) {
  return GlassUtils.showGlassDialog<BackupVersion>(
    context: context,
    barrierDismissible: false,
    builder: (_) => BackupRestorePickerDialog(
      radio: radio,
      langProvider: langProvider,
    ),
  );
}

class BackupRestorePickerDialog extends StatefulWidget {
  final RadioProvider radio;
  final LanguageProvider langProvider;

  const BackupRestorePickerDialog({
    super.key,
    required this.radio,
    required this.langProvider,
  });

  @override
  State<BackupRestorePickerDialog> createState() =>
      _BackupRestorePickerDialogState();
}

class _BackupRestorePickerDialogState extends State<BackupRestorePickerDialog> {
  static const int _maxDetailLabels = 8;

  List<BackupVersion> _versions = [];
  bool _loading = true;
  String? _error;
  int _selected = -1;

  final Map<String, BackupDiff?> _diffCache = {};
  final Map<String, Future<BackupDiff?>> _diffRequests = {};

  LanguageProvider get _lang => widget.langProvider;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final versions = await widget.radio.listAvailableBackups();
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _selected = versions.isEmpty ? -1 : 0;
        _loading = false;
      });
      if (versions.isNotEmpty) {
        // Progressive background loading of the diffs (2 at a time)
        unawaitedDiffs();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> unawaitedDiffs() async {
    for (var i = 0; i < _versions.length; i += 2) {
      if (!mounted) return;
      await Future.wait([
        _ensureDiff(i),
        if (i + 1 < _versions.length) _ensureDiff(i + 1),
      ]);
    }
  }

  /// Returns the cached diff or triggers its computation.
  Future<BackupDiff?> _ensureDiff(int index) {
    if (index < 0 || index >= _versions.length) {
      return Future.value(null);
    }
    final version = _versions[index];
    if (_diffCache.containsKey(version.fileId)) {
      return Future.value(_diffCache[version.fileId]);
    }
    return _diffRequests.putIfAbsent(
      version.fileId,
      () => _computeDiff(index),
    );
  }

  Future<BackupDiff?> _computeDiff(int index) async {
    // The oldest backup has no previous version to compare with.
    if (index >= _versions.length - 1) return null;

    try {
      final service = widget.radio.backupService;
      const timeout = Duration(seconds: 25);

      final currentJson = await service
          .downloadBackupById(_versions[index].fileId)
          .timeout(timeout);
      final previousJson = await service
          .downloadBackupById(_versions[index + 1].fileId)
          .timeout(timeout);

      final current = jsonDecode(currentJson);
      final previous = jsonDecode(previousJson);
      if (current is! Map<String, dynamic> || previous is! Map<String, dynamic>) {
        return null;
      }

      final diff = BackupDiffService.compute(previous, current);
      if (mounted) {
        setState(() => _diffCache[_versions[index].fileId] = diff);
      } else {
        _diffCache[_versions[index].fileId] = diff;
      }
      return diff;
    } catch (_) {
      if (mounted) {
        setState(() => _diffCache[_versions[index].fileId] = null);
      } else {
        _diffCache[_versions[index].fileId] = null;
      }
      return null;
    }
  }

  bool _isOldest(int index) => index >= _versions.length - 1;

  String _summaryOf(BackupDiff diff) {
    final merged = <String, List<int>>{}; // label -> [added, removed, changed]
    for (final section in diff.changes) {
      final label = _lang.translate(section.labelKey);
      final entry = merged.putIfAbsent(label, () => [0, 0, 0]);
      entry[0] += section.added;
      entry[1] += section.removed;
      entry[2] += section.changed;
    }

    final parts = <String>[];
    merged.forEach((label, counts) {
      if (counts[0] > 0) parts.add('+${counts[0]} $label');
      if (counts[1] > 0) parts.add('-${counts[1]} $label');
      if (counts[2] > 0) parts.add('~${counts[2]} $label');
    });

    if (parts.isEmpty) return _lang.translate('diff_no_changes');
    return parts.join('  ·  ');
  }

  String _translateOrderKey(String key) {
    switch (key) {
      case 'station_order':
        return _lang.translate('diff_order_station');
      case 'genre_order':
        return _lang.translate('diff_order_genre');
      case 'category_order':
        return _lang.translate('diff_order_category');
      default:
        return key;
    }
  }

  Widget _sectionDetail(DiffSection section) {
    final entries = <Widget>[];

    void addEntries(List<String> labels, String prefix, Color color) {
      final visible = labels.take(_maxDetailLabels);
      for (final label in visible) {
        if (label.isEmpty) continue;
        entries.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: Text(
              '$prefix$label',
              style: TextStyle(fontSize: 12, color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
      if (labels.length > _maxDetailLabels) {
        entries.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: Text(
              _lang
                  .translate('diff_and_more')
                  .replaceAll('{0}', '${labels.length - _maxDetailLabels}'),
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.withValues(alpha: 0.8),
              ),
            ),
          ),
        );
      }
    }

    final theme = Theme.of(context);
    addEntries(section.addedLabels, '+ ', Colors.green.shade700);
    addEntries(section.removedLabels, '- ', theme.colorScheme.error);
    addEntries(
      section.changedLabels.map(_translateOrderKey).toList(),
      '~ ',
      Colors.orange.shade800,
    );

    if (entries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _lang.translate(section.labelKey),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.textTheme.bodyLarge?.color,
            ),
          ),
          ...entries,
        ],
      ),
    );
  }

  Widget _buildDiffContent(int index) {
    final version = _versions[index];

    if (_isOldest(index)) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          _lang.translate('restore_first_backup'),
          style: TextStyle(
            fontSize: 12,
            fontStyle: FontStyle.italic,
            color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    if (!_diffCache.containsKey(version.fileId)) {
      // Trigger computation as soon as the tile becomes visible/expanded.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureDiff(index);
      });
      return const Padding(
        padding: EdgeInsets.only(top: 6),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final diff = _diffCache[version.fileId];
    if (diff == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          _lang.translate('diff_unavailable'),
          style: TextStyle(
            fontSize: 12,
            fontStyle: FontStyle.italic,
            color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    final sections = diff.changes;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _summaryOf(diff),
            style: TextStyle(
              fontSize: 12.5,
              color: sections.isEmpty
                  ? Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.7)
                  : Theme.of(context).colorScheme.primary,
              fontWeight: sections.isEmpty ? FontWeight.normal : FontWeight.w600,
            ),
          ),
          if (sections.isNotEmpty) ...sections.map(_sectionDetail),
        ],
      ),
    );
  }

  Widget _buildRow(int index) {
    final version = _versions[index];
    final theme = Theme.of(context);
    final selected = _selected == index;
    final date = DateTime.fromMillisecondsSinceEpoch(version.timestamp);
    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(date);

    final isAuto = version.type == 'auto';
    final isManual = version.type == 'manual';
    final typeText = isAuto
        ? _lang.translate('backup_type_auto')
        : isManual
            ? _lang.translate('backup_type_manual')
            : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.07)
            : Colors.transparent,
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.dividerColor.withValues(alpha: 0.3),
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          initiallyExpanded: index == 0,
          onExpansionChanged: (expanded) {
            setState(() => _selected = index);
            if (expanded) _ensureDiff(index);
          },
          leading: GestureDetector(
            onTap: () => setState(() => _selected = index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? theme.colorScheme.primary : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.dividerColor.withValues(alpha: 0.6),
                  width: 2,
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: 12, color: theme.colorScheme.onPrimary)
                  : null,
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  dateStr,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.textTheme.bodyLarge?.color,
                  ),
                ),
              ),
              if (typeText != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: (isAuto
                            ? theme.colorScheme.primary
                            : theme.colorScheme.errorContainer)
                        .withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    typeText,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: isAuto
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
            ],
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [_buildDiffContent(index)],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              _lang.translate('loading'),
              style: TextStyle(
                color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 36,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              _lang.translate('backup_failed').replaceAll('{0}', _error!),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _loadVersions,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(_lang.translate('retry_search')),
            ),
          ],
        ),
      );
    }

    if (_versions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 36,
              color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              _lang.translate('restore_no_backups'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _versions.length,
      itemBuilder: (context, index) => _buildRow(index),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canRestore = !_loading && _error == null && _selected >= 0;

    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Row(
        children: [
          const Icon(Icons.history, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_lang.translate('restore_select_backup')),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 440,
        child: _buildBody(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_lang.translate('cancel')),
        ),
        TextButton(
          onPressed: canRestore
              ? () => Navigator.pop(context, _versions[_selected])
              : null,
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.primary,
            disabledForegroundColor:
                theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
          child: Text(_lang.translate('restore')),
        ),
      ],
    );
  }
}
