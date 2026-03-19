import 'dart:io';
import 'package:flutter/services.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart'; // For kReleaseMode

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'providers/radio_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/language_provider.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'services/backup_service.dart';
import 'screens/login_screen.dart';

import 'package:audio_service/audio_service.dart';

import 'services/radio_audio_handler.dart';
import 'package:workmanager/workmanager.dart';
import 'services/background_tasks.dart';
import 'widgets/global_hidden_player.dart';
import 'widgets/connectivity_banner.dart';
import 'widgets/admob_banner_widget.dart';
import 'services/encryption_service.dart';
import 'services/entitlement_service.dart';
import 'widgets/admin_debug_overlay.dart';
import 'services/app_open_ad_manager.dart';
import 'services/notification_service.dart';
import 'services/user_sync_service.dart';

late AudioHandler audioHandler;

@pragma('vm:entry-point')
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Ensure Analytics is active and log the first event
  final analytics = FirebaseAnalytics.instance;
  await analytics.setAnalyticsCollectionEnabled(true);

  if (kDebugMode) {
    debugPrint(
      "📊 Firebase Analytics [DEBUG]: Session started. Ensure DebugView is active on device.",
    );
  }

  await analytics.logAppOpen();
  debugPrint("✅ Firebase Analytics: App Open Event Logged");

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  debugPrint("App Entry Point");

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    Workmanager().initialize(callbackDispatcher, isInDebugMode: !kReleaseMode);
  }

  debugPrint("Initializing AudioService in main()...");
  audioHandler = await AudioService.init(
    builder: () => RadioAudioHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.antigravity.radio.channel.audio.v2',
      androidNotificationChannelName: 'Radio Playback',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidNotificationClickStartsActivity: true,
      androidResumeOnClick: true,
      androidShowNotificationBadge: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );

  debugPrint("Initializing EncryptionService...");
  await EncryptionService().init();

  runApp(const AppBootstrapper());
}

class AppBootstrapper extends StatefulWidget {
  const AppBootstrapper({super.key});

  @override
  State<AppBootstrapper> createState() => _AppBootstrapperState();
}

class _AppBootstrapperState extends State<AppBootstrapper> {
  bool _isInitialized = false;
  String? _error;
  late BackupService _backupService;

  @override
  void initState() {
    super.initState();
    _backupService = BackupService();
    _initApp();
  }

  Future<void> _initApp() async {
    debugPrint("Initializing App...");
    try {
      // Simulate small delay to ensure UI renders first frame
      await Future.delayed(const Duration(milliseconds: 100));

      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        MobileAds.instance.initialize();
      }

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e, stack) {
      debugPrint("Initialization Error: $e");
      debugPrint(stack.toString());
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1. Error State
    if (_error != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF0a0a0f),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: SingleChildScrollView(
                child: Text(
                  "Startup Error:\n$_error",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 2. Loading State
    if (!_isInitialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(
            0xFF0a0a0f,
          ), // Set a consistent background color
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 20),
                Text(
                  "Initializing Audio Service...",
                  style: GoogleFonts.inter(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 3. App Loaded
    final entitlementService = EntitlementService(_backupService);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _backupService),
        ChangeNotifierProvider.value(value: entitlementService),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LanguageProvider()),
        ChangeNotifierProvider(
          create: (_) =>
              RadioProvider(audioHandler, _backupService, entitlementService),
          lazy: false,
        ),
      ],
      child: const RadioApp(),
    );
  }
}

class RadioApp extends StatefulWidget {
  const RadioApp({super.key});

  @override
  State<RadioApp> createState() => _RadioAppState();
}

class _RadioAppState extends State<RadioApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final entitlements = Provider.of<EntitlementService>(
        context,
        listen: false,
      );
      AppOpenAdManager().init(entitlements);
      _initNotifications();
      _checkForUpdate();
    });
  }

  Future<void> _initNotifications() async {
    final notificationService = NotificationService();
    await notificationService.init();

    final userSyncService = UserSyncService(
      Provider.of<BackupService>(context, listen: false),
    );
    await userSyncService.syncUserInfo();

    // Trigger an internal event for Firebase In-App Messaging
    // You can create campaigns based on this 'app_opened' event in Firebase Console
    await notificationService.triggerInAppEvent('app_opened');
  }

  Future<void> _checkForUpdate() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final info = await InAppUpdate.checkForUpdate();
        if (info.updateAvailability == UpdateAvailability.updateAvailable) {
          if (mounted) {
            _showUpdateDialog();
          }
        }
      } catch (e) {
        debugPrint('Error checking for updates: $e');
      }
    }
  }

  void _showUpdateDialog() {
    final languageProvider = Provider.of<LanguageProvider>(
      context,
      listen: false,
    );

    showDialog(
      context: context,
      barrierDismissible: false, // Force user interaction
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1a1a24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          title: Text(
            languageProvider.translate('update_available'),
            style: GoogleFonts.inter(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            languageProvider.translate('update_desc'),
            style: GoogleFonts.inter(color: Colors.white.withOpacity(0.8)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                languageProvider.translate('later'),
                style: GoogleFonts.inter(color: Colors.white.withOpacity(0.6)),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await InAppUpdate.performImmediateUpdate();
                } catch (e) {
                  debugPrint('Error performing immediate update: $e');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Update failed: $e')),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: Text(
                languageProvider.translate('update_now'),
                style: GoogleFonts.inter(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppOpenAdManager().showAdIfAvailable();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeData.brightness == Brightness.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor:
            themeProvider.themeData.scaffoldBackgroundColor,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: MaterialApp(
        title: 'MusicStream',
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          if (child == null) return const SizedBox.shrink();

          final isSupportedPlatform =
              !kIsWeb && (Platform.isAndroid || Platform.isIOS);

          return Material(
            type: MaterialType.transparency,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        child,
                        const GlobalHiddenPlayer(),
                        const ConnectivityBanner(),
                        const AdminDebugOverlay(),
                      ],
                    ),
                  ),
                  Selector<RadioProvider, bool>(
                    selector: (_, p) => p.showGlobalBanner,
                    builder: (context, showBanner, child) {
                      if (isSupportedPlatform && showBanner) {
                        return Container(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: const SafeArea(
                            top: false,
                            child: AdMobBannerWidget(),
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            ),
          );
        },
        theme: themeProvider.themeData,
        darkTheme: themeProvider.themeData,
        themeMode: themeProvider.themeData.brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        navigatorObservers: [
          FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance),
        ],
        home: const LoginScreen(),
      ),
    );
  }
}
