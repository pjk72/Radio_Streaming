import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import '../providers/theme_provider.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import 'song_details_screen.dart';
import '../utils/glass_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final Set<String> _collapsedDays = {};

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

  final ScrollController _dynamicScrollController = ScrollController();
  final GlobalKey _topSongsSectionKey = GlobalKey();
  bool _showScrollToTop = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _dynamicScrollController.addListener(_onScroll);
    _loadPreferences();
  }

  double _topSongsOffset = 0.0;

  void _measureTopSongsOffset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _topSongsSectionKey.currentContext;
      if (ctx != null && _dynamicScrollController.hasClients) {
        try {
          final renderBox = ctx.findRenderObject() as RenderBox?;
          final scrollableBox = _dynamicScrollController.position.context.notificationContext?.findRenderObject() as RenderBox?;
          if (renderBox != null && renderBox.hasSize && scrollableBox != null) {
            final targetInScrollable = renderBox.localToGlobal(Offset.zero, ancestor: scrollableBox);
            final calculatedOffset = _dynamicScrollController.offset + targetInScrollable.dy - 12.0;
            if (calculatedOffset > 100) {
              _topSongsOffset = calculatedOffset;
            }
          }
        } catch (_) {}
      }
    });
  }

  void _onScroll() {
    if (_dynamicScrollController.hasClients) {
      final threshold = _topSongsOffset > 0 ? _topSongsOffset : 900.0;
      final shouldShow = _dynamicScrollController.offset > (threshold + 60.0);
      if (shouldShow != _showScrollToTop) {
        setState(() {
          _showScrollToTop = shouldShow;
        });
      }
    }
  }

  void _scrollToSongsListStart() {
    if (_dynamicScrollController.hasClients) {
      final target = _topSongsOffset > 0 ? _topSongsOffset : 900.0;
      _dynamicScrollController.animateTo(
        target.clamp(0.0, _dynamicScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final period = prefs.getString('statistics_selected_period');
      if (period != null && _periodOptions.contains(period)) {
        setState(() {
          _selectedPeriod = period;
          if (period == 'custom') {
            final start = prefs.getString('statistics_custom_start');
            final end = prefs.getString('statistics_custom_end');
            if (start != null && end != null) {
              _customStartDate = DateTime.tryParse(start);
              _customEndDate = DateTime.tryParse(end);
            } else {
              _selectedPeriod = 'last_7_days';
            }
          }
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _dynamicScrollController.removeListener(_onScroll);
    _dynamicScrollController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: (_showScrollToTop && _tabController.index == 0)
          ? FloatingActionButton.small(
              heroTag: 'stats_scroll_to_top',
              onPressed: _scrollToSongsListStart,
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              elevation: 4,
              tooltip: langProvider.translate('scroll_to_top'),
              child: const Icon(Icons.arrow_upward_rounded),
            )
          : null,
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
                _buildStatCard(
                  langProvider.translate('songs'),
                  totalSongs.toString(),
                  Icons.music_note,
                  context,
                  onTap: () {
                    _showTemporaryPlaylistSheet(
                      context: context,
                      title: '${langProvider.translate('songs')} (${langProvider.translate('library')})',
                      subtitle: '$totalSongs ${langProvider.translate('songs').toLowerCase()}',
                      songs: songs,
                      provider: provider,
                      langProvider: langProvider,
                    );
                  },
                ),
                _buildStatCard(
                  langProvider.translate('playlists'),
                  totalPlaylists.toString(),
                  Icons.queue_music,
                  context,
                ),
                _buildStatCard(
                  langProvider.translate('artists'),
                  artists.length.toString(),
                  Icons.person,
                  context,
                  onTap: () {
                    final sortedByArtist = List<SavedSong>.from(songs)
                      ..sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
                    _showTemporaryPlaylistSheet(
                      context: context,
                      title: langProvider.translate('artists'),
                      subtitle: '${artists.length} ${langProvider.translate('artists').toLowerCase()} • $totalSongs ${langProvider.translate('songs').toLowerCase()}',
                      songs: sortedByArtist,
                      provider: provider,
                      langProvider: langProvider,
                    );
                  },
                ),
                _buildStatCard(
                  langProvider.translate('albums'),
                  albums.length.toString(),
                  Icons.album,
                  context,
                  onTap: () {
                    final sortedByAlbum = List<SavedSong>.from(songs)
                      ..sort((a, b) => a.album.toLowerCase().compareTo(b.album.toLowerCase()));
                    _showTemporaryPlaylistSheet(
                      context: context,
                      title: langProvider.translate('albums'),
                      subtitle: '${albums.length} ${langProvider.translate('albums').toLowerCase()} • $totalSongs ${langProvider.translate('songs').toLowerCase()}',
                      songs: sortedByAlbum,
                      provider: provider,
                      langProvider: langProvider,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildChartCard(
              langProvider.translate('genres'),
              _buildGenreBarChart(
                genreCounts,
                context,
                onSectionTap: (genreKey) {
                  final matchingSongs = songs.where((s) {
                    String? resolvedGenre = s.genre;
                    if (resolvedGenre == null || resolvedGenre.isEmpty) {
                      resolvedGenre = playlistSongById[s.id]?.genre;
                    }
                    final genre = (resolvedGenre != null && resolvedGenre.isNotEmpty)
                        ? resolvedGenre
                        : langProvider.translate('unknown');
                    return genre.toLowerCase() == genreKey.toLowerCase();
                  }).toList();

                  _showTemporaryPlaylistSheet(
                    context: context,
                    title: genreKey,
                    subtitle: '${matchingSongs.length} ${langProvider.translate('songs').toLowerCase()} • ${langProvider.translate('genres')}',
                    songs: matchingSongs,
                    provider: provider,
                    langProvider: langProvider,
                  );
                },
              ),
              context,
              height: null,
            ),
            const SizedBox(height: 24),
            _buildChartCard(
              langProvider.translate('years'),
              _buildYearBarChart(
                yearCounts,
                context,
                onSectionTap: (decadeKey) {
                  final matchingSongs = songs.where((s) {
                    String? resolvedDate = s.releaseDate;
                    if (resolvedDate == null || resolvedDate.isEmpty) {
                      resolvedDate = playlistSongById[s.id]?.releaseDate;
                    }
                    String yearStr = langProvider.translate('unknown');
                    if (resolvedDate != null && resolvedDate.length >= 4) {
                      final intYear = int.tryParse(resolvedDate.substring(0, 4));
                      if (intYear != null && intYear > 1000) {
                        final decade = (intYear ~/ 10) * 10;
                        yearStr = decade.toString();
                      }
                    }
                    return yearStr == decadeKey;
                  }).toList();

                  _showTemporaryPlaylistSheet(
                    context: context,
                    title: '${decadeKey}s',
                    subtitle: '${matchingSongs.length} ${langProvider.translate('songs').toLowerCase()} • ${langProvider.translate('years')}',
                    songs: matchingSongs,
                    provider: provider,
                    langProvider: langProvider,
                  );
                },
              ),
              context,
              height: null,
            ),
            const SizedBox(height: 90),
          ],
        );
      },
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    BuildContext context, {
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(icon, color: Theme.of(context).primaryColor, size: 28),
                  if (onTap != null)
                    Icon(
                      Icons.play_circle_outline_rounded,
                      size: 18,
                      color: Theme.of(context).primaryColor.withValues(alpha: 0.8),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                value,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              Text(
                title,
                style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChartCard(
    String title,
    Widget chart,
    BuildContext context, {
    double? height = 200,
  }) {
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.touch_app_rounded,
                    size: 14,
                    color: Theme.of(context).primaryColor.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    Provider.of<LanguageProvider>(context, listen: false).translate('tap_to_play_hint'),
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).primaryColor.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          height != null ? SizedBox(height: height, child: chart) : chart,
        ],
      ),
    );
  }

  Widget _buildPieChart(
    Map<String, int> data,
    BuildContext context, {
    void Function(String key)? onSectionTap,
  }) {
    if (data.isEmpty) {
      return Center(
        child: Text(
          Provider.of<LanguageProvider>(context, listen: false).translate('no_data'),
        ),
      );
    }

    // Mostra solo i top 15 generi/artisti
    final sortedEntries = data.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topEntries = sortedEntries.take(15).toList();

    // Calcola il totale per calcolare le percentuali
    final double total = topEntries.fold(0.0, (sum, entry) => sum + entry.value);

    return Column(
      children: [
        SizedBox(
          height: 220,
          child: PieChart(
            PieChartData(
              pieTouchData: PieTouchData(
                touchCallback: (FlTouchEvent event, pieTouchResponse) {
                  if (event is FlTapUpEvent &&
                      pieTouchResponse != null &&
                      pieTouchResponse.touchedSection != null) {
                    final touchedIndex =
                        pieTouchResponse.touchedSection!.touchedSectionIndex;
                    if (touchedIndex >= 0 && touchedIndex < topEntries.length) {
                      final key = topEntries[touchedIndex].key;
                      onSectionTap?.call(key);
                    }
                  }
                },
              ),
              sections: topEntries.asMap().entries.map((entry) {
                int idx = entry.key;
                var e = entry.value;
                final percentage = total > 0
                    ? (e.value / total * 100).toStringAsFixed(1)
                    : '0.0';
                return PieChartSectionData(
                  color: _sharedChartColors[idx % _sharedChartColors.length],
                  value: e.value.toDouble(),
                  title: '$percentage%',
                  radius: 65,
                  titleStyle: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
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
            spacing: 8,
            runSpacing: 8,
            children: topEntries.asMap().entries.map((entry) {
              int idx = entry.key;
              var e = entry.value;
              final percentage = total > 0
                  ? (e.value / total * 100).toStringAsFixed(1)
                  : '0.0';
              final label =
                  e.key.length > 15 ? '${e.key.substring(0, 15)}…' : e.key;
              final sectionColor =
                  _sharedChartColors[idx % _sharedChartColors.length];

              return Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onSectionTap != null ? () => onSectionTap(e.key) : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: sectionColor.withValues(alpha: 0.4),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: sectionColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$label ($percentage%)',
                          style: const TextStyle(fontSize: 11, color: Colors.white70),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.play_circle_outline_rounded,
                          size: 13,
                          color: sectionColor,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildGenreBarChart(
    Map<String, int> data,
    BuildContext context, {
    void Function(String key)? onSectionTap,
  }) {
    if (data.isEmpty) {
      return Center(
        child: Text(
          Provider.of<LanguageProvider>(context, listen: false).translate('no_data'),
        ),
      );
    }

    // Sort by count descending, take top 15
    final sorted = data.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(15).toList();
    final maxVal = top.first.value.toDouble();

    return Column(
      children: top.asMap().entries.map((entry) {
        final idx = entry.key;
        final e = entry.value;
        final label = e.key.length > 16 ? '${e.key.substring(0, 16)}…' : e.key;
        final fraction = maxVal > 0 ? e.value / maxVal : 0.0;
        final color = _sharedChartColors[idx % _sharedChartColors.length];

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onSectionTap != null ? () => onSectionTap(e.key) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5.0, horizontal: 4.0),
              child: Row(
                children: [
                  SizedBox(
                    width: 65,
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
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.play_circle_outline_rounded,
                    size: 14,
                    color: color.withValues(alpha: 0.8),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildYearBarChart(
    Map<String, int> data,
    BuildContext context, {
    void Function(String key)? onSectionTap,
  }) {
    if (data.isEmpty) {
      return Center(
        child: Text(
          Provider.of<LanguageProvider>(context, listen: false).translate('no_data'),
        ),
      );
    }

    // Sort valid decades chronologically
    final validEntries = data.entries
        .where((e) => int.tryParse(e.key) != null)
        .toList()
      ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

    if (validEntries.isEmpty) {
      return Center(
        child: Text(
          Provider.of<LanguageProvider>(context, listen: false)
              .translate('no_valid_year'),
        ),
      );
    }

    final maxVal = validEntries
        .map((e) => e.value)
        .reduce((a, b) => a > b ? a : b)
        .toDouble();

    return Column(
      children: validEntries.asMap().entries.map((entry) {
        final idx = entry.key;
        final e = entry.value;
        final fraction = maxVal > 0 ? e.value / maxVal : 0.0;
        final color = _sharedChartColors[idx % _sharedChartColors.length];

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onSectionTap != null ? () => onSectionTap(e.key) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5.0, horizontal: 4.0),
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
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.play_circle_outline_rounded,
                    size: 14,
                    color: color.withValues(alpha: 0.8),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  void _showSaveToPlaylistDialog({
    required BuildContext context,
    required List<SavedSong> songs,
    required RadioProvider provider,
    required String sourceName,
  }) {
    GlassUtils.showGlassDialog(
      context: context,
      builder: (dialogCtx) {
        final lang = Provider.of<LanguageProvider>(context, listen: false);
        final playlists = provider.playlists.toList();

        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(
            lang.translate('add_to_playlist'),
            style: TextStyle(
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    "${lang.translate('copy_songs_to')} $sourceName (${songs.length} ${lang.translate('songs').toLowerCase()})",
                    style: TextStyle(
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: playlists.length + 1,
                    itemBuilder: (ctx, index) {
                      if (index == 0) {
                        return Material(
                          color: Colors.black.withValues(alpha: 0.001),
                          child: ListTile(
                            leading: const Icon(
                              Icons.add,
                              color: Colors.blueAccent,
                            ),
                            title: Text(
                              lang.translate('create_new_playlist'),
                              style: const TextStyle(color: Colors.blueAccent),
                            ),
                            onTap: () async {
                              Navigator.pop(dialogCtx);
                              _showCreatePlaylistFromStats(
                                context: context,
                                provider: provider,
                                songs: songs,
                                sourceName: sourceName,
                              );
                            },
                          ),
                        );
                      }
                      final p = playlists[index - 1];
                      return Material(
                        color: Colors.black.withValues(alpha: 0.001),
                        child: ListTile(
                          leading: Icon(
                            Icons.queue_music_rounded,
                            color: Theme.of(context).primaryColor,
                            size: 20,
                          ),
                          title: Text(
                            p.name,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color,
                            ),
                          ),
                          onTap: () async {
                            Navigator.pop(dialogCtx);
                            await provider.addSongsToPlaylist(p.id, songs);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    lang
                                        .translate('copied_songs_to')
                                        .replaceAll('{0}', p.name),
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(lang.translate('cancel')),
            ),
          ],
        );
      },
    );
  }

  void _showCreatePlaylistFromStats({
    required BuildContext context,
    required RadioProvider provider,
    required List<SavedSong> songs,
    required String sourceName,
  }) {
    final TextEditingController nameController = TextEditingController();
    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) {
        final lang = Provider.of<LanguageProvider>(context, listen: false);
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(
            lang.translate('new_playlist'),
            style: TextStyle(
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          content: TextField(
            controller: nameController,
            autofocus: true,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodyLarge?.color,
            ),
            decoration: InputDecoration(
              labelText: lang.translate('playlist_name'),
              labelStyle: TextStyle(
                color: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.color
                    ?.withValues(alpha: 0.7),
              ),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: Theme.of(context).dividerColor,
                ),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: Theme.of(context).primaryColor,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(lang.translate('cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final playlistName = nameController.text.trim();
                if (playlistName.isNotEmpty) {
                  Navigator.pop(ctx);
                  final newPlaylist = await provider.createPlaylist(
                    playlistName,
                    songs: List<SavedSong>.from(songs),
                  );
                  provider.resolvePlaylistLinksInBackground(
                    newPlaylist.id,
                    songs,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          lang
                              .translate('copied_songs_to')
                              .replaceAll('{0}', playlistName),
                        ),
                      ),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: Text(
                lang.translate('create'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showTemporaryPlaylistSheet({
    required BuildContext context,
    required String title,
    required String subtitle,
    required List<SavedSong> songs,
    required RadioProvider provider,
    required LanguageProvider langProvider,
  }) {
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(langProvider.translate('no_data')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final isDark = themeProvider.isDarkMode;
    final primaryColor = themeProvider.activePrimaryColor;
    final surfaceColor = themeProvider.activeSurfaceColor;

    final cleanedSongs = songs
        .map((s) => s.copyWith(title: _cleanDisplayTitle(s.title)))
        .toList();

    final tempPlaylist = Playlist(
      id: 'temp_stats_${DateTime.now().millisecondsSinceEpoch}',
      name: title,
      songs: cleanedSongs,
      createdAt: DateTime.now(),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          decoration: BoxDecoration(
            color: isDark ? surfaceColor : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 12),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black26,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.playlist_play_rounded,
                        color: primaryColor,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: isDark ? Colors.white60 : Colors.black54,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(sheetCtx),
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ],
                ),
              ),

              // Action button bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.play_circle_fill_rounded, size: 20),
                        label: Text(
                          langProvider.translate('play_all'),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: () async {
                          Navigator.pop(sheetCtx);
                          await provider.playAdHocPlaylist(tempPlaylist, null);
                          if (context.mounted) {
                            Navigator.of(context).push(
                              PageRouteBuilder(
                                pageBuilder: (context, animation, secondaryAnimation) =>
                                    const SongDetailsScreen(),
                                transitionsBuilder: (context, animation, secondaryAnimation, child) {
                                  const begin = Offset(0.0, 1.0);
                                  const end = Offset.zero;
                                  const curve = Curves.easeOutQuart;
                                  return SlideTransition(
                                    position: animation.drive(
                                      Tween(begin: begin, end: end).chain(CurveTween(curve: curve)),
                                    ),
                                    child: child,
                                  );
                                },
                              ),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.playlist_add_rounded, color: primaryColor, size: 24),
                        tooltip: langProvider.translate('add_to_playlist'),
                        onPressed: () {
                          Navigator.pop(sheetCtx);
                          _showSaveToPlaylistDialog(
                            context: context,
                            songs: cleanedSongs,
                            provider: provider,
                            sourceName: title,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(height: 16),

              // Songs List
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    final displayTitle = _cleanDisplayTitle(song.title);

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6.0),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () async {
                            Navigator.pop(sheetCtx);
                            await provider.playAdHocPlaylist(tempPlaylist, song.id);
                            if (context.mounted) {
                              Navigator.of(context).push(
                                PageRouteBuilder(
                                  pageBuilder: (context, animation, secondaryAnimation) =>
                                      const SongDetailsScreen(),
                                  transitionsBuilder: (context, animation, secondaryAnimation, child) {
                                    const begin = Offset(0.0, 1.0);
                                    const end = Offset.zero;
                                    const curve = Curves.easeOutQuart;
                                    return SlideTransition(
                                      position: animation.drive(
                                        Tween(begin: begin, end: end).chain(CurveTween(curve: curve)),
                                      ),
                                      child: child,
                                    );
                                  },
                                ),
                              );
                            }
                          },
                            child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: song.artUri != null && song.artUri!.isNotEmpty
                                      ? CachedNetworkImage(
                                          imageUrl: song.artUri!,
                                          width: 44,
                                          height: 44,
                                          fit: BoxFit.cover,
                                          memCacheWidth: 130,
                                          memCacheHeight: 130,
                                          placeholder: (c, u) => Container(
                                            width: 44,
                                            height: 44,
                                            color: Colors.white10,
                                            child: const Icon(Icons.music_note, size: 18, color: Colors.white38),
                                          ),
                                          errorWidget: (c, u, e) => Container(
                                            width: 44,
                                            height: 44,
                                            color: Colors.white10,
                                            child: const Icon(Icons.music_note, size: 18, color: Colors.white38),
                                          ),
                                        )
                                      : Container(
                                          width: 44,
                                          height: 44,
                                          color: Colors.white10,
                                          child: const Icon(Icons.music_note, size: 18, color: Colors.white38),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        displayTitle,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: isDark ? Colors.white : Colors.black87,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        song.artist,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark ? Colors.white60 : Colors.black54,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.play_circle_outline_rounded,
                                  color: primaryColor,
                                  size: 24,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
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
            'releaseDate': (entry.value.releaseDate != null && entry.value.releaseDate!.isNotEmpty) ? entry.value.releaseDate : null,
          };
        }

        // 2. Overlay with allUniqueSongs (official playlists – most enriched)
        for (final s in provider.allUniqueSongs) {
          final existing = songLookup[s.id] ?? {};
          songLookup[s.id] = {
            'artist': (s.artist.isNotEmpty) ? s.artist : existing['artist'],
            'genre':  (s.genre != null && s.genre!.isNotEmpty) ? s.genre : existing['genre'],
            'releaseDate': (s.releaseDate != null && s.releaseDate!.isNotEmpty) ? s.releaseDate : existing['releaseDate'],
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
            final releaseDate = track['releaseDate']?.toString();
            if (id == null) continue;
            final existing = songLookup[id] ?? {};
            songLookup[id] = {
              'artist': (artist != null && artist.isNotEmpty) ? artist : existing['artist'],
              'genre':  (genre  != null && genre.isNotEmpty)  ? genre  : existing['genre'],
              'releaseDate': (releaseDate != null && releaseDate.isNotEmpty) ? releaseDate : existing['releaseDate'],
            };
          }
        }
        // ────────────────────────────────────────────────────────────

        // Calcola andamento giornaliero per il grafico
        Map<String, int> dailyListens = {};
        Map<String, Map<String, int>> dailySongCounts = {};
        Map<String, Map<String, DateTime>> dailyLatestSongPlayTime = {};
        Map<String, int> totalSongCounts = {};
        Map<String, DateTime> latestSongPlayTime = {};
        Map<String, int> artistCounts = {};
        Map<String, int> genreCounts = {};
        Map<String, int> yearCounts = {};
        
        for (var e in filteredLog) {
          try {
            final ts = DateTime.parse(e['ts']);
            final dayKey = DateFormat('MM-dd').format(ts);
            final fullDateKey = DateFormat('yyyy-MM-dd').format(ts);
            dailyListens[dayKey] = (dailyListens[dayKey] ?? 0) + 1;
            
            final id = e['id'] as String;
            
            dailySongCounts.putIfAbsent(fullDateKey, () => {});
            dailySongCounts[fullDateKey]![id] = (dailySongCounts[fullDateKey]![id] ?? 0) + 1;
            
            dailyLatestSongPlayTime.putIfAbsent(fullDateKey, () => {});
            if (!dailyLatestSongPlayTime[fullDateKey]!.containsKey(id) ||
                ts.isAfter(dailyLatestSongPlayTime[fullDateKey]![id]!)) {
              dailyLatestSongPlayTime[fullDateKey]![id] = ts;
            }

            totalSongCounts[id] = (totalSongCounts[id] ?? 0) + 1;
            if (!latestSongPlayTime.containsKey(id) ||
                ts.isAfter(latestSongPlayTime[id]!)) {
              latestSongPlayTime[id] = ts;
            }

            final info = songLookup[id];
            if (info != null) {
              final artist = info['artist'];
              if (artist != null && artist.isNotEmpty) {
                artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
              }
              final genre = info['genre'] ?? langProvider.translate('unknown');
              genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
              
              final resolvedDate = info['releaseDate'];
              String yearStr = langProvider.translate('unknown');
              if (resolvedDate != null && resolvedDate.length >= 4) {
                final intYear = int.tryParse(resolvedDate.substring(0, 4));
                if (intYear != null && intYear > 1000) {
                  final decade = (intYear ~/ 10) * 10;
                  yearStr = '${decade}s';
                }
              }
              yearCounts[yearStr] = (yearCounts[yearStr] ?? 0) + 1;
            }
          } catch (_) {}
        }
        // Helper to extract unique matching SavedSong objects from filteredLog
        List<SavedSong> getMatchingHistorySongs(
          bool Function(String id, Map<String, String?> info, dynamic logEntry) filter,
        ) {
          final Map<String, SavedSong> matched = {};
          for (var e in filteredLog) {
            try {
              final id = e['id'] as String;
              final info = songLookup[id] ?? {};
              if (filter(id, info, e)) {
                if (!matched.containsKey(id)) {
                  SavedSong? song;
                  final inLib = provider.allUniqueSongs.where((s) => s.id == id);
                  if (inLib.isNotEmpty) {
                    song = inLib.first;
                  } else if (metadata.containsKey(id)) {
                    song = metadata[id];
                  } else {
                    song = SavedSong(
                      id: id,
                      title: e['title']?.toString() ?? 'Track',
                      artist: info['artist'] ?? '',
                      album: '',
                      genre: info['genre'],
                      releaseDate: info['releaseDate'],
                      dateAdded: DateTime.now(),
                    );
                  }
                  if (song != null) {
                    matched[id] = song;
                  }
                }
              }
            } catch (_) {}
          }
          return matched.values.toList();
        }

        // Top canzoni
        final sortedDays = dailySongCounts.keys.toList()..sort((a, b) => b.compareTo(a));

        _measureTopSongsOffset();

        return ListView(
          controller: _dynamicScrollController,
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
                            child: Text(
                              period == 'custom' && _customStartDate != null && _customEndDate != null
                                  ? '${_getPeriodLabel(period, langProvider)} (${DateFormat('dd/MM/yy').format(_customStartDate!)} - ${DateFormat('dd/MM/yy').format(_customEndDate!)})'
                                  : _getPeriodLabel(period, langProvider),
                            ),
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
                              try {
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setString('statistics_selected_period', val!);
                                await prefs.setString('statistics_custom_start', picked.start.toIso8601String());
                                await prefs.setString('statistics_custom_end', picked.end.toIso8601String());
                              } catch (_) {}
                            }
                          } else if (val != null) {
                            setState(() {
                              _selectedPeriod = val;
                            });
                            try {
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.setString('statistics_selected_period', val);
                            } catch (_) {}
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
                          try {
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setString('statistics_custom_start', picked.start.toIso8601String());
                            await prefs.setString('statistics_custom_end', picked.end.toIso8601String());
                          } catch (_) {}
                        }
                      },
                    )
                ],
              ),
            ),
            const SizedBox(height: 24),
            
            // Grafico Lineare degli ascolti
            _buildChartCard(
              '${langProvider.translate('listening_trend')} (${filteredLog.length})',
              _buildLineChart(
                dailyListens,
                context,
                onDayTap: (dayKey) {
                  final matchingSongs = getMatchingHistorySongs((id, info, e) {
                    try {
                      final ts = DateTime.parse(e['ts']);
                      return DateFormat('MM-dd').format(ts) == dayKey;
                    } catch (_) {
                      return false;
                    }
                  });
                  _showTemporaryPlaylistSheet(
                    context: context,
                    title: '${langProvider.translate('listening_trend')}: $dayKey',
                    subtitle: '${matchingSongs.length} ${langProvider.translate('songs').toLowerCase()}',
                    songs: matchingSongs,
                    provider: provider,
                    langProvider: langProvider,
                  );
                },
              ),
              context,
            ),
            
            const SizedBox(height: 24),

            // Grafico artisti più ascoltati
            _buildChartCard(
              langProvider.translate('top_artists'),
              _buildPieChart(
                artistCounts,
                context,
                onSectionTap: (artistKey) {
                  final matchingSongs = getMatchingHistorySongs((id, info, e) {
                    final artist = info['artist'] ?? '';
                    return artist.toLowerCase() == artistKey.toLowerCase();
                  });
                  _showTemporaryPlaylistSheet(
                    context: context,
                    title: artistKey,
                    subtitle: '${matchingSongs.length} ${langProvider.translate('songs').toLowerCase()} • ${langProvider.translate('top_artists')}',
                    songs: matchingSongs,
                    provider: provider,
                    langProvider: langProvider,
                  );
                },
              ),
              context,
              height: null,
            ),
            
            const SizedBox(height: 24),

            // Grafico generi più ascoltati
            _buildChartCard(
              langProvider.translate('top_genres'),
              _buildPieChart(
                genreCounts,
                context,
                onSectionTap: (genreKey) {
                  final matchingSongs = getMatchingHistorySongs((id, info, e) {
                    final genre = info['genre'] ?? langProvider.translate('unknown');
                    return genre.toLowerCase() == genreKey.toLowerCase();
                  });
                  _showTemporaryPlaylistSheet(
                    context: context,
                    title: genreKey,
                    subtitle: '${matchingSongs.length} ${langProvider.translate('songs').toLowerCase()} • ${langProvider.translate('top_genres')}',
                    songs: matchingSongs,
                    provider: provider,
                    langProvider: langProvider,
                  );
                },
              ),
              context,
              height: null,
            ),
            
            const SizedBox(height: 24),

            // Grafico annate più ascoltate
            _buildChartCard(
              langProvider.translate('years'),
              _buildPieChart(
                yearCounts,
                context,
                onSectionTap: (yearKey) {
                  final matchingSongs = getMatchingHistorySongs((id, info, e) {
                    final resolvedDate = info['releaseDate'];
                    String yearStr = langProvider.translate('unknown');
                    if (resolvedDate != null && resolvedDate.length >= 4) {
                      final intYear = int.tryParse(resolvedDate.substring(0, 4));
                      if (intYear != null && intYear > 1000) {
                        final decade = (intYear ~/ 10) * 10;
                        yearStr = '${decade}s';
                      }
                    }
                    return yearStr == yearKey;
                  });
                  _showTemporaryPlaylistSheet(
                    context: context,
                    title: yearKey,
                    subtitle: '${matchingSongs.length} ${langProvider.translate('songs').toLowerCase()} • ${langProvider.translate('years')}',
                    songs: matchingSongs,
                    provider: provider,
                    langProvider: langProvider,
                  );
                },
              ),
              context,
              height: null,
            ),
            
            const SizedBox(height: 24),
            
            // Lista top canzoni (Trending style)
            Container(
              key: _topSongsSectionKey,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      langProvider.translate('top_songs'),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(width: 8),
                if (_groupByDate) ...[
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      _collapsedDays.length == sortedDays.length && sortedDays.isNotEmpty
                          ? Icons.unfold_more
                          : Icons.unfold_less,
                      size: 20,
                      color: Theme.of(context).primaryColor,
                    ),
                    tooltip: _collapsedDays.length == sortedDays.length && sortedDays.isNotEmpty
                        ? 'Espandi tutti'
                        : 'Comprimi tutti',
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
                  const SizedBox(width: 4),
                ],
                // Toggle pill badge per raggruppamento date
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _groupByDate = !_groupByDate;
                      });
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: _groupByDate
                            ? Theme.of(context).primaryColor
                            : Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _groupByDate
                              ? Theme.of(context).primaryColor
                              : Colors.white24,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.calendar_today_rounded,
                            size: 13,
                            color: _groupByDate ? Colors.white : Colors.white70,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            langProvider.translate('group_by_date'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: _groupByDate ? FontWeight.bold : FontWeight.w500,
                              color: _groupByDate ? Colors.white : Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
                  ..sort((a, b) {
                    final cmp = b.value.compareTo(a.value); // 1. Per numero di ascolti (più alto a più basso)
                    if (cmp != 0) return cmp;
                    // 2. Cronologico: ultimo ascolto in alto (più recente)
                    final timeA = dailyLatestSongPlayTime[day]?[a.key] ?? DateTime.fromMillisecondsSinceEpoch(0);
                    final timeB = dailyLatestSongPlayTime[day]?[b.key] ?? DateTime.fromMillisecondsSinceEpoch(0);
                    return timeB.compareTo(timeA);
                  });
                  
                List<Widget> widgets = [];
                final isCollapsed = _collapsedDays.contains(day);
                
                widgets.add(
                  Padding(
                    padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                    child: Material(
                      color: Colors.transparent,
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
                            color: Theme.of(context).primaryColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Theme.of(context).primaryColor.withValues(alpha: 0.3)),
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
                  ),
                );
                
                if (!isCollapsed) {
                  for (var entry in sortedSongsForDay) {
                    final songId = entry.key;
                    final count = entry.value;
                    final song = metadata[songId];
                    
                    if (song == null) continue;
                    
                    widgets.add(_buildSongTile(song, count, provider, langProvider, songLookup, context));
                  }
                }
                return widgets;
              })
            else
              Builder(
                builder: (context) {
                  final sortedAllSongs = totalSongCounts.entries.toList()
                    ..sort((a, b) {
                      final cmp = b.value.compareTo(a.value); // 1. Per numero di ascolti (più alto a più basso)
                      if (cmp != 0) return cmp;
                      // 2. Cronologico: ultimo ascolto in alto (più recente)
                      final timeA = latestSongPlayTime[a.key] ?? DateTime.fromMillisecondsSinceEpoch(0);
                      final timeB = latestSongPlayTime[b.key] ?? DateTime.fromMillisecondsSinceEpoch(0);
                      return timeB.compareTo(timeA);
                    });
                  return Column(
                    children: sortedAllSongs.map((entry) {
                      final songId = entry.key;
                      final count = entry.value;
                      final song = metadata[songId];
                      if (song == null) {
                        return const SizedBox.shrink();
                      }
                      return _buildSongTile(song, count, provider, langProvider, songLookup, context);
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

  Widget _buildLineChart(
    Map<String, int> dailyListens,
    BuildContext context, {
    void Function(String dayKey)? onDayTap,
  }) {
    if (dailyListens.isEmpty) {
      return Center(
        child: Text(
          Provider.of<LanguageProvider>(context, listen: false)
              .translate('no_time_data'),
        ),
      );
    }

    final sortedKeys = dailyListens.keys.toList()..sort();

    List<FlSpot> spots = [];
    double maxX = (sortedKeys.length - 1).toDouble();
    if (maxX < 1) {
      maxX = 1;
    }

    double maxY = 0;

    for (int i = 0; i < sortedKeys.length; i++) {
      double y = dailyListens[sortedKeys[i]]!.toDouble();
      if (y > maxY) {
        maxY = y;
      }
      spots.add(FlSpot(i.toDouble(), y));
    }

    if (maxY == 0) {
      maxY = 10;
    } else {
      maxY = maxY * 1.5;
    }

    return LineChart(
      LineChartData(
        lineTouchData: LineTouchData(
          enabled: true,
          touchCallback: (FlTouchEvent event, LineTouchResponse? touchResponse) {
            if (event is FlTapUpEvent &&
                touchResponse != null &&
                touchResponse.lineBarSpots != null &&
                touchResponse.lineBarSpots!.isNotEmpty) {
              final spotIndex = touchResponse.lineBarSpots!.first.spotIndex;
              if (spotIndex >= 0 && spotIndex < sortedKeys.length) {
                final dayKey = sortedKeys[spotIndex];
                onDayTap?.call(dayKey);
              }
            }
          },
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final idx = spot.spotIndex;
                final date = idx >= 0 && idx < sortedKeys.length ? sortedKeys[idx] : '';
                return LineTooltipItem(
                  '$date\n${spot.y.toInt()} ascolti\n▶ Tocca per ascoltare',
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                );
              }).toList();
            },
          ),
        ),
        gridData: const FlGridData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= 0 && value.toInt() < sortedKeys.length) {
                  // Mostra meno label se ci sono molti giorni
                  if (sortedKeys.length > 10 && value.toInt() % (sortedKeys.length ~/ 5) != 0) {
                    return const SizedBox.shrink();
                  }
                  final date = sortedKeys[value.toInt()];
                  // Formatta la data per mostrare solo giorno/mese (es. "12/04")
                  String formattedDate = date;
                  try {
                    final parts = date.split('-');
                    if (parts.length == 3) {
                      formattedDate = "${parts[2]}/${parts[1]}";
                    }
                  } catch (_) {}

                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      formattedDate,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 10,
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 30,
              interval: 1,
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                if (value == 0 || value == maxY) return const SizedBox.shrink();
                return Text(
                  value.toInt().toString(),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 10,
                  ),
                );
              },
              reservedSize: 28,
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: Theme.of(context).primaryColor.withValues(alpha: 0.2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongTile(
    dynamic song,
    int count,
    RadioProvider provider,
    LanguageProvider langProvider,
    Map<String, Map<String, String?>> songLookup,
    BuildContext context,
  ) {
    final info = songLookup[song.id];
    final resolvedGenre = (song.genre != null && song.genre!.isNotEmpty)
        ? song.genre
        : info?['genre'];
    final resolvedReleaseDate = (song.releaseDate != null && song.releaseDate!.isNotEmpty)
        ? song.releaseDate
        : info?['releaseDate'];

    String? year;
    if (resolvedReleaseDate != null && resolvedReleaseDate.length >= 4) {
      final intYear = int.tryParse(resolvedReleaseDate.substring(0, 4));
      if (intYear != null && intYear > 1000) {
        year = intYear.toString();
      }
    }

    final genre = (resolvedGenre != null &&
            resolvedGenre.isNotEmpty &&
            resolvedGenre != langProvider.translate('unknown'))
        ? resolvedGenre
        : null;

    final List<String> metaParts = [];
    if (year != null) metaParts.add(year);
    if (genre != null) metaParts.add(genre);
    final String extraInfo = metaParts.join(' • ');

    final String displayTitle = _cleanDisplayTitle(song.title);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: song.artUri != null && song.artUri!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: song.artUri!,
                width: 50,
                height: 50,
                fit: BoxFit.cover,
                memCacheWidth: 150,
                memCacheHeight: 150,
                placeholder: (context, url) => Container(
                  width: 50,
                  height: 50,
                  color: Colors.white10,
                  child: const Icon(Icons.music_note, size: 20, color: Colors.white38),
                ),
                errorWidget: (context, url, error) => Container(
                  width: 50,
                  height: 50,
                  color: Colors.white10,
                  child: const Icon(Icons.music_note, size: 20, color: Colors.white38),
                ),
              )
            : Container(width: 50, height: 50, color: Colors.white10, child: const Icon(Icons.music_note)),
      ),
      title: Text(displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54),
          ),
          if (extraInfo.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              extraInfo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
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
                            ? CachedNetworkImage(
                                imageUrl: song.artUri!,
                                width: 80,
                                height: 80,
                                fit: BoxFit.cover,
                                memCacheWidth: 240,
                                memCacheHeight: 240,
                                placeholder: (context, url) => Container(
                                  width: 80,
                                  height: 80,
                                  color: Colors.white10,
                                  child: const Icon(Icons.music_note, size: 36, color: Colors.white38),
                                ),
                                errorWidget: (context, url, error) => Container(
                                  width: 80,
                                  height: 80,
                                  color: Colors.white10,
                                  child: const Icon(Icons.music_note, size: 36, color: Colors.white38),
                                ),
                              )
                            : Container(width: 80, height: 80, color: Colors.white10, child: const Icon(Icons.music_note, size: 36)),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(displayTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold), maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Text(song.artist, style: const TextStyle(color: Colors.white54, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                            if (extraInfo.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                extraInfo,
                                style: TextStyle(
                                  color: Theme.of(context).primaryColor.withValues(alpha: 0.9),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
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

  String _cleanDisplayTitle(String title) {
    String clean = title;
    // Rimuove prefissi come 📱, ⬇️, 📁, 🎵, 🎶, 🎧, ecc.
    clean = clean.replaceAll(RegExp(r'^(⬇️|📱|📁|🎵|🎶|🎧|▶️|💿|📀|[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{27BF}])\s*', unicode: true), '');
    clean = clean.replaceAll(RegExp(r'^(⬇️|📱|📁)\s*'), '');
    return clean.trim().isNotEmpty ? clean.trim() : title;
  }
}
