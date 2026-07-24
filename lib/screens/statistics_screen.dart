import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import '../providers/theme_provider.dart';
import 'song_details_screen.dart';


class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> with SingleTickerProviderStateMixin {
  static const List<Color> _sharedChartColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.amber,
    Colors.indigo,
    Colors.cyan,
    Colors.brown,
    Colors.lime,
    Colors.grey,
    Colors.blueGrey,
    Colors.deepOrange,
  ];

  late TabController _tabController;
  String _selectedPeriod = 'last_7_days';
  DateTime? _customStartDate;
  DateTime? _customEndDate;
  bool _groupByDate = true;
  Set<String> _collapsedDays = {};

  final List<String> _periodOptions = [
    'today',
    'yesterday',
    'this_week',
    'last_7_days',
    'last_week',
    'this_month',
    'last_30_days',
    'last_month',
    'last_60_days',
    'last_90_days',
    'custom'
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(langProvider.translate('statistics')),
        backgroundColor: Colors.transparent,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Theme.of(context).primaryColor,
          tabs: [
            Tab(text: langProvider.translate('dynamic_data')),
            Tab(text: langProvider.translate('static_data')),
          ],
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          color: themeProvider.activeBackgroundColor,
        ),
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildDynamicTab(context),
            _buildStaticTab(context),
          ],
        ),
      ),
    );
  }

  Widget _buildStaticTab(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(context);
    return Consumer<RadioProvider>(
      builder: (context, provider, child) {
        final songs = provider.allUniqueSongs;
        
        // Calcoli Statici
        final int totalSongs = songs.length;
        final int totalPlaylists = provider.playlists.length;
        
        final Set<String> artists = {};
        final Set<String> albums = {};
        final Map<String, int> genreCounts = {};
        final Map<String, int> yearCounts = {};
        
        // Build a lookup map for fast access by song ID from all playlist songs
        final Map<String, dynamic> playlistSongById = {};
        for (final playlist in provider.playlists) {
          for (final ps in playlist.songs) {
            playlistSongById.putIfAbsent(ps.id, () => ps);
          }
        }

        for (var song in songs) {
          if (song.artist.isNotEmpty) artists.add(song.artist);
          if (song.album.isNotEmpty) albums.add(song.album);
          
          // --- Point 1: fill missing metadata from playlist sources before aggregating ---
          String? resolvedGenre = song.genre;
          String? resolvedDate = song.releaseDate;

          if ((resolvedGenre == null || resolvedGenre.isEmpty) ||
              (resolvedDate == null || resolvedDate.isEmpty)) {
            // Try to get richer data from playlist song (may have been enriched separately)
            final enriched = playlistSongById[song.id];
            if (enriched != null) {
              if ((resolvedGenre == null || resolvedGenre.isEmpty) &&
                  enriched.genre != null &&
                  enriched.genre!.isNotEmpty) {
                resolvedGenre = enriched.genre;
              }
              if ((resolvedDate == null || resolvedDate.isEmpty) &&
                  enriched.releaseDate != null &&
                  enriched.releaseDate!.isNotEmpty) {
                resolvedDate = enriched.releaseDate;
              }
            }
          }

          final genre = (resolvedGenre != null && resolvedGenre.isNotEmpty)
              ? resolvedGenre
              : langProvider.translate('unknown');
          genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
          
          String yearStr = langProvider.translate('unknown');
          if (resolvedDate != null && resolvedDate.length >= 4) {
            final intYear = int.tryParse(resolvedDate.substring(0, 4));
            if (intYear != null && intYear > 1000) {
              final decade = (intYear ~/ 10) * 10;
              yearStr = decade.toString();
            }
          }
          yearCounts[yearStr] = (yearCounts[yearStr] ?? 0) + 1;
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.5,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              children: [
                _buildStatCard(langProvider.translate('songs'), totalSongs.toString(), Icons.music_note, context),
                _buildStatCard(langProvider.translate('playlists'), totalPlaylists.toString(), Icons.queue_music, context),
                _buildStatCard(langProvider.translate('artists'), artists.length.toString(), Icons.person, context),
                _buildStatCard(langProvider.translate('albums'), albums.length.toString(), Icons.album, context),
              ],
            ),
            const SizedBox(height: 24),
            _buildChartCard(langProvider.translate('genres'), _buildGenreBarChart(genreCounts, context), context, height: null),
            const SizedBox(height: 24),
            _buildChartCard(langProvider.translate('years'), _buildYearBarChart(yearCounts, context), context, height: null),
            const SizedBox(height: 90),
          ],
        );
      },
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).primaryColor, size: 28),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          Text(
            title,
            style: TextStyle(fontSize: 14, color: Colors.white.withOpacity(0.7)),
          ),
        ],
      ),
    );
  }

  Widget _buildChartCard(String title, Widget chart, BuildContext context, {double? height = 200}) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          height != null ? SizedBox(height: height, child: chart) : chart,
        ],
      ),
    );
  }

  Widget _buildPieChart(Map<String, int> data, BuildContext context) {
    if (data.isEmpty) return Center(child: Text(Provider.of<LanguageProvider>(context, listen: false).translate('no_data')));
    
    // Mostra solo i top 15 generi/artisti
    final sortedEntries = data.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final topEntries = sortedEntries.take(15).toList();
    
    // Calcola il totale per calcolare le percentuali
    final double total = topEntries.fold(0.0, (sum, entry) => sum + entry.value);
    
    return Column(
      children: [
        SizedBox(
          height: 220,
          child: PieChart(
            PieChartData(
              sections: topEntries.asMap().entries.map((entry) {
                int idx = entry.key;
                var e = entry.value;
                final percentage = total > 0 ? (e.value / total * 100).toStringAsFixed(1) : '0.0';
                return PieChartSectionData(
                  color: _sharedChartColors[idx % _sharedChartColors.length],
                  value: e.value.toDouble(),
                  title: '$percentage%',
                  radius: 65,
                  titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                );
              }).toList(),
              sectionsSpace: 2,
              centerSpaceRadius: 35,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: topEntries.asMap().entries.map((entry) {
              int idx = entry.key;
              var e = entry.value;
              final percentage = total > 0 ? (e.value / total * 100).toStringAsFixed(1) : '0.0';
              final label = e.key.length > 15 ? '${e.key.substring(0, 15)}…' : e.key;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _sharedChartColors[idx % _sharedChartColors.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$label ($percentage%)',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildGenreBarChart(Map<String, int> data, BuildContext context) {
    if (data.isEmpty) return Center(child: Text(Provider.of<LanguageProvider>(context, listen: false).translate('no_data')));

    // Sort by count descending, take top 15
    final sorted = data.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(15).toList();
    final maxVal = top.first.value.toDouble();

    return Column(
      children: top.asMap().entries.map((entry) {
        final idx = entry.key;
        final e = entry.value;
        final label = e.key.length > 16 ? '${e.key.substring(0, 16)}…' : e.key;
        final fraction = maxVal > 0 ? e.value / maxVal : 0.0;
        final color = _sharedChartColors[idx % _sharedChartColors.length];

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5.0),
          child: Row(
            children: [
              SizedBox(
                width: 50,
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.0, 1.0),
                      child: Container(
                        height: 18,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${e.value}',
                style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildYearBarChart(Map<String, int> data, BuildContext context) {
    if (data.isEmpty) return Center(child: Text(Provider.of<LanguageProvider>(context, listen: false).translate('no_data')));

    // Sort valid decades chronologically
    final validEntries = data.entries
        .where((e) => int.tryParse(e.key) != null)
        .toList()
      ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

    if (validEntries.isEmpty) return Center(child: Text(Provider.of<LanguageProvider>(context, listen: false).translate('no_valid_year')));

    final maxVal = validEntries.map((e) => e.value).reduce((a, b) => a > b ? a : b).toDouble();

    return Column(
      children: validEntries.asMap().entries.map((entry) {
        final idx = entry.key;
        final e = entry.value;
        final fraction = maxVal > 0 ? e.value / maxVal : 0.0;
        final color = _sharedChartColors[idx % _sharedChartColors.length];

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5.0),
          child: Row(
            children: [
              SizedBox(
                width: 50,
                child: Text(
                  '${e.key}s',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.0, 1.0),
                      child: Container(
                        height: 18,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${e.value}',
                style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // --- TAB DINAMICO ---

  Future<DateTimeRange?> _showSolidDateRangePicker({
    DateTimeRange? initialDateRange,
  }) {
    final bgColor = Theme.of(context).cardColor.withValues(alpha: 0.7);
    return showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
      initialDateRange: initialDateRange,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              surface: bgColor,
              onSurface: Colors.white,
            ),
            scaffoldBackgroundColor: bgColor,
            dialogTheme: DialogThemeData(
              backgroundColor: bgColor,
              elevation: 24,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
          ),
          child: child!,
        );
      },
    );
  }

  DateTimeRange _getDateRangeForPeriod() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    switch (_selectedPeriod) {
      case 'today':
        return DateTimeRange(start: today, end: now);
      case 'yesterday':
        final yesterday = today.subtract(const Duration(days: 1));
        return DateTimeRange(start: yesterday, end: today.subtract(const Duration(seconds: 1)));
      case 'this_week':
        final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
        return DateTimeRange(start: startOfWeek, end: now);
      case 'last_7_days':
        return DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now);
      case 'last_week':
        final startOfLastWeek = today.subtract(Duration(days: today.weekday - 1 + 7));
        final endOfLastWeek = startOfLastWeek.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
        return DateTimeRange(start: startOfLastWeek, end: endOfLastWeek);
      case 'this_month':
        final startOfMonth = DateTime(now.year, now.month, 1);
        return DateTimeRange(start: startOfMonth, end: now);
      case 'last_30_days':
        return DateTimeRange(start: now.subtract(const Duration(days: 30)), end: now);
      case 'last_month':
        final startOfLastMonth = DateTime(now.year, now.month - 1, 1);
        final endOfLastMonth = DateTime(now.year, now.month, 0, 23, 59, 59);
        return DateTimeRange(start: startOfLastMonth, end: endOfLastMonth);
      case 'last_60_days':
        return DateTimeRange(start: now.subtract(const Duration(days: 60)), end: now);
      case 'last_90_days':
        return DateTimeRange(start: now.subtract(const Duration(days: 90)), end: now);
      case 'custom':
        if (_customStartDate != null && _customEndDate != null) {
          return DateTimeRange(start: _customStartDate!, end: _customEndDate!.add(const Duration(hours: 23, minutes: 59, seconds: 59)));
        }
        return DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now);
      default:
        return DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now);
    }
  }

  String _getPeriodLabel(String key, LanguageProvider langProvider) {
    Map<String, String> labels = {
      'today': 'Oggi',
      'yesterday': 'Ieri',
      'this_week': 'Settimana corrente',
      'last_7_days': 'Ultimi 7 giorni',
      'last_week': 'Settimana scorsa',
      'this_month': 'Mese corrente',
      'last_30_days': 'Ultimi 30 giorni',
      'last_month': 'Mese scorso',
      'last_60_days': 'Ultimi 60 giorni',
      'last_90_days': 'Ultimi 90 giorni',
      'custom': 'Filtro calendario'
    };
    
    // Prova a tradurre se c'è la chiave, altrimenti usa i default italiani
    String translation = langProvider.translate('period_$key');
    if (translation == 'period_$key') {
      return labels[key] ?? key;
    }
    return translation;
  }

  Widget _buildDynamicTab(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(context);

    return Consumer<RadioProvider>(
      builder: (context, provider, child) {
        final weeklyLog = provider.weeklyPlayLog;
        final metadata = provider.historyMetadata;

        final range = _getDateRangeForPeriod();
        
        // Filtra log per data
        List<dynamic> filteredLog = weeklyLog.where((e) {
          try {
            final ts = DateTime.parse(e['ts']);
            return ts.isAfter(range.start) && ts.isBefore(range.end);
          } catch (_) {
            return false;
          }
        }).toList();

        // ────────────────────────────────────────────────────────────
        // Build a global song-lookup map by ID from ALL sources so that
        // even songs played from Trending (not in any user playlist) are
        // correctly attributed with artist and genre.
        // Priority for each field: allUniqueSongs > promotedTracks > historyMetadata
        // ────────────────────────────────────────────────────────────
        final Map<String, Map<String, String?>> songLookup = {};

        // 1. Seed with historyMetadata (always has title/artist, may lack genre)
        for (final entry in metadata.entries) {
          songLookup[entry.key] = {
            'artist': entry.value.artist.isNotEmpty ? entry.value.artist : null,
            'genre':  (entry.value.genre != null && entry.value.genre!.isNotEmpty) ? entry.value.genre : null,
          };
        }

        // 2. Overlay with allUniqueSongs (official playlists – most enriched)
        for (final s in provider.allUniqueSongs) {
          final existing = songLookup[s.id] ?? {};
          songLookup[s.id] = {
            'artist': (s.artist.isNotEmpty) ? s.artist : existing['artist'],
            'genre':  (s.genre != null && s.genre!.isNotEmpty) ? s.genre : existing['genre'],
          };
        }

        // 3. Overlay with promotedPlaylists predefinedTracks (Trending area)
        for (final tp in provider.promotedPlaylists) {
          final tracks = tp.predefinedTracks;
          if (tracks == null) continue;
          for (final track in tracks) {
            final id    = track['id']?.toString();
            final artist= track['artist']?.toString();
            final genre = track['genre']?.toString();
            if (id == null) continue;
            final existing = songLookup[id] ?? {};
            songLookup[id] = {
              'artist': (artist != null && artist.isNotEmpty) ? artist : existing['artist'],
              'genre':  (genre  != null && genre.isNotEmpty)  ? genre  : existing['genre'],
            };
          }
        }
        // ────────────────────────────────────────────────────────────

        // Calcola andamento giornaliero per il grafico
        Map<String, int> dailyListens = {};
        Map<String, Map<String, int>> dailySongCounts = {};
        Map<String, int> totalSongCounts = {};
        Map<String, int> artistCounts = {};
        Map<String, int> genreCounts = {};
        
        for (var e in filteredLog) {
          try {
            final ts = DateTime.parse(e['ts']);
            final dayKey = DateFormat('MM-dd').format(ts);
            final fullDateKey = DateFormat('yyyy-MM-dd').format(ts);
            dailyListens[dayKey] = (dailyListens[dayKey] ?? 0) + 1;
            
            final id = e['id'] as String;
            
            dailySongCounts.putIfAbsent(fullDateKey, () => {});
            dailySongCounts[fullDateKey]![id] = (dailySongCounts[fullDateKey]![id] ?? 0) + 1;
            totalSongCounts[id] = (totalSongCounts[id] ?? 0) + 1;

            final info = songLookup[id];
            if (info != null) {
              final artist = info['artist'];
              if (artist != null && artist.isNotEmpty) {
                artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
              }
              final genre = info['genre'] ?? langProvider.translate('unknown');
              genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
            }
          } catch (_) {}
        }


        // Top canzoni
        final sortedDays = dailySongCounts.keys.toList()..sort((a, b) => b.compareTo(a));

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Dropdown filtro
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedPeriod,
                        isExpanded: true,
                        dropdownColor: Theme.of(context).cardColor.withValues(alpha: 0.7),
                        items: _periodOptions.map((period) {
                          return DropdownMenuItem(
                            value: period,
                            child: Text(_getPeriodLabel(period, langProvider)),
                          );
                        }).toList(),
                        onChanged: (val) async {
                          if (val == 'custom') {
                            final picked = await _showSolidDateRangePicker();
                            if (picked != null) {
                              setState(() {
                                _selectedPeriod = val!;
                                _customStartDate = picked.start;
                                _customEndDate = picked.end;
                              });
                            }
                          } else if (val != null) {
                            setState(() {
                              _selectedPeriod = val;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  if (_selectedPeriod == 'custom')
                    IconButton(
                      icon: const Icon(Icons.edit_calendar),
                      onPressed: () async {
                        final picked = await _showSolidDateRangePicker(
                          initialDateRange: _customStartDate != null
                              ? DateTimeRange(start: _customStartDate!, end: _customEndDate!)
                              : null,
                        );
                        if (picked != null) {
                          setState(() {
                            _customStartDate = picked.start;
                            _customEndDate = picked.end;
                          });
                        }
                      },
                    )
                ],
              ),
            ),
            const SizedBox(height: 24),
            
            // Grafico Lineare degli ascolti
            _buildChartCard('${langProvider.translate('listening_trend')} (${filteredLog.length})', _buildLineChart(dailyListens, context), context),
            
            const SizedBox(height: 24),

            // Grafico artisti più ascoltati
            _buildChartCard(langProvider.translate('top_artists'), _buildPieChart(artistCounts, context), context, height: null),
            
            const SizedBox(height: 24),

            // Grafico generi più ascoltati
            _buildChartCard(langProvider.translate('top_genres'), _buildPieChart(genreCounts, context), context, height: null),
            
            const SizedBox(height: 24),
            
            // Lista top canzoni (Trending style)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  langProvider.translate('top_songs'),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    if (_groupByDate)
                      IconButton(
                        icon: Icon(_collapsedDays.length == sortedDays.length && sortedDays.isNotEmpty ? Icons.unfold_more : Icons.unfold_less),
                        tooltip: _collapsedDays.length == sortedDays.length && sortedDays.isNotEmpty ? 'Espandi tutti' : 'Comprimi tutti',
                        onPressed: () {
                          setState(() {
                            if (_collapsedDays.length == sortedDays.length && sortedDays.isNotEmpty) {
                              _collapsedDays.clear();
                            } else {
                              _collapsedDays.addAll(sortedDays);
                            }
                          });
                        },
                      ),
                    Text(
                      langProvider.translate('group_by_date'),
                      style: const TextStyle(fontSize: 14),
                    ),
                    Switch(
                      value: _groupByDate,
                      onChanged: (val) {
                        setState(() {
                          _groupByDate = val;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            
            if (sortedDays.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Text(langProvider.translate('no_listens_period'), style: const TextStyle(color: Colors.white54)),
                ),
              ),
              
            if (_groupByDate)
              ...sortedDays.expand((day) {
                final parsedDate = DateTime.parse(day);
                final displayDate = DateFormat('dd/MM/yyyy').format(parsedDate);
                final sortedSongsForDay = dailySongCounts[day]!.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value));
                  
                List<Widget> widgets = [];
                final isCollapsed = _collapsedDays.contains(day);
                
                widgets.add(
                  Padding(
                    padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          if (isCollapsed) {
                            _collapsedDays.remove(day);
                          } else {
                            _collapsedDays.add(day);
                          }
                        });
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Theme.of(context).primaryColor.withOpacity(0.3)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              displayDate,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                            Icon(
                              isCollapsed ? Icons.expand_more : Icons.expand_less,
                              color: Theme.of(context).primaryColor,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
                
                if (!isCollapsed) {
                  for (var entry in sortedSongsForDay) {
                    final songId = entry.key;
                    final count = entry.value;
                    final song = metadata[songId];
                    
                    if (song == null) continue;
                    
                    widgets.add(_buildSongTile(song, count, provider, langProvider, context));
                  }
                }
                return widgets;
              })
            else
              Builder(
                builder: (context) {
                  final sortedAllSongs = totalSongCounts.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value));
                  return Column(
                    children: sortedAllSongs.map((entry) {
                      final songId = entry.key;
                      final count = entry.value;
                      final song = metadata[songId];
                      if (song == null) return const SizedBox.shrink();
                      return _buildSongTile(song, count, provider, langProvider, context);
                    }).toList(),
                  );
                }
              ),
            
            
            const SizedBox(height: 90),
          ],
        );
      },
    );
  }

  Widget _buildLineChart(Map<String, int> dailyListens, BuildContext context) {
    if (dailyListens.isEmpty) return Center(child: Text(Provider.of<LanguageProvider>(context, listen: false).translate('no_time_data')));

    final sortedKeys = dailyListens.keys.toList()..sort();
    
    List<FlSpot> spots = [];
    double maxX = (sortedKeys.length - 1).toDouble();
    if (maxX < 1) maxX = 1;
    
    double maxY = 0;

    for (int i = 0; i < sortedKeys.length; i++) {
      double y = dailyListens[sortedKeys[i]]!.toDouble();
      if (y > maxY) maxY = y;
      spots.add(FlSpot(i.toDouble(), y));
    }
    
    if (maxY == 0) maxY = 10;
    else maxY = maxY * 1.5;

    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= 0 && value.toInt() < sortedKeys.length) {
                  // Mostra meno label se ci sono molti giorni
                  if (sortedKeys.length > 10 && value.toInt() % (sortedKeys.length ~/ 5) != 0) {
                    return const SizedBox();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      sortedKeys[value.toInt()],
                      style: const TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                  );
                }
                return const SizedBox();
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                if (value == value.toInt().toDouble()) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: Text(
                      value.toInt().toString(),
                      style: const TextStyle(color: Colors.white54, fontSize: 10),
                      textAlign: TextAlign.right,
                    ),
                  );
                }
                return const SizedBox();
              },
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minX: 0,
        maxX: maxX,
        minY: 0,
        maxY: maxY,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Theme.of(context).primaryColor,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: Theme.of(context).primaryColor.withOpacity(0.2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongTile(dynamic song, int count, RadioProvider provider, LanguageProvider langProvider, BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: song.artUri != null && song.artUri!.isNotEmpty
            ? Image.network(song.artUri!, width: 50, height: 50, fit: BoxFit.cover)
            : Container(width: 50, height: 50, color: Colors.white10, child: const Icon(Icons.music_note)),
      ),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
      trailing: Text(langProvider.translate('listens_count').replaceAll('{0}', count.toString()), style: TextStyle(color: Theme.of(context).primaryColor, fontWeight: FontWeight.bold)),
      onTap: () {
        // Mostra un bottom sheet di anteprima, lasciando all'utente la scelta
        showModalBottomSheet(
          context: context,
          backgroundColor:Theme.of(context).cardColor.withValues(alpha: 0.7),
          builder: (sheetCtx) {
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle bar
                  Container(
                    width: 40, height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Cover + info
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: song.artUri != null && song.artUri!.isNotEmpty
                            ? Image.network(song.artUri!, width: 80, height: 80, fit: BoxFit.cover)
                            : Container(width: 80, height: 80, color: Colors.white10, child: const Icon(Icons.music_note, size: 36)),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(song.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold), maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Text(song.artist, style: const TextStyle(color: Colors.white54, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(Icons.headphones, size: 14, color: Theme.of(context).primaryColor),
                                const SizedBox(width: 4),
                                Text(langProvider.translate('listens_count').replaceAll('{0}', count.toString()), style: TextStyle(color: Theme.of(context).primaryColor, fontSize: 13, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  // Pulsante Ascolta
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.play_circle_fill, size: 22),
                      label: Text(langProvider.translate('listen_now'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () async {
                        Navigator.pop(sheetCtx); // chiudi il bottom sheet

                        // Trova la playlist che contiene questo brano
                        String? playlistId;
                        for (final playlist in provider.playlists) {
                          if (playlist.songs.any((s) => s.id == song.id)) {
                            playlistId = playlist.id;
                            break;
                          }
                        }
                        final songToPlay = playlistId != null
                            ? provider.playlists
                                .firstWhere((p) => p.id == playlistId)
                                .songs
                                .firstWhere((s) => s.id == song.id, orElse: () => song)
                            : song;

                        await provider.playPlaylistSong(songToPlay, playlistId);

                        if (context.mounted) {
                          Navigator.of(context).push(
                            PageRouteBuilder(
                              pageBuilder: (context, animation, secondaryAnimation) =>
                                  const SongDetailsScreen(),
                              transitionsBuilder:
                                  (context, animation, secondaryAnimation, child) {
                                const begin = Offset(0.0, 1.0);
                                const end = Offset.zero;
                                const curve = Curves.easeOutQuart;
                                return SlideTransition(
                                  position: animation
                                      .drive(Tween(begin: begin, end: end)
                                          .chain(CurveTween(curve: curve))),
                                  child: child,
                                );
                              },
                            ),
                          );
                        }
                      },
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
}
