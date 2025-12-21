import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

class YouTubePopup extends StatefulWidget {
  final String videoId;
  final bool initialAudioOnly;

  const YouTubePopup({
    super.key,
    required this.videoId,
    this.initialAudioOnly = false,
  });

  @override
  State<YouTubePopup> createState() => _YouTubePopupState();
}

class _YouTubePopupState extends State<YouTubePopup> {
  late YoutubePlayerController _videoController;
  bool _isAudioOnly = false;

  @override
  void initState() {
    super.initState();
    _initializeVideoPlayer();
    _isAudioOnly = widget.initialAudioOnly;
  }

  void _initializeVideoPlayer() {
    _videoController = YoutubePlayerController(
      initialVideoId: widget.videoId,
      flags: const YoutubePlayerFlags(
        autoPlay: true,
        mute: false,
        enableCaption: false,
        hideControls: false, // We will handle UI hiding manually
      ),
    );
  }

  void _toggleMode() {
    setState(() {
      _isAudioOnly = !_isAudioOnly;
    });
  }

  @override
  void dispose() {
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background dismiss
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(color: Colors.black.withOpacity(0.8)),
            ),
          ),

          // Content Container
          Container(
            width: MediaQuery.of(context).size.width * 0.9,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(10),
                  ),
                  // Stack Video + Audio Overlay
                  child: SizedBox(
                    height: 200,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Layer 1: The Video Player (Always present)
                        YoutubePlayer(
                          controller: _videoController,
                          showVideoProgressIndicator: true,
                          progressIndicatorColor: Colors.redAccent,
                          onEnded: (_) {},
                        ),

                        // Layer 2: Audio Only Overlay (Covers video)
                        if (_isAudioOnly)
                          Container(
                            color: Colors.grey[900],
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.music_note,
                                  size: 60,
                                  color: Colors.white54,
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  "Audio Only Mode",
                                  style: TextStyle(color: Colors.white),
                                ),
                                const SizedBox(height: 8),
                                // Controls linked to Video Controller
                                ValueListenableBuilder<YoutubePlayerValue>(
                                  valueListenable: _videoController,
                                  builder: (context, value, child) {
                                    final isPlaying = value.isPlaying;
                                    return IconButton(
                                      icon: Icon(
                                        isPlaying
                                            ? Icons.pause_circle_filled
                                            : Icons.play_circle_filled,
                                      ),
                                      iconSize: 64,
                                      color: Colors.redAccent,
                                      onPressed: () {
                                        if (isPlaying) {
                                          _videoController.pause();
                                        } else {
                                          _videoController.play();
                                        }
                                      },
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // Toggle Button
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xFF222222),
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(10),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _toggleMode,
                        icon: Icon(
                          _isAudioOnly ? Icons.videocam : Icons.headphones,
                          color: Colors.white,
                        ),
                        label: Text(
                          _isAudioOnly
                              ? "Switch to Video"
                              : "Switch to Audio Only",
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Close button
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
