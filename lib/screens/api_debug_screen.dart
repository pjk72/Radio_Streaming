import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';

class ApiDebugScreen extends StatelessWidget {
  const ApiDebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);

    // Helper to format JSON
    String prettyPrint(String jsonStr) {
      try {
        if (jsonStr.startsWith("{") || jsonStr.startsWith("[")) {
          final decoded = jsonDecode(jsonStr);
          final encoder = JsonEncoder.withIndent('  ');
          return encoder.convert(decoded);
        }
      } catch (_) {}
      return jsonStr;
    }

    final recognitionJson = prettyPrint(provider.lastApiResponse);
    final songLinkJson = prettyPrint(provider.lastSongLinkResponse);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFF1a1a2e),
        appBar: AppBar(
          title: const Text("API Debug", style: TextStyle(color: Colors.white)),
          iconTheme: const IconThemeData(color: Colors.white),
          backgroundColor: Colors.transparent,
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.greenAccent,
            tabs: [
              Tab(text: "Recognition (ACR)"),
              Tab(text: "Song Links (Odesli)"),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildLogView(recognitionJson),
            _buildLogView(songLinkJson),
          ],
        ),
      ),
    );
  }

  Widget _buildLogView(String content) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        content,
        style: const TextStyle(
          color: Colors.greenAccent,
          fontFamily: 'monospace',
          fontSize: 14,
        ),
      ),
    );
  }
}
