import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../services/backup_service.dart';
import 'appearance_screen.dart';
import 'manage_stations_screen.dart';
import 'api_debug_screen.dart';
import 'debug_log_screen.dart';
import 'spotify_login_screen.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'local_library_screen.dart';
import '../services/entitlement_service.dart';
import '../providers/language_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Timer? _backupUnlockTimer;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _backupUnlockTimer?.cancel();
    super.dispose();
  }

  String _getLastBackupText(int timestamp, String type, LanguageProvider lang) {
    if (timestamp == 0) return lang.translate('never');
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(date);
    String typeStr =
        " (${lang.translate(type == 'auto' ? 'auto_type' : 'manual_type')})";

    if (diff.inDays >= 365) {
      final years = (diff.inDays / 365).floor();
      if (years == 1) return "${lang.translate('year_ago')}$typeStr";
      return "${lang.translate('years_ago').replaceAll('{0}', years.toString())}$typeStr";
    } else if (diff.inDays >= 30) {
      final months = (diff.inDays / 30).floor();
      final days = diff.inDays % 30;
      if (days > 0) {
        final monthStr = months == 1
            ? lang.translate('month_ago')
            : lang.translate('months_ago').replaceAll('{0}', months.toString());
        final dayStr = days == 1
            ? lang.translate('day_ago')
            : lang.translate('days_ago').replaceAll('{0}', days.toString());
        return "$monthStr${lang.translate('and_separator')}$dayStr$typeStr";
      }
      return "${months == 1 ? lang.translate('month_ago') : lang.translate('months_ago').replaceAll('{0}', months.toString())}$typeStr";
    } else if (diff.inDays >= 1) {
      return "${diff.inDays == 1 ? lang.translate('day_ago') : lang.translate('days_ago').replaceAll('{0}', diff.inDays.toString())}$typeStr";
    } else if (diff.inHours >= 1) {
      return "${diff.inHours == 1 ? lang.translate('hour_ago') : lang.translate('hours_ago').replaceAll('{0}', diff.inHours.toString())}$typeStr";
    } else if (diff.inMinutes >= 1) {
      return "${diff.inMinutes == 1 ? lang.translate('minute_ago') : lang.translate('minutes_ago').replaceAll('{0}', diff.inMinutes.toString())}$typeStr";
    } else {
      return "${lang.translate('just_now')}$typeStr";
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<BackupService>(context);
    final radio = Provider.of<RadioProvider>(context);
    final entitlements = Provider.of<EntitlementService>(context);
    final langProvider = Provider.of<LanguageProvider>(context);

    final canUseRecognition = entitlements.isFeatureEnabled('song_recognition');
    final canUseSpotify = entitlements.isFeatureEnabled('spotify_integration');
    final canUseLocal = entitlements.isFeatureEnabled('local_library');
    final canManageStations = entitlements.isFeatureEnabled('manage_stations');
    final canUseAppearance = entitlements.isFeatureEnabled('appearance');
    final canUseDebugLogs = entitlements.isFeatureEnabled('debug_logs');

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                  children: [
                    _buildSettingsTile(
                      context,
                      icon: Icons.language,
                      title: langProvider.translate('language'),
                      subtitle: langProvider.translate('language_desc'),
                      onTap: () {
                        _showLanguagePicker(context, langProvider);
                      },
                    ),
                    if (canUseAppearance)
                      _buildSettingsTile(
                        context,
                        icon: Icons.palette_rounded,
                        title: langProvider.translate('appearance'),
                        subtitle: langProvider.translate('appearance_desc'),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const AppearanceScreen(),
                            ),
                          );
                        },
                      ),

                    if (canManageStations)
                      _buildSettingsTile(
                        context,
                        icon: Icons.radio,
                        title: langProvider.translate('manage_stations'),
                        subtitle: langProvider.translate(
                          'manage_stations_desc',
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ManageStationsScreen(),
                            ),
                          );
                        },
                      ),

                    if (canUseLocal)
                      _buildSettingsTile(
                        context,
                        icon: Icons.folder,
                        title: langProvider.translate('local_library'),
                        subtitle: langProvider.translate('local_library_desc'),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const LocalLibraryScreen(),
                            ),
                          );
                        },
                      ),
                    if (canUseDebugLogs)
                      _buildSettingsTile(
                        context,
                        icon: Icons.bug_report_rounded,
                        title: langProvider.translate('logs'),
                        subtitle: langProvider.translate('logs_desc'),
                        onTap: () {
                          showModalBottomSheet(
                            context: context,
                            backgroundColor: Colors.transparent,
                            isScrollControlled: true,
                            builder: (context) => _buildLogsSubMenu(context),
                          );
                        },
                      ),
                    if (canUseRecognition)
                      _buildSettingsSwitchTile(
                        context,
                        icon: Icons.music_note_rounded,
                        title: langProvider.translate('song_recognition'),
                        subtitle: langProvider.translate(
                          'song_recognition_desc',
                        ),
                        value: radio.isACRCloudEnabled,
                        onChanged: (val) => radio.setACRCloudEnabled(val),
                      ),

                    const SizedBox(height: 32),

                    Text(
                      langProvider.translate('cloud_backup'),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).textTheme.titleLarge?.color,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).dividerColor.withValues(alpha: 0.05),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: entitlements.isUsingLocalConfig
                                      ? Border.all(
                                          color: Theme.of(context).primaryColor,
                                          width: 2,
                                        )
                                      : null,
                                ),
                                child: CircleAvatar(
                                  backgroundImage:
                                      auth.currentUser?.photoUrl != null
                                      ? NetworkImage(
                                          auth.currentUser!.photoUrl!,
                                        )
                                      : null,
                                  backgroundColor: Theme.of(
                                    context,
                                  ).dividerColor.withValues(alpha: 0.1),
                                  child: auth.currentUser?.photoUrl == null
                                      ? Icon(
                                          Icons.person,
                                          color: Theme.of(
                                            context,
                                          ).iconTheme.color,
                                        )
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      auth.isSignedIn
                                          ? (auth.currentUser?.displayName
                                                    ?.split(' ')
                                                    .first ??
                                                langProvider.translate(
                                                  'user_default',
                                                ))
                                          : langProvider.translate(
                                              'not_signed_in',
                                            ),
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).textTheme.bodyLarge?.color,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (auth.isSignedIn)
                                      Text(
                                        auth.currentUser?.email ?? "",
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).textTheme.bodySmall?.color,
                                          fontSize: 12,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed: () async {
                                  if (auth.isSignedIn) {
                                    await auth.signOut();
                                  } else {
                                    try {
                                      await auth.signIn();
                                    } catch (e) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            langProvider
                                                .translate('error_generic')
                                                .replaceAll(
                                                  '{0}',
                                                  e.toString(),
                                                ),
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                                child: Text(
                                  auth.isSignedIn
                                      ? langProvider.translate('sign_out')
                                      : langProvider.translate('sign_in'),
                                ),
                              ),
                            ],
                          ),
                          if (auth.isSignedIn) ...[
                            const Divider(color: Colors.white10, height: 32),

                            // Last Backup
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  langProvider.translate('last_backup'),
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color
                                        ?.withValues(alpha: 0.7),
                                  ),
                                ),
                                Text(
                                  _getLastBackupText(
                                    radio.lastBackupTs,
                                    radio.lastBackupType,
                                    langProvider,
                                  ),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(
                                      context,
                                    ).textTheme.bodyLarge?.color,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),

                            // Frequency Config
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  langProvider.translate('backup_frequency'),
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color
                                        ?.withValues(alpha: 0.7),
                                  ),
                                ),
                                DropdownButton<String>(
                                  value: radio.backupFrequency,
                                  dropdownColor: Theme.of(context).cardColor,
                                  underline: Container(), // Hide underline
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium?.color,
                                  ),
                                  iconEnabledColor: Theme.of(
                                    context,
                                  ).primaryColor,
                                  items: [
                                    DropdownMenuItem(
                                      value: 'manual',
                                      child: Text(
                                        langProvider.translate('manual'),
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'daily',
                                      child: Text(
                                        langProvider.translate('daily'),
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'weekly',
                                      child: Text(
                                        langProvider.translate('weekly'),
                                      ),
                                    ),
                                  ],
                                  onChanged: !radio.canInitiateBackup
                                      ? null
                                      : (val) {
                                          if (val != null) {
                                            radio.setBackupFrequency(val);
                                          }
                                        },
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),

                            // Startup Playback
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  langProvider.translate('startup_playback'),
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color
                                        ?.withValues(alpha: 0.7),
                                  ),
                                ),
                                DropdownButton<String>(
                                  value: radio.startOption,
                                  dropdownColor: Theme.of(context).cardColor,
                                  underline: Container(),
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium?.color,
                                  ),
                                  iconEnabledColor: Theme.of(
                                    context,
                                  ).primaryColor,
                                  items: [
                                    DropdownMenuItem(
                                      value: 'none',
                                      child: Text(
                                        langProvider.translate('none'),
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'last',
                                      child: Text(
                                        langProvider.translate('last_played'),
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'specific',
                                      child: Text(
                                        langProvider.translate(
                                          'specific_station',
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) {
                                      radio.setStartOption(val);
                                    }
                                  },
                                ),
                              ],
                            ),
                            if (radio.startOption == 'specific') ...[
                              const SizedBox(height: 8),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white10,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.radio,
                                    color: Colors.white70,
                                    size: 20,
                                  ),
                                ),
                                title: Text(
                                  radio.startupStationId != null
                                      ? radio.stations
                                            .firstWhere(
                                              (s) =>
                                                  s.id ==
                                                  radio.startupStationId,
                                              orElse: () =>
                                                  radio.stations.firstWhere(
                                                    (s) => true,
                                                    orElse: () =>
                                                        // ignore: missing_return
                                                        throw Exception(
                                                          "No stations",
                                                        ),
                                                  ), // Placeholder if list empty, handled by below check
                                            )
                                            .name
                                      : langProvider.translate(
                                          'select_station',
                                        ),
                                  style: const TextStyle(color: Colors.white),
                                ),
                                subtitle: Text(
                                  langProvider.translate('tap_to_choose'),
                                  style: const TextStyle(color: Colors.white38),
                                ),
                                trailing: const Icon(
                                  Icons.chevron_right,
                                  color: Colors.white38,
                                ),
                                onTap: () async {
                                  final selectedId = await showModalBottomSheet<int>(
                                    context: context,
                                    backgroundColor: const Color(0xFF16213e),
                                    isScrollControlled: true,
                                    shape: const RoundedRectangleBorder(
                                      borderRadius: BorderRadius.vertical(
                                        top: Radius.circular(16),
                                      ),
                                    ),
                                    builder: (ctx) {
                                      return DraggableScrollableSheet(
                                        initialChildSize: 0.7,
                                        minChildSize: 0.5,
                                        maxChildSize: 0.9,
                                        expand: false,
                                        builder: (ctx, scrollController) {
                                          return Column(
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.all(
                                                  16.0,
                                                ),
                                                child: Text(
                                                  langProvider.translate(
                                                    'select_station',
                                                  ),
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                              Expanded(
                                                child: ListView.builder(
                                                  controller: scrollController,
                                                  itemCount:
                                                      radio.stations.length,
                                                  itemBuilder: (ctx, index) {
                                                    final s =
                                                        radio.stations[index];
                                                    final isSelected =
                                                        s.id ==
                                                        radio.startupStationId;
                                                    return ListTile(
                                                      leading: CircleAvatar(
                                                        backgroundImage:
                                                            s.logo != null &&
                                                                s
                                                                    .logo!
                                                                    .isNotEmpty
                                                            ? (s.logo!.startsWith(
                                                                    'http',
                                                                  )
                                                                  ? NetworkImage(
                                                                      s.logo!,
                                                                    )
                                                                  : AssetImage(
                                                                          s.logo!,
                                                                        )
                                                                        as ImageProvider)
                                                            : null,
                                                        child: s.logo == null
                                                            ? const Icon(
                                                                Icons.radio,
                                                              )
                                                            : null,
                                                      ),
                                                      title: Text(
                                                        s.name,
                                                        style: TextStyle(
                                                          color: isSelected
                                                              ? Theme.of(
                                                                  context,
                                                                ).primaryColor
                                                              : Colors.white,
                                                          fontWeight: isSelected
                                                              ? FontWeight.bold
                                                              : FontWeight
                                                                    .normal,
                                                        ),
                                                      ),
                                                      onTap: () {
                                                        Navigator.pop(
                                                          ctx,
                                                          s.id,
                                                        );
                                                      },
                                                      trailing: isSelected
                                                          ? Icon(
                                                              Icons.check,
                                                              color: Theme.of(
                                                                context,
                                                              ).primaryColor,
                                                            )
                                                          : null,
                                                    );
                                                  },
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      );
                                    },
                                  );
                                  if (selectedId != null) {
                                    radio.setStartupStationId(selectedId);
                                  }
                                },
                              ),
                            ],

                            const SizedBox(height: 16),

                            // Actions
                            Row(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (_) {
                                      if (!radio.canInitiateBackup) {
                                        _backupUnlockTimer?.cancel();
                                        _backupUnlockTimer = Timer(
                                          const Duration(seconds: 3),
                                          () {
                                            radio.enableBackupOverride();
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    langProvider.translate(
                                                      'backup_force_enabled',
                                                    ),
                                                  ),
                                                  duration: Duration(
                                                    seconds: 1,
                                                  ),
                                                ),
                                              );
                                            }
                                          },
                                        );
                                      }
                                    },
                                    onTapUp: (_) =>
                                        _backupUnlockTimer?.cancel(),
                                    onTapCancel: () =>
                                        _backupUnlockTimer?.cancel(),
                                    child: AbsorbPointer(
                                      absorbing: !radio.canInitiateBackup,
                                      child: ElevatedButton.icon(
                                        icon: radio.isBackingUp
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: Colors.white,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.cloud_upload,
                                                size: 16,
                                              ),
                                        label: Text(
                                          langProvider.translate('backup'),
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF6c5ce7,
                                          ),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                          // Visual feedback for disabled state
                                          disabledBackgroundColor: const Color(
                                            0xFF6c5ce7,
                                          ).withValues(alpha: 0.5),
                                          disabledForegroundColor:
                                              Colors.white38,
                                        ),
                                        onPressed: !radio.canInitiateBackup
                                            ? null
                                            : () async {
                                                // ... (Same backup Logic) ...
                                                final confirm = await showDialog<bool>(
                                                  context: context,
                                                  builder: (ctx) => AlertDialog(
                                                    backgroundColor:
                                                        const Color(0xFF16213e),
                                                    title: Text(
                                                      langProvider.translate(
                                                        'overwrite_backup_title',
                                                      ),
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                    content: Text(
                                                      langProvider.translate(
                                                        'overwrite_backup_desc',
                                                      ),
                                                      style: TextStyle(
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.pop(
                                                              ctx,
                                                              false,
                                                            ),
                                                        child: Text(
                                                          langProvider
                                                              .translate(
                                                                'cancel',
                                                              ),
                                                        ),
                                                      ),
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.pop(
                                                              ctx,
                                                              true,
                                                            ),
                                                        child: Text(
                                                          langProvider
                                                              .translate(
                                                                'backup',
                                                              ),
                                                          style: TextStyle(
                                                            color: Color(
                                                              0xFF6c5ce7,
                                                            ),
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                                if (confirm == true &&
                                                    context.mounted) {
                                                  try {
                                                    await radio.performBackup();
                                                    if (context.mounted) {
                                                      ScaffoldMessenger.of(
                                                        context,
                                                      ).showSnackBar(
                                                        SnackBar(
                                                          content: Text(
                                                            langProvider.translate(
                                                              'backup_successful',
                                                            ),
                                                          ),
                                                          backgroundColor:
                                                              Colors.green,
                                                        ),
                                                      );
                                                    }
                                                  } catch (e) {
                                                    if (context.mounted) {
                                                      ScaffoldMessenger.of(
                                                        context,
                                                      ).showSnackBar(
                                                        SnackBar(
                                                          content: Text(
                                                            "${langProvider.translate('backup_failed')}: $e",
                                                          ),
                                                          backgroundColor:
                                                              Colors.red,
                                                        ),
                                                      );
                                                    }
                                                  }
                                                }
                                              },
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    icon: radio.isRestoring
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.cloud_download,
                                            size: 16,
                                          ),
                                    label: Text(
                                      langProvider.translate('restore'),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.orange.shade800,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                    ),
                                    onPressed:
                                        (radio.isBackingUp || radio.isRestoring)
                                        ? null
                                        : () async {
                                            final confirm =
                                                await showDialog<bool>(
                                                  context: context,
                                                  builder: (ctx) => AlertDialog(
                                                    backgroundColor:
                                                        const Color(0xFF16213e),
                                                    title: Text(
                                                      langProvider.translate(
                                                        'restore_backup_title',
                                                      ),
                                                    ),
                                                    content: Text(
                                                      langProvider.translate(
                                                        'restore_backup_desc',
                                                      ),
                                                      style: const TextStyle(
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.pop(
                                                              ctx,
                                                              false,
                                                            ),
                                                        child: Text(
                                                          langProvider
                                                              .translate(
                                                                'cancel',
                                                              ),
                                                        ),
                                                      ),
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.pop(
                                                              ctx,
                                                              true,
                                                            ),
                                                        child: Text(
                                                          langProvider
                                                              .translate(
                                                                'restore',
                                                              ),
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .redAccent,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                            if (confirm == true &&
                                                context.mounted) {
                                              try {
                                                await radio.restoreBackup();
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        langProvider.translate(
                                                          'restore_successful',
                                                        ),
                                                      ),
                                                      backgroundColor:
                                                          Colors.green,
                                                    ),
                                                  );
                                                }
                                              } catch (e) {
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        langProvider
                                                            .translate(
                                                              'restore_failed',
                                                            )
                                                            .replaceAll(
                                                              '{0}',
                                                              e.toString(),
                                                            ),
                                                      ),
                                                      backgroundColor:
                                                          Colors.red,
                                                    ),
                                                  );
                                                }
                                              }
                                            }
                                          },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (canUseSpotify) ...[
                      const SizedBox(height: 32),
                      const Text(
                        "Spotify Integration",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1db954).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(
                              0xFF1db954,
                            ).withValues(alpha: 0.3),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const FaIcon(
                                  FontAwesomeIcons.spotify,
                                  color: Color(0xFF1db954),
                                  size: 32,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        radio.spotifyService.isUserConnected
                                            ? langProvider.translate(
                                                'connected_to_spotify',
                                              )
                                            : langProvider.translate(
                                                'spotify_not_connected',
                                              ),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        radio.spotifyService.isUserConnected
                                            ? langProvider.translate(
                                                'now_can_import',
                                              )
                                            : langProvider.translate(
                                                'login_to_import',
                                              ),
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    if (radio.spotifyService.isUserConnected) {
                                      await radio.spotifyLogout();
                                    } else {
                                      final loginUrl = radio.spotifyService
                                          .getLoginUrl();
                                      final redirectUri =
                                          radio.spotifyService.redirectUri;
                                      final code = await Navigator.push<String>(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => SpotifyLoginScreen(
                                            loginUrl: loginUrl,
                                            redirectUri: redirectUri,
                                          ),
                                        ),
                                      );

                                      if (code != null) {
                                        final success = await radio
                                            .spotifyHandleAuthCode(code);
                                        if (success && context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                langProvider.translate(
                                                  'spotify_connected',
                                                ),
                                              ),
                                              backgroundColor: const Color(
                                                0xFF1db954,
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    }
                                  },
                                  child: Text(
                                    radio.spotifyService.isUserConnected
                                        ? langProvider.translate('sign_out')
                                        : langProvider.translate('sign_in'),
                                    style: const TextStyle(
                                      color: Color(0xFF1db954),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (radio.spotifyService.isUserConnected) ...[
                              const Divider(color: Colors.white10, height: 32),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.playlist_add_rounded),
                                label: Text(
                                  langProvider.translate(
                                    'import_spotify_playlist',
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1db954),
                                  foregroundColor: Colors.black,
                                  minimumSize: const Size(double.infinity, 45),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () =>
                                    _showSpotifyPlaylistPicker(context, radio),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (radio.isImportingSpotify) _buildImportOverlay(context, radio),
      ],
    );
  }

  Widget _buildImportOverlay(BuildContext context, RadioProvider radio) {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    return Container(
      color: Colors.black54,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 20,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (radio.spotifyImportProgress == 0)
                const CircularProgressIndicator(
                  color: Colors.redAccent,
                  strokeWidth: 3,
                )
              else ...[
                LinearProgressIndicator(
                  value: radio.spotifyImportProgress,
                  backgroundColor: Colors.white10,
                  color: Colors.redAccent,
                  minHeight: 10,
                  borderRadius: BorderRadius.circular(5),
                ),
                const SizedBox(height: 12),
                Text(
                  "${(radio.spotifyImportProgress * 100).toInt()}%",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                radio.spotifyImportProgress > 0.8
                    ? langProvider.translate('finalizing')
                    : langProvider
                          .translate('importing_playlist')
                          .replaceAll('{0}', radio.spotifyImportName ?? ''),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                langProvider.translate('import_take_moments'),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpotifyPlaylistPicker(
    BuildContext context,
    RadioProvider radio,
  ) async {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16213e),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: radio.spotifyService.getUserPlaylists(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 300,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError ||
                !snapshot.hasData ||
                snapshot.data!.isEmpty) {
              return SizedBox(
                height: 200,
                child: Center(
                  child: Text(
                    langProvider.translate('no_playlists_found'),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              );
            }

            final playlists = snapshot.data!;
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.4,
              maxChildSize: 0.9,
              expand: false,
              builder: (ctx, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        langProvider
                            .translate('import_playlist_title')
                            .replaceAll('{0}', playlists.length.toString()),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: playlists.length,
                        itemBuilder: (ctx, index) {
                          final p = playlists[index];
                          final images = p['images'] as List?;
                          final String? imgUrl =
                              (images != null && images.isNotEmpty)
                              ? images[0]['url']
                              : null;

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            leading: SizedBox(
                              width: 50,
                              height: 50,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: imgUrl != null
                                    ? Image.network(
                                        imgUrl,
                                        width: 50,
                                        height: 50,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(
                                        color: Colors.white10,
                                        child: const Icon(
                                          Icons.music_note,
                                          color: Colors.white54,
                                        ),
                                      ),
                              ),
                            ),
                            title: Text(
                              p['name'],
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              langProvider
                                  .translate('songs_count')
                                  .replaceAll(
                                    '{0}',
                                    p['tracks']['total'].toString(),
                                  ),
                              style: const TextStyle(color: Colors.white54),
                            ),
                            onTap: () async {
                              // Close bottom sheet first
                              Navigator.pop(ctx);

                              try {
                                final success = await radio
                                    .importSpotifyPlaylist(
                                      p['name'],
                                      p['id'],
                                      total: p['tracks']['total'] is int
                                          ? p['tracks']['total']
                                          : int.tryParse(
                                              p['tracks']['total'].toString(),
                                            ),
                                    );

                                if (context.mounted) {
                                  if (success) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          Provider.of<LanguageProvider>(
                                            context,
                                            listen: false,
                                          ).translate('import_complete'),
                                        ),
                                        backgroundColor: Colors.green,
                                      ),
                                    );
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          langProvider.translate(
                                            'no_tracks_in_playlist',
                                          ),
                                        ),
                                        backgroundColor: Colors.orange,
                                      ),
                                    );
                                  }
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        Provider.of<LanguageProvider>(
                                              context,
                                              listen: false,
                                            )
                                            .translate('import_failed')
                                            .replaceAll('{0}', e.toString()),
                                      ),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildLogsSubMenu(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            langProvider.translate('system_logs'),
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          _buildSettingsTile(
            context,
            icon: Icons.code,
            title: langProvider.translate('api_debug_title'),
            subtitle: langProvider.translate('api_debug_desc'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ApiDebugScreen()),
              );
            },
          ),
          _buildSettingsTile(
            context,
            icon: Icons.bug_report,
            title: langProvider.translate('debug_logs_title'),
            subtitle: langProvider.translate('debug_logs_desc'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DebugLogScreen()),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cardColor = Theme.of(context).cardColor;
    final contrastColor = cardColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cardColor.withValues(alpha: 0.2),
        border: Border.all(color: contrastColor.withValues(alpha: 0.2)),
      ),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Theme.of(context).primaryColor),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).textTheme.titleMedium?.color,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: Theme.of(
              context,
            ).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
          ),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: Theme.of(context).iconTheme.color?.withValues(alpha: 0.5),
        ),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  Widget _buildSettingsSwitchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    bool value = false,
    bool enabled = true,
    required ValueChanged<bool> onChanged,
  }) {
    final cardColor = Theme.of(context).cardColor;
    final contrastColor = cardColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: contrastColor.withValues(alpha: enabled ? 0.20 : 0.05),
        ),
      ),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: SwitchListTile(
          secondary: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Theme.of(context).primaryColor),
          ),
          title: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).textTheme.titleMedium?.color,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(
              color: Theme.of(
                context,
              ).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
            ),
          ),
          value: value,
          onChanged: enabled ? onChanged : null,
          activeColor: Theme.of(context).primaryColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  void _showLanguagePicker(
    BuildContext context,
    LanguageProvider langProvider,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          expand: false,
          builder: (ctx, scrollController) {
            final options = [
              {
                'code': 'system',
                'label': langProvider.translate('system'),
                'flag': '🌐',
              },
              {
                'code': 'en',
                'label': langProvider.translate('english'),
                'flag': '🇺🇸',
              },
              {
                'code': 'it',
                'label': langProvider.translate('italian'),
                'flag': '🇮🇹',
              },
              {
                'code': 'es',
                'label': langProvider.translate('spanish'),
                'flag': '🇪🇸',
              },
              {
                'code': 'fr',
                'label': langProvider.translate('french'),
                'flag': '🇫🇷',
              },
              {
                'code': 'de',
                'label': langProvider.translate('german'),
                'flag': '🇩🇪',
              },
              {
                'code': 'ru',
                'label': langProvider.translate('russian'),
                'flag': '🇷🇺',
              },
              {
                'code': 'pt',
                'label': langProvider.translate('portuguese'),
                'flag': '🇵🇹',
              },
              {
                'code': 'zh',
                'label': langProvider.translate('chinese'),
                'flag': '🇨🇳',
              },
            ];

            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      langProvider.translate('language'),
                      style: TextStyle(
                        color: Theme.of(context).textTheme.titleLarge?.color,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: options.length,
                      itemBuilder: (ctx, index) {
                        final option = options[index];
                        final isSelected =
                            langProvider.currentLanguageCode == option['code'];
                        return ListTile(
                          leading: Text(
                            option['flag']!,
                            style: const TextStyle(fontSize: 24),
                          ),
                          title: Text(
                            option['label']!,
                            style: TextStyle(
                              color: isSelected
                                  ? Theme.of(context).primaryColor
                                  : Theme.of(
                                      context,
                                    ).textTheme.bodyLarge?.color,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          trailing: isSelected
                              ? Icon(
                                  Icons.check,
                                  color: Theme.of(context).primaryColor,
                                )
                              : null,
                          onTap: () {
                            langProvider.setLanguage(option['code']!);
                            Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
