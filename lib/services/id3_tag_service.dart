import 'dart:convert';
import 'dart:typed_data';
import '../models/saved_song.dart';

/// Service for generating standard ID3v2.3/ID3v1.1 tags (for MP3) and
/// iTunes/MP4 metadata atoms (for MP3/AAC), embedding them cleanly into
/// audio files so external media players can play them seamlessly.
class Id3TagService {
  static final Id3TagService _instance = Id3TagService._internal();
  factory Id3TagService() => _instance;
  Id3TagService._internal();

  /// Replaces common Unicode characters with their Latin-1 / ASCII equivalents,
  /// so that ID3v1 fields (which are Latin-1 only) never throw encoding errors.
  static String _sanitizeToLatin1(String text) {
    return text
        .replaceAll('\u2019', "'") // RIGHT SINGLE QUOTATION MARK → apostrophe
        .replaceAll('\u2018', "'") // LEFT SINGLE QUOTATION MARK
        .replaceAll('\u201C', '"') // LEFT DOUBLE QUOTATION MARK
        .replaceAll('\u201D', '"') // RIGHT DOUBLE QUOTATION MARK
        .replaceAll('\u2013', '-') // EN DASH
        .replaceAll('\u2014', '-') // EM DASH
        .replaceAll('\u2026', '...') // HORIZONTAL ELLIPSIS
        .replaceAll('\u00E0', 'a') // à
        .replaceAll('\u00E8', 'e') // è
        .replaceAll('\u00E9', 'e') // é
        .replaceAll('\u00EC', 'i') // ì
        .replaceAll('\u00F2', 'o') // ò
        .replaceAll('\u00F9', 'u') // ù
        .replaceAll('\u00C0', 'A') // À
        .replaceAll('\u00C8', 'E') // È
        .replaceAll('\u00C9', 'E') // É
        .replaceAll('\u00CC', 'I') // Ì
        .replaceAll('\u00D2', 'O') // Ò
        .replaceAll('\u00D9', 'U') // Ù
        // Replace any remaining non-Latin-1 character (codeUnit > 255) with '?'
        .split('').map((c) => c.codeUnitAt(0) > 255 ? '?' : c).join();
  }


  /// Detects the true container/codec format from raw audio bytes.
  static String detectAudioExtension(Uint8List bytes) {
    var checkBytes = bytes;
    // If it has an ID3 header, strip it first to inspect the underlying container
    if (bytes.length >= 10 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      final stripped = stripExistingId3Tags(bytes);
      if (stripped.length >= 8) {
        checkBytes = stripped;
      }
    }

    if (checkBytes.length >= 8) {
      // Check M4A / MP4: 'ftyp' at offset 4..7
      if (checkBytes[4] == 0x66 &&
          checkBytes[5] == 0x74 &&
          checkBytes[6] == 0x79 &&
          checkBytes[7] == 0x70) {
        return '.m4a';
      }
      // Or 'ftyp' at offset 0..3
      if (checkBytes[0] == 0x66 &&
          checkBytes[1] == 0x74 &&
          checkBytes[2] == 0x79 &&
          checkBytes[3] == 0x70) {
        return '.m4a';
      }
    }

    if (checkBytes.length >= 4) {
      // Matroska / WebM: 0x1A 0x45 0xDF 0xA3
      if (checkBytes[0] == 0x1A &&
          checkBytes[1] == 0x45 &&
          checkBytes[2] == 0xDF &&
          checkBytes[3] == 0xA3) {
        return '.webm';
      }
      // MP3 with ID3 tag: 'ID3'
      if (checkBytes[0] == 0x49 && checkBytes[1] == 0x44 && checkBytes[2] == 0x33) {
        return '.mp3';
      }
      // FLAC: 'fLaC'
      if (checkBytes[0] == 0x66 &&
          checkBytes[1] == 0x4C &&
          checkBytes[2] == 0x61 &&
          checkBytes[3] == 0x43) {
        return '.flac';
      }
      // OGG: 'OggS'
      if (checkBytes[0] == 0x4F &&
          checkBytes[1] == 0x67 &&
          checkBytes[2] == 0x67 &&
          checkBytes[3] == 0x53) {
        return '.ogg';
      }
      // WAV: 'RIFF'
      if (checkBytes[0] == 0x52 &&
          checkBytes[1] == 0x49 &&
          checkBytes[2] == 0x46 &&
          checkBytes[3] == 0x46) {
        return '.wav';
      }
    }

    if (checkBytes.length >= 2) {
      // MP3 raw frame sync: 0xFF followed by high 3 bits set (0xE0)
      if (checkBytes[0] == 0xFF && ((checkBytes[1] & 0xE0) == 0xE0)) {
        return '.mp3';
      }
    }

    // Default fallback
    return '.mp3';
  }

