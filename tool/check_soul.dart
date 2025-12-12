import 'package:http/http.dart' as http;

void main() async {
  final urls = [
    "https://icecast.omroep.nl/radio6-bb-mp3", // NPO Soul & Jazz
    "http://uk5.internet-radio.com:8104/stream", // A soul station
    "http://media-ice.musicradio.com/MagicSoul.mp3", // Another try
  ];

  for (final url in urls) {
    print("Checking $url");
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'Range': 'bytes=0-100'})
          .timeout(Duration(seconds: 5));
      print("Status: ${res.statusCode}");
    } catch (e) {
      print("Error: $e");
    }
  }
}
