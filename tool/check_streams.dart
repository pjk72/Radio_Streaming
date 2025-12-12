import 'package:http/http.dart' as http;

void main() async {
  final base = "https://icy.unitedradio.it";
  final names = [
    "RadioDeejay",
    "radiodeejay",
    "Deejay",
    "deejay",
    "Radio_Deejay",
    "Station_DJ",
    "dj",
    "OneNationOneStation",
  ];
  final exts = ["", ".mp3", ".aac"];

  for (final name in names) {
    for (final ext in exts) {
      final url = "$base/$name$ext";
      try {
        final response = await http
            .head(Uri.parse(url))
            .timeout(Duration(seconds: 2));
        if (response.statusCode == 200) {
          print("FOUND: $url");
          print("Type: ${response.headers['content-type']}");
        } else if (response.statusCode != 404) {
          print("Code ${response.statusCode}: $url");
        }
      } catch (e) {
        // ignore errors
      }
    }
  }

  // Also check some random external ones found in old lists
  final others = [
    "http://radiodeejay-lh.akamaihd.net/i/RadioDeejay_Live_1@189857/master.m3u8",
    "https://live.radiodeejay.it/stream",
    "http://webradio.radiodeejay.it",
  ];
  for (final url in others) {
    try {
      final response = await http
          .head(Uri.parse(url))
          .timeout(Duration(seconds: 2));
      print(
        "OTHER: $url -> ${response.statusCode} (${response.headers['content-type']})",
      );
    } catch (e) {
      print("OTHER Error: $url -> $e");
    }
  }
}