  // ==========================================
  // ID3 (MP3) ENCODING HELPERS
  // ==========================================

  static List<int> _encodeSynchsafe(int size) {
    return [
      (size >> 21) & 0x7F,
      (size >> 14) & 0x7F,
      (size >> 7) & 0x7F,
      size & 0x7F,
    ];
  }

  static List<int> _encodeUint32(int size) {
    return [
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
    ];
  }

  static List<int> _encodeUtf16LeWithBom(String text) {
    final List<int> bytes = [0xFF, 0xFE];
    for (int i = 0; i < text.length; i++) {
      final int unit = text.codeUnitAt(i);
      bytes.add(unit & 0xFF);
      bytes.add((unit >> 8) & 0xFF);
    }
    return bytes;
  }

  static List<int> _createTextFrame(String frameId, String text) {
    if (text.trim().isEmpty) return [];

    final cleanText = text.trim();
    // Check if text can be safely encoded in ISO-8859-1 (Latin-1)
    final bool isPureLatin1 = !cleanText.codeUnits.any((u) => u > 255);

    List<int> frameData;
    if (isPureLatin1) {
      // 0x00 = ISO-8859-1 (Latin-1). Supported by 100% of car stereos, Windows Explorer, USB players.
      frameData = <int>[
        0x00,
        ...latin1.encode(cleanText),
      ];
    } else {
      // 0x01 = UTF-16 with BOM (Little Endian)
      frameData = <int>[
        0x01,
        ..._encodeUtf16LeWithBom(cleanText),
      ];
    }

    final frameHeader = <int>[
      ...ascii.encode(frameId),
      ..._encodeUint32(frameData.length),
      0x00, 0x00, // Flags
    ];

    return [...frameHeader, ...frameData];
  }

  static List<int> _createCommentFrame({
    required String text,
    String language = 'eng',
  }) {
    if (text.trim().isEmpty) return [];

    final cleanText = text.trim();
    final bool isPureLatin1 = !cleanText.codeUnits.any((u) => u > 255);

    List<int> frameData;
    if (isPureLatin1) {
      frameData = <int>[
        0x00, // ISO-8859-1
        ...ascii.encode(language.padRight(3, ' ').substring(0, 3)),
        0x00, // Null terminator for empty description
        ...latin1.encode(cleanText),
      ];
    } else {
      frameData = <int>[
        0x01, // UTF-16 with BOM
        ...ascii.encode(language.padRight(3, ' ').substring(0, 3)),
        0xFF, 0xFE, 0x00, 0x00, // Empty description UTF-16 with BOM
        ..._encodeUtf16LeWithBom(cleanText),
      ];
    }

    final frameHeader = <int>[
      ...ascii.encode('COMM'),
      ..._encodeUint32(frameData.length),
      0x00, 0x00,
    ];

    return [...frameHeader, ...frameData];
  }

