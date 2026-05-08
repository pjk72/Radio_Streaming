import 'dart:io';

/// This class allows the application to handle network requests to servers
/// with misconfigured or self-signed SSL certificates. This is particularly
/// useful for radio streaming apps that interact with diverse third-party stations
/// which may have hostname mismatches or outdated certificates.
class RadioHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}
