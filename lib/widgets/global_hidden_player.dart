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
      // Should be playing. On many devices, backgrounding (paused/inactive)
      // triggers an auto-pause in the webview. We must fight this.
      if (state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused) {
        // Multiple attempts to resume as the OS might try to pause multiple times during transition
        for (var delay in [100, 500, 1000, 2000]) {
          Future.delayed(Duration(milliseconds: delay), () {
            if (provider.isPlaying && provider.hiddenAudioController != null) {
              provider.hiddenAudioController!.play();
            }
          });
        }
      }
    } else {
      // Should be paused
      if (state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused) {
        controller.pause();
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
          child: Opacity(
            opacity: 0.01, // Nearly invisible but RENDERED
            child: SizedBox(
              width: 10,
              height: 10,
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