  static List<int> _createUrlFrame({
    required String description,
    required String url,
  }) {
    if (url.trim().isEmpty) return [];

    final descBytes = latin1.encode(description);
    final urlBytes = ascii.encode(url.trim());

    final frameData = <int>[
      0x00, // ISO-8859-1 encoding
      ...descBytes,
      0x00, // Null separator
      ...urlBytes,
    ];

    final frameHeader = <int>[
      ...ascii.encode('WXXX'),
      ..._encodeUint32(frameData.length),
      0x00, 0x00,
    ];

    return [...frameHeader, ...frameData];
  }

  static List<int> _createUserTextFrame({
    required String description,
    required String value,
  }) {
    if (value.trim().isEmpty) return [];

    final descBytes = latin1.encode(description);
    final bool isPureLatin1 = !value.codeUnits.any((u) => u > 255);

    List<int> frameData;
    if (isPureLatin1) {
      frameData = <int>[
        0x00, // ISO-8859-1
        ...descBytes,
        0x00, // Null separator
        ...latin1.encode(value),
      ];
    } else {
      frameData = <int>[
        0x01, // UTF-16 with BOM
        ..._encodeUtf16LeWithBom(description),
        0x00, 0x00,
        ..._encodeUtf16LeWithBom(value),
      ];
    }

    final frameHeader = <int>[
      ...ascii.encode('TXXX'),
      ..._encodeUint32(frameData.length),
      0x00, 0x00,
    ];

    return [...frameHeader, ...frameData];
  }

  static List<int> _createPictureFrame(Uint8List imageBytes, {String mimeType = 'image/jpeg'}) {
    if (imageBytes.isEmpty) return [];

    String detectedMime = mimeType;
    if (imageBytes.length >= 4) {
      if (imageBytes[0] == 0x89 &&
          imageBytes[1] == 0x50 &&
          imageBytes[2] == 0x4E &&
          imageBytes[3] == 0x47) {
        detectedMime = 'image/png';
      } else if (imageBytes[0] == 0xFF && imageBytes[1] == 0xD8) {
        detectedMime = 'image/jpeg';
      }
    }

    final mimeBytes = ascii.encode(detectedMime);

    final frameData = <int>[
      0x00, // Encoding: ISO-8859-1
      ...mimeBytes,
      0x00, // Null terminator for MIME
      0x03, // Picture type: Front Cover
      0x00, // Null terminator for empty Description (standard for APIC)
      ...imageBytes,
    ];

    final frameHeader = <int>[
      ...ascii.encode('APIC'),
      ..._encodeUint32(frameData.length),
      0x00, 0x00,
    ];

    return [...frameHeader, ...frameData];
  }

