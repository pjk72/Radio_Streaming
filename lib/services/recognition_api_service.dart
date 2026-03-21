import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'log_service.dart';

class RecognitionApiService {
  final String _host = 'shazam-song-recognition-api.p.rapidapi.com';
  // RapidAPI Key (Shazam Core)
  final String _apiKey = '65c517cd98mshd509565706f012ep1e49f3jsne80c01e37828';

  static bool _isGlobalRecognizing = false;
  http.Client? _activeClient;

  Future<Map<String, dynamic>?> identifyStream(String streamUrl) async {
    if (_isGlobalRecognizing) {
      LogService().log(
        "RecognitionAPI: Global lock active, ignoring duplicate request.",
      );
      return null;
    }
    _isGlobalRecognizing = true;
    _activeClient = http.Client();
    try {
      final resolvedUrl = await _resolveStreamUrl(streamUrl);
      if (_activeClient == null) return null;
      LogService().log("RecognitionAPI: Resolved URL: $resolvedUrl");

      // Download ~3 seconds of the stream (roughly 80KB of mp3)
      final Uint8List? audioData = await _downloadStreamChunk(
        resolvedUrl,
        80 * 1024,
      );

      if (_activeClient == null) return null;
      if (audioData == null || audioData.isEmpty) {
        LogService().log("RecognitionAPI: Failed to download stream chunk.");
        return null;
      }

      // 4. Send MP3 straight to recognition service (Shazam API)
      final uri = Uri.https(_host, '/recognize/file');

      if (_activeClient == null) return null;
      final response = await _activeClient!.post(
        uri,
        headers: {
          'x-rapidapi-key': _apiKey,
          'x-rapidapi-host': _host,
          'Content-Type': 'application/octet-stream',
        },
        body: audioData,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data; // Return raw recognition JSON (Shazam format)
      } else {
        LogService().log(
          "RecognitionAPI HTTP Error: ${response.statusCode} - ${response.body}",
        );
      }
    } catch (e) {
      if (_activeClient != null) {
        LogService().log("RecognitionAPI Exception: $e");
      } else {
        LogService().log("RecognitionAPI Recognition Cancelled.");
      }
    } finally {
      _activeClient?.close();
      _activeClient = null;
      _isGlobalRecognizing = false;
    }
    return null;
  }

  void cancel() {
    LogService().log("RecognitionAPI: Cancelling active recognition...");
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

class MusicIdentifier extends StatefulWidget {
  @override
  _MusicIdentifierState createState() => _MusicIdentifierState();
}

class _MusicIdentifierState extends State<MusicIdentifier> {
  String _result = "Seleziona un file audio per iniziare";
  bool _isLoading = false;

  final String _host = 'shazam-song-recognition-api.p.rapidapi.com';
  // API Key RapidAPI
  final String _apiKey = '65c517cd98mshd509565706f012ep1e49f3jsne80c01e37828';

  Future<void> _identifyMusic() async {
    // 1. Seleziona il file audio
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );

    if (result != null) {
      setState(() => _isLoading = true);
      File file = File(result.files.single.path!);

      try {
        // 2. Leggi il file come byte
        final audioBytes = await file.readAsBytes();

        // 3. Invia la richiesta a Shazam RapidAPI
        final uri = Uri.https(_host, '/recognize/file');
        final response = await http.post(
          uri,
          headers: {
            'x-rapidapi-key': _apiKey,
            'x-rapidapi-host': _host,
            'Content-Type': 'application/octet-stream',
          },
          body: audioBytes,
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data.containsKey('track') && data['track'] != null) {
            final trackInfo = data['track'];
            setState(() {
              _result =
                  "Trovata: ${trackInfo['title']} - ${trackInfo['subtitle']}";
            });
          } else {
            setState(
              () => _result = "Nessuna canzone riconosciuta in questo audio.",
            );
          }
        } else {
          setState(
            () => _result =
                "Errore API Shazam: ${response.statusCode}\n${response.body}",
          );
        }
      } catch (e) {
        setState(() => _result = "Errore: $e");
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Shazam Music ID")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isLoading) CircularProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(_result, textAlign: TextAlign.center),
            ),
            ElevatedButton(
              onPressed: _isLoading ? null : _identifyMusic,
              child: Text("Seleziona Canzone"),
            ),
          ],
        ),
      ),
    );
  }
}
