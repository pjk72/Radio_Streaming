import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'log_service.dart';

class ShazamApiService {
  final String _host = 'shazam-core.p.rapidapi.com';
  // Replace with actual RapidAPI key
  final String _apiKey = '65c517cd98mshd509565706f012ep1e49f3jsne80c01e37828';

  http.Client? _activeClient;

  Future<Map<String, dynamic>?> identifyStream(String streamUrl) async {
    _activeClient = http.Client();
    try {
      final resolvedUrl = await _resolveStreamUrl(streamUrl);
      if (_activeClient == null) return null;
      LogService().log("ShazamAPI: Resolved URL: $resolvedUrl");

      // Download ~3 seconds of the stream (roughly 60KB of mp3)
      final Uint8List? audioData = await _downloadStreamChunk(
        resolvedUrl,
        80 * 1024,
      );

      if (_activeClient == null) return null;
      if (audioData == null || audioData.isEmpty) {
        LogService().log("ShazamAPI: Failed to download stream chunk.");
        return null;
      }

      // 4. Send MP3 straight to Shazam
      // With correct MediaType to avoid application/octet-stream rejection by API
      var request = http.MultipartRequest(
        'POST',
        Uri.https(_host, '/v1/tracks/recognize'),
      );

      request.headers['x-rapidapi-key'] = _apiKey;
      request.headers['x-rapidapi-host'] = _host;

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          audioData,
          filename: 'sample.mp3',
          contentType: MediaType('audio', 'mpeg'),
        ),
      );

      if (_activeClient == null) return null;
      final streamedResponse = await _activeClient!.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data; // Return raw Shazam JSON
      } else {
        LogService().log(
          "ShazamAPI HTTP Error: ${response.statusCode} - ${response.body}",
        );
      }
    } catch (e) {
      if (_activeClient != null) {
        LogService().log("ShazamAPI Exception: $e");
      } else {
        LogService().log("ShazamAPI Recognition Cancelled.");
      }
    } finally {
      _activeClient?.close();
      _activeClient = null;
    }
    return null;
  }

  void cancel() {
    LogService().log("ShazamAPI: Cancelling active recognition...");
    _activeClient?.close();
    _activeClient = null;
  }

  Future<Uint8List?> _downloadStreamChunk(String url, int maxSize) async {
    if (_activeClient == null) return null;
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'VLC/3.0.18 LibVLC/3.0.18';

      final response = await _activeClient!
          .send(request)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return null;

      final List<int> buffer = [];
      await for (var chunk in response.stream) {
        if (_activeClient == null) return null;
        buffer.addAll(chunk);
        if (buffer.length >= maxSize) break;
      }
      return Uint8List.fromList(buffer);
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveStreamUrl(String initialUrl) async {
    String currentUrl = initialUrl;
    for (int i = 0; i < 5; i++) {
      if (_activeClient == null) return currentUrl;
      final lower = currentUrl.toLowerCase();

      if (lower.endsWith('.mp3') ||
          lower.endsWith('.aac') ||
          lower.endsWith('.mp4') ||
          lower.endsWith('.ts')) {
        return currentUrl;
      }

      bool isPlaylist =
          lower.contains('.m3u8') ||
          lower.contains('.m3u') ||
          lower.contains('.pls');

      if (!isPlaylist) return currentUrl;

      try {
        final uri = Uri.parse(currentUrl);
        if (_activeClient == null) return currentUrl;

        final response = await _activeClient!.get(uri);
        if (response.statusCode != 200) return currentUrl;

        final body = response.body;
        final lines = body.split('\n');
        String? candidate;

        if (body.contains('[playlist]')) {
          final match = lines.firstWhere(
            (l) => l.toLowerCase().startsWith('file1='),
            orElse: () => '',
          );
          if (match.isNotEmpty) {
            candidate = match.split('=').last.trim();
          }
        } else {
          final validLines = lines
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty && !l.startsWith('#'))
              .toList();
          if (validLines.isNotEmpty) candidate = validLines.last;
        }

        if (candidate != null && candidate.isNotEmpty) {
          if (candidate.startsWith('http')) {
            currentUrl = candidate;
          } else {
            currentUrl = uri.resolve(candidate).toString();
          }
          continue;
        } else {
          return currentUrl;
        }
      } catch (e) {
        return currentUrl;
      }
    }
    return currentUrl;
  }
}
