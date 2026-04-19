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
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'services/interstitial_ad_service.dart';
import 'widgets/admin_debug_overlay.dart';
import 'services/app_open_ad_manager.dart';
import 'services/notification_service.dart';
import 'services/user_sync_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'utils/glass_utils.dart';

import 'utils/http_overrides.dart';

late AudioHandler audioHandler;

@pragma('vm:entry-point')
Future<void> main() async {
  HttpOverrides.global = RadioHttpOverrides();
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  bool isNonFatalError(dynamic error) {
    final String errorStr = error.toString();
    return errorStr.contains("Failed to load font") ||
        errorStr.contains("fonts.gstatic.com") ||
        errorStr.contains("SocketException") ||
        errorStr.contains("HandshakeException") ||
        errorStr.contains("TimeoutException") ||
        errorStr.contains("MEDIA_ERROR_SERVER_DIED") ||
        errorStr.contains("PermissionHandler") ||
        errorStr.contains("HTTP request failed") ||
        errorStr.contains("NetworkImage") ||
        errorStr.contains("statusCode:") ||
        errorStr.contains("Network is unreachable") ||
        errorStr.contains("googleusercontent.com") ||
        errorStr.contains("Unable to load asset") ||
        errorStr.contains("asset: \"null\"") ||
        errorStr.contains("errno = 101");
  }

  FlutterError.onError = (errorDetails) {
    if (isNonFatalError(errorDetails.exception)) {
      FirebaseCrashlytics.instance.recordError(
        errorDetails.exception,
        errorDetails.stack,
        fatal: false,
      );
    } else {
      FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(
      error,
      stack,
      fatal: !isNonFatalError(error),
    );
    return true;
  };

  await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
  await FirebasePerformance.instance.setPerformanceCollectionEnabled(true);

  final analytics = FirebaseAnalytics.instance;
  await analytics.setAnalyticsCollectionEnabled(true);
  await analytics.logAppOpen();

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  if (!kIsWeb) {
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
    // Removed InterstitialAdService().loadAd() from here as SDK is not yet initialized
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _backupService),
        ChangeNotifierProvider.value(value: _entitlementService),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LanguageProvider()),
        ChangeNotifierProxyProvider<LanguageProvider, RadioProvider>(
          create: (ctx) => RadioProvider(
            audioHandler,
            _backupService,
            _entitlementService,
          )..updateLanguageCode(
            Provider.of<LanguageProvider>(ctx, listen: false)
                .resolvedLanguageCode,
          ),
          update: (ctx, lang, radio) {
            if (radio != null) {
              radio.updateLanguageCode(lang.resolvedLanguageCode);
            }
            return radio!;
          },
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
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  bool _isInitialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();
  }

  Future<void> _initApp() async {
    // 1. Start the minimum splash timer immediately (2.5s)
    final splashTimer = Future.delayed(const Duration(milliseconds: 2500));

    try {
      // 2. CRITICAL INITIALIZATIONS
      if (!kIsWeb) {
        try {
          await MobileAds.instance
              .initialize()
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
      }

      final entitlements = Provider.of<EntitlementService>(context, listen: false);
      AppOpenAdManager().init(entitlements);

      // Preload Interstitial Ads after library is initialized with entitlements
      InterstitialAdService().init(entitlements);

      // 3. SECONDARY INITIALIZATIONS (Wait for these but with a safety timeout)
      // This ensures the splash stays until they are done, but doesn't hang forever
      await Future.wait([
        _initNotifications().timeout(const Duration(seconds: 10)),
        splashTimer, // Ensure we stay at least 2.5s regardless
      ]).catchError((e) {
        debugPrint("Secondary initialization timed out or failed: $e");
        return [];
      });

      if (mounted) {
        setState(() => _isInitialized = true);
        // Trigger update check after initialization is complete
        // so the navigator is guaranteed to be in the tree
        _checkForUpdate();
      }
    } catch (e) {
      debugPrint("Startup Error: $e");
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isInitialized = true;
        });
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
    // Add a delay to ensure the splash screen is gone and the initial screen is visible
    await Future.delayed(const Duration(seconds: 3));

    // Wait if an App Open Ad is showing to avoid covering the dialog
    while (AppOpenAdManager().isShowingAd) {
      await Future.delayed(const Duration(seconds: 1));
    }

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final info = await InAppUpdate.checkForUpdate();
        debugPrint('Update available: ${info.updateAvailability}');
        if (info.updateAvailability == UpdateAvailability.updateAvailable) {
          if (mounted) _showUpdateDialog();
        }
      } catch (e) {
        debugPrint('Update check failed: $e');
      }
    }
  }

  void _showUpdateDialog() {
    final navContext = _navigatorKey.currentContext;
    if (navContext == null) return;

    final languageProvider = Provider.of<LanguageProvider>(
      navContext,
      listen: false,
    );
    GlassUtils.showGlassDialog(
      context: navContext,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
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
    final languageProvider = Provider.of<LanguageProvider>(context);
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
        navigatorKey: _navigatorKey,
        title: 'MusicStream',
        debugShowCheckedModeBanner: false,
        theme: themeProvider.themeData,
        locale: Locale(languageProvider.resolvedLanguageCode),
        supportedLocales: const [
          Locale('en'),
          Locale('it'),
          Locale('es'),
          Locale('fr'),
          Locale('de'),
          Locale('ru'),
          Locale('pt'),
          Locale('zh'),
          Locale('ar'),
        ],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
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
