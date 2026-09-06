import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    as ye
    hide Playlist;

import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import '../models/saved_song.dart';
import '../services/entitlement_service.dart';
import '../services/recognition_api_service.dart';
import '../services/interstitial_ad_service.dart';
import '../services/encryption_service.dart';
import '../services/id3_tag_service.dart';
import '../utils/glass_utils.dart';
import '../utils/shazam_utils.dart';

class SongMetadataDetailsScreen extends StatefulWidget {
  const SongMetadataDetailsScreen({
    super.key,
    required this.initialSong,
    this.provider,
    this.playlistId,
  });

  final SavedSong initialSong;
  final RadioProvider? provider;
  final String? playlistId;

  @override
  State<SongMetadataDetailsScreen> createState() =>
      _SongMetadataDetailsScreenState();
}

class _SongMetadataDetailsScreenState extends State<SongMetadataDetailsScreen> {
  late SavedSong _song;
  bool _isFetching = false;
  bool _isSaving = false;
  bool _isAnalyzing = false;
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;

  @override
  void initState() {
    super.initState();
    _song = widget.initialSong;
    _titleController = TextEditingController(text: widget.initialSong.title);
    _artistController = TextEditingController(text: widget.initialSong.artist);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  void _showSnack(String key, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(context, listen: false)
                .translate(key),
          ),
          backgroundColor: color,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _reloadMetadata() async {
    final provider = widget.provider;
    if (provider == null || _isFetching) return;
    setState(() => _isFetching = true);
    try {
      await provider.findMissingArtworks(
        playlistId: widget.playlistId,
        songIdToSync: _song.id,
        explicitSong: _song,
      );

      SavedSong? updatedSong;
      try {
        if (widget.playlistId != null) {
          final p = provider.playlists
              .firstWhere((p) => p.id == widget.playlistId);
          updatedSong = p.songs.firstWhere((s) => s.id == _song.id);
        } else {
          updatedSong =
              provider.allUniqueSongs.firstWhere((s) => s.id == _song.id);
        }
      } catch (_) {}

      if (updatedSong != null && mounted) {
        final bool changed =
            updatedSong.duration != _song.duration ||
                updatedSong.genre != _song.genre ||
                updatedSong.artUri != _song.artUri ||
                updatedSong.album != _song.album;
        setState(() {
          _song = updatedSong!;
          _titleController.text = updatedSong.title;
          _artistController.text = updatedSong.artist;
        });
        _showSnack(changed ? 'metadata_updated' : 'no_new_metadata',
            changed ? Colors.green : Colors.orangeAccent);
      }
    } catch (e) {
      debugPrint('Error enriching song in details screen: $e');
    } finally {
      if (mounted) setState(() => _isFetching = false);
    }
  }

  Future<void> _saveMetadata() async {
    final provider = widget.provider;
    final playlistId = widget.playlistId;
    if (provider == null || playlistId == null) return;
    final newTitle = _titleController.text.trim();
    final newArtist = _artistController.text.trim();
    if (newTitle.isEmpty) return;
    setState(() => _isSaving = true);
    try {
      final updated = _song.copyWith(title: newTitle, artist: newArtist);
      if (updated.localPath != null && updated.localPath!.isNotEmpty) {
        try {
          final file = File(updated.localPath!);
          if (file.existsSync()) {
            final bytes = await file.readAsBytes();
            final tagged = Id3TagService().injectMetadata(
              audioBytes: bytes,
              song: updated,
            );
            await file.writeAsBytes(tagged, flush: true);
          }
        } catch (_) {}
      }
      await provider.updateSongMetadataGlobally(
        originalSongId: _song.id,
        title: newTitle,
        artist: newArtist,
      );
      await provider.updateSongInPlaylist(playlistId, updated);
      if (mounted) setState(() => _song = updated);
      _showSnack('metadata_updated', Colors.green);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _startRecognition() async {
    if (RecognitionApiService.isShazamDisabled.value) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Provider.of<LanguageProvider>(context, listen: false)
                  .translate('music_recognition_disabled_momentarily'),
            ),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    setState(() => _isAnalyzing = true);

    final String? resolvedUrl = await _resolvePlayableStreamUrl(_song);

    var streamUrl = resolvedUrl;
    if (streamUrl == null &&
        widget.provider != null &&
        widget.provider!.currentStation != null) {
      var stationUrl = widget.provider!.currentStation!.url;
      if (stationUrl.startsWith('youtube://')) {
        streamUrl = await _resolveYouTubeAudioUrl(
          stationUrl.substring('youtube://'.length).trim(),
        );
      } else {
        streamUrl = stationUrl;
      }
    }

    Map<String, dynamic>? result;

    if (streamUrl != null && streamUrl.isNotEmpty) {
      try {
        result = await RecognitionApiService().identifyStream(streamUrl);
      } catch (e) {
        debugPrint('Recognition error (stream): $e');
      }
    }

    if ((result == null || result['track'] == null) &&
        _song.isDownloaded &&
        _song.localPath != null &&
        _song.localPath!.isNotEmpty) {
      final Uint8List? bytes = await _readLocalSongBytes(_song.localPath!);
      if (bytes != null && bytes.isNotEmpty) {
        try {
          final Uint8List? sample = _extractMiddleSample(bytes);
          result = await RecognitionApiService()
              .identifyFromAudioBytes(sample ?? bytes);
        } catch (e) {
          debugPrint('Recognition error (local): $e');
        }
      }
    }

    _presentRecognitionResult(result);
  }

  void _presentRecognitionResult(Map<String, dynamic>? result) {
    if (!mounted) return;
    if (result != null && result['track'] != null) {
      InterstitialAdService().loadAd();
      _showRecognitionResultForSong(result['track']);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageProvider>(context, listen: false)
                .translate('song_not_recognized'),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    // The loading indicator must stay active until the result has been
    // presented (the "recognized" popup or the "not recognized" snackbar).
    if (mounted) setState(() => _isAnalyzing = false);
  }

  /// Recovers a playable audio source URL for the song.
  /// Priority: rawStreamUrl -> resolved YouTube audio stream.
  /// Handles the internal youtube:// scheme and full YouTube URLs by
  /// converting them into a direct audio stream URL using YoutubeExplode.
  Future<String?> _resolvePlayableStreamUrl(SavedSong song) async {
    final raw = song.rawStreamUrl;
    if (raw != null && raw.isNotEmpty) {
      if (raw.startsWith('youtube://')) {
        final videoId = raw.substring('youtube://'.length).trim();
        final resolved = await _resolveYouTubeAudioUrl(videoId);
        if (resolved != null) return resolved;
      } else if (raw.startsWith('http')) {
        return raw;
      }
    }

    String? youtubeUrl = song.youtubeUrl;

    // Try to recover a YouTube URL through SongLink when missing.
    if ((youtubeUrl == null || youtubeUrl.isEmpty) &&
        widget.provider != null) {
      try {
        final links = await widget.provider!.resolveLinks(
          title: song.title,
          artist: song.artist,
          appleMusicUrl: song.appleMusicUrl,
        );
        final youtube = links['youtube'];
        if (youtube != null && youtube.isNotEmpty) {
          youtubeUrl = youtube;
        }
      } catch (_) {}
    }

    // Final fallback: search YouTube to find the URL when the song has none,
    // then register it in the song metadata so it can be reused later.
    if ((youtubeUrl == null || youtubeUrl.isEmpty) &&
        widget.provider != null &&
        song.title.trim().isNotEmpty) {
      final found = await widget.provider!.searchYoutubeVideo(
        song.title,
        song.artist,
      );
      if (found != null && found.isNotEmpty) {
        youtubeUrl = found;
        await _persistYoutubeUrl(found);
      }
    }

    if (youtubeUrl == null || youtubeUrl.isEmpty) return null;

    var videoId = YoutubePlayer.convertUrlToId(youtubeUrl) ??
        (youtubeUrl.length == 11 ? youtubeUrl : null);
    if (videoId == null) return null;

    final resolved = await _resolveYouTubeAudioUrl(videoId);
    return resolved ?? youtubeUrl;
  }

  /// Registers the recovered YouTube URL into the song metadata and persists
  /// it into the current playlist so it can be reused on later recognitions.
  Future<void> _persistYoutubeUrl(String youtubeUrl) async {
    final provider = widget.provider;
    final playlistId = widget.playlistId;
    if (provider == null) return;
    if (_song.youtubeUrl == youtubeUrl) return;
    final updated = _song.copyWith(youtubeUrl: youtubeUrl);
    if (mounted) {
      setState(() => _song = updated);
    }
    if (playlistId == null) return;
    try {
      await provider.updateSongInPlaylist(playlistId, updated);
    } catch (e) {
      debugPrint('Persist youtubeUrl error: $e');
    }
  }

  /// Converts a YouTube video id into a direct, playable audio stream URL.
  /// Prefers a clean audio-only stream (best for fingerprinting); falls back
  /// to the muxed (audio+video) stream used for playback.
  Future<String?> _resolveYouTubeAudioUrl(String videoId) async {
    if (videoId.isEmpty) return null;
    try {
      final yt = ye.YoutubeExplode();
      try {
        final manifest = await yt.videos.streamsClient.getManifest(videoId);
        if (manifest.audioOnly.isNotEmpty) {
          return manifest.audioOnly.withHighestBitrate().url.toString();
        }
        if (manifest.muxed.isNotEmpty) {
          return manifest.muxed.withHighestBitrate().url.toString();
        }
        return null;
      } finally {
        yt.close();
      }
    } catch (e) {
      debugPrint('Resolve playable stream error: $e');
      return null;
    }
  }

  /// Reads the audio bytes of a downloaded (local) song for recognition.
  /// Encrypted app-managed files (.mst / _secure / offline_music) are first
  /// decrypted so the resulting audio is valid.
  Future<Uint8List?> _readLocalSongBytes(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final lower = path.toLowerCase();
      if (lower.endsWith('.mst') ||
          lower.contains('_secure.') ||
          lower.contains('offline_music')) {
        final decrypted = await EncryptionService().decryptToTempFile(path);
        return await decrypted.readAsBytes();
      }
      return await file.readAsBytes();
    } catch (e) {
      debugPrint('Read local song bytes error: $e');
      return null;
    }
  }

  Uint8List? _extractMiddleSample(Uint8List bytes,
      {int maxSample = 256 * 1024}) {
    if (bytes.length <= maxSample) return null;
    if (!_isLikelyMp3(bytes)) return null;
    final int mid = bytes.length ~/ 2;
    final int start = (mid - (maxSample ~/ 2)).clamp(0, bytes.length - maxSample);
    return Uint8List.sublistView(bytes, start, start + maxSample);
  }

  bool _isLikelyMp3(Uint8List bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return true;
    if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) return true;
    return false;
  }

  void _showRecognitionResultForSong(Map<String, dynamic> trackData) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    String title = trackData['title'] ?? lang.translate('unknown');
    String artist = trackData['subtitle'] ?? lang.translate('unknown');
    String cover = '';
    if (trackData['images'] != null) {
      cover = trackData['images']['coverart'] ??
          trackData['images']['background'] ??
          '';
    }

    String album = '';
    String year = '';
    String genre = '';

    if (trackData['sections'] != null) {
      for (var section in trackData['sections']) {
        if (section['type'] == 'SONG') {
          for (var meta in section['metadata'] ?? []) {
            if (meta['title'] == 'Album') album = meta['text'];
            if (meta['title'] == 'Released') year = meta['text'];
            if (meta['title'] == 'Genre') genre = meta['text'];
          }
        }
      }
    }
    if (genre.isEmpty &&
        trackData['genres'] != null &&
        trackData['genres']['primary'] != null) {
      genre = trackData['genres']['primary'];
    }

    GlassUtils.showGlassDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            return AlertDialog(
              backgroundColor:
                  Theme.of(ctx).cardColor.withValues(alpha: 0.15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.1), width: 1),
              ),
              contentPadding: const EdgeInsets.all(24),
              elevation: 0,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cover.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16.0),
                      child: CachedNetworkImage(
                        imageUrl: cover,
                        height: 180,
                        width: 180,
                        fit: BoxFit.cover,
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    artist,
                    style:
                        const TextStyle(fontSize: 14, color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  if (album.isNotEmpty || year.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (album.isNotEmpty)
                            Text(
                              "Album: $album",
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white60),
                              textAlign: TextAlign.center,
                            ),
                          if (year.isNotEmpty)
                            Text(
                              "${lang.translate('year')}: $year",
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white60),
                              textAlign: TextAlign.center,
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: Text(lang.translate('cancel')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0088FF),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () {
                            if (widget.provider != null) {
                              widget.provider!.updateSongMetadataGlobally(
                                originalSongId: _song.id,
                                title: title,
                                artist: artist,
                                album: album.isNotEmpty ? album : null,
                                artUri: cover.isNotEmpty ? cover : null,
                                genre: genre.isNotEmpty ? genre : null,
                                releaseDate:
                                    year.isNotEmpty ? year : null,
                              );
                            }
                            final updated = _song.copyWith(
                              title: title,
                              artist: artist,
                              album: album.isNotEmpty ? album : _song.album,
                              artUri:
                                  cover.isNotEmpty ? cover : _song.artUri,
                              genre: genre.isNotEmpty ? genre : _song.genre,
                              releaseDate: year.isNotEmpty
                                  ? year
                                  : _song.releaseDate,
                            );
                            if (mounted) {
                              setState(() {
                                _song = updated;
                                _titleController.text = updated.title;
                                _artistController.text = updated.artist;
                              });
                            }
                            Navigator.of(ctx).pop();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content:
                                      Text(lang.translate('metadata_updated')),
                                  backgroundColor: Colors.green,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.check_rounded, size: 18),
                          label: Text(
                            lang.translate('confirm'),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    InterstitialAdService().showAdIfAvailable();
  }

  Widget _buildInfoCard(List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        children: children,
      ),
    );
  }

  Widget _buildRowItem(IconData icon, String label, String value) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: onSurface.withValues(alpha: 0.5)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: onSurface.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: TextStyle(color: onSurface, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final lang = Provider.of<LanguageProvider>(context);
    if (_song.artUri != null && _song.artUri!.isNotEmpty) {
      return SizedBox(
        height: 200,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: _song.artUri!,
              fit: BoxFit.cover,
              errorWidget: (context, url, error) =>
                  Container(color: Theme.of(context).cardColor),
            ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Theme.of(context).cardColor.withValues(alpha: 0.8),
                    Theme.of(context).cardColor,
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _titleController,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 8),
                      hintText: lang.translate('title'),
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Colors.white38, width: 1),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _artistController,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 8),
                      hintText: lang.translate('artist'),
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Colors.white38, width: 1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 140,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _titleController,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 2,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              hintText: lang.translate('title'),
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.black26,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    const BorderSide(color: Colors.white38, width: 1),
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _artistController,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
            ),
            maxLines: 1,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              hintText: lang.translate('artist'),
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.black26,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    const BorderSide(color: Colors.white38, width: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCards() {
    final lang = Provider.of<LanguageProvider>(context);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildInfoCard([
          _buildRowItem(
              Icons.album_rounded, lang.translate('label_album'), _song.album),
          if (_song.genre != null && _song.genre!.isNotEmpty)
            _buildRowItem(
                Icons.music_note_rounded,
                lang.translate('genre'),
                _song.genre!),
          if (_song.duration != null)
            _buildRowItem(
              Icons.timer_rounded,
              lang.translate('duration_label'),
              "${_song.duration!.inMinutes}:${(_song.duration!.inSeconds % 60).toString().padLeft(2, '0')}",
            ),
          _buildRowItem(
            Icons.calendar_today_rounded,
            lang.translate('release_date'),
            (() {
              if (_song.releaseDate == null || _song.releaseDate!.isEmpty) {
                return lang.translate('unknown');
              }
              final dt = DateTime.tryParse(_song.releaseDate!);
              if (dt != null) {
                return "${dt.day.toString().padLeft(2, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.year}";
              }
              return _song.releaseDate!;
            })(),
          ),
          _buildRowItem(
            Icons.date_range_rounded,
            lang.translate('label_date_added'),
            _song.dateAdded.toString().split('.')[0],
          ),
        ]),
        const SizedBox(height: 16),
        _buildInfoCard([
          _buildRowItem(
              Icons.fingerprint_rounded, lang.translate('label_id'), _song.id),
          if (_song.provider != null && _song.provider!.isNotEmpty)
            _buildRowItem(
                Icons.cloud_circle_rounded, "Provider", _song.provider!),
          if (_song.youtubeUrl != null)
            _buildRowItem(Icons.play_circle_fill_rounded,
                lang.translate('label_youtube_url'), _song.youtubeUrl!),
          if (_song.localPath != null && _song.localPath!.isNotEmpty)
            _buildRowItem(
                Icons.folder_rounded, "Local Path", _song.localPath!),
        ]),
        if (_song.extras != null && _song.extras!.isNotEmpty) ...[
          const SizedBox(height: 16),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              collapsedIconColor: onSurface.withValues(alpha: 0.5),
              iconColor: onSurface,
              title: Text(
                "Raw Metadata",
                style: TextStyle(
                  color: onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                "Tap to view provider specific data",
                style: TextStyle(
                  color: onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: _song.extras!.entries.map((e) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                e.key,
                                style: TextStyle(
                                  color: onSurface.withValues(alpha: 0.6),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: SelectableText(
                                e.value.toString(),
                                style: TextStyle(
                                  color: onSurface,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRecognitionButton() {
    final lang = Provider.of<LanguageProvider>(context);
    final bool isShazamDisabled = RecognitionApiService.isShazamDisabled.value;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: (isShazamDisabled || _isAnalyzing)
              ? null
              : () {
                  ShazamUtils.checkAndShowShazamInfoDialog(
                    context,
                    _startRecognition,
                    showInfo: false,
                  );
                },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: isShazamDisabled
                  ? Colors.grey.withValues(alpha: 0.2)
                  : const Color(0xFF0088FF).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: isShazamDisabled
                    ? Colors.grey.withValues(alpha: 0.3)
                    : const Color(0xFF0088FF).withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_isAnalyzing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF0088FF),
                    ),
                  )
                else
                  const Icon(
                    Icons.track_changes,
                    color: Color(0xFF0088FF),
                    size: 20,
                  ),
                const SizedBox(width: 8),
                Text(
                  _isAnalyzing
                      ? lang.translate('shazam_analyzing')
                      : lang.translate('music_recognition'),
                  style: TextStyle(
                    color: isShazamDisabled ? Colors.grey : Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomButtons() {
    final lang = Provider.of<LanguageProvider>(context);
    final bool recognitionEnabled = Provider.of<EntitlementService>(context)
        .isFeatureEnabled('external_song_recognition');
    final bool canSave =
        widget.provider != null && widget.playlistId != null;

    final Widget saveButton = _buildSaveButton(lang, canSave);
    final Widget reloadButton = _buildReloadButton(lang);
    final Widget closeButton = _buildCloseButton(lang);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          // Line 1: Music Recognition (full width)
          if (recognitionEnabled) ...[
            _buildRecognitionButton(),
            const SizedBox(height: 8),
          ],
          // Line 2: Reload (full width)
          SizedBox(width: double.infinity, child: reloadButton),
          const SizedBox(height: 8),
          // Line 3: Save + Close
          Row(
            children: [
              Expanded(child: saveButton),
              const SizedBox(width: 10),
              Expanded(child: closeButton),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton(LanguageProvider lang, bool canSave) {
    return ElevatedButton.icon(
      onPressed: (_isSaving || !canSave) ? null : _saveMetadata,
      icon: _isSaving
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.save_rounded, size: 18),
      label: Text(
        lang.translate('save'),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        minimumSize: const Size(0, 44),
      ),
    );
  }

  Widget _buildReloadButton(LanguageProvider lang) {
    return ElevatedButton.icon(
      onPressed: _isFetching ? null : _reloadMetadata,
      icon: _isFetching
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.sync_rounded, size: 18),
      label: Text(
        lang.translate('reload'),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blueGrey.shade700,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        minimumSize: const Size(0, 44),
      ),
    );
  }

  Widget _buildCloseButton(LanguageProvider lang) {
    return ElevatedButton(
      onPressed: () => Navigator.pop(context),
      style: ElevatedButton.styleFrom(
        backgroundColor: Theme.of(context).primaryColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        minimumSize: const Size(0, 44),
      ),
      child: Text(
        lang.translate('close'),
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageProvider>(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          lang.translate('view_song_details'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: _buildHeader(),
                  ),
                  const SizedBox(height: 16),
                  _buildInfoCards(),
                ],
              ),
            ),
            _buildBottomButtons(),
          ],
        ),
      ),
    );
  }
}