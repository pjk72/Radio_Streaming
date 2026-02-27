import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../services/trending_service.dart';
import '../services/spotify_service.dart';
import '../providers/radio_provider.dart';
import 'trending_details_screen.dart';
import '../providers/language_provider.dart';
import '../models/saved_song.dart';
import 'artist_details_screen.dart';

class TrendingScreen extends StatefulWidget {
  const TrendingScreen({super.key});

  @override
  State<TrendingScreen> createState() => _TrendingScreenState();
}

class _TrendingScreenState extends State<TrendingScreen>
    with AutomaticKeepAliveClientMixin {
  late TrendingService _trendingService;

  // State
  late String _selectedCountryCode;
  String? _systemCountryCode;

  final TextEditingController _customQueryController = TextEditingController();
  bool _useCustomQuery = false;

  bool _isLoading = false;
  List<TrendingPlaylist> _playlists = [];
  String? _errorMessage;

  Map<String, String> _getCountryMap(LanguageProvider langProvider) {
    return {
      "IT": "🇮🇹 ${langProvider.translate('country_IT')}",
      "US": "🇺🇸 ${langProvider.translate('country_US')}",
      "GB": "🇬🇧 ${langProvider.translate('country_GB')}",
      "FR": "🇫🇷 ${langProvider.translate('country_FR')}",
      "DE": "🇩🇪 ${langProvider.translate('country_DE')}",
      "ES": "🇪🇸 ${langProvider.translate('country_ES')}",
      "CA": "🇨🇦 ${langProvider.translate('country_CA')}",
      "AU": "🇦🇺 ${langProvider.translate('country_AU')}",
      "BR": "🇧🇷 ${langProvider.translate('country_BR')}",
      "JP": "🇯🇵 ${langProvider.translate('country_JP')}",
      "RU": "🇷🇺 ${langProvider.translate('country_RU')}",
      "CN": "🇨🇳 ${langProvider.translate('country_CN')}",
      "IN": "🇮🇳 ${langProvider.translate('country_IN')}",
      "MX": "🇲🇽 ${langProvider.translate('country_MX')}",
      "AR": "🇦🇷 ${langProvider.translate('country_AR')}",
      "NL": "🇳🇱 ${langProvider.translate('country_NL')}",
      "BE": "🇧🇪 ${langProvider.translate('country_BE')}",
      "CH": "🇨🇭 ${langProvider.translate('country_CH')}",
      "SE": "🇸🇪 ${langProvider.translate('country_SE')}",
      "NO": "🇳🇴 ${langProvider.translate('country_NO')}",
      "DK": "🇩🇰 ${langProvider.translate('country_DK')}",
      "FI": "🇫🇮 ${langProvider.translate('country_FI')}",
      "PL": "🇵🇱 ${langProvider.translate('country_PL')}",
      "AT": "🇦🇹 ${langProvider.translate('country_AT')}",
      "PT": "🇵🇹 ${langProvider.translate('country_PT')}",
      "GR": "🇬🇷 ${langProvider.translate('country_GR')}",
      "TR": "🇹🇷 ${langProvider.translate('country_TR')}",
      "ZA": "🇿🇦 ${langProvider.translate('country_ZA')}",
      "KR": "🇰🇷 ${langProvider.translate('country_KR')}",
      "IE": "🇮🇪 ${langProvider.translate('country_IE')}",
      "NZ": "🇳🇿 ${langProvider.translate('country_NZ')}",
      "MA": "🇲🇦 ${langProvider.translate('country_MA')}",
    };
  }

  @override
  void initState() {
    super.initState();
    // Initialize Service (simple dependency injection)
    // We need SpotifyService from Provider or singleton?
    // It's not a provider in main, but instantiated in others?
    // Wait, SpotifyService is usually just instantiated or passed.
    // In `RadioProvider` it seems to be used.
    // Let's rely on creating a fresh one or getting from context if available.
    // Actually, `SpotifyService` holds state (tokens). Creating a new one might need re-login.
    // `RadioProvider` likely has one.
    // Let's implement `didChangeDependencies` to get it safe.

    _selectedCountryCode = _detectCountry();
    _systemCountryCode = _selectedCountryCode;
    if (_playlists.isEmpty) {
      _fetchTrending();
    }
  }

  @override
  bool get wantKeepAlive => true;

  String _detectCountry() {
    try {
      final String systemLocale = Platform.localeName;
      // Normalize separator (some systems use '-' instead of '_')
      final String normalized = systemLocale.replaceAll('-', '_');

      if (normalized.contains('_')) {
        final parts = normalized.split('_');
        if (parts.length > 1) {
          final code = parts[1].toUpperCase();
          return code;
        }
      }
    } catch (_) {}
    return 'US'; // Safe international fallback
  }

  Future<void> _fetchTrending() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
      final countryMap = _getCountryMap(langProvider);

      final spotify = SpotifyService();
      await spotify.init(); // Load tokens

      _trendingService = TrendingService(spotify);

      final results = await _trendingService.searchTrending(
        // Robust extraction: Handle "🇮🇹 Italy" vs "Italy" vs legacy
        // We take everything AFTER the first space to get the full country name ("South Africa", not just "Africa")
        countryMap[_selectedCountryCode]!.contains(' ')
            ? countryMap[_selectedCountryCode]!.substring(
                countryMap[_selectedCountryCode]!.indexOf(' ') + 1,
              )
            : countryMap[_selectedCountryCode] ?? 'USA',
        DateTime.now().year.toString(),
        customQuery: _useCustomQuery && _customQueryController.text.isNotEmpty
            ? _customQueryController.text
            : null,
      );

      if (mounted) {
        setState(() {
          _playlists = results;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    // _trendingService.dispose(); // If we kept it around
    _customQueryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Colors.transparent, // Parent handles background
      body: Consumer<LanguageProvider>(
        builder: (context, langProvider, child) {
          return Column(
            children: [
              // Header / Controls
              _buildControls(context, langProvider),

              // List
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _errorMessage != null
                    ? Center(
                        child: Text(
                          langProvider
                              .translate('error_prefix')
                              .replaceAll('{0}', _errorMessage!),
                          style: const TextStyle(color: Colors.red),
                        ),
                      )
                    : _buildGrid(context, langProvider),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildControls(BuildContext context, LanguageProvider langProvider) {
    // Sort entries alphabetically by value (Country Name)
    final countryMap = _getCountryMap(langProvider);
    final sortedCountries = countryMap.entries.toList()
      ..sort((a, b) {
        // Priority check
        if (a.key == _systemCountryCode) return -1;
        if (b.key == _systemCountryCode) return 1;

        // Name extraction
        final nameA = a.value.contains(' ')
            ? a.value.substring(a.value.indexOf(' ') + 1)
            : a.value;
        final nameB = b.value.contains(' ')
            ? b.value.substring(b.value.indexOf(' ') + 1)
            : b.value;
        return nameA.compareTo(nameB);
      });

    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.5),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 1: Country Selection + Custom Search Toggle
          Row(
            children: [
              Container(
                width: 150, // Reduced width as requested
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedCountryCode,
                    isExpanded: true,
                    dropdownColor: Theme.of(context).cardColor,
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyLarge?.color,
                    ),
                    items: sortedCountries.map((e) {
                      return DropdownMenuItem(
                        value: e.key,
                        child: Text(
                          e.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _selectedCountryCode = val;
                          _useCustomQuery = false;
                        });
                        _fetchTrending();
                      }
                    },
                  ),
                ),
              ),
              const Spacer(),
              // Toggle for custom search
              TextButton.icon(
                icon: Icon(
                  _useCustomQuery ? Icons.close : Icons.tune,
                  size: 16,
                ),
                label: Text(
                  _useCustomQuery
                      ? langProvider.translate('use_default')
                      : langProvider.translate('custom_search'),
                ),
                onPressed: () {
                  setState(() {
                    _useCustomQuery = !_useCustomQuery;
                    if (!_useCustomQuery) {
                      _customQueryController.clear();
                      _fetchTrending();
                    }
                  });
                },
              ),
            ],
          ),

          if (_useCustomQuery) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _customQueryController,
              decoration: InputDecoration(
                hintText: langProvider.translate('custom_search_hint'),
                filled: true,
                fillColor: Theme.of(context).scaffoldBackgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _fetchTrending,
                ),
              ),
              onSubmitted: (_) => _fetchTrending(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context, LanguageProvider langProvider) {
    return Consumer<RadioProvider>(
      builder: (context, provider, child) {
        // 0. Prepare Artists List
        final List<Map<String, String>> rawTopArtists = provider
            .getTopArtists();
        final Map<String, Map<String, String>> mergedArtists = {};

        for (var artist in rawTopArtists) {
          final fullName = artist['name'] ?? '';
          final shortName = fullName.split(',').first.trim().toLowerCase();

          if (shortName.isEmpty) continue;

          if (!mergedArtists.containsKey(shortName)) {
            mergedArtists[shortName] = artist;
          } else {
            // If we have a duplicate short name, prioritize the favorite one
            final existing = mergedArtists[shortName]!;
            final isNewFavorite = artist['isFavorite'] == 'true';
            final isExistingFavorite = existing['isFavorite'] == 'true';

            if (isNewFavorite && !isExistingFavorite) {
              mergedArtists[shortName] = artist;
            } else if (existing['image'] == null ||
                existing['image']!.isEmpty) {
              if (artist['image'] != null && artist['image']!.isNotEmpty) {
                mergedArtists[shortName] = artist;
              }
            }
          }
        }
        final List<Map<String, String>> topArtists = mergedArtists.values
            .toList();

        // 1. Unified FIFO (Recently Played)
        List<Map<String, dynamic>> unifiedRecent = provider
            .getUnifiedRecentSongs();

        // 2. Prepare Trending Playlists by Provider
        final Map<String, List<TrendingPlaylist>> groupedTrending = {};
        for (var p in _playlists) {
          groupedTrending.putIfAbsent(p.provider, () => []).add(p);
        }

        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            // Top Artists Section
            if (topArtists.isNotEmpty)
              _buildHorizontalSection(
                title: langProvider.translate('top_artists'),
                items: topArtists.take(30).toList(),
                height: 140,
                itemBuilder: (artistData) {
                  final data = artistData as Map<String, String>;
                  return _ArtistCard(
                    key: ValueKey(data['name']),
                    artistData: data,
                    showCarIcon: data['isAAMajority'] == 'true',
                  );
                },
              ),

            // Unified FIFO Section (Recently Played)
            if (unifiedRecent.isNotEmpty)
              _buildHorizontalSection(
                title: langProvider.translate('recently_played'),
                items: unifiedRecent.take(30).toList(),
                itemBuilder: (data) {
                  final item = data as Map<String, dynamic>;
                  return _buildSongCard(
                    item['song'] as SavedSong,
                    provider,
                    langProvider,
                    showCarIcon: item['isLastFromAA'] == true,
                  );
                },
              ),

            // Trending Playlists by Category
            ...groupedTrending.entries.map((entry) {
              return _buildHorizontalSection(
                title:
                    "${entry.key} ${langProvider.translate('playlists_suffix')}",
                items: entry.value,
                itemBuilder: (playlist) {
                  final item = playlist as TrendingPlaylist;
                  final isPlaying =
                      provider.currentPlayingPlaylistId ==
                      'trending_${item.id}';
                  return SizedBox(
                    width: 130, // Narrower, more modern width
                    child: _buildCard(item, isPlaying, langProvider),
                  );
                },
              );
            }).toList(),

            const SizedBox(height: 90), // bottom padding for player
          ],
        );
      },
    );
  }

  Widget _buildHorizontalSection({
    required String title,
    required List<dynamic> items,
    required Widget Function(dynamic) itemBuilder,
    double height = 190,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: height,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) => itemBuilder(items[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildSongCard(
    SavedSong song,
    RadioProvider provider,
    LanguageProvider langProvider, {
    bool showCarIcon = false,
  }) {
    final theme = Theme.of(context);
    final isPlaying = provider.audioOnlySongId == song.id;
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TrendingDetailsScreen(
              albumName: song.album.isNotEmpty
                  ? song.album
                  : langProvider.translate('album_label'),
              artistName: song.artist,
              artworkUrl: song.artUri,
              originalSong: song,
            ),
          ),
        );
      },
      child: SizedBox(
        width: 130, // Square layout width
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: theme.cardColor,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                  image: song.artUri != null && song.artUri!.isNotEmpty
                      ? DecorationImage(
                          image: CachedNetworkImageProvider(song.artUri!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: Stack(
                  children: [
                    if (song.artUri == null || song.artUri!.isEmpty)
                      const Center(
                        child: Icon(
                          Icons.music_note,
                          size: 40,
                          color: Colors.white24,
                        ),
                      ),
                    if (showCarIcon)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.directions_car,
                            color: Colors.white,
                            size: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: isPlaying ? theme.primaryColor : null,
                    ),
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(
    TrendingPlaylist item,
    bool isPlaying,
    LanguageProvider langProvider,
  ) {
    final theme = Theme.of(context);
    const borderRadius = BorderRadius.all(Radius.circular(16));

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TrendingDetailsScreen(playlist: item),
          ),
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              color: isPlaying
                  ? theme.primaryColor.withValues(alpha: 0.2)
                  : Colors.black.withValues(alpha: 0.15),
              blurRadius: isPlaying ? 12 : 8,
              offset: isPlaying ? const Offset(0, 4) : const Offset(0, 2),
            ),
          ],
          border: isPlaying
              ? Border.all(color: theme.primaryColor, width: 1.5)
              : null,
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Image Area
              Expanded(
                flex: 4,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _TrendingPlaylistCover(
                      playlist: item,
                      service: _trendingService,
                    ),

                    // Subtle Gradient Overlay for depth
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.2),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // Provider Badge (Top Right)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _buildProviderBadge(item.provider),
                    ),

                    // Active Status Overlay
                    if (isPlaying)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.2),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: theme.primaryColor,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.equalizer,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Content Area
              Expanded(
                flex: 2,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: isPlaying
                              ? theme.primaryColor
                              : theme.textTheme.bodyLarge?.color,
                          height: 1.2,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.music_note,
                            size: 10,
                            color:
                                theme.textTheme.bodySmall?.color?.withValues(
                                  alpha: 0.7,
                                ) ??
                                Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              langProvider
                                  .translate('songs_count')
                                  .replaceAll(
                                    '{0}',
                                    item.trackCount.toString(),
                                  ),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color:
                                    theme.textTheme.bodySmall?.color
                                        ?.withValues(alpha: 0.7) ??
                                    Colors.grey,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProviderBadge(String provider) {
    IconData icon;
    Color color;

    switch (provider.toUpperCase()) {
      case 'SPOTIFY':
        icon = FontAwesomeIcons.spotify;
        color = const Color(0xFF1DB954);
        break;
      case 'YOUTUBE':
        icon = FontAwesomeIcons.youtube;
        color = const Color(0xFFFF0000);
        break;
      case 'AUDIUS':
        icon = FontAwesomeIcons.music;
        color = const Color(0xFFCC00FF);
        break;
      case 'DEEZER':
        icon = FontAwesomeIcons.deezer;
        color = Colors
            .black; // Deezer logo is often black or rainbow. Black implies dark logo? Actually white on black.
        // Let's use a standard Deezer color, or just black if on white background.
        // Since the badge background is white (see line 468), black icon is fine.
        break;
      default:
        icon = Icons.radio;
        color = Colors.blue;
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9), // Slightly transparent
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, color: color, size: 12),
    );
  }
}

class _ArtistCard extends StatefulWidget {
  final Map<String, String> artistData;
  final bool showCarIcon;

  const _ArtistCard({
    super.key,
    required this.artistData,
    this.showCarIcon = false,
  });

  @override
  State<_ArtistCard> createState() => _ArtistCardState();
}

class _ArtistCardState extends State<_ArtistCard> {
  Future<String?>? _imageFuture;

  @override
  void initState() {
    super.initState();
    _fetchImage();
  }

  @override
  void didUpdateWidget(_ArtistCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artistData['name'] != widget.artistData['name']) {
      _fetchImage();
    }
  }

  void _fetchImage() {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    _imageFuture = provider.fetchArtistImage(widget.artistData['name'] ?? '');
  }

  void _showResetConfirmation(
    BuildContext context,
    LanguageProvider langProvider,
    String artistName,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(langProvider.translate('reset_artist_history')),
        content: Text(
          langProvider
              .translate('delete_station_desc')
              .replaceAll('{0}', artistName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(langProvider.translate('cancel')),
          ),
          TextButton(
            onPressed: () {
              Provider.of<RadioProvider>(
                context,
                listen: false,
              ).resetArtistHistory(artistName);
              Navigator.pop(context);
            },
            child: Text(
              langProvider.translate('delete'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer<LanguageProvider>(
      builder: (context, langProvider, child) {
        final String fullName =
            widget.artistData['name'] ??
            langProvider.translate('unknown_artist');
        final String name = fullName.split(',').first.trim();
        final String fallbackImageUrl = widget.artistData['image'] ?? '';
        final bool isFavorite = widget.artistData['isFavorite'] == 'true';

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ArtistDetailsScreen(
                  artistName: name,
                  fallbackImage: fallbackImageUrl.isNotEmpty
                      ? fallbackImageUrl
                      : null,
                ),
              ),
            );
          },
          child: FutureBuilder<String?>(
            future: _imageFuture,
            builder: (context, snapshot) {
              final imageUrl = snapshot.data ?? fallbackImageUrl;

              return SizedBox(
                width: 100,
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          // WOW EFFECT: Premium Circular Photo with Theme-based Glow
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeInOut,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.cardColor,
                              border: Border.all(
                                color: isFavorite
                                    ? theme.primaryColor.withValues(alpha: 0.8)
                                    : Colors.white24,
                                width: isFavorite ? 3 : 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: isFavorite
                                      ? theme.primaryColor.withValues(
                                          alpha: 0.3,
                                        )
                                      : Colors.black.withValues(alpha: 0.15),
                                  blurRadius: isFavorite ? 15 : 6,
                                  spreadRadius: isFavorite ? 2 : 0,
                                  offset: const Offset(0, 3),
                                ),
                                if (isFavorite)
                                  BoxShadow(
                                    color: theme.primaryColor.withValues(
                                      alpha: 0.1,
                                    ),
                                    blurRadius: 25,
                                    spreadRadius: 5,
                                  ),
                              ],
                              image: imageUrl.isNotEmpty
                                  ? DecorationImage(
                                      image: CachedNetworkImageProvider(
                                        imageUrl,
                                      ),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: imageUrl.isEmpty
                                ? const Center(
                                    child: Icon(
                                      Icons.person,
                                      size: 40,
                                      color: Colors.white24,
                                    ),
                                  )
                                : null,
                          ),

                          // Car Icon (Android Auto)
                          if (widget.showCarIcon)
                            Positioned(
                              top: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.directions_car,
                                  color: Colors.white,
                                  size: 10,
                                ),
                              ),
                            ),

                          // Favorite Heart Toggle
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: GestureDetector(
                              onTap: () {
                                Provider.of<RadioProvider>(
                                  context,
                                  listen: false,
                                ).toggleFollowArtist(name);
                              },
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: theme.scaffoldBackgroundColor,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.4,
                                      ),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  isFavorite
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 16,
                                  color: isFavorite
                                      ? Colors.red
                                      : (theme.brightness == Brightness.light
                                            ? theme.hintColor
                                            : Colors.white70),
                                ),
                              ),
                            ),
                          ),

                          // Reset History (X Button)
                          Positioned(
                            left: 0,
                            top: 0,
                            child: GestureDetector(
                              onTap: () => _showResetConfirmation(
                                context,
                                langProvider,
                                name,
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: theme.scaffoldBackgroundColor
                                      .withValues(alpha: 0.8),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.close,
                                  size: 10,
                                  color: theme.brightness == Brightness.light
                                      ? theme.hintColor
                                      : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: isFavorite
                            ? FontWeight.bold
                            : FontWeight.normal,
                        fontSize: 12,
                        color: isFavorite ? theme.primaryColor : null,
                        shadows: [
                          if (isFavorite)
                            Shadow(
                              color: theme.primaryColor.withValues(alpha: 0.3),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _TrendingPlaylistCover extends StatefulWidget {
  final TrendingPlaylist playlist;
  final TrendingService service;

  const _TrendingPlaylistCover({required this.playlist, required this.service});

  @override
  State<_TrendingPlaylistCover> createState() => _TrendingPlaylistCoverState();
}

class _TrendingPlaylistCoverState extends State<_TrendingPlaylistCover> {
  List<String>? _collageUrls;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.playlist.imageUrls.isEmpty) {
      _fetchCollage();
    }
  }

  Future<void> _fetchCollage() async {
    if (_isLoading) return;
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final tracks = await widget.service.getPlaylistTracks(widget.playlist);
      final urls = tracks
          .map((t) => t['image'])
          .where((img) => img != null && img.isNotEmpty)
          .cast<String>()
          .toList();

      if (mounted) {
        setState(() {
          _collageUrls = urls;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1. If we have a direct playlist image, use it
    if (widget.playlist.imageUrls.isNotEmpty) {
      return _buildImage(widget.playlist.imageUrls.first);
    }

    // 2. If we are fetching tracks for collage
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white24,
          ),
        ),
      );
    }

    // 3. Display collage or fallback
    final urls = _collageUrls ?? [];
    if (urls.isEmpty) {
      return const Center(
        child: Icon(Icons.music_note, color: Colors.white24, size: 24),
      );
    }

    if (urls.length >= 4) {
      return GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: urls.take(4).map((url) => _buildImage(url)).toList(),
      );
    }

    // Single track image fallback
    return _buildImage(urls.first);
  }

  Widget _buildImage(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      placeholder: (_, __) => Container(color: Colors.black12),
      errorWidget: (_, __, ___) => Container(
        color: Colors.black26,
        child: const Icon(Icons.music_note, color: Colors.white10, size: 16),
      ),
    );
  }
}
