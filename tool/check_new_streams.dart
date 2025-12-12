import 'package:http/http.dart' as http;

void main() async {
  final urls = [
    "http://strm112.1.fm/60s_70s_mobile_mp3",
    "http://strm112.1.fm/60s_70s_mp3",
    "http://ice1.somafm.com/u80s-128-mp3", // Just to check connectivity
    "http://media-ice.musicradio.com/MagicSoulMP3", // Guess
  ];

  for (final url in urls) {
    print("Checking $url");
    try {
      final res = await http.head(Uri.parse(url)).timeout(Duration(seconds: 5));
      print("Status: ${res.statusCode}");
    } catch (e) {
      print("Error: $e");
    }
  }
}
