import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/radio_provider.dart';
import '../providers/theme_provider.dart';
import 'backup_service.dart';

/// Runs the complete Google sign-in flow, identical to the "Accedi" button in
/// Settings: snapshots the guest session, switches to the Google account and
/// restores the cloud backup. Returns true when the user signed in.
Future<bool> runGoogleSignInFlow(
  BuildContext context,
  RadioProvider radio,
  BackupService auth,
  ThemeProvider theme,
) async {
  try {
    await radio.snapshotGuestSession();
    try {
      await radio.audioHandler.stop();
    } catch (_) {}

    // Pulisce tutto il vecchio stato Guest PRIMA di caricare Google
    await radio.resetAllData(themeProvider: theme, restoreGuest: false);

    await auth.signIn();
    if (auth.isSignedIn) {
      // Forza il ripristino totale dal cloud (isFullReplace: true)
      await radio.restoreBackup(isFullReplace: true);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('was_guest', false);
      return true;
    }

    if (context.mounted) {
      _showMessage(
        context,
        "Sign in canceled",
        const EdgeInsets.only(bottom: 40, left: 80, right: 80),
        const Duration(seconds: 2),
      );
    }
    return false;
  } catch (e) {
    if (context.mounted) {
      _showMessage(
        context,
        "Sign-in failed. Try again.",
        const EdgeInsets.only(bottom: 40, left: 60, right: 60),
        const Duration(seconds: 3),
      );
    }
    return false;
  }
}

void _showMessage(
  BuildContext context,
  String text,
  EdgeInsets margin,
  Duration duration,
) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
        textAlign: TextAlign.center,
      ),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      margin: margin,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      elevation: 0,
    ),
  );
}