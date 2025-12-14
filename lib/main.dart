import 'dart:io';
import 'package:device_preview/device_preview.dart';
import 'package:flutter/foundation.dart'; // For kReleaseMode

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'providers/radio_provider.dart';

import 'screens/login_screen.dart';
import 'services/backup_service.dart';
import 'package:audio_service/audio_service.dart';
import 'services/radio_audio_handler.dart';
import 'package:workmanager/workmanager.dart';
import 'services/background_tasks.dart';

late AudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    Workmanager().initialize(callbackDispatcher, isInDebugMode: !kReleaseMode);
  }
  // Removed blocking permission request here

  audioHandler = await AudioService.init(
    builder: () => RadioAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.antigravity.radio.channel.audio.v2',
      androidNotificationChannelName: 'Radio Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationClickStartsActivity: true,
      androidResumeOnClick: true,
      androidShowNotificationBadge: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );

  final backupService = BackupService();

  runApp(
    DevicePreview(
      enabled: !kReleaseMode, // Enable only in debug mode
      builder: (context) => MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => backupService, lazy: false),
          ChangeNotifierProvider(
            create: (_) => RadioProvider(audioHandler, backupService),
            lazy: false,
          ),
        ],
        child: const RadioApp(),
      ),
    ),
  );
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
    return MaterialApp(
      title: 'Radio Stream',
      debugShowCheckedModeBanner: false,
      useInheritedMediaQuery: true, // Required for DevicePreview
      locale: DevicePreview.locale(context), // Required for DevicePreview
      builder: DevicePreview.appBuilder, // Required for DevicePreview
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0a0a0f),
        primaryColor: const Color(0xFF6c5ce7),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6c5ce7),
          secondary: Color(0xFF00cec9),
          surface: Color(0xFF13131f), // Panel color
        ),
        textTheme: GoogleFonts.interTextTheme(
          Theme.of(context).textTheme,
        ).apply(bodyColor: Colors.white, displayColor: Colors.white),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}
