import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import '../models/saved_song.dart';

/// Available time filters for the statistics dashboard
enum StatsFilter { lifetime, last7Days, lastWeek, lastMonth, custom }

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  StatsFilter _filter = StatsFilter.lifetime;
  DateTimeRange? _customRange;

  // Returns the date range for the current filter, or null for lifetime
  DateTimeRange? get _activeDateRange {
    final now = DateTime.now();
    switch (_filter) {
      case StatsFilter.last7Days:
        return DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now);
      case StatsFilter.lastWeek:
        final weekday = now.weekday;
        final monday = now.subtract(Duration(days: weekday + 6));
        final sunday = monday.add(const Duration(days: 6));
        return DateTimeRange(start: monday, end: sunday);
      case StatsFilter.lastMonth:
        return DateTimeRange(
          start: DateTime(now.year, now.month - 1, now.day),
          end: now,
        );
      case StatsFilter.custom:
        return _customRange;
      case StatsFilter.lifetime:
        return null;
    }
  }

  Future<void> _showCustomRangePicker(BuildContext context) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: _customRange ??
          DateTimeRange(
            start: DateTime.now().subtract(const Duration(days: 30)),
            end: DateTime.now(),
          ),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            dialogBackgroundColor: Colors.transparent,
            scaffoldBackgroundColor: Colors.transparent,
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: Theme.of(context).primaryColor,
                  onPrimary: Colors.white,
                  surface: Colors.black.withValues(alpha: 0.3),
                  onSurface: Colors.white,
                  secondary: Theme.of(context).primaryColor,
                ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                textStyle: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 350, maxHeight: 550),
                margin: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 30,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
    if (picked != null) {
      setState(() {
        _customRange = picked;
        _filter = StatsFilter.custom;
      });
    }
  }

  /// Aggregates play counts from weeklyPlayLog filtered by the date range
  Map<String, dynamic> _aggregateFiltered(RadioProvider radio, DateTimeRange range) {
    final Map<String, int> phoneHistory = {};
    final Map<String, int> aaHistory = {};

    for (final entry in radio.weeklyPlayLog) {
      try {
        final ts = DateTime.parse(entry['ts'] as String);
        if (ts.isAfter(range.start) && ts.isBefore(range.end.add(const Duration(days: 1)))) {
          final songId = entry['id'] as String;
          final source = entry['source'] as String? ?? 'phone';
          if (source == 'car') {
            aaHistory[songId] = (aaHistory[songId] ?? 0) + 1;
          } else {
            phoneHistory[songId] = (phoneHistory[songId] ?? 0) + 1;
          }
        }
      } catch (_) {}
    }
    return {'phone': phoneHistory, 'aa': aaHistory};
  }

  @override
  Widget build(BuildContext context) {
    final radio = Provider.of<RadioProvider>(context);
    final lang = Provider.of<LanguageProvider>(context);

    // ── DATA AGGREGATION ────────────────────────────────────────────────
    final Map<String, int> activeHistory;
    final Map<String, int> activeAAHistory;
    final int totalSongsCount = radio.playlists.fold<int>(0, (sum, p) => sum + p.songs.length);
    final int totalPlaylists = radio.playlists.length;

    final range = _activeDateRange;
    if (range != null) {
      final agg = _aggregateFiltered(radio, range);
      activeHistory = agg['phone'] as Map<String, int>;
      activeAAHistory = agg['aa'] as Map<String, int>;
    } else {
      activeHistory = radio.userPlayHistory;
      activeAAHistory = radio.aaUserPlayHistory;
    }

    // Build unified top songs for the selected period
    final List<Map<String, dynamic>> topSongsData = [];
    final Set<String> allSongIds = {...activeHistory.keys, ...activeAAHistory.keys};
    for (final id in allSongIds) {
      final song = radio.historyMetadata[id];
      if (song != null) {
        topSongsData.add({
          'song': song,
          'phoneCount': activeHistory[id] ?? 0,
          'aaCount': activeAAHistory[id] ?? 0,
        });
      }
    }
    topSongsData.sort((a, b) => ((b['phoneCount'] as int) + (b['aaCount'] as int))
        .compareTo((a['phoneCount'] as int) + (a['aaCount'] as int)));

    int phoneTotal = 0;
    activeHistory.forEach((_, c) => phoneTotal += c);
    int aaTotal = 0;
    activeAAHistory.forEach((_, c) => aaTotal += c);
    final totalListenings = phoneTotal + aaTotal;
    final estimatedHours = (totalListenings * 3.5 / 60).toStringAsFixed(1);

    final Set<String> uniqueArtists = {};
    final Set<String> uniqueAlbums = {};
    final Map<String, int> decadeCounts = {};
    final Map<String, int> genreCounts = {};

    void processSong(SavedSong s) {
      uniqueArtists.add(s.artist);
      uniqueAlbums.add(s.album);
      // Dynamic Genre from Song metadata
      final g = s.genre ?? lang.translate('genre_unknown');
      genreCounts[g] = (genreCounts[g] ?? 0) + 1;

      if (s.releaseDate != null && s.releaseDate!.length >= 4) {
        final year = int.tryParse(s.releaseDate!.substring(0, 4));
        if (year != null) {
          final decade = "${(year ~/ 10) * 10}s";
          decadeCounts[decade] = (decadeCounts[decade] ?? 0) + 1;
        }
      }
    }

    if (range == null) {
      for (final p in radio.playlists) {
        for (final s in p.songs) processSong(s);
      }
      for (final s in radio.historyMetadata.values) processSong(s);
    } else {
      for (final id in allSongIds) {
        final song = radio.historyMetadata[id];
        if (song != null) processSong(song);
      }
    }

    final sortedDecades = decadeCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final playlistDistData = radio.playlists
        .map((p) => MapEntry(p.name, p.songs.length))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final Map<String, int> artistCounts = {};
    for (final data in topSongsData) {
      final song = data['song'] as SavedSong;
      final count = (data['phoneCount'] as int) + (data['aaCount'] as int);
      artistCounts[song.artist] = (artistCounts[song.artist] ?? 0) + count;
    }
    final sortedArtists = artistCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final sortedGenres = genreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // ── UI ──────────────────────────────────────────────────────────────
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(lang.translate('statistics'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          children: [
            // ── TIME FILTER BAR ────────────────────────────────────────
            _buildTimeFilterBar(lang),

            const SizedBox(height: 20),

            // ── METRICS GRID ───────────────────────────────────────────
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.1,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              children: [
                _buildMiniStatCard(context, title: lang.translate('total_songs'), value: totalSongsCount.toString(), icon: Icons.music_note_rounded, color: Colors.blueAccent),
                _buildMiniStatCard(context, title: lang.translate('estimated_listening_time'), value: lang.translate('hours_unit').replaceFirst('{0}', estimatedHours), icon: Icons.timer_rounded, color: Colors.orangeAccent),
                _buildMiniStatCard(context, title: lang.translate('total_playlists'), value: totalPlaylists.toString(), icon: Icons.playlist_play_rounded, color: Colors.tealAccent),
                _buildMiniStatCard(context, title: lang.translate('total_listening'), value: totalListenings.toString(), icon: Icons.headphones_rounded, color: Colors.cyanAccent),
                _buildMiniStatCard(context, title: lang.translate('total_artists'), value: uniqueArtists.length.toString(), icon: Icons.person_rounded, color: Colors.purpleAccent),
                _buildMiniStatCard(context, title: lang.translate('total_albums'), value: uniqueAlbums.length.toString(), icon: Icons.album_rounded, color: Colors.pinkAccent),
              ],
            ),

            const SizedBox(height: 24),

            // ── TOP SONGS ──────────────────────────────────────────────
            _buildSectionHeader(context, lang.translate('stats_top_songs')),
            const SizedBox(height: 12),
            _buildHorizontalChart(
              context,
              items: topSongsData.take(10).map((d) {
                final song = d['song'] as SavedSong;
                return ChartItem(
                  label: song.title,
                  subLabel: song.artist,
                  value: (d['phoneCount'] as int) + (d['aaCount'] as int),
                );
              }).toList(),
              color: Theme.of(context).primaryColor,
            ),

            const SizedBox(height: 24),

            // ── PLAYLIST DISTRIBUTION ──────────────────────────────────
            _buildSectionHeader(context, lang.translate('playlist_distribution')),
            const SizedBox(height: 12),
            _buildHorizontalChart(
              context,
              items: playlistDistData.take(10).map((e) => ChartItem(label: e.key, value: e.value)).toList(),
              color: Colors.tealAccent,
            ),

            const SizedBox(height: 24),

            // ── TOP ARTISTS ────────────────────────────────────────────
            _buildSectionHeader(context, lang.translate('most_played_artists')),
            const SizedBox(height: 12),
            _buildHorizontalChart(
              context,
              items: sortedArtists.take(10).map((e) => ChartItem(label: e.key, value: e.value)).toList(),
              color: Colors.indigoAccent,
              isGradient: true,
            ),

            const SizedBox(height: 24),

            // ── DECADES ────────────────────────────────────────────────
            if (sortedDecades.isNotEmpty) ...[
              _buildSectionHeader(context, lang.translate('top_decades')),
              const SizedBox(height: 12),
              _buildHorizontalChart(
                context,
                items: sortedDecades.map((e) => ChartItem(label: e.key, value: e.value)).toList(),
                color: Colors.orangeAccent,
              ),
              const SizedBox(height: 24),
            ],

            // ── GENRE DISTRIBUTION ─────────────────────────────────────
            if (sortedGenres.isNotEmpty) ...[
              _buildSectionHeader(context, lang.translate('genre_distribution')),
              const SizedBox(height: 12),
              _buildHorizontalChart(
                context,
                items: sortedGenres
                    .map((e) => ChartItem(label: e.key, value: e.value))
                    .toList(),
                color: Colors.deepPurpleAccent,
              ),
              const SizedBox(height: 24),
            ],

            // ── LISTENING SOURCE ───────────────────────────────────────
            _buildSectionHeader(context, lang.translate('listening_source')),
            const SizedBox(height: 12),
            _buildSourceChart(context, lang, phoneTotal, aaTotal),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ── FILTER BAR ─────────────────────────────────────────────────────────
  Widget _buildTimeFilterBar(LanguageProvider lang) {
    return _buildGlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.calendar_today_rounded,
              size: 16, color: Theme.of(context).primaryColor),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _chip(lang.translate('lifetime'), StatsFilter.lifetime),
                  const SizedBox(width: 8),
                  _chip(lang.translate('last_7_days'), StatsFilter.last7Days),
                  const SizedBox(width: 8),
                  _chip(lang.translate('last_week'), StatsFilter.lastWeek),
                  const SizedBox(width: 8),
                  _chip(lang.translate('last_month'), StatsFilter.lastMonth),
                  const SizedBox(width: 8),
                  _customChip(lang),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, StatsFilter value) {
    final isSelected = _filter == value;
    return GestureDetector(
      onTap: () => setState(() => _filter = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).primaryColor
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.white24 : Colors.white12,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white54,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _customChip(LanguageProvider lang) {
    final isSelected = _filter == StatsFilter.custom;
    String label = lang.translate('custom_range');
    if (isSelected && _customRange != null) {
      final fmt = (DateTime d) => '${d.day}/${d.month}';
      label = lang
          .translate('custom_range_label')
          .replaceFirst('{0}', fmt(_customRange!.start))
          .replaceFirst('{1}', fmt(_customRange!.end));
    }
    return GestureDetector(
      onTap: () => _showCustomRangePicker(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).primaryColor
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.white24 : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.date_range_rounded,
                size: 12,
                color: isSelected ? Colors.white : Colors.white54),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white54,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── CHARTS ─────────────────────────────────────────────────────────────
  Widget _buildHorizontalChart(
    BuildContext context, {
    required List<ChartItem> items,
    required Color color,
    bool isGradient = false,
    List<Color>? barColors,
  }) {
    if (items.isEmpty) {
      return _buildGlassContainer(
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text('No data for this period',
                style: TextStyle(color: Colors.white24, fontSize: 12)),
          ),
        ),
      );
    }
    final maxVal = items.first.value.toDouble();
    return _buildGlassContainer(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: items.asMap().entries.map((entry) {
            final idx = entry.key;
            final item = entry.value;
            final heightFactor = maxVal == 0 ? 0.0 : item.value / maxVal;
            final Color barColor = barColors != null
                ? barColors[idx % barColors.length]
                : (isGradient ? Colors.purpleAccent : color);
            return Container(
              width: 80,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(item.value.toString(),
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Container(
                    height: 100 * heightFactor,
                    width: 35,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: isGradient && barColors == null
                            ? [
                                Colors.purpleAccent.withValues(alpha: 0.8),
                                Colors.blueAccent.withValues(alpha: 0.2)
                              ]
                            : [
                                barColor.withValues(alpha: 0.85),
                                barColor.withValues(alpha: 0.2)
                              ],
                      ),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(8)),
                      boxShadow: [
                        BoxShadow(
                          color: barColor.withValues(alpha: 0.25),
                          blurRadius: 6,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 45, // Fixed height for labels to prevent shifting bars
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Text(item.label,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w500),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        if (item.subLabel != null)
                          Text(item.subLabel!,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 9),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildSourceChart(
      BuildContext context, LanguageProvider lang, int phone, int aa) {
    final total = phone + aa;
    final phonePct = total == 0 ? 0.0 : phone / total;
    final aaPct = total == 0 ? 0.0 : aa / total;
    return _buildGlassContainer(
      child: Column(
        children: [
          Row(
            children: [
              _buildLegendItem(
                  lang.translate('smartphone'),
                  Colors.blueAccent,
                  "${(phonePct * 100).toStringAsFixed(1)}%"),
              const Spacer(),
              _buildLegendItem(
                  lang.translate('android_auto'),
                  Colors.greenAccent,
                  "${(aaPct * 100).toStringAsFixed(1)}%"),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  if (phonePct > 0)
                    Expanded(
                        flex: (phonePct * 1000).toInt(),
                        child: Container(color: Colors.blueAccent)),
                  if (aaPct > 0)
                    Expanded(
                        flex: (aaPct * 1000).toInt(),
                        child: Container(color: Colors.greenAccent)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── HELPERS ────────────────────────────────────────────────────────────
  Widget _buildMiniStatCard(BuildContext context,
      {required String title,
      required String value,
      required IconData icon,
      required Color color}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 36),
              const SizedBox(height: 12),
              Text(value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(title,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).primaryColor.withValues(alpha: 0.8),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color, String pct) {
    return Row(
      children: [
        Container(
            width: 6,
            height: 6,
            decoration:
                BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(color: Colors.white60, fontSize: 11)),
        const SizedBox(width: 4),
        Text(pct,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11)),
      ],
    );
  }

  Widget _buildGlassContainer(
      {required Widget child, EdgeInsetsGeometry? padding}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: padding ?? const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(24),
            border:
                Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class ChartItem {
  final String label;
  final String? subLabel;
  final int value;
  ChartItem({required this.label, this.subLabel, required this.value});
}
