import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class SpotifyLoginScreen extends StatefulWidget {
  final String loginUrl;
  final String redirectUri;
  const SpotifyLoginScreen({
    super.key,
    required this.loginUrl,
    required this.redirectUri,
  });

  @override
  State<SpotifyLoginScreen> createState() => _SpotifyLoginScreenState();
}

class _SpotifyLoginScreenState extends State<SpotifyLoginScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            if (request.url.startsWith(widget.redirectUri)) {
              final uri = Uri.parse(request.url);
              final code = uri.queryParameters['code'];
              if (code != null) {
                Navigator.pop(context, code);
              } else {
                Navigator.pop(context);
              }
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.loginUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Spotify Login"),
        backgroundColor: const Color(0xFF1db954),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