  /// Builds a complete ID3v2.3 tag byte array.
  List<int> buildId3v2Tag({
    required SavedSong song,
    Uint8List? coverArtBytes,
  }) {
    final List<int> frames = [];

    // 1. Title (TIT2)
    if (song.title.isNotEmpty) {
      frames.addAll(_createTextFrame('TIT2', song.title));
    }

    // 2. Artist / Lead Performer (TPE1)
    if (song.artist.isNotEmpty) {
      frames.addAll(_createTextFrame('TPE1', song.artist));
    }

    // 3. Album (TALB)
    if (song.album.isNotEmpty) {
      frames.addAll(_createTextFrame('TALB', song.album));
    }

    // 4. Content Type / Genre (TCON)
    if (song.genre != null && song.genre!.trim().isNotEmpty) {
      frames.addAll(_createTextFrame('TCON', song.genre!.trim()));
    }

    // 5. Release Year (TYER in ID3v2.3)
    String? year;
    if (song.releaseDate != null && song.releaseDate!.trim().isNotEmpty) {
      final cleanDate = song.releaseDate!.trim();
      final yearMatch = RegExp(r'\b(19\d\d|20\d\d)\b').firstMatch(cleanDate);
      year = yearMatch != null ? yearMatch.group(0) : cleanDate;
    } else {
      year = song.dateAdded.year.toString();
    }
    if (year != null && year.isNotEmpty) {
      frames.addAll(_createTextFrame('TYER', year));
    }

    // 6. Track Number (TRCK)
    frames.addAll(_createTextFrame('TRCK', '1'));

    // 7. Duration in milliseconds (TLEN)
    if (song.duration != null && song.duration!.inMilliseconds > 0) {
      frames.addAll(_createTextFrame('TLEN', song.duration!.inMilliseconds.toString()));
    }

    // 8. Comment (COMM)
    final commentText = 'MusicStream Audio Export | ID: ${song.id}';
    frames.addAll(_createCommentFrame(text: commentText));

    // 9. URLs (WXXX)
    if (song.youtubeUrl != null && song.youtubeUrl!.isNotEmpty) {
      frames.addAll(_createUrlFrame(description: 'YouTube', url: song.youtubeUrl!));
    }
    if (song.appleMusicUrl != null && song.appleMusicUrl!.isNotEmpty) {
      frames.addAll(_createUrlFrame(description: 'AppleMusic', url: song.appleMusicUrl!));
    }

    // 10. Custom User Text (TXXX)
    frames.addAll(_createUserTextFrame(description: 'MUSICSTREAM_SONG_ID', value: song.id));
    if (song.provider != null && song.provider!.isNotEmpty) {
      frames.addAll(_createUserTextFrame(description: 'MUSICSTREAM_PROVIDER', value: song.provider!));
    }

    // 11. Attached Picture (APIC)
    if (coverArtBytes != null && coverArtBytes.isNotEmpty) {
      frames.addAll(_createPictureFrame(coverArtBytes));
    }

    if (frames.isEmpty) return [];

    final List<int> header = [
      0x49, 0x44, 0x33, // 'ID3'
      0x03, // Major version 3 (ID3v2.3)
      0x00, // Revision
      0x00, // Flags
      ..._encodeSynchsafe(frames.length),
    ];

    return [...header, ...frames];
  }

  /// Builds a legacy ID3v1.1 tag (128 bytes) appended to the end of an MP3 file.
  List<int> buildId3v1Tag({required SavedSong song}) {
    final List<int> tag = List<int>.filled(128, 0);

    // 0..2: 'TAG'
    tag[0] = 0x54;
    tag[1] = 0x41;
    tag[2] = 0x47;

    void writeFixedAscii(int start, int length, String text) {
      // Sanitize to Latin-1 safe string before encoding
      final safeText = _sanitizeToLatin1(text);
      final bytes = latin1.encode(safeText);
      for (int i = 0; i < length; i++) {
        if (i < bytes.length) {
          tag[start + i] = bytes[i];
        } else {
          tag[start + i] = 0x00;
        }
      }
    }

    writeFixedAscii(3, 30, song.title);
    writeFixedAscii(33, 30, song.artist);
    writeFixedAscii(63, 30, song.album);

    String year = song.dateAdded.year.toString();
    if (song.releaseDate != null && song.releaseDate!.isNotEmpty) {
      final match = RegExp(r'\b(19\d\d|20\d\d)\b').firstMatch(song.releaseDate!);
      if (match != null) {
        year = match.group(0)!;
      }
    }
    writeFixedAscii(93, 4, year);
    writeFixedAscii(97, 28, 'MusicStream');

    tag[125] = 0x00;
    tag[126] = 0x00;
    tag[127] = 12; // Genre code: Other

    return tag;
  }

