import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'providers/radio_provider.dart';

import 'screens/login_screen.dart';
import 'services/backup_service.dart';
import 'package:audio_service/audio_service.dart';
import 'services/radio_audio_handler.dart';

late AudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Removed blocking permission request here

  audioHandler = await AudioService.init(
    builder: () => RadioAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.antigravity.radio.channel.audio.v2',
      androidNotificationChannelName: 'Radio Playback',
      androidNotificationOngoing: true,
      androidNotificationClickStartsActivity: true,
      androidResumeOnClick: true,
      androidShowNotificationBadge: true,
      // Fix: Ensure icon is specified if needed, or rely on default.
      // Sometimes missing icon resource causes check failures in some versions.
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );

  final backupService = BackupService();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => backupService, lazy: false),
        ChangeNotifierProvider(
          create: (_) => RadioProvider(audioHandler, backupService),
          lazy: false,
        ),
      ],
      child: const RadioApp(),
    ),
  );
}

class RadioApp extends StatelessWidget {
  const RadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radio Stream',
      debugShowCheckedModeBanner: false,
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
