import 'dart:io';
import 'package:flutter/services.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui';

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
import 'package:cached_network_image/cached_network_image.dart';

late AudioHandler audioHandler;

@pragma('vm:entry-point')
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  FlutterError.onError = (errorDetails) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
  await FirebasePerformance.instance.setPerformanceCollectionEnabled(true);

  final analytics = FirebaseAnalytics.instance;
  await analytics.setAnalyticsCollectionEnabled(true);
  await analytics.logAppOpen();

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    Workmanager().initialize(callbackDispatcher, isInDebugMode: !kReleaseMode);
  }

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

  await EncryptionService().init();

  runApp(const MusicStreamRoot());
}

class MusicStreamRoot extends StatefulWidget {
  const MusicStreamRoot({super.key});

  @override
  State<MusicStreamRoot> createState() => _MusicStreamRootState();
}

class _MusicStreamRootState extends State<MusicStreamRoot> {
  late BackupService _backupService;
  late EntitlementService _entitlementService;

  @override
  void initState() {
    super.initState();
    _backupService = BackupService();
    _entitlementService = EntitlementService(_backupService);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _backupService),
        ChangeNotifierProvider.value(value: _entitlementService),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LanguageProvider()),
        ChangeNotifierProvider(
          create: (_) =>
              RadioProvider(audioHandler, _backupService, _entitlementService),
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
  bool _isInitialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      // 2.5 seconds of splash screen time
      await Future.delayed(const Duration(milliseconds: 2500));

      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        MobileAds.instance.initialize();
      }

      final entitlements = Provider.of<EntitlementService>(
        context,
        listen: false,
      );
      AppOpenAdManager().init(entitlements);

      await _initNotifications();
      await _checkForUpdate();

      if (mounted) {
        setState(() => _isInitialized = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<void> _initNotifications() async {
    final notificationService = NotificationService();
    await notificationService.init();
    final userSyncService = UserSyncService(
      Provider.of<BackupService>(context, listen: false),
    );
    await userSyncService.syncUserInfo();
    await notificationService.triggerInAppEvent('app_opened');
  }

  Future<void> _checkForUpdate() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final info = await InAppUpdate.checkForUpdate();
        if (info.updateAvailability == UpdateAvailability.updateAvailable) {
          if (mounted) _showUpdateDialog();
        }
      } catch (_) {}
    }
  }

  void _showUpdateDialog() {
    final languageProvider = Provider.of<LanguageProvider>(
      context,
      listen: false,
    );
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a24),
        title: Text(languageProvider.translate('update_available')),
        content: Text(languageProvider.translate('update_desc')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(languageProvider.translate('later')),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await InAppUpdate.performImmediateUpdate();
            },
            child: Text(languageProvider.translate('update_now')),
          ),
        ],
      ),
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
        systemNavigationBarColor:
            themeProvider.themeData.scaffoldBackgroundColor,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
      ),
      child: MaterialApp(
        title: 'MusicStream',
        debugShowCheckedModeBanner: false,
        theme: themeProvider.themeData,
        builder: (context, child) {
          return Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                // 1. BASE COLOR LAYER
                Container(color: themeProvider.activeBackgroundColor),

                // 2. IMAGE LAYER
                if (!_isInitialized)
                  // SPLASH BACKGROUND (STAYS UNTIL FULLY LOADED)
                  Image.asset('assets/splash_bg.png', fit: BoxFit.cover)
                else if (themeProvider.customBackgroundImageUrl != null)
                  // CUSTOM IMAGE (AFTER INITIALIZATION)
                  CachedNetworkImage(
                    imageUrl: themeProvider.customBackgroundImageUrl!,
                    fit: BoxFit.cover,
                    placeholder: (context, url) =>
                        Container(color: themeProvider.activeBackgroundColor),
                    errorWidget: (context, url, error) =>
                        const SizedBox.shrink(),
                  ),

                // Global Overlay (only if an image is showing)
                if (!_isInitialized ||
                    themeProvider.customBackgroundImageUrl != null)
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.4),
                          Colors.black.withValues(alpha: 0.8),
                        ],
                      ),
                    ),
                  ),

                // Content Transition
                if (!_isInitialized)
                  _buildSplashContent()
                else if (_error != null)
                  _buildErrorContent()
                else
                  _buildMainContent(child!),
              ],
            ),
          );
        },
        home: const LoginScreen(),
      ),
    );
  }

  Widget _buildSplashContent() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            "MusicStream",
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 48,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 40),
          const CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
          const SizedBox(height: 20),
          Text(
            "Initializing Experience...",
            style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorContent() {
    return Center(
      child: Text(
        "Startup Error:\n$_error",
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.redAccent),
      ),
    );
  }

  Widget _buildMainContent(Widget navigator) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              navigator,
              const GlobalHiddenPlayer(),
              const ConnectivityBanner(),
              const AdminDebugOverlay(),
            ],
          ),
        ),
        // Banner Ad
        Selector<RadioProvider, bool>(
          selector: (_, p) => p.showGlobalBanner,
          builder: (context, showBanner, _) {
            if (showBanner) return const AdMobBannerWidget();
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }
}
