import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';

class SleepTimerScreen extends StatelessWidget {
  const SleepTimerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final radio = Provider.of<RadioProvider>(context);
    final langProvider = Provider.of<LanguageProvider>(context);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          langProvider.translate('sleep_timer'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // Background Gradient matching app style
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Theme.of(context).scaffoldBackgroundColor,
                  Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.8),
                ],
              ),
            ),
          ),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _buildGlassCard(
                  context,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(
                        context,
                        langProvider.translate('sleep_timer'),
                        Icons.timer_outlined,
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          langProvider.translate('sleep_timer'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          radio.sleepTimerEnabled
                              ? "${langProvider.translate('remaining_time')}: ${_formatDuration(radio.remainingSleepTime)}"
                              : langProvider.translate('sleep_timer_desc'),
                          style: const TextStyle(color: Colors.white38),
                        ),
                        value: radio.sleepTimerEnabled,
                        onChanged: (val) => radio.setSleepTimerEnabled(val),
                        activeColor: Theme.of(context).primaryColor,
                      ),
                      if (radio.sleepTimerEnabled) ...[
                        const Divider(color: Colors.white10, height: 32),
                        _buildSettingsRow(
                          context,
                          label: langProvider.translate('set_duration'),
                          value: _formatDuration(radio.sleepTimerDuration),
                          onTap: () => _showTimePicker(
                            context,
                            radio: radio,
                            langProvider: langProvider,
                            isDuration: true,
                            title: langProvider.translate('set_duration'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlassCard(BuildContext context, {required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).primaryColor, size: 20),
        const SizedBox(width: 12),
        Text(
          title.toUpperCase(),
          style: TextStyle(
            color: Theme.of(context).primaryColor,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsRow(
    BuildContext context, {
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            Row(
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white24,
                  size: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration? d) {
    if (d == null) return "00:00";
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    return "${twoDigits(d.inHours)}:${twoDigits(d.inMinutes.remainder(60))}";
  }

  void _showTimePicker(
    BuildContext context, {
    required RadioProvider radio,
    required LanguageProvider langProvider,
    required bool isDuration,
    required String title,
  }) {
    int selectedHour = isDuration ? 0 : DateTime.now().hour;
    int selectedMinute = isDuration ? 30 : DateTime.now().minute;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.45,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.8),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 30),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildTimeColumn(
                          max: 23,
                          current: selectedHour,
                          onChanged: (val) => setModalState(() => selectedHour = val),
                        ),
                        const Text(":", style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                        _buildTimeColumn(
                          max: 59,
                          current: selectedMinute,
                          onChanged: (val) => setModalState(() => selectedMinute = val),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).primaryColor,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                        ),
                        onPressed: () {
                          if (isDuration) {
                            radio.setSleepTimerDuration(Duration(hours: selectedHour, minutes: selectedMinute));
                          }
                          Navigator.pop(ctx);
                        },
                        child: Text(langProvider.translate('done').toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTimeColumn({required int max, required int current, required ValueChanged<int> onChanged}) {
    return SizedBox(
      width: 80,
      child: ListWheelScrollView.useDelegate(
        itemExtent: 50,
        perspective: 0.005,
        diameterRatio: 1.2,
        physics: const FixedExtentScrollPhysics(),
        onSelectedItemChanged: onChanged,
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: max + 1,
          builder: (context, index) {
            final isSelected = index == current;
            return Center(
              child: Text(
                index.toString().padLeft(2, '0'),
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white24,
                  fontSize: isSelected ? 28 : 20,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            );
          },
        ),
        controller: FixedExtentScrollController(initialItem: current),
      ),
    );
  }
}
