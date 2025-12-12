import 'package:http/http.dart' as http;

void main() async {
  final url = "http://strm112.1.fm/urbanadult_mobile_mp3";
  print("Checking $url");
  try {
    final res = await http.head(Uri.parse(url)).timeout(Duration(seconds: 5));
    print("Status: ${res.statusCode}");
  } catch (e) {
    print("Error: $e");
  }
}
