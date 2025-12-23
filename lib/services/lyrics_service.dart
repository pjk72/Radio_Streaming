import 'dart:convert';
import 'package:http/http.dart' as http;

class LyricLine {
  final Duration time;
  final String text;

  LyricLine({required this.time, required this.text});
}

class LyricsData {
  final List<LyricLine> lines;
  final String? source;
  final bool isSynced;

  LyricsData({required this.lines, this.source, this.isSynced = false});

  static LyricsData empty() => LyricsData(lines: [], isSynced: false);
}

class LyricsService {
  static const String _lrclibBaseUrl = 'https://lrclib.net/api/get';
  static const String _lyricsOvhBaseUrl = 'https://api.lyrics.ovh/v1';

  Future<LyricsData> fetchLyrics({
    required String artist,
    required String title,
    String? album,
    int? durationSeconds,
  }) async {
    // 1. Try LRCLIB (Primary - supports Sync)
    try {
      final queryParameters = {'artist_name': artist, 'track_name': title};
      if (album != null && album.isNotEmpty && album != "Live Radio") {
        queryParameters['album_name'] = album;
      }
      if (durationSeconds != null && durationSeconds > 0) {
        queryParameters['duration'] = durationSeconds.toString();
      }

      final uri = Uri.parse(
        _lrclibBaseUrl,
      ).replace(queryParameters: queryParameters);
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String? syncedLyrics = data['syncedLyrics'];
        final String? plainLyrics = data['plainLyrics'];

        if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
          return LyricsData(
            lines: _parseLrc(syncedLyrics),
            source: 'LRCLIB (Synced)',
            isSynced: true,
          );
        } else if (plainLyrics != null && plainLyrics.isNotEmpty) {
          return LyricsData(
            lines: plainLyrics
                .split('\n')
                .map((l) => LyricLine(time: Duration.zero, text: l.trim()))
                .toList(),
            source: 'LRCLIB (Plain)',
          );
        }
      }
    } catch (e) {
      print('LRCLIB Fetch Error: $e');
    }

    // 2. Fallback to Lyrics.ovh (Secondary - Static only)
    try {
      final uri = Uri.parse(
        '$_lyricsOvhBaseUrl/${Uri.encodeComponent(artist)}/${Uri.encodeComponent(title)}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String? lyrics = data['lyrics'];

        if (lyrics != null && lyrics.isNotEmpty) {
          return LyricsData(
            lines: lyrics
                .split('\n')
                .where((l) => l.trim().isNotEmpty)
                .map((l) => LyricLine(time: Duration.zero, text: l.trim()))
                .toList(),
            source: 'Lyrics.ovh',
          );
        }
      }
    } catch (e) {
      print('Lyrics.ovh Fetch Error: $e');
    }

    return LyricsData.empty();
  }

  List<LyricLine> _parseLrc(String lrcContent) {
    final List<LyricLine> lines = [];
    final RegExp regExp = RegExp(r'\[(\d+):(\d+\.\d+)\](.*)');

    for (var line in lrcContent.split('\n')) {
      final match = regExp.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = double.parse(match.group(2)!);
        final text = match.group(3)!.trim();

        final duration = Duration(
          minutes: minutes,
          milliseconds: (seconds * 1000).toInt(),
        );

        lines.add(LyricLine(time: duration, text: text));
      }
    }

    // Sort lines by time just in case
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}