  /// Strips any ID3v2 headers or ID3v1 footers from audio bytes.
  static Uint8List stripExistingId3Tags(Uint8List bytes) {
    int startOffset = 0;

    // Check ID3v2 header at start
    if (bytes.length >= 10 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      final int tagSize = ((bytes[6] & 0x7F) << 21) |
          ((bytes[7] & 0x7F) << 14) |
          ((bytes[8] & 0x7F) << 7) |
          (bytes[9] & 0x7F);

      int totalHeaderSize = 10 + tagSize;
      if ((bytes[5] & 0x10) != 0) {
        // ID3v2.4 footer present
        totalHeaderSize += 10;
      }

      if (totalHeaderSize <= bytes.length) {
        startOffset = totalHeaderSize;
      }
    }

    int endOffset = bytes.length;

    // Check ID3v1 tag at end (128 bytes)
    if (bytes.length - startOffset >= 128) {
      final int tagPos = bytes.length - 128;
      if (bytes[tagPos] == 0x54 &&
          bytes[tagPos + 1] == 0x41 &&
          bytes[tagPos + 2] == 0x47) {
        endOffset = tagPos;
      }
    }

    if (startOffset > 0 || endOffset < bytes.length) {
      return bytes.sublist(startOffset, endOffset);
    }
    return bytes;
  }

  /// Injects ID3v2.3 (header) and ID3v1.1 (footer) into MP3 audio bytes.
  Uint8List injectMp3Metadata({
    required Uint8List audioBytes,
    required SavedSong song,
    Uint8List? coverArtBytes,
  }) {
    final cleanAudio = stripExistingId3Tags(audioBytes);
    final id3v2Tag = buildId3v2Tag(song: song, coverArtBytes: coverArtBytes);
    final id3v1Tag = buildId3v1Tag(song: song);

    final totalLength = id3v2Tag.length + cleanAudio.length + id3v1Tag.length;
    final result = Uint8List(totalLength);

    int offset = 0;
    if (id3v2Tag.isNotEmpty) {
      result.setRange(offset, offset + id3v2Tag.length, id3v2Tag);
      offset += id3v2Tag.length;
    }

    result.setRange(offset, offset + cleanAudio.length, cleanAudio);
    offset += cleanAudio.length;

    result.setRange(offset, offset + id3v1Tag.length, id3v1Tag);
    return result;
  }

  // ==========================================
  // MP3 / MP4 (AAC) ATOM ENCODING HELPERS
  // ==========================================

  static int _readUint32(Uint8List bytes, int offset) {
    return ((bytes[offset] & 0xFF) << 24) |
        ((bytes[offset + 1] & 0xFF) << 16) |
        ((bytes[offset + 2] & 0xFF) << 8) |
        (bytes[offset + 3] & 0xFF);
  }

  static List<int> _createMP3Atom(String type, List<int> payload) {
    final len = 8 + payload.length;
    return [
      (len >> 24) & 0xFF,
      (len >> 16) & 0xFF,
      (len >> 8) & 0xFF,
      len & 0xFF,
      ...latin1.encode(type),
      ...payload,
    ];
  }

  static List<int> _createMP3TextItem(String atomType, String text) {
    if (text.trim().isEmpty) return [];
    final utf8Bytes = utf8.encode(text.trim());
    // data atom: [4 len][4 'data'][4 flags: 1 = UTF-8 text][4 locale: 0][payload]
    final dataAtom = _createMP3Atom('data', [
      0x00, 0x00, 0x00, 0x01, // Type: 1 (UTF-8 text)
      0x00, 0x00, 0x00, 0x00, // Locale: 0
      ...utf8Bytes,
    ]);
    return _createMP3Atom(atomType, dataAtom);
  }

  static List<int> _createMP3CoverItem(Uint8List imageBytes) {
    if (imageBytes.isEmpty) return [];
    int imageType = 0x0D; // 0x0D = JPEG
    if (imageBytes.length >= 4 &&
        imageBytes[0] == 0x89 &&
        imageBytes[1] == 0x50 &&
        imageBytes[2] == 0x4E &&
        imageBytes[3] == 0x47) {
      imageType = 0x0E; // 0x0E = PNG
    }
    // data atom: [4 len][4 'data'][4 flags: 0x0D or 0x0E][4 locale: 0][image bytes]
    final dataAtom = _createMP3Atom('data', [
      0x00, 0x00, 0x00, imageType,
      0x00, 0x00, 0x00, 0x00,
      ...imageBytes,
    ]);
    return _createMP3Atom('covr', dataAtom);
  }

