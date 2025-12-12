import 'package:http/http.dart' as http;

void main() async {
  final url =
      "http://radiodeejay-lh.akamaihd.net/i/RadioDeejay_Live_1@189857/master.m3u8";
  try {
    final response = await http.get(Uri.parse(url));
    print("Code: ${response.statusCode}");
    print("Body:\n${response.body}");
  } catch (e) {
    print("Error: $e");
  }
}
