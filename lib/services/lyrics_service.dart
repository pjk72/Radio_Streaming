import 'dart:convert';
import 'package:http/http.dart' as http;
import 'log_service.dart';

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
    bool isRadio = false,
  }) async {
    final cleanArtist = _cleanString(artist);
    final cleanTitle = _cleanString(title);

    LogService().log(
      "Lyrics Search: '$artist' - '$title' -> Cleaned: '$cleanArtist' - '$cleanTitle'",
    );

    // 1. Try LRCLIB (Primary - supports Synced Lyrics)
    // Endpoint: https://lrclib.net/api/get
    try {
      final queryParameters = {
        'artist_name': cleanArtist,
        'track_name': cleanTitle,
      };
      if (album != null && album.isNotEmpty && album != "Live Radio") {
        queryParameters['album_name'] = album;
      }
      if (durationSeconds != null && durationSeconds > 0) {
        queryParameters['duration'] = durationSeconds.toString();
      }

      final uri = Uri.parse(
        _lrclibBaseUrl,
      ).replace(queryParameters: queryParameters);

      LogService().log("Trying LRCLIB: $uri");

      final response = await http.get(uri).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String? syncedLyrics = data['syncedLyrics'];
        final String? plainLyrics = data['plainLyrics'];

        LogService().log(
          "LRCLIB Success. Synced: ${syncedLyrics != null}, Plain: ${plainLyrics != null}, Mode: ${isRadio ? 'Radio' : 'Normal'}",
        );

        // Radio Mode: Prefer Plain Text (Un-synced)
        if (isRadio) {
          if (plainLyrics != null && plainLyrics.isNotEmpty) {
            return LyricsData(
              lines: plainLyrics
                  .split('\n')
                  .map((l) => LyricLine(time: Duration.zero, text: l.trim()))
                  .toList(),
              source: 'LRCLIB (Plain)',
              isSynced: false,
            );
          }
        }

        if (syncedLyrics != null && syncedLyrics.isNotEmpty && !isRadio) {
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
      } else {
        LogService().log("LRCLIB Failed/Not Found: ${response.statusCode}");
      }
    } catch (e) {
      LogService().log("LRCLIB Error: $e");
    }

    // 2. Fallback to Lyrics.ovh (Secondary - Static only)
    // Endpoint: https://api.lyrics.ovh/v1/Artist/Title
    try {
      final uri = Uri.parse(
        '$_lyricsOvhBaseUrl/${Uri.encodeComponent(cleanArtist)}/${Uri.encodeComponent(cleanTitle)}',
      );

      LogService().log("Trying Lyrics.ovh: $uri");

      final response = await http.get(uri).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String? lyrics = data['lyrics'];

        if (lyrics != null && lyrics.isNotEmpty) {
          LogService().log("Lyrics.ovh Success.");
          return LyricsData(
            lines: lyrics
                .split('\n')
                .where((l) => l.trim().isNotEmpty)
                .map((l) => LyricLine(time: Duration.zero, text: l.trim()))
                .toList(),
            source: 'Lyrics.ovh',
          );
        } else {
          LogService().log("Lyrics.ovh: Empty response");
        }
      } else {
        LogService().log("Lyrics.ovh Failed: ${response.statusCode}");
      }
    } catch (e) {
      LogService().log("Lyrics.ovh Error: $e");
    }

    LogService().log("Lyrics NOT FOUND for: $cleanArtist - $cleanTitle");
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

  String _cleanString(String s) {
    if (s.isEmpty) return s;

    String clean = s;

    // Remove common suffixes
    final suffixesToRemove = [
      ' - Topic',
      ' (Official Video)',
      ' (Official Audio)',
      ' (Lyric Video)',
      ' (Lyrics)',
      ' [Official Video]',
      ' [Official Audio]',
      ' (HD)',
      ' (HQ)',
    ];

    for (var suffix in suffixesToRemove) {
      if (clean.toLowerCase().endsWith(suffix.toLowerCase())) {
        clean = clean.substring(0, clean.length - suffix.length);
      }
    }

    // Remove text after bullet point (•) often used in radio metadata
    if (clean.contains('•')) {
      clean = clean.split('•').first;
    }

    // Replace "FT." or "feat." with space or just stop there?
    // Usually LRCLIB prefers just the main artist.
    if (clean.toUpperCase().contains(' FT. ')) {
      clean = clean.substring(0, clean.toUpperCase().indexOf(' FT. '));
    } else if (clean.toLowerCase().contains(' feat. ')) {
      clean = clean.substring(0, clean.toLowerCase().indexOf(' feat. '));
    }

    return clean.trim();
  }
}
