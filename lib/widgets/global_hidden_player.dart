import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../providers/radio_provider.dart';

class GlobalHiddenPlayer extends StatefulWidget {
  const GlobalHiddenPlayer({super.key});

  @override
  State<GlobalHiddenPlayer> createState() => _GlobalHiddenPlayerState();
}

class _GlobalHiddenPlayerState extends State<GlobalHiddenPlayer>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final controller = provider.hiddenAudioController;

    if (controller == null) return;

    // Strict Sync: Ensure player matches provider state on any lifecycle change
    if (provider.isPlaying) {
      // Should be playing
      if (state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused) {
        // Force Resume steps
        Future.delayed(
          const Duration(milliseconds: 100),
          () => controller.play(),
        );
        Future.delayed(
          const Duration(milliseconds: 500),
          () => controller.play(),
        );
      }
    } else {
      // Should be paused
      if (state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused) {
        // Force Pause steps to prevent auto-play
        controller.pause();
        Future.delayed(
          const Duration(milliseconds: 100),
          () => controller.pause(),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RadioProvider>(
      builder: (context, provider, child) {
        if (provider.hiddenAudioController == null) {
          return const SizedBox.shrink();
        }

        // To ensure YouTube keeps playing, the view must be "visible" (not culled).
        // YoutubePlayer runs inside an InAppWebView internally anyway (on mobile),
        // but the widget needs to be in the tree.
        return Align(
          alignment: Alignment.bottomRight,
          child: Offstage(
            offstage: false, // Must be false to keep the webview alive
            child: SizedBox(
              width: 1,
              height: 1,
              child: YoutubePlayer(
                key: ValueKey(provider.audioOnlySongId ?? 'youtube_player'),
                controller: provider.hiddenAudioController!,
                showVideoProgressIndicator: false,
              ),
            ),
          ),
        );
      },
    );
  }
}
