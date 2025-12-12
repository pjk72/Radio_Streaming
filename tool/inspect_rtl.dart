import 'package:http/http.dart' as http;

void main() async {
  final url =
      "https://dd782ed59e2a4e86aabf6fc508674b59.msvdn.net/live/S97044836/tbbP8T1ZRPBL/playlist_audio.m3u8";
  print("Fetching $url");
  try {
    final response = await http.get(Uri.parse(url));
    print("Status: ${response.statusCode}");
    print("Body:\n${response.body}");

    if (response.statusCode == 200) {
      final lines = response.body.split('\n');
      for (var line in lines) {
        line = line.trim();
        if (line.isNotEmpty && !line.startsWith("#")) {
          print("First non-comment: $line");
          final next = Uri.parse(url).resolve(line);
          print("Resolves to: $next");

          print("Fetching inner...");
          final inner = await http.get(next);
          print("Inner Status: ${inner.statusCode}");
          print("Inner Body:\n${inner.body}");
          break;
        }
      }
    }
  } catch (e) {
    print("Error: $e");
  }
}
