import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/log_service.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';

class LogEntry {
  final String time;
  final String origin;
  final String action;
  final String attributes;
  final Map<String, String> attributesMap;
  final String raw;

  LogEntry({
    required this.time,
    required this.origin,
    required this.action,
    required this.attributes,
    required this.attributesMap,
    required this.raw,
  });

  factory LogEntry.parse(String logLine) {
    // Expected format: "[HH:mm:ss] Origin: Action: Attributes"
    final timeMatch = RegExp(r'^\[(.*?)\]').firstMatch(logLine);
    final time = timeMatch?.group(1) ?? "";

    final messagePart = logLine.replaceFirst(RegExp(r'^\[.*?\]\s*'), '');
    final parts = messagePart.split(':');

    String origin = "System";
    String action = "";
    String attributes = "";

    if (parts.length >= 1) {
      origin = parts[0].trim();
    }
    if (parts.length >= 2) {
      action = parts[1].trim();
    }
    if (parts.length >= 3) {
      attributes = parts.sublist(2).join(':').trim();
    }

    // Fallback if no colons found
    if (parts.length == 1) {
      origin = "General";
      action = parts[0].trim();
    }

    // Secondary parsing for attributes (key=value patterns)
    final Map<String, String> attrMap = {};
    if (attributes.isNotEmpty) {
      // Try to find key=value or key:value patterns
      final kvRegExp = RegExp(
        r'([\w\s]+)[:=]((?:[^,;]+|(?:\{[^\}]+\})|(?:\[[^\]]+\]))+)',
      );
      final matches = kvRegExp.allMatches(attributes);
      for (final m in matches) {
        final key = m.group(1)?.trim();
        final value = m.group(2)?.trim();
        if (key != null &&
            value != null &&
            key.isNotEmpty &&
            value.isNotEmpty) {
          attrMap[key] = value;
        }
      }
    }

    return LogEntry(
      time: time,
      origin: origin,
      action: action,
      attributes: attributes,
      attributesMap: attrMap,
      raw: logLine,
    );
  }
}

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  bool _isWrapped = false;
  bool _showFilters = false;
  final Set<String> _selectedOrigins = {};
  final Set<String> _selectedActions = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(Provider.of<LanguageProvider>(context).translate('debug_logs'), style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: Icon(
                  _showFilters ? Icons.expand_less : Icons.filter_list,
                  color: _showFilters ? Colors.orangeAccent : Colors.white70,
                ),
                tooltip: _showFilters ? "Hide Filters" : "Show Filters",
                onPressed: () => setState(() => _showFilters = !_showFilters),
              ),
              if (!_showFilters &&
                  (_selectedOrigins.isNotEmpty || _selectedActions.isNotEmpty))
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.orangeAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: Icon(
              _isWrapped ? Icons.wrap_text : Icons.short_text,
              color: Colors.blueAccent,
            ),
            tooltip: _isWrapped ? "Disable Wrap" : "Enable Wrap",
            onPressed: () {
              setState(() {
                _isWrapped = !_isWrapped;
              });
            },
          ),
          if (_selectedOrigins.isNotEmpty || _selectedActions.isNotEmpty)
            IconButton(
              icon: const Icon(
                Icons.filter_alt_off,
                color: Colors.orangeAccent,
              ),
              tooltip: "Clear All Filters",
              onPressed: () {
                setState(() {
                  _selectedOrigins.clear();
                  _selectedActions.clear();
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.greenAccent),
            onPressed: () {
              final text = LogService().logs.value.join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(Provider.of<LanguageProvider>(context, listen: false).translate('logs_copied'))),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            onPressed: () {
              LogService().clear();
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

          final allParsed = logs.map((l) => LogEntry.parse(l)).toList();

          // Interdependent filters
          final originsForFiltering = _selectedActions.isEmpty
              ? allParsed
              : allParsed.where((e) => _selectedActions.contains(e.action));
          final origins =
              originsForFiltering.map((e) => e.origin).toSet().toList()..sort();

          final actionsForFiltering = _selectedOrigins.isEmpty
              ? allParsed
              : allParsed.where((e) => _selectedOrigins.contains(e.origin));
          final actions =
              actionsForFiltering.map((e) => e.action).toSet().toList()..sort();

          var filteredLogs = allParsed;
          if (_selectedOrigins.isNotEmpty) {
            filteredLogs = filteredLogs
                .where((e) => _selectedOrigins.contains(e.origin))
                .toList();
          }
          if (_selectedActions.isNotEmpty) {
            filteredLogs = filteredLogs
                .where((e) => _selectedActions.contains(e.action))
                .toList();
          }

          return Stack(
            children: [
              // 1. LOG LIST (Main Content)
              Column(
                children: [
                  _buildHeader(),
                  const Divider(color: Colors.white24, height: 1),
                  Expanded(
                    child: filteredLogs.isEmpty
                        ? const Center(
                            child: Text(
                              "No logs match your filters.",
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.builder(
                            itemCount: filteredLogs.length,
                            padding: const EdgeInsets.only(bottom: 20),
                            itemBuilder: (context, index) {
                              final entry = filteredLogs[index];
                              final previousEntry = index > 0
                                  ? filteredLogs[index - 1]
                                  : null;

                              bool showSeparator = false;
                              if (previousEntry != null) {
                                if (entry.origin != previousEntry.origin ||
                                    entry.action != previousEntry.action) {
                                  showSeparator = true;
                                }
                              }

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (showSeparator)
                                    Container(
                                      height: 1,
                                      margin: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      color: Colors.white12,
                                    ),
                                  InkWell(
                                    onTap: () => _showLogDetail(entry),
                                    child: _buildLogRow(entry),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ],
              ),

              // 2. FILTER OVERLAY PANEL
              if (_showFilters)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.95),
                      border: const Border(
                        bottom: BorderSide(color: Colors.white10, width: 1),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildFilterList(
                          "Files/Origins",
                          origins,
                          _selectedOrigins,
                        ),
                        _buildFilterList("Actions", actions, _selectedActions),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => setState(() => _showFilters = false),
                          icon: const Icon(Icons.close, size: 14),
                          label: const Text(
                            "CLOSE FILTERS",
                            style: TextStyle(fontSize: 10),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white54,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterList(
    String title,
    List<String> items,
    Set<String> selectionSet,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 40,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: items.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            final isAllSelected = selectionSet.isEmpty;
            return Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: ChoiceChip(
                label: Text(Provider.of<LanguageProvider>(context).translate('all_title').replaceAll('{0}', title), style: const TextStyle(fontSize: 11)),
                selected: isAllSelected,
                onSelected: (selected) {
                  if (selected) setState(() => selectionSet.clear());
                },
                backgroundColor: Colors.white10,
                selectedColor: Colors.blueAccent.withOpacity(0.3),
                labelStyle: TextStyle(
                  color: isAllSelected ? Colors.blueAccent : Colors.white60,
                ),
                showCheckmark: false,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            );
          }

          final item = items[index - 1];
          final isSelected = selectionSet.contains(item);

          return Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ChoiceChip(
              label: Text(item, style: const TextStyle(fontSize: 11)),
              selected: isSelected,
              onSelected: (selected) {
                setState(() {
                  if (selected) {
                    selectionSet.add(item);
                  } else {
                    selectionSet.remove(item);
                  }
                });
              },
              backgroundColor: Colors.white10,
              selectedColor: Colors.greenAccent.withOpacity(0.2),
              labelStyle: TextStyle(
                color: isSelected ? Colors.greenAccent : Colors.white60,
              ),
              showCheckmark: false,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          );
        },
      ),
    );
  }

  void _showLogDetail(LogEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text(Provider.of<LanguageProvider>(context).translate('log_detail'), style: TextStyle(color: Colors.white)),
          ],
        ),
        content: SizedBox(
          width: MediaQuery.of(context).size.width * 0.8,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _detailItem("Time", entry.time, Colors.grey),
                _detailItem("Origin", entry.origin, Colors.blueAccent),
                _detailItem("Action", entry.action, Colors.greenAccent),
                const Divider(color: Colors.white24, height: 24),

                // STRUCTURED ATTRIBUTES
                const Text(
                  "Attributes:",
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                if (entry.attributesMap.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.1),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: entry.attributesMap.entries.map((e) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "• ",
                                style: TextStyle(
                                  color: Colors.blueAccent,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                "${e.key}: ",
                                style: const TextStyle(
                                  color: Colors.blueAccent,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  e.value,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontFamily: 'Courier',
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  )
                else
                  Text(
                    entry.attributes.isEmpty ? "None" : entry.attributes,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'Courier',
                      fontSize: 13,
                    ),
                  ),

                const SizedBox(height: 16),
                const Text(
                  "Raw Log:",
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.greenAccent.withOpacity(0.2),
                    ),
                  ),
                  child: Text(
                    entry.raw,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'Courier',
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            child: const Text(
              "CLOSE",
              style: TextStyle(color: Colors.blueAccent),
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          TextButton(
            child: const Text(
              "COPY RAW",
              style: TextStyle(color: Colors.greenAccent),
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: entry.raw));
              Navigator.of(context).pop();
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(Provider.of<LanguageProvider>(context, listen: false).translate('raw_log_copied'))));
            },
          ),
        ],
      ),
    );
  }

  Widget _detailItem(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              "$label:",
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: Row(
        children: [
          _headerCell("Time", 1),
          _headerCell("File/Origin", 2),
          _headerCell("Action", 2),
          _headerCell("Attributes", 3),
        ],
      ),
    );
  }

  Widget _headerCell(String text, int flex) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _buildLogRow(LogEntry entry) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.05), width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _dataCell(entry.time, 1, Colors.grey),
          _dataCell(entry.origin, 2, Colors.blueAccent),
          _dataCell(entry.action, 2, Colors.greenAccent),
          _dataCell(entry.attributes, 3, Colors.white),
        ],
      ),
    );
  }

  Widget _dataCell(String text, int flex, Color color) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.only(right: 4.0),
        child: Text(
          text,
          softWrap: _isWrapped,
          overflow: _isWrapped ? TextOverflow.visible : TextOverflow.ellipsis,
          style: TextStyle(color: color, fontFamily: 'Courier', fontSize: 11),
        ),
      ),
    );
  }
}
