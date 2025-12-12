import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';

class ApiDebugScreen extends StatelessWidget {
  const ApiDebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final jsonStr = provider.lastApiResponse;

    String prettyJson = jsonStr;
    try {
      if (jsonStr.startsWith("{") || jsonStr.startsWith("[")) {
        final decoded = jsonDecode(jsonStr);
        final encoder = JsonEncoder.withIndent('  ');
        prettyJson = encoder.convert(decoded);
      }
    } catch (_) {}

    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        title: const Text(
          "API JSON Debug",
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        backgroundColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          prettyJson,
          style: const TextStyle(
            color: Colors.greenAccent,
            fontFamily: 'monospace',
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
