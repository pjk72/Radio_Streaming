import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class YouTubeAudioService {
  final YoutubeExplode _yt = YoutubeExplode();

  Future<String?> getAudioStreamUrl(String videoId) async {
    try {
      var manifest = await _yt.videos.streamsClient.getManifest(videoId);
      var audioOnly = manifest.audioOnly;
      if (audioOnly.isEmpty) return null;

      // Get the stream with the highest bitrate
      var streamInfo = audioOnly.withHighestBitrate();
      return streamInfo.url.toString();
    } catch (e) {
      print("Error fetching YouTube audio stream: $e");
      return null;
    }
  }

  void dispose() {
    _yt.close();
  }
}
