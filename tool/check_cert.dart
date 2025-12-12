import 'dart:io';

void main() async {
  final url = "https://shoutcast.radio24.it/radio24.mp3";
  print("Checking cert for $url");

  try {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(url));
    print("Handshake/Connection successful (if no error)");
    final response = await request.close();
    print("Status: ${response.statusCode}");
  } catch (e) {
    if (e is HandshakeException) {
      print("Handshake Exception: $e");
      // We can't easily inspect the cert properties in standard Dart without more complex setup
      // But we know it failed.
    } else if (e is CertificateException) {
      print("Cert Exception: $e");
    } else {
      print("Error: $e");
    }
  }
}
