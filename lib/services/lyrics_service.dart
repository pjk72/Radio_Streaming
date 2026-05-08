import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:math';
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
    bool isRadio = false,
  }) async {
    final cleanArtist = cleanString(artist);
    final cleanTitle = cleanString(title);

    LogService().log(
      "Lyrics Search Initiated (${isRadio ? 'Radio' : 'Playlist'}): '$cleanArtist' - '$cleanTitle'",
    );

    if (cleanArtist.isEmpty || cleanTitle.isEmpty) {
      return LyricsData.empty();
    }

    // 1. Radio Requirement: Go DIRECTLY to Lyrics.ovh
    if (isRadio) {
      try {
        final ovhResult = await _tryLyricsOvh(
          artist: cleanArtist,
          title: cleanTitle,
        );
        if (ovhResult != null) return ovhResult;
      } catch (e) {
        LogService().log("Lyrics.ovh Error (Radio): $e");
      }
      LogService().log("Lyrics NOT FOUND (Radio) for: $cleanArtist - $cleanTitle");
      return LyricsData.empty();
    }

    // 2. Playlist Requirement: Try LRCLIB first (Primary - supports Synced Lyrics)
    try {
      final result = await _tryLrclib(
        artist: cleanArtist,
        title: cleanTitle,
        isRadio: false,
      );
      if (result != null) return result;
    } catch (e) {
      LogService().log("LRCLIB Error (Playlist): $e");
    }

    // 3. Playlist Fallback: Try Lyrics.ovh
    try {
      final ovhResult = await _tryLyricsOvh(
        artist: cleanArtist,
        title: cleanTitle,
      );
      if (ovhResult != null) return ovhResult;
    } catch (e) {
      LogService().log("Lyrics.ovh Error (Playlist Fallback): $e");
    }

    // 4. Fallback: Parse "Artist - Title" from the title parameter (Requested Feature)
    // "prendere solo il titolo della canzone se trovi questo se esiste questo simbolo " - "
    // considera la prima parte come il nome dell'artista e la seconda parte il titolo della canzone"
    if (title.contains(' - ')) {
      final parts = title.split(' - ');
      // Take the first part as artist, and the REST as title (in case of multiple dashes, rare but possible)
      // Or just strictly 2 parts? The user said "prima parte... seconda parte".
      // Let's assume standard "Artist - Title".
      if (parts.length >= 2) {
        final derivedArtist = parts[0];
        final derivedTitle = parts.sublist(1).join(' - '); // Rejoin the rest

        final cleanDerivedArtist = cleanString(derivedArtist);
        final cleanDerivedTitle = cleanString(derivedTitle);

        // Avoid re-trying exactly what we just tried if the cleanup makes them identical
        // to the passed arguments.
        final bool isSameAsOriginal =
            cleanDerivedArtist.toLowerCase() == cleanArtist.toLowerCase() &&
            cleanDerivedTitle.toLowerCase() == cleanTitle.toLowerCase();

        if (!isSameAsOriginal &&
            cleanDerivedArtist.isNotEmpty &&
            cleanDerivedTitle.isNotEmpty) {
          LogService().log(
            "Lyrics Fallback 2: Splitting title '$title' -> Artist: '$cleanDerivedArtist', Title: '$cleanDerivedTitle'",
          );

          // Retry LRCLIB
          try {
            final result = await _tryLrclib(
              artist: cleanDerivedArtist,
              title: cleanDerivedTitle,
              isRadio: isRadio,
            );
            if (result != null) return result;
          } catch (e) {
            LogService().log(
              "LRCLIB Fallback 2 Error ($cleanDerivedArtist - $cleanDerivedTitle): $e",
            );
          }

          // Retry Lyrics.ovh
          try {
            final ovhResult = await _tryLyricsOvh(
              artist: cleanDerivedArtist,
              title: cleanDerivedTitle,
            );
            if (ovhResult != null) return ovhResult;
          } catch (e) {
            LogService().log(
              "Lyrics.ovh Fallback 2 Error ($cleanDerivedArtist - $cleanDerivedTitle): $e",
            );
          }
        }
      }
    }

    LogService().log("Lyrics NOT FOUND for: $cleanArtist - $cleanTitle");

    return LyricsData.empty();
  }

  Future<LyricsData?> _tryLrclib({
    required String artist,
    required String title,
    bool isRadio = false,
  }) async {
    try {
      final queryParameters = {'artist_name': artist, 'track_name': title};

      // Removed strict Album/Duration checks to ensure broader matching
      // as requested by user ("semplicemente ricerca col nome dell'artista e il titolo")

      final uri = Uri.parse(
        _lrclibBaseUrl,
      ).replace(queryParameters: queryParameters);
      LogService().log("Trying LRCLIB: $uri");

      final response = await http.get(uri).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String? syncedLyrics = data['syncedLyrics'];
        final String? plainLyrics = data['plainLyrics'];

        LogService().log("LRCLIB Success for '$artist' - '$title'");

        if (isRadio && plainLyrics != null && plainLyrics.isNotEmpty) {
          return LyricsData(
            lines: plainLyrics
                .split('\n')
                .map((l) => LyricLine(time: Duration.zero, text: l.trim()))
                .toList(),
            source: 'LRCLIB (Plain)',
            isSynced: false,
          );
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
      }
    } catch (_) {}
    return null;
  }

  Future<LyricsData?> _tryLyricsOvh({
    required String artist,
    required String title,
  }) async {
    try {
      final uri = Uri.parse(
        '$_lyricsOvhBaseUrl/${Uri.encodeComponent(artist)}/${Uri.encodeComponent(title)}',
      );

      LogService().log("Trying Lyrics.ovh: $uri");

      final response = await http.get(uri).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String? lyrics = data['lyrics'];

        if (lyrics != null && lyrics.isNotEmpty) {
          LogService().log("Lyrics.ovh Success for '$artist' - '$title'");
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
    } catch (_) {}
    return null;
  }

  List<LyricLine> _parseLrc(String lrcContent) {
    if (lrcContent.isEmpty) {
      LogService().log("Warning: _parseLrc called with empty content");
      return [];
    }
    // Log first 50 chars to verify format
    LogService().log(
      "Parsing LRC content (first 50): ${lrcContent.substring(0, min(lrcContent.length, 50)).replaceAll('\n', '\\n')}",
    );

    final List<LyricLine> lines = [];
    final RegExp regExp = RegExp(r'\[(\d+):(\d+(\.\d+)?)\](.*)');

    final splitLines = lrcContent.split('\n');
    LogService().log("Total lines to parse: ${splitLines.length}");

    for (var line in splitLines) {
      if (line.trim().isEmpty) continue;

      final match = regExp.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = double.parse(match.group(2)!);
        final text = match.group(4)!.trim();

        final duration = Duration(
          minutes: minutes,
          milliseconds: (seconds * 1000).toInt(),
        );

        lines.add(LyricLine(time: duration, text: text));
      } else {
        LogService().log("Failed to match line: '$line'");
      }
    }

    LogService().log("Successfully parsed ${lines.length} lines.");

    // Sort lines by time just in case
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  static String cleanString(String s) {
    if (s.isEmpty) return s;

    String clean = s;
    // 0. Explicitly remove offline/download icons
    clean = clean.replaceFirst("⬇️ ", "").replaceFirst("📱 ", "");

    // 2. Explicitly remove requested common suffixes (with or without brackets)
    final suffixesPattern = RegExp(
      r'(\s-\sTopic|\s-\sSingle(\sVersion)?|\s-\sRadio\sEdit|\s-\sRemastered|\s-\sDeluxe(\sEdition|\sVersion)?|\s-\sMain\sVersion|\s?\(?Official Video\)?|\s?\(?Official Audio\)?|\s?\(?Lyric Video\)?|\s?\(?Lyrics\)?|\s?\[?Official Video\]?|\s?\[?Official Audio\]?|\s?\(?HD\)?|\s?\(?HQ\)?)$',
      caseSensitive: false,
    );
    clean = clean.replaceAll(suffixesPattern, '');

    // 3. Remove anything else inside parentheses or brackets
    clean = clean.replaceAll(RegExp(r'\([^)]*\)'), '');
    clean = clean.replaceAll(RegExp(r'\[[^\]]*\]'), '');

    // 4. Remove "feat", "ft", "prod", "with" followed by anything
    clean = clean.replaceAll(
      RegExp(r'\s(feat|ft|with|prod)\.?\s.*', caseSensitive: false),
      '',
    );

    // 5. Remove text after bullet point (•)
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

  Future<LyricsData> translateLyrics(
    LyricsData original,
    String targetLang,
  ) async {
    if (original.lines.isEmpty) return original;

    try {
      LogService().log("Translating lyrics to $targetLang...");

      // We process lines in chunks if they are too long, but for lyrics,
      // it's usually safe to join with a unique separator.
      // E.g., a special character combination:  "  |||  "
      final textToTranslate = original.lines.map((l) => l.text).join(' \n ');

      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$targetLang&dt=t',
      );

      final response = await http
          .post(uri, body: {'q': textToTranslate})
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final translatedLinesData = data[0] as List;
        String fullTranslation = '';

        for (var part in translatedLinesData) {
          if (part[0] != null) {
            fullTranslation += part[0].toString();
          }
        }

        final translatedTextLines = fullTranslation.split('\n');

        List<LyricLine> newLines = [];
        for (int i = 0; i < original.lines.length; i++) {
          final originalLine = original.lines[i];
          final translatedText = i < translatedTextLines.length
              ? translatedTextLines[i].trim()
              : '';

          String combinedText = originalLine.text;
          if (translatedText.isNotEmpty &&
              translatedText.toLowerCase() != originalLine.text.toLowerCase()) {
            combinedText = "${originalLine.text}\n$translatedText";
          }

          newLines.add(LyricLine(time: originalLine.time, text: combinedText));
        }

        LogService().log("Lyrics successfully translated to $targetLang.");
        return LyricsData(
          lines: newLines,
          source: '${original.source} (Translated)',
          isSynced: original.isSynced,
        );
      } else {
        LogService().log(
          "Translation API Error: ${response.statusCode} - ${response.body}",
        );
      }
    } catch (e) {
      LogService().log("Translation error: $e");
    }

    return original;
  }

  Future<String> translateText(String text, String targetLang) async {
    if (text.isEmpty) return text;

    try {
      LogService().log("Translating text to $targetLang...");

      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$targetLang&dt=t',
      );

      final response = await http
          .post(uri, body: {'q': text})
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final translatedParts = data[0] as List;
        String fullTranslation = '';

        for (var part in translatedParts) {
          if (part[0] != null) {
            fullTranslation += part[0].toString();
          }
        }
        LogService().log("Text successfully translated to $targetLang.");
        return fullTranslation;
      }
    } catch (e) {
      LogService().log("Text Translation error: $e");
    }
    return text;
  }
}
