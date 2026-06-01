import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as ye hide Playlist;

import '../providers/radio_provider.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import '../providers/language_provider.dart';
import '../services/entitlement_service.dart';
import '../services/rewarded_ad_service.dart';
import '../services/notification_service.dart';
import '../services/encryption_service.dart';
import '../utils/glass_utils.dart';

Future<void> downloadPlaylist(
  BuildContext context,
  RadioProvider provider,
  Playlist playlist, {
  Future<void> Function(SavedSong)? onSongDownloaded,
}) async {
  // Entitlement Check: download_songs
  final entitlements = Provider.of<EntitlementService>(
    context,
    listen: false,
  );
  final lang = Provider.of<LanguageProvider>(context, listen: false);
  final int downloadLimit = entitlements.getFeatureLimit('download_songs');
  final int lifetimeCount = provider.lifetimeDownloadCount;
  final int earnedCredits = provider.earnedDownloadCredits;

  // Se il limite è 0 (Disabilitato) e non è -99 (Modo Pubblicità)
  if (downloadLimit == 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('no_permission_download'),
        ),
      ),
    );
    return;
  }

  final int effectiveLimit = (downloadLimit == -99) ? 0 : downloadLimit;
  final int remainingCredits = (effectiveLimit == -1)
      ? -1 // Illimitato
      : (effectiveLimit + earnedCredits - lifetimeCount);

  if (remainingCredits <= 0 && downloadLimit != -1) {
    // Show an elegant popup to offer the rewarded ad
    final bool? proceed = await GlassUtils.showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: Container(
          width: double.maxFinite,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).primaryColor.withValues(alpha: 0.1),
                const Color(0xFF1a1a2e).withValues(alpha: 0.8),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Theme.of(context).primaryColor.withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 24),
              // Animated-like Icon Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).primaryColor.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.1),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.stars_rounded,
                  color: Colors.amberAccent,
                  size: 48,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                lang.translate('ad_offer_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  lang.translate('ad_offer_desc'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Styled Note Box
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: Colors.white.withValues(alpha: 0.6),
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          lang.translate('ad_offer_note'),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Actions
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(
                          lang.translate('cancel'),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          lang.translate('watch_ad'),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (proceed == true) {
      // Show loading indicator
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 16),
                Text(lang.translate('loading_ad')),
              ],
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      int earnedAmount = 0;
      final bool rewardEarned = await RewardedAdService().showAdIfAvailable(
        onUserEarnedReward: (ad, reward) {
          earnedAmount = reward.amount.toInt();
        },
        onAdNotAvailable: () {
          if (context.mounted) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(lang.translate('ad_not_available')),
                backgroundColor: Colors.redAccent,
              ),
            );
          }
        },
      );

      if (rewardEarned) {
        final int bonus = earnedAmount > 0 ? earnedAmount : 5;
        await provider.addEarnedDownloadCredits(bonus);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lang
                  .translate('credits_earned_msg')
                  .replaceAll('{0}', bonus.toString()),
            ),
            backgroundColor: Colors.green,
          ),
        );
        // Ricominciamo la funzione per aggiornare i calcoli
        return await downloadPlaylist(context, provider, playlist);
      }
    }
    return;
  }

  // 0. High Data Usage Confirmation
  final bool shouldProceed =
      await GlassUtils.showGlassDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          surfaceTintColor: Colors.transparent,
          elevation: 24,
          shadowColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.7),
              width: 1,
            ),
          ),
          title: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.signal_wifi_off_rounded,
                  color: Colors.orangeAccent,
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                Provider.of<LanguageProvider>(
                  context,
                  listen: false,
                ).translate('data_usage_warning'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                Provider.of<LanguageProvider>(
                  context,
                  listen: false,
                ).translate('data_usage_desc'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
              if (remainingCredits != -1)
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        lang
                            .translate('remaining_downloads')
                            .replaceAll('{0}', remainingCredits.toString()),
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: InkWell(
                        onTap: () async {
                          int earnedAmount = 0;
                          bool earned = await RewardedAdService()
                              .showAdIfAvailable(
                                onUserEarnedReward: (ad, reward) {
                                  earnedAmount = reward.amount.toInt();
                                },
                                onAdNotAvailable: () {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(
                                      context,
                                    ).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          lang.translate('ad_not_available'),
                                        ),
                                        backgroundColor: Colors.redAccent,
                                      ),
                                    );
                                  }
                                },
                              );

                          if (earned) {
                            final int bonus = earnedAmount > 0
                                ? earnedAmount
                                : 1;
                            await provider.addEarnedDownloadCredits(bonus);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    lang
                                        .translate('credits_earned_msg')
                                        .replaceAll('{0}', bonus.toString()),
                                  ),
                                  backgroundColor: Colors.green,
                                ),
                              );
                              Navigator.pop(ctx, null);
                              downloadPlaylist(context, provider, playlist);
                            }
                          }
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.amber.withValues(alpha: 0.1),
                                Colors.amber.withValues(alpha: 0.2),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.amber.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.stars_rounded,
                                color: Colors.amber,
                                size: 24,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                "${lang.translate('bonus')} - ${lang.translate('watch_ad')}",
                                style: const TextStyle(
                                  color: Colors.amber,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.blueAccent.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: Colors.blueAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        Provider.of<LanguageProvider>(
                          context,
                          listen: false,
                        ).translate('wifi_recommendation'),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      Provider.of<LanguageProvider>(
                        context,
                        listen: false,
                      ).translate('cancel'),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      Provider.of<LanguageProvider>(
                        context,
                        listen: false,
                      ).translate('continue'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ) ??
      false;

  if (!shouldProceed) return;

  // 1. Initialize Notifiers BEFORE the dialog so they are ready
  ValueNotifier<String> songTitleNotifier = ValueNotifier("Initializing...");
  ValueNotifier<String> statusNotifier = ValueNotifier("Waiting...");
  ValueNotifier<double> currentFileProgress = ValueNotifier(0.0);
  ValueNotifier<double> totalProgress = ValueNotifier(0.0);
  bool isJobCancelled = false;
  bool isDismissed = false;
  int notificationId = playlist.id.hashCode;

  // Placeholder for saveDir until we determine it
  String currentPath = "Determining Path...";
  ValueNotifier<String> pathNotifier = ValueNotifier(currentPath);

  final cancelSubscription = NotificationService().onCancelDownload.listen((
    id,
  ) {
    if (id == notificationId) {
      isJobCancelled = true;
      statusNotifier.value = "Stopping...";
    }
  });

  // 1. Initial Global Sync: Link any already downloaded duplicates
  await provider.syncAllDownloadStatuses();

  // 2. Show Progress Dialog IMMEDIATELY
  if (!context.mounted) return;

  GlassUtils.showGlassDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: Center(
        child: Card(
          color: Theme.of(context).cardColor.withValues(alpha: 0.7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            width: 320,
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Downloading Playlist",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 20),

                // Song Title
                ValueListenableBuilder<String>(
                  valueListenable: songTitleNotifier,
                  builder: (context, title, _) {
                    return Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    );
                  },
                ),
                const SizedBox(height: 20),

                // File Progress Bar
                ValueListenableBuilder<double>(
                  valueListenable: currentFileProgress,
                  builder: (context, progress, _) {
                    return Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Current Song",
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            ValueListenableBuilder<String>(
                              valueListenable: statusNotifier,
                              builder: (context, status, _) => Text(
                                status,
                                style: const TextStyle(
                                  color: Colors.greenAccent,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.white10,
                          color: Colors.greenAccent,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 16),

                // Total Progress Bar
                Column(
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Total Progress",
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ValueListenableBuilder<double>(
                      valueListenable: totalProgress,
                      builder: (context, progress, _) {
                        return LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.white10,
                          color: Colors.blueAccent,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Action Buttons
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          isJobCancelled = true;
                          statusNotifier.value = "Stopping...";
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent.withValues(
                            alpha: 0.1,
                          ),
                          foregroundColor: Colors.redAccent,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Colors.redAccent),
                          ),
                        ),
                        icon: const Icon(Icons.stop_rounded, size: 18),
                        label: const Text(
                          "Stop",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          isDismissed = true;
                          Navigator.pop(ctx);

                          // Trigger initial notification immediately upon hiding
                          NotificationService().showDownloadProgress(
                            id: notificationId,
                            title: playlist.name,
                            subTitle: "Preparing...",
                            progress: 0,
                            maxProgress: playlist.songs.length * 100,
                          );

                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Download continuing in background",
                              ),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent.withValues(
                            alpha: 0.1,
                          ),
                          foregroundColor: Colors.blueAccent,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Colors.blueAccent),
                          ),
                        ),
                        icon: const Icon(
                          Icons.visibility_off_rounded,
                          size: 18,
                        ), // Hide dialog icon
                        label: const Text(
                          "Hide",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  // 3. Perform Async Setup inside a try-catch
  Directory saveDir;
  try {
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.audio,
      ].request().timeout(const Duration(seconds: 10), onTimeout: () => {});
    }

    String safeName = playlist.name
        .replaceAll(RegExp(r'[^\w\-]'), '_')
        .trim();
    if (safeName.isEmpty) safeName = "playlist_${playlist.id}";

    Directory? fallbackBase;

    if (Platform.isAndroid) {
      saveDir = Directory(
        '/storage/emulated/0/Android/media/com.fazio.musicstream/download/$safeName',
      );
    } else {
      try {
        fallbackBase = await getDownloadsDirectory();
      } catch (_) {}
      fallbackBase ??= await getApplicationDocumentsDirectory();
      saveDir = Directory('${fallbackBase.path}/MusicStream/$safeName');
    }

    if (!saveDir.existsSync()) {
      try {
        await saveDir.create(recursive: true);
      } catch (e) {
        fallbackBase ??= await getApplicationDocumentsDirectory();
        saveDir = Directory('${fallbackBase.path}/MusicStream/$safeName');
        await saveDir.create(recursive: true);
      }
    }

    pathNotifier.value = saveDir.path;
  } catch (e) {
    if (context.mounted && !isDismissed) Navigator.pop(context);
    return;
  }

  int successCount = 0;
  List<SavedSong> updatedSongs = List.from(playlist.songs);
  bool anyUpdate = false;

  try {
    for (int i = 0; i < updatedSongs.length; i++) {
      if (isJobCancelled) break;

      final song = updatedSongs[i];
      final String progressText =
          "${i + 1}/${updatedSongs.length}: ${song.title}";
      songTitleNotifier.value = progressText;
      statusNotifier.value = "Preparing...";

      if (isDismissed && !isJobCancelled) {
        NotificationService().showDownloadProgress(
          id: notificationId,
          title: playlist.name,
          subTitle: "Song ${i + 1}/${updatedSongs.length}: ${song.title}",
          progress: i * 100,
          maxProgress: updatedSongs.length * 100,
        );
      }
      currentFileProgress.value = 0.0;

      bool isHandled = false;

      // 1. Device Search
      if (song.localPath != null) {
        if (File(song.localPath!).existsSync()) {
          successCount++;
          isHandled = true;
          
          if (onSongDownloaded != null) {
            await onSongDownloaded(updatedSongs[i]);
          }
        } else {
          updatedSongs[i] = song.copyWith(forceClearLocalPath: true);
          anyUpdate = true;
          // Persist the clearance immediately
          if (!playlist.id.startsWith('temp_')) {
            await provider.updateSongsInPlaylist(playlist.id, updatedSongs);
          }
        }
      }

      if (!isHandled && !isJobCancelled) {
        try {
          final foundOnDevice = await provider
              .findSongOnDevice(song.title, song.artist)
              .timeout(const Duration(seconds: 5));
          if (foundOnDevice != null && File(foundOnDevice).existsSync()) {
            updatedSongs[i] = song.copyWith(localPath: foundOnDevice);
            anyUpdate = true;
            successCount++;
            isHandled = true;
            // Sync this status to all other playlists
            await provider.updateSongDownloadStatusGlobally(updatedSongs[i]);
          }
        } catch (_) {}
      }

      // 2. Internal Cache Check
      if (!isHandled && !isJobCancelled) {
        final hashedId = sha1.convert(utf8.encode(song.id)).toString();
        File? confirmedCache;

        // New check for hashed name and .mst extension
        final mstFile = File('${saveDir.path}/$hashedId.mst');

        // Legacy check for old extension/unhashed
        final safeId = song.id.replaceAll(RegExp(r'[^\w\d_]'), '');
        final m4aFile = File('${saveDir.path}/${safeId}_secure.m4a');
        final webmFile = File('${saveDir.path}/${safeId}_secure.webm');

        if (mstFile.existsSync() && mstFile.lengthSync() > 1024 * 50) {
          confirmedCache = mstFile;
        } else if (m4aFile.existsSync() && m4aFile.lengthSync() > 1024 * 50) {
          confirmedCache = m4aFile;
        } else if (webmFile.existsSync() &&
            webmFile.lengthSync() > 1024 * 50) {
          confirmedCache = webmFile;
        }

        if (confirmedCache != null) {
          updatedSongs[i] = song.copyWith(localPath: confirmedCache.path);
          anyUpdate = true;
          successCount++;
          isHandled = true;
          // Sync this status to all other playlists
          await provider.updateSongDownloadStatusGlobally(updatedSongs[i]);
          
          if (onSongDownloaded != null) {
            await onSongDownloaded(updatedSongs[i]);
          }
          
          // Persist progress
          if (!playlist.id.startsWith('temp_')) {
            await provider.updateSongsInPlaylist(playlist.id, updatedSongs);
          }
        }
      }

      // 3. Download
      if (!isHandled) {
        if (isJobCancelled) break;

        // Check limit again before downloading a BRAND NEW song
        final currentRemaining = (effectiveLimit == -1)
            ? -1
            : (effectiveLimit +
                  provider.earnedDownloadCredits -
                  provider.lifetimeDownloadCount);

        if (currentRemaining != -1 && currentRemaining <= 0) {
          statusNotifier.value = "Limit Reached";
          if (context.mounted && !isDismissed) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Download limit reached. Skipping remaining."),
                duration: const Duration(seconds: 3),
              ),
            );
          }
          break; // Stop the entire playlist download if limit reached
        }

        try {
          String? audioUrl = song.youtubeUrl;
          if (audioUrl == null) {
            final links = await provider
                .resolveLinks(
                  title: song.title,
                  artist: song.artist,
                  youtubeUrl: song.youtubeUrl,
                  appleMusicUrl: song.appleMusicUrl,
                )
                .timeout(const Duration(seconds: 20));
            audioUrl = links['youtube'];

            audioUrl ??= await provider.searchYoutubeVideo(
              song.title,
              song.artist,
            );
          }

          if (audioUrl != null) {
            if (isJobCancelled) break;

            var videoId = YoutubePlayer.convertUrlToId(audioUrl);
            if (videoId == null && audioUrl.contains('v=')) {
              videoId = audioUrl.split('v=').last.split('&').first;
            }

            if (videoId != null) {
              int retryCount = 0;
              const int maxRetries = 2;
              bool downloadSuccess = false;

              while (retryCount < maxRetries && !downloadSuccess) {
                if (isJobCancelled) break;

                try {
                  statusNotifier.value = retryCount == 0
                      ? "Downloading..."
                      : "Retry ${retryCount + 1}...";

                  if (retryCount > 0) {
                    await Future.delayed(const Duration(milliseconds: 500));
                  }
                  if (isJobCancelled) break;

                  final yt = ye.YoutubeExplode();

                  try {
                    final manifest = await yt.videos.streamsClient
                        .getManifest(videoId)
                        .timeout(const Duration(seconds: 40));

                    ye.StreamInfo? audioStreamInfo;

                    final m4aStreams = manifest.audioOnly.where(
                      (s) => s.container.name == 'm4a',
                    );

                    if (m4aStreams.isNotEmpty) {
                      audioStreamInfo = m4aStreams.withHighestBitrate();
                    } else {
                      final muxedStreams = manifest.muxed.where(
                        (s) => s.container.name == 'mp4',
                      );
                      if (muxedStreams.isNotEmpty) {
                        audioStreamInfo = muxedStreams.withHighestBitrate();
                      } else {
                        audioStreamInfo = manifest.audioOnly
                            .withHighestBitrate();
                      }
                    }

                    final hashedId = sha1
                        .convert(utf8.encode(song.id))
                        .toString();
                    final fileName = '$hashedId.mst';
                    final file = File('${saveDir.path}/$fileName');

                    if (await file.exists()) {
                      try {
                        await file.delete();
                      } catch (_) {}
                    }

                    int totalBytes = audioStreamInfo.size.totalBytes;
                    int receivedBytes = 0;
                    int bytesSinceLastUpdate = 0;
                    DateTime lastUpdateTime = DateTime.now();

                    final stream = yt.videos.streamsClient.get(
                      audioStreamInfo,
                    );
                    final iosink = file.openWrite(mode: FileMode.writeOnly);

                    try {
                      await for (final data in stream.timeout(
                        const Duration(seconds: 45),
                      )) {
                        if (isJobCancelled) {
                          throw Exception("CancelledByUser");
                        }

                        iosink.add(EncryptionService().encryptData(data));
                        receivedBytes += data.length;
                        bytesSinceLastUpdate += data.length;

                        final now = DateTime.now();
                        final timeDiff = now
                            .difference(lastUpdateTime)
                            .inMilliseconds;

                        if (bytesSinceLastUpdate > 100 * 1024 ||
                            timeDiff > 500) {
                          double curProgress = 0.0;
                          if (totalBytes > 0) {
                            curProgress = (receivedBytes / totalBytes).clamp(
                              0.0,
                              1.0,
                            );
                          }
                          currentFileProgress.value = curProgress;

                          final speedKbps = timeDiff > 0
                              ? (bytesSinceLastUpdate / 1024) /
                                    (timeDiff / 1000)
                              : 0.0;
                          final speedStr = speedKbps > 1024
                              ? "${(speedKbps / 1024).toStringAsFixed(1)} MB/s"
                              : "${speedKbps.toStringAsFixed(0)} KB/s";

                          statusNotifier.value = "$speedStr";

                          lastUpdateTime = now;
                          bytesSinceLastUpdate = 0;

                          // Update notification progress within the stream
                          if (isDismissed && !isJobCancelled) {
                            final int totalSongs = updatedSongs.length;
                            final int songIndex = i;
                            // Total progress: (current song index * 100) + current song percentage
                            final int overallProgress =
                                (songIndex * 100) +
                                (curProgress * 100).toInt();

                            NotificationService().showDownloadProgress(
                              id: notificationId,
                              title: playlist.name,
                              subTitle:
                                  "Song ${i + 1}/$totalSongs: ${song.title} (${(curProgress * 100).toInt()}%)",
                              progress: overallProgress,
                              maxProgress: totalSongs * 100,
                            );
                          }
                        }
                      }
                    } finally {
                      await iosink.flush();
                      await iosink.close();
                    }

                    if (isJobCancelled) {
                      if (await file.exists()) {
                        await file.delete();
                      }
                      break;
                    }

                    final finalLength = await file.length();
                    if (finalLength < 100 * 1024) {
                      throw Exception("File is incomplete.");
                    }

                    // If we resolved the URL dynamically, save it too
                    updatedSongs[i] = song.copyWith(
                      localPath: file.path,
                      youtubeUrl: audioUrl,
                    );
                    anyUpdate = true;
                    successCount++;
                    downloadSuccess = true;

                    // CONSUMA CREDITO PERMANENTE
                    await provider.incrementLifetimeDownloadCount();

                    // Sync this status to all other playlists
                    await provider.updateSongDownloadStatusGlobally(
                      updatedSongs[i],
                    );
                    
                    if (onSongDownloaded != null) {
                      await onSongDownloaded(updatedSongs[i]);
                    }
                    
                    // Persist progress immediately so we don't lose it if killed
                    if (!playlist.id.startsWith('temp_')) {
                      await provider.updateSongsInPlaylist(
                        playlist.id,
                        updatedSongs,
                      );
                    }
                  } finally {
                    yt.close();
                  }
                } catch (e) {
                  if (e.toString().contains("CancelledByUser")) {
                    // Cleanup partial file on cancellation
                    final hashedId = sha1
                        .convert(utf8.encode(song.id))
                        .toString();
                    try {
                      final mstFile = File('${saveDir.path}/$hashedId.mst');
                      if (await mstFile.exists()) await mstFile.delete();
                    } catch (_) {}
                    break; // Break retry loop
                  }
                  retryCount++;
                  if (retryCount >= maxRetries) {
                    // Final failure, cleanup
                    final hashedId = sha1
                        .convert(utf8.encode(song.id))
                        .toString();
                    try {
                      final mstFile = File('${saveDir.path}/$hashedId.mst');
                      if (await mstFile.exists()) await mstFile.delete();
                    } catch (_) {}
                  }
                }
              }
            }
          }
        } catch (e) {
          // Error solving link
        }
      }

      totalProgress.value = (i + 1) / updatedSongs.length;
      if (isJobCancelled) break;
    }

    if (anyUpdate && !playlist.id.startsWith('temp_')) {
      await provider.updateSongsInPlaylist(playlist.id, updatedSongs);
    }
  } catch (e) {
    // General error
  } finally {
    if (context.mounted && !isDismissed) Navigator.pop(context);
    cancelSubscription.cancel();

    if (isJobCancelled) {
      NotificationService().cancel(notificationId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Provider.of<LanguageProvider>(
                context,
                listen: false,
              ).translate('download_cancelled'),
            ),
          ),
        );
      }
    } else {
      if (isDismissed) {
        // Show final completion in notification
        NotificationService().showDownloadProgress(
          id: notificationId,
          title: playlist.name,
          subTitle:
              "Download Complete: $successCount / ${playlist.songs.length}",
          progress: playlist.songs.length * 100,
          maxProgress: playlist.songs.length * 100,
        );
        // Only clear after a delay so they see it's done
        Future.delayed(const Duration(seconds: 5), () {
          NotificationService().cancel(notificationId);
        });
      } else {
        NotificationService().cancel(notificationId);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Download Complete: $successCount / ${playlist.songs.length}",
            ),
          ),
        );
      }
    }
  }
}
