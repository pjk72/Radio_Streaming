import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/log_service.dart';

class DebugLogScreen extends StatelessWidget {
  const DebugLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Debug Logs"),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              LogService().clear();
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final text = LogService().logs.value.join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Logs copied to clipboard")),
              );
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: LogService().logs,
        builder: (context, logs, child) {
          if (logs.isEmpty) {
            return const Center(
              child: Text(
                "No logs yet.",
                style: TextStyle(color: Colors.white54),
              ),
            );
          }
          return ListView.builder(
            itemCount: logs.length,
            padding: const EdgeInsets.all(8),
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: Text(
                  logs[index],
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'Courier',
                    fontSize: 12,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
