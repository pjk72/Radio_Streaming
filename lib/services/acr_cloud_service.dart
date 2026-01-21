import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class ACRCloudService {
  final String _host = 'identify-eu-west-1.acrcloud.com';
  final String _accessKey = 'e47be4f50a59873e2612ca7c4981538a';
  final String _secretKey = '5PTB3klzHKOvjjmwERuJnkl08aEeIV5xE4GGBOqP';

  http.Client? _activeClient;

  Future<Map<String, dynamic>?> identifyStream(String streamUrl) async {
    _activeClient = http.Client();
    try {
      // 0. Resolve Stream URL (Handle PLS/M3U)
      final resolvedUrl = await _resolveStreamUrl(streamUrl);
      if (_activeClient == null) return null; // Cancelled
      print("ACRCloud: Resolved URL: $resolvedUrl");

      // 1. Download a buffer of the stream
      // Reduced package size for faster/lighter request. ~6s is sufficient.
      final Uint8List? audioData = await _downloadStreamChunk(
        resolvedUrl,
        150 * 1024,
      );

      if (_activeClient == null) return null; // Cancelled
      if (audioData == null || audioData.isEmpty) {
        print("ACRCloud: Failed to download stream chunk.");
        return null;
      }

      // 2. Prepare Request
      final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000)
          .floor()
          .toString();

      // ACRCloud Signature V1 Format:
      // stringToSign = HTTP_METHOD + "\n" + HTTP_URI + "\n" + access_key + "\n" + data_type + "\n" + signature_version + "\n" + timestamp
      final stringToSign =
          'POST\n/v1/identify\n$_accessKey\naudio\n1\n$timestamp';

      final signature = base64Encode(
        Hmac(
          sha1,
          utf8.encode(_secretKey),
        ).convert(utf8.encode(stringToSign)).bytes,
      );

      var request = http.MultipartRequest(
        'POST',
        Uri.https(_host, '/v1/identify'),
      );

      request.fields['access_key'] = _accessKey;
      request.fields['data_type'] = 'audio';
      request.fields['signature_version'] = '1';
      request.fields['signature'] = signature;
      request.fields['timestamp'] = timestamp;
      request.fields['sample_bytes'] = audioData.length.toString();

      request.files.add(
        http.MultipartFile.fromBytes(
          'sample',
          audioData,
          filename: 'sample.mp3', // Generic extension, ACR handles most formats
        ),
      );

      if (_activeClient == null) return null; // Cancelled
      final streamedResponse = await _activeClient!.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final status = data['status'];
        if (status['code'] == 0) {
          // Success
          return data;
        } else {
          print("ACRCloud Error: ${status['msg']}");
        }
      } else {
        print("ACRCloud HTTP Error: ${response.statusCode}");
      }
    } catch (e) {
      if (_activeClient != null) {
        print("ACRCloud Exception: $e");
      } else {
        print("ACRCloud Recognition Cancelled.");
      }
    } finally {
      _activeClient?.close();
      _activeClient = null;
    }
    return null;
  }

  void cancel() {
    print("ACRCloud: Cancelling active recognition...");
    _activeClient?.close();
    _activeClient = null;
  }

  Future<Uint8List?> _downloadStreamChunk(String url, int maxSize) async {
    if (_activeClient == null) return null;
    try {
      final request = http.Request('GET', Uri.parse(url));
      // Add headers to mimic a real player to avoid strict anti-bot servers
      request.headers['User-Agent'] = 'VLC/3.0.18 LibVLC/3.0.18';
      // request.headers['Icy-MetaData'] = '1'; // REMOVED: Metadata injects bytes that corrupt the audio file for fingerprinting

      final response = await _activeClient!
          .send(request)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return null;

      final List<int> buffer = [];
      await for (var chunk in response.stream) {
        if (_activeClient == null) return null; // Interrupt if client closed
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
    // Limit recursion to avoid infinite loops
    for (int i = 0; i < 5; i++) {
      if (_activeClient == null) return currentUrl;
      final lower = currentUrl.toLowerCase();

      // If it looks like a direct audio file, return it
      // Note: .ts is standard for HLS segments
      if (lower.endsWith('.mp3') ||
          lower.endsWith('.aac') ||
          lower.endsWith('.mp4') ||
          lower.endsWith('.ts')) {
        return currentUrl;
      }

      // Detect playlist types
      bool isPlaylist =
          lower.contains('.m3u8') ||
          lower.contains('.m3u') ||
          lower.contains('.pls');

      if (!isPlaylist) {
        // Perform a HEAD/GET check to see Content-Type if extension is ambiguous?
        // For now, assume it's audio if not known playlist extension.
        return currentUrl;
      }

      try {
        final uri = Uri.parse(currentUrl);
        if (_activeClient == null) return currentUrl;

        final response = await _activeClient!.get(uri);
        if (response.statusCode != 200) return currentUrl;

        final body = response.body;
        final lines = body.split('\n');
        String? candidate;

        if (body.contains('[playlist]')) {
          // PLS Format
          final match = lines.firstWhere(
            (l) => l.toLowerCase().startsWith('file1='),
            orElse: () => '',
          );
          if (match.isNotEmpty) {
            candidate = match.split('=').last.trim();
          }
        } else {
          // M3U / M3U8 Format (HLS)
          // Filter out comments and empty lines
          final validLines = lines
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty && !l.startsWith('#'))
              .toList();

          if (validLines.isNotEmpty) {
            // Usually the last one in a master playlist is highest quality,
            // but in a media playlist (chunks), the last one is the NEWEST chunk.
            // For recognition, any chunk works. Let's take the first one for speed/simplicity
            // or last one to ensure we get a live chunk?
            // Live HLS playlists have a sliding window. OLD chunks disappear.
            // Safest is to take the LAST valid line for a live stream chunklist.
            candidate = validLines.last;
          }
        }

        if (candidate != null && candidate.isNotEmpty) {
          // Handle Relative URLs (common in HLS)
          if (candidate.startsWith('http')) {
            currentUrl = candidate;
          } else {
            // Resolve relative path
            // If uri is https://example.com/hls/master.m3u8
            // and candidate is "chunklist.m3u8"
            // new url is https://example.com/hls/chunklist.m3u8

            // Standard resolution handles '..' etc.
            currentUrl = uri.resolve(candidate).toString();
          }
          print("ACRCloud: Followed redirect to: $currentUrl");
          continue; // Loop again to check if this new URL is a playlist or audio
        } else {
          // Parsing failed, return what we have
          print("ACRCloud: Failed to parse playlist candidate.");
          return currentUrl;
        }
      } catch (e) {
        print("ACRCloud: Error resolving stream: $e");
        return currentUrl;
      }
    }
    return currentUrl;
  }
}
