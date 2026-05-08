import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:flutter/foundation.dart';

class YouTubeAudioService {
  final YoutubeExplode _yt = YoutubeExplode();

  Future<({String url, Duration duration})?> getAudioStreamData(
    String videoId,
  ) async {
    try {
      var video = await _yt.videos.get(videoId);
      var manifest = await _yt.videos.streamsClient.getManifest(videoId);

      // Use muxed (Video+Audio) for maximum compatibility.
      // Raw audio streams (especially WebM/Opus) can cause silence on some Android devices.
      var streamInfo = manifest.muxed.withHighestBitrate();

      return (
        url: streamInfo.url.toString(),
        duration: video.duration ?? Duration.zero,
      );
    } catch (e) {
      debugPrint("Error fetching YouTube audio stream: $e");
      return null;
    }
  }

  void dispose() {
    _yt.close();
  }
}