  static List<int> _buildMP3Udta({
    required SavedSong song,
    Uint8List? coverArtBytes,
  }) {
    final List<int> ilstChildren = [];

    // Title: ©nam
    if (song.title.isNotEmpty) {
      ilstChildren.addAll(_createMP3TextItem('\xA9nam', song.title));
    }
    // Artist: ©ART
    if (song.artist.isNotEmpty) {
      ilstChildren.addAll(_createMP3TextItem('\xA9ART', song.artist));
    }
    // Album: ©alb
    if (song.album.isNotEmpty) {
      ilstChildren.addAll(_createMP3TextItem('\xA9alb', song.album));
    }
    // Year/Date: ©day
    String? year;
    if (song.releaseDate != null && song.releaseDate!.trim().isNotEmpty) {
      final cleanDate = song.releaseDate!.trim();
      final yearMatch = RegExp(r'\b(19\d\d|20\d\d)\b').firstMatch(cleanDate);
      year = yearMatch != null ? yearMatch.group(0) : cleanDate;
    } else {
      year = song.dateAdded.year.toString();
    }
    if (year != null && year.isNotEmpty) {
      ilstChildren.addAll(_createMP3TextItem('\xA9day', year));
    }
    // Genre: ©gen
    if (song.genre != null && song.genre!.trim().isNotEmpty) {
      ilstChildren.addAll(_createMP3TextItem('\xA9gen', song.genre!.trim()));
    }
    // Comment: ©cmt
    ilstChildren.addAll(
      _createMP3TextItem('\xA9cmt', 'MusicStream Audio | ID: ${song.id}'),
    );
    // Cover Art URL: ©url
    if (song.artUri != null && song.artUri!.trim().isNotEmpty) {
      ilstChildren.addAll(_createMP3TextItem('\xA9url', song.artUri!.trim()));
    }
    // YouTube / Podcast URL: purl
    if (song.youtubeUrl != null && song.youtubeUrl!.trim().isNotEmpty) {
      ilstChildren.addAll(_createMP3TextItem('purl', song.youtubeUrl!.trim()));
    }

    // Cover art: covr
    if (coverArtBytes != null && coverArtBytes.isNotEmpty) {
      ilstChildren.addAll(_createMP3CoverItem(coverArtBytes));
    }

    if (ilstChildren.isEmpty) return [];

    final ilstAtom = _createMP3Atom('ilst', ilstChildren);

    // Handler atom (hdlr) for metadata
    final hdlrPayload = [
      0x00, 0x00, 0x00, 0x00, // version/flags
      0x00, 0x00, 0x00, 0x00, // predefined
      ...ascii.encode('mdir'), // 'mdir'
      ...ascii.encode('appl'), // 'appl'
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
    ];
    final hdlrAtom = _createMP3Atom('hdlr', hdlrPayload);

    // meta atom has 4 bytes of version/flags (0x00000000) before its children
    final metaPayload = [
      0x00, 0x00, 0x00, 0x00, // version/flags
      ...hdlrAtom,
      ...ilstAtom,
    ];
    final metaAtom = _createMP3Atom('meta', metaPayload);

    return _createMP3Atom('udta', metaAtom);
  }

  static Uint8List _updateMoovWithUdta(Uint8List moovBytes, List<int> newUdta) {
    int pos = 8;
    final List<int> otherAtoms = [];

    while (pos + 8 <= moovBytes.length) {
      int len = _readUint32(moovBytes, pos);
      if (len < 8 || pos + len > moovBytes.length) {
        otherAtoms.addAll(moovBytes.sublist(pos));
        break;
      }
      final type = latin1.decode(
        moovBytes.sublist(pos + 4, pos + 8),
      );
      if (type != 'udta') {
        otherAtoms.addAll(moovBytes.sublist(pos, pos + len));
      }
      pos += len;
    }

    final newMoovPayload = <int>[
      ...otherAtoms,
      ...newUdta,
    ];

    final int totalMoovLen = 8 + newMoovPayload.length;
    final res = Uint8List(totalMoovLen);
    res[0] = (totalMoovLen >> 24) & 0xFF;
    res[1] = (totalMoovLen >> 16) & 0xFF;
    res[2] = (totalMoovLen >> 8) & 0xFF;
    res[3] = totalMoovLen & 0xFF;
    res[4] = 0x6D; // 'm'
    res[5] = 0x6F; // 'o'
    res[6] = 0x6F; // 'o'
    res[7] = 0x76; // 'v'
    res.setRange(8, totalMoovLen, newMoovPayload);
    return res;
  }

  static Uint8List _adjustMoovChunkOffsets(Uint8List moovBytes, int delta) {
    final copy = Uint8List.fromList(moovBytes);
    _adjustAtomsRecursively(copy, 8, copy.length, delta);
    return copy;
  }

  static void _adjustAtomsRecursively(
    Uint8List bytes,
    int start,
    int end,
    int delta,
  ) {
    int pos = start;
    while (pos + 8 <= end) {
      final len = _readUint32(bytes, pos);
      if (len < 8 || pos + len > end) break;
      final type = latin1.decode(
        bytes.sublist(pos + 4, pos + 8),
      );

      if (type == 'stco') {
        // stco: [4 len][4 'stco'][4 ver/flags][4 entry_count][N * 4 offsets]
        if (pos + 16 <= pos + len) {
          final count = _readUint32(bytes, pos + 12);
          int offsetPos = pos + 16;
          for (int i = 0; i < count && offsetPos + 4 <= pos + len; i++) {
            final oldOffset = _readUint32(bytes, offsetPos);
            final newOffset = (oldOffset + delta) & 0xFFFFFFFF;
            bytes[offsetPos] = (newOffset >> 24) & 0xFF;
            bytes[offsetPos + 1] = (newOffset >> 16) & 0xFF;
            bytes[offsetPos + 2] = (newOffset >> 8) & 0xFF;
            bytes[offsetPos + 3] = newOffset & 0xFF;
            offsetPos += 4;
          }
        }
      } else if (type == 'co64') {
        // co64: [4 len][4 'co64'][4 ver/flags][4 entry_count][N * 8 offsets]
        if (pos + 16 <= pos + len) {
          final count = _readUint32(bytes, pos + 12);
          int offsetPos = pos + 16;
          for (int i = 0; i < count && offsetPos + 8 <= pos + len; i++) {
            final hi = _readUint32(bytes, offsetPos);
            final lo = _readUint32(bytes, offsetPos + 4);
            final oldVal = (hi << 32) | lo;
            final newVal = oldVal + delta;
            final newHi = (newVal >> 32) & 0xFFFFFFFF;
            final newLo = newVal & 0xFFFFFFFF;
            bytes[offsetPos] = (newHi >> 24) & 0xFF;
            bytes[offsetPos + 1] = (newHi >> 16) & 0xFF;
            bytes[offsetPos + 2] = (newHi >> 8) & 0xFF;
            bytes[offsetPos + 3] = newHi & 0xFF;
            bytes[offsetPos + 4] = (newLo >> 24) & 0xFF;
            bytes[offsetPos + 5] = (newLo >> 16) & 0xFF;
            bytes[offsetPos + 6] = (newLo >> 8) & 0xFF;
            bytes[offsetPos + 7] = newLo & 0xFF;
            offsetPos += 8;
          }
        }
      } else if (type == 'trak' ||
          type == 'mdia' ||
          type == 'minf' ||
          type == 'stbl') {
        // Container atoms: recurse into children
        _adjustAtomsRecursively(bytes, pos + 8, pos + len, delta);
      }

      pos += len;
    }
  }

  /// Injects standard iTunes metadata atoms into MP3/AAC audio bytes.
  static Uint8List injectMP3Metadata({
    required Uint8List audioBytes,
    required SavedSong song,
    Uint8List? coverArtBytes,
  }) {
    try {
      final cleanAudio = stripExistingId3Tags(audioBytes);
      if (cleanAudio.length < 16) return audioBytes;

      final newUdta = _buildMP3Udta(song: song, coverArtBytes: coverArtBytes);
      if (newUdta.isEmpty) return cleanAudio;

      int offset = 0;
      int? moovOffset;
      int? moovLength;
      int? mdatOffset;

      while (offset + 8 <= cleanAudio.length) {
        int atomLen = _readUint32(cleanAudio, offset);
        final atomType = latin1.decode(
          cleanAudio.sublist(offset + 4, offset + 8),
        );

        if (atomLen == 1 && offset + 16 <= cleanAudio.length) {
          final hi = _readUint32(cleanAudio, offset + 8);
          final lo = _readUint32(cleanAudio, offset + 12);
          atomLen = (hi << 32) | lo;
        } else if (atomLen == 0) {
          atomLen = cleanAudio.length - offset;
        }

        if (atomLen < 8 || offset + atomLen > cleanAudio.length) {
          break;
        }

        if (atomType == 'moov') {
          moovOffset = offset;
          moovLength = atomLen;
        } else if (atomType == 'mdat') {
          mdatOffset = offset;
        }

        offset += atomLen;
      }

      if (moovOffset == null || moovLength == null) {
        return cleanAudio;
      }

      final oldMoovBytes = cleanAudio.sublist(
        moovOffset,
        moovOffset + moovLength,
      );
      final updatedMoovBytes = _updateMoovWithUdta(oldMoovBytes, newUdta);
      final int deltaLength = updatedMoovBytes.length - moovLength;

      Uint8List finalMoovBytes = updatedMoovBytes;
      if (mdatOffset != null && moovOffset < mdatOffset && deltaLength != 0) {
        finalMoovBytes = _adjustMoovChunkOffsets(updatedMoovBytes, deltaLength);
      }

      final totalNewLength = cleanAudio.length + deltaLength;
      final result = Uint8List(totalNewLength);

      result.setRange(0, moovOffset, cleanAudio.sublist(0, moovOffset));
      result.setRange(
        moovOffset,
        moovOffset + finalMoovBytes.length,
        finalMoovBytes,
      );

      final afterOldMoovOffset = moovOffset + moovLength;
      if (afterOldMoovOffset < cleanAudio.length) {
        result.setRange(
          moovOffset + finalMoovBytes.length,
          totalNewLength,
          cleanAudio.sublist(afterOldMoovOffset),
        );
      }

      return result;
    } catch (_) {
      return stripExistingId3Tags(audioBytes);
    }
  }

  /// Injects appropriate metadata based on the detected audio container format:
  /// - MP3: embeds iTunes metadata atoms (udta.meta.ilst) and adjusts sample chunk offsets.
  /// - MP3: embeds standard ID3v2.3 header and ID3v1.1 footer.
  /// - Other formats (WebM, AAC ADTS, FLAC, etc.): returns clean audio without corrupting headers.
  Uint8List injectMetadata({
    required Uint8List audioBytes,
    required SavedSong song,
    Uint8List? coverArtBytes,
  }) {
    final String ext = detectAudioExtension(audioBytes);
    if (ext == '.m4a' || ext == '.mp4') {
      return injectMP3Metadata(
        audioBytes: audioBytes,
        song: song,
        coverArtBytes: coverArtBytes,
      );
    } else if (ext == '.mp3') {
      return injectMp3Metadata(
        audioBytes: audioBytes,
        song: song,
        coverArtBytes: coverArtBytes,
      );
    }
    // Safe return for other formats
    return stripExistingId3Tags(audioBytes);
  }
}

