import 'package:http/http.dart' as http;

void main() async {
  final url =
      "https://4c4b867c89244861ac216426883d1ad0.msvdn.net/radiodeejay/radiodeejay/master_ma.m3u8";
  try {
    final response = await http.get(Uri.parse(url));
    print("Code: ${response.statusCode}");
    print("Body:\n${response.body}");

    // If it works, try to extract the inner m3u8
    final lines = response.body.split('\n');
    for (var line in lines) {
      if (line.isNotEmpty && !line.startsWith("#")) {
        print("Next URL candidate: $line");
        var finalUrl = line;
        if (!line.startsWith("http")) {
          // relative path resolution (simple)
          final parent = url.substring(0, url.lastIndexOf('/'));
          finalUrl = "$parent/$line";
        }
        print("Fetching inner: $finalUrl");
        final innerResp = await http.get(Uri.parse(finalUrl));
        print("Inner Body:\n${innerResp.body}");
        break; // just check first
      }
    }
  } catch (e) {
    print("Error: $e");
  }
}
