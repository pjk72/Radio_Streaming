import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_streaming_app/models/saved_song.dart';
import 'package:radio_streaming_app/services/id3_tag_service.dart';

void main() {
  group('Id3TagService Tests', () {
    final service = Id3TagService();

    final testSong = SavedSong(
      id: 'test_song_123',
      title: 'Bohemian Rhapsody',
      artist: 'Queen',
      album: 'A Night at the Opera',
      artUri: 'https://example.com/cover.jpg',
      genre: 'Rock',
      releaseDate: '1975-10-31',
      dateAdded: DateTime(2024, 5, 1),
      duration: const Duration(minutes: 5, seconds: 55),
      youtubeUrl: 'https://youtube.com/watch?v=fJ9rUzIMcZQ',
      appleMusicUrl: 'https://music.apple.com/song/123',
      provider: 'RadioStream',
    );

    test('buildId3v2Tag creates valid ID3v2.3 header and frames', () {
      final dummyArt = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]);
      final tag = service.buildId3v2Tag(song: testSong, coverArtBytes: dummyArt);

      expect(tag.length, greaterThan(10));
      // ID3 Header check
      expect(tag[0], 0x49); // 'I'
      expect(tag[1], 0x44); // 'D'
      expect(tag[2], 0x33); // '3'
      expect(tag[3], 0x03); // Major version 3 (ID3v2.3)
      expect(tag[4], 0x00); // Revision 0

      // Synchsafe size decode
      final size = ((tag[6] & 0x7F) << 21) |
          ((tag[7] & 0x7F) << 14) |
          ((tag[8] & 0x7F) << 7) |
          (tag[9] & 0x7F);

      expect(size, equals(tag.length - 10));

      // Check text frames presence
      final tagString = latin1.decode(tag);
      expect(tagString.contains('TIT2'), isTrue);
      expect(tagString.contains('TPE1'), isTrue);
      expect(tagString.contains('TALB'), isTrue);
      expect(tagString.contains('TCON'), isTrue);
      expect(tagString.contains('TYER'), isTrue);
      expect(tagString.contains('COMM'), isTrue);
      expect(tagString.contains('APIC'), isTrue);
      expect(tagString.contains('WXXX'), isTrue);
      expect(tagString.contains('TXXX'), isTrue);
    });

    test('buildId3v1Tag creates valid 128-byte tag', () {
      final v1Tag = service.buildId3v1Tag(song: testSong);
      expect(v1Tag.length, equals(128));
      expect(v1Tag[0], 0x54); // 'T'
      expect(v1Tag[1], 0x41); // 'A'
      expect(v1Tag[2], 0x47); // 'G'

      final titleStr = latin1.decode(v1Tag.sublist(3, 33)).replaceAll('\x00', '').trim();
      expect(titleStr, equals('Bohemian Rhapsody'));

      final artistStr = latin1.decode(v1Tag.sublist(33, 63)).replaceAll('\x00', '').trim();
      expect(artistStr, equals('Queen'));

      final albumStr = latin1.decode(v1Tag.sublist(63, 93)).replaceAll('\x00', '').trim();
      expect(albumStr, equals('A Night at the Opera'));

      final yearStr = latin1.decode(v1Tag.sublist(93, 97)).replaceAll('\x00', '').trim();
      expect(yearStr, equals('1975'));
    });

    test('injectMetadata combines tags with raw audio and strips previous tags', () {
      final dummyAudio = Uint8List.fromList([
        0xFF, 0xFB, 0x90, 0x64, // MPEG-1 Layer III sync frame header
        ...List.generate(500, (i) => i % 256),
      ]);

      // 1. First injection
      final taggedAudio = service.injectMetadata(
        audioBytes: dummyAudio,
        song: testSong,
      );

      expect(taggedAudio.length, greaterThan(dummyAudio.length + 128));

      // 2. Re-injecting on already tagged audio should strip old tags first
      final reTaggedAudio = service.injectMetadata(
        audioBytes: taggedAudio,
        song: testSong,
      );

      expect(reTaggedAudio.length, equals(taggedAudio.length));
    });

    test('injectMP3Metadata embeds iTunes atoms (title, artist, album, covr, url)', () {
      // Build a minimal valid MP3 container (ftyp + moov + mdat)
      final ftypAtom = [
        0x00, 0x00, 0x00, 0x14, // len = 20
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x4D, 0x34, 0x41, 0x20, // 'MP3 '
        0x00, 0x00, 0x00, 0x00, // minor version
        0x4D, 0x34, 0x41, 0x20, // compatible brand
      ];

      final moovAtom = [
        0x00, 0x00, 0x00, 0x08, // len = 8 (empty moov)
        0x6D, 0x6F, 0x6F, 0x76, // 'moov'
      ];

      final mdatAtom = [
        0x00, 0x00, 0x00, 0x0C, // len = 12
        0x6D, 0x64, 0x61, 0x74, // 'mdat'
        0x01, 0x02, 0x03, 0x04, // sample data
      ];

      final dummyMP3 = Uint8List.fromList([...ftypAtom, ...moovAtom, ...mdatAtom]);
      final fakeCover = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]);

      final taggedMP3 = Id3TagService.injectMP3Metadata(
        audioBytes: dummyMP3,
        song: testSong,
        coverArtBytes: fakeCover,
      );

      final taggedStr = latin1.decode(taggedMP3);
      expect(taggedStr.contains('moov'), isTrue);
      expect(taggedStr.contains('udta'), isTrue);
      expect(taggedStr.contains('meta'), isTrue);
      expect(taggedStr.contains('ilst'), isTrue);
      expect(taggedStr.contains('\xA9nam'), isTrue);
      expect(taggedStr.contains('Bohemian Rhapsody'), isTrue);
      expect(taggedStr.contains('\xA9ART'), isTrue);
      expect(taggedStr.contains('Queen'), isTrue);
      expect(taggedStr.contains('\xA9alb'), isTrue);
      expect(taggedStr.contains('A Night at the Opera'), isTrue);
      expect(taggedStr.contains('\xA9url'), isTrue);
      expect(taggedStr.contains('https://example.com/cover.jpg'), isTrue);
      expect(taggedStr.contains('covr'), isTrue);
    });
  });
}
