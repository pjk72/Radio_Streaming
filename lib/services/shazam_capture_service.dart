import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'log_service.dart';
import 'recognition_api_service.dart';

enum ShazamCapturePhase { listening, analyzing }

/// Shared microphone capture + recognition flow used by both
/// NowPlayingHeader and TutorialCreateRadioWizard.
///
/// Strategy: record up to [maxClips] short clips sequentially and run
/// recognition after each one. This drastically increases the chance of a
/// match on live radio, where a single window can land on a DJ jingle,
/// voiceover or instrumental intro.
class ShazamCaptureService {
  /// Length of each recording window.
  static const int clipDurationSeconds = 6;

  /// Maximum number of recording windows before giving up.
  static const int maxClips = 3;

  final AudioRecorder _record = AudioRecorder();

  bool _isCancelled = false;
  bool _isBusy = false;

  /// True when the user explicitly cancelled the last capture.
  bool wasCancelled = false;

  Future<bool> hasPermission() => _record.hasPermission();

  /// Cancels an in-progress capture. The current recording window is stopped
  /// and no further windows are started.
  void cancel() => _isCancelled = true;

  Future<void> dispose() async {
    try {
      await _record.stop();
    } catch (_) {}
    await _record.dispose();
  }

  /// Records and recognizes a song from the microphone.
  ///
  /// [onPhaseChanged] reports the current UI phase together with the clip
  /// index (1-based) so callers can show progress.
  /// [onMicAcquired] / [onMicReleased] are invoked around the microphone
  /// lifetime (used to toggle the radio's ignoring-pause mode).
  ///
  /// Returns the recognition result map (with a non-null 'track') or null
  /// when nothing was recognized, all keys failed or the user cancelled.
  Future<Map<String, dynamic>?> captureAndRecognize({
    required void Function(ShazamCapturePhase phase, int clipIndex, int totalClips)
        onPhaseChanged,
    void Function()? onMicAcquired,
    void Function()? onMicReleased,
  }) async {
    if (_isBusy) {
      LogService().log("ShazamCapture: capture already in progress, ignoring.");
      return null;
    }
    _isBusy = true;
    _isCancelled = false;
    wasCancelled = false;

    try {
      final Directory tempDir = await getTemporaryDirectory();

      for (int clip = 1; clip <= maxClips; clip++) {
        if (_isCancelled) break;

        onPhaseChanged(ShazamCapturePhase.listening, clip, maxClips);
        onMicAcquired?.call();

        Uint8List? audioBytes;
        try {
          audioBytes = await _recordClip(tempDir, clip);
        } catch (e) {
          LogService().log("ShazamCapture: recording error on clip $clip: $e");
          onMicReleased?.call();
          rethrow;
        }
        onMicReleased?.call();

        if (_isCancelled) break;
        if (audioBytes == null || audioBytes.isEmpty) continue;

        onPhaseChanged(ShazamCapturePhase.analyzing, clip, maxClips);

        final result =
            await RecognitionApiService().identifyFromAudioBytes(audioBytes);

        if (_isCancelled) break;

        if (result != null && result['track'] != null) {
          LogService().log(
              "ShazamCapture: recognized on clip $clip/$maxClips.");
          return result;
        }

        LogService().log(
            "ShazamCapture: no match on clip $clip/$maxClips, trying next window.");
      }

      if (_isCancelled) {
        wasCancelled = true;
        LogService().log("ShazamCapture: cancelled by user.");
      }
      return null;
    } finally {
      _isBusy = false;
    }
  }

  Future<Uint8List?> _recordClip(Directory tempDir, int clipIndex) async {
    final String tempPath = '${tempDir.path}/shazam_capture_$clipIndex.m4a';

    await _record.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
        numChannels: 1,
        audioInterruption: AudioInterruptionMode.none,
      ),
      path: tempPath,
    );

    await Future.delayed(const Duration(seconds: clipDurationSeconds));

    final path = await _record.stop();
    if (path == null) return null;

    try {
      final File audioFile = File(path);
      final Uint8List bytes = await audioFile.readAsBytes();
      // Best-effort cleanup so temp storage doesn't grow.
      try {
        await audioFile.delete();
      } catch (_) {}
      return bytes;
    } catch (e) {
      LogService().log("ShazamCapture: failed reading clip $clipIndex: $e");
      return null;
    }
  }
}
