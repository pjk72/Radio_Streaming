import 'dart:io';
import 'package:flutter/services.dart';
// import 'package:device_preview/device_preview.dart'; // Disabled for debugging
import 'package:flutter/foundation.dart'; // For kReleaseMode

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'providers/radio_provider.dart';
import 'providers/theme_provider.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'services/backup_service.dart';
import 'services/log_service.dart';
import 'screens/login_screen.dart';
import 'package:flutter_ironsource_x/ironsource.dart';
import 'package:audio_service/audio_service.dart';
import 'services/radio_audio_handler.dart';
import 'package:workmanager/workmanager.dart';
import 'services/background_tasks.dart';
import 'widgets/global_hidden_player.dart';
import 'widgets/connectivity_banner.dart';

late AudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  debugPrint("App Entry Point");

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    Workmanager().initialize(callbackDispatcher, isInDebugMode: !kReleaseMode);
  }

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

      debugPrint("Initializing AudioService...");
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        MobileAds.instance.initialize();
        // Initialize IronSource
        try {
          LogService().log("Initializing IronSource SDK...");
          await IronSource.initialize(appKey: '24c9e07a5');
          LogService().log("IronSource Initialized Successfully");
          debugPrint("IronSource Initialized");

          // Validate Integration
          await IronSource.validateIntegration();
          final advertiserId = await IronSource.getAdvertiserId();
          LogService().log(
            "IronSource Integration Validated. AdvertiserID: $advertiserId",
          );
        } catch (e) {
          LogService().log("IronSource Init Error: $e");
          debugPrint("IronSource Init Error: $e");
        }
      }
      audioHandler = await AudioService.init(
        builder: () => RadioAudioHandler(),
        config: AudioServiceConfig(
          androidNotificationChannelId:
              'com.antigravity.radio.channel.audio.v2',
          androidNotificationChannelName: 'Radio Playback',
          androidNotificationOngoing:
              false, // Must be false if androidStopForegroundOnPause is false
          androidStopForegroundOnPause: false,
          androidNotificationClickStartsActivity: true,
          androidResumeOnClick: true,
          androidShowNotificationBadge: true,
          androidNotificationIcon: 'mipmap/ic_launcher',
        ),
      );
      debugPrint("AudioService Initialized");

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
          backgroundColor:
              Colors.blue, // DEBUG: Blue background to verify rendering
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
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _backupService),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(
          create: (_) => RadioProvider(audioHandler, _backupService),
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Attempt to stop the service if the app is being detached (closed)
    // and we are not currently playing (streaming).
    if (state == AppLifecycleState.detached) {
      if (audioHandler.playbackState.value.playing == false) {
        audioHandler.stop();
        exit(0); // Force kill process to ensure fresh start next time
      }
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
          return Stack(
            children: [
              child!,
              const GlobalHiddenPlayer(), // Persists across navigation
              const ConnectivityBanner(), // Shows "No Internet" when offline
            ],
          );
        },
        theme: themeProvider.themeData,
        darkTheme: themeProvider.themeData,
        themeMode: themeProvider.themeData.brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        home: const LoginScreen(),
      ),
    );
  }
}
