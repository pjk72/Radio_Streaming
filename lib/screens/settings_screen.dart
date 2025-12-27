import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../services/backup_service.dart';
import 'manage_stations_screen.dart';
import 'api_debug_screen.dart';
import 'debug_log_screen.dart';
import 'spotify_login_screen.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  Timer? _backupUnlockTimer;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _backupUnlockTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(String text) {
    return text.toLowerCase().contains(_searchQuery);
  }

  String _getLastBackupText(int timestamp, String type) {
    if (timestamp == 0) return "Never";

    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(date);
    String typeStr = " (${type == 'auto' ? 'Auto' : 'Manual'})";

    if (diff.inDays >= 365) {
      final years = (diff.inDays / 365).floor();
      return "$years year${years > 1 ? 's' : ''} ago$typeStr";
    } else if (diff.inDays >= 30) {
      final months = (diff.inDays / 30).floor();
      final days = diff.inDays % 30;
      if (days > 0) {
        return "$months month${months > 1 ? 's' : ''} and $days day${days > 1 ? 's' : ''} ago$typeStr";
      }
      return "$months month${months > 1 ? 's' : ''} ago$typeStr";
    } else if (diff.inDays >= 1) {
      return "${diff.inDays} day${diff.inDays > 1 ? 's' : ''} ago$typeStr";
    } else if (diff.inHours >= 1) {
      return "${diff.inHours} hour${diff.inHours > 1 ? 's' : ''} ago$typeStr";
    } else if (diff.inMinutes >= 1) {
      return "${diff.inMinutes} minute${diff.inMinutes > 1 ? 's' : ''} ago$typeStr";
    } else {
      return "Just now$typeStr";
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<BackupService>(context);
    final radio = Provider.of<RadioProvider>(context);

    // Filter Logic
    final bool showManageStations =
        _searchQuery.isEmpty ||
        _matches("Manage Stations") ||
        _matches("Stations") ||
        _matches("Add") ||
        _matches("Edit");

    final bool showGeneral =
        _searchQuery.isEmpty ||
        _matches("Compact View") ||
        _matches("Display") ||
        _matches("Density");

    final bool showBackup =
        _searchQuery.isEmpty ||
        _matches("Cloud Backup") ||
        _matches("Backup") ||
        _matches("Restore") ||
        _matches("Sign In") ||
        _matches("Google") ||
        _matches("Frequency");

    final bool showSpotify =
        _searchQuery.isEmpty ||
        _matches("Spotify") ||
        _matches("Playlist") ||
        _matches("Import");

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.2), // Separate area
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16.0),
                color: Colors.white.withValues(alpha: 0.05),
                child: Row(
                  children: [
                    const Icon(Icons.settings_rounded, color: Colors.white),
                    const SizedBox(width: 12),
                    Text(
                      "Settings",
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const Spacer(),
                    // Search Bar
                    Container(
                      width: 160,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: "Search...",
                          hintStyle: const TextStyle(
                            color: Colors.white38,
                            fontSize: 13,
                          ),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.white38,
                            size: 16,
                          ),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white38,
                                    size: 16,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.only(
                            top: 2,
                          ), // vertically center
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (showManageStations)
                      _buildSettingsTile(
                        context,
                        icon: Icons.radio,
                        title: "Manage Stations",
                        subtitle: "Add, edit, or remove radio stations",
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ManageStationsScreen(),
                            ),
                          );
                        },
                      ),
                    _buildSettingsTile(
                      context,
                      icon: Icons.code,
                      title: "API Debug",
                      subtitle: "View raw JSON responses",
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ApiDebugScreen(),
                          ),
                        );
                      },
                    ),
                    _buildSettingsTile(
                      context,
                      icon: Icons.bug_report,
                      title: "Debug Logs",
                      subtitle: "View application logs",
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const DebugLogScreen(),
                          ),
                        );
                      },
                    ),
                    if (showGeneral)
                      _buildSettingsSwitchTile(
                        context,
                        icon: Icons.view_headline_rounded,
                        title: "Compact View",
                        subtitle: "Show more stations in less space",
                        value: radio.isCompactView,
                        onChanged: (val) => radio.setCompactView(val),
                      ),

                    if (showManageStations && showBackup)
                      const SizedBox(height: 32),

                    if (showBackup) ...[
                      const Text(
                        "Cloud Backup",
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
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  backgroundImage:
                                      auth.currentUser?.photoUrl != null
                                      ? NetworkImage(
                                          auth.currentUser!.photoUrl!,
                                        )
                                      : null,
                                  backgroundColor: Colors.white10,
                                  child: auth.currentUser?.photoUrl == null
                                      ? const Icon(
                                          Icons.person,
                                          color: Colors.white,
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        auth.isSignedIn
                                            ? (auth.currentUser?.displayName
                                                      ?.split(' ')
                                                      .first ??
                                                  "User")
                                            : "Not Signed In",
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (auth.isSignedIn)
                                        Text(
                                          auth.currentUser?.email ?? "",
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
                                    if (auth.isSignedIn) {
                                      await auth.signOut();
                                    } else {
                                      try {
                                        await auth.signIn();
                                      } catch (e) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(content: Text("Error: $e")),
                                        );
                                      }
                                    }
                                  },
                                  child: Text(
                                    auth.isSignedIn ? "Sign Out" : "Sign In",
                                  ),
                                ),
                              ],
                            ),
                            if (auth.isSignedIn) ...[
                              const Divider(color: Colors.white10, height: 32),

                              // Last Backup
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    "Last Backup",
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  Text(
                                    _getLastBackupText(
                                      radio.lastBackupTs,
                                      radio.lastBackupType,
                                    ),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              // Frequency Config
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    "Backup Frequency",
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  DropdownButton<String>(
                                    value: radio.backupFrequency,
                                    dropdownColor: const Color(0xFF16213e),
                                    underline: Container(), // Hide underline
                                    style: const TextStyle(color: Colors.white),
                                    iconEnabledColor: Theme.of(
                                      context,
                                    ).primaryColor,
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'manual',
                                        child: Text("Manual"),
                                      ),
                                      DropdownMenuItem(
                                        value: 'daily',
                                        child: Text("Daily"),
                                      ),
                                      DropdownMenuItem(
                                        value: 'weekly',
                                        child: Text("Weekly"),
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
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    "Startup Playback",
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  DropdownButton<String>(
                                    value: radio.startOption,
                                    dropdownColor: const Color(0xFF16213e),
                                    underline: Container(),
                                    style: const TextStyle(color: Colors.white),
                                    iconEnabledColor: Theme.of(
                                      context,
                                    ).primaryColor,
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'none',
                                        child: Text("None"),
                                      ),
                                      DropdownMenuItem(
                                        value: 'last',
                                        child: Text("Last Played"),
                                      ),
                                      DropdownMenuItem(
                                        value: 'specific',
                                        child: Text("Specific Station"),
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
                                        : "Select Station",
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  subtitle: const Text(
                                    "Tap to choose",
                                    style: const TextStyle(
                                      color: Colors.white38,
                                    ),
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
                                                const Padding(
                                                  padding: EdgeInsets.all(16.0),
                                                  child: Text(
                                                    "Select Startup Station",
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 18,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  child: ListView.builder(
                                                    controller:
                                                        scrollController,
                                                    itemCount:
                                                        radio.stations.length,
                                                    itemBuilder: (ctx, index) {
                                                      final s =
                                                          radio.stations[index];
                                                      final isSelected =
                                                          s.id ==
                                                          radio
                                                              .startupStationId;
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
                                                            fontWeight:
                                                                isSelected
                                                                ? FontWeight
                                                                      .bold
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
                                                  const SnackBar(
                                                    content: Text(
                                                      "Backup Force Enabled",
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
                                          label: const Text("Backup"),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(
                                              0xFF6c5ce7,
                                            ),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                            // Visual feedback for disabled state
                                            disabledBackgroundColor:
                                                const Color(
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
                                                          const Color(
                                                            0xFF16213e,
                                                          ),
                                                      title: const Text(
                                                        "Overwrite Backup?",
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                      content: const Text(
                                                        "This will overwrite your existing cloud backup with the current app data. Are you sure?",
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
                                                          child: const Text(
                                                            "Cancel",
                                                          ),
                                                        ),
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                ctx,
                                                                true,
                                                              ),
                                                          child: const Text(
                                                            "Backup",
                                                            style: TextStyle(
                                                              color: Color(
                                                                0xFF6c5ce7,
                                                              ),
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                  if (confirm == true &&
                                                      context.mounted) {
                                                    try {
                                                      await radio
                                                          .performBackup();
                                                      if (context.mounted) {
                                                        ScaffoldMessenger.of(
                                                          context,
                                                        ).showSnackBar(
                                                          const SnackBar(
                                                            content: Text(
                                                              "Backup Successful!",
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
                                                              "Backup Failed: $e",
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
                                      label: const Text("Restore"),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.orange.shade800,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                      onPressed:
                                          (radio.isBackingUp ||
                                              radio.isRestoring)
                                          ? null
                                          : () async {
                                              final confirm = await showDialog<bool>(
                                                context: context,
                                                builder: (ctx) => AlertDialog(
                                                  backgroundColor: const Color(
                                                    0xFF16213e,
                                                  ),
                                                  title: const Text(
                                                    "Restore Backup?",
                                                  ),
                                                  content: const Text(
                                                    "This will overwrite your current stations and settings. Are you sure?",
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
                                                      child: const Text(
                                                        "Cancel",
                                                      ),
                                                    ),
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            ctx,
                                                            true,
                                                          ),
                                                      child: const Text(
                                                        "Restore",
                                                        style: TextStyle(
                                                          color:
                                                              Colors.redAccent,
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
                                                      const SnackBar(
                                                        content: Text(
                                                          "Restore Successful!",
                                                        ),
                                                        backgroundColor:
                                                            Colors.green,
                                                        // ignore: use_build_context_synchronously
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
                                                          "Restore Failed: $e",
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
                    ],
                    if (showSpotify) ...[
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
                                        radio.spotifyService.isLoggedIn
                                            ? "Connected to Spotify"
                                            : "Spotify Not Connected",
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        radio.spotifyService.isLoggedIn
                                            ? "Now you can import your playlists"
                                            : "Login to import your playlists",
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
                                    if (radio.spotifyService.isLoggedIn) {
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
                                            const SnackBar(
                                              content: Text(
                                                "Spotify Connected!",
                                              ),
                                              backgroundColor: Color(
                                                0xFF1db954,
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    }
                                  },
                                  child: Text(
                                    radio.spotifyService.isLoggedIn
                                        ? "Logout"
                                        : "Connect",
                                    style: const TextStyle(
                                      color: Color(0xFF1db954),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (radio.spotifyService.isLoggedIn) ...[
                              const Divider(color: Colors.white10, height: 32),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.playlist_add_rounded),
                                label: const Text("Import Spotify Playlist"),
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
                    ? "Finalizing..."
                    : "Importing '${radio.spotifyImportName}'",
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                "This may take a few moments for large playlists",
                style: TextStyle(color: Colors.white54, fontSize: 12),
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
              return const SizedBox(
                height: 200,
                child: Center(
                  child: Text(
                    "No playlists found",
                    style: TextStyle(color: Colors.white),
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
                        "Import Playlist (${playlists.length} found)",
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
                              "${p['tracks']['total']} tracks • ${p['owner']?['display_name'] ?? 'Unknown'}",
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
                                      const SnackBar(
                                        content: Text("Import Complete!"),
                                        backgroundColor: Colors.green,
                                      ),
                                    );
                                  } else {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          "No tracks found in this playlist.",
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
                                      content: Text("Import Failed: $e"),
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

  Widget _buildSettingsTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
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
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54)),
        trailing: const Icon(Icons.chevron_right, color: Colors.white54),
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
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
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
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54)),
        value: value,
        onChanged: onChanged,
        activeColor: Theme.of(context).primaryColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}
