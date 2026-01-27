import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../services/trending_service.dart';
import '../services/spotify_service.dart';
import '../providers/radio_provider.dart';
import 'trending_details_screen.dart';

class TrendingScreen extends StatefulWidget {
  const TrendingScreen({super.key});

  @override
  State<TrendingScreen> createState() => _TrendingScreenState();
}

class _TrendingScreenState extends State<TrendingScreen> {
  late TrendingService _trendingService;

  // State
  String _selectedCountryCode = 'IT';

  final TextEditingController _customQueryController = TextEditingController();
  bool _useCustomQuery = false;

  bool _isLoading = false;
  List<TrendingPlaylist> _playlists = [];
  String? _errorMessage;

  final Map<String, String> _countryMap = {
    "IT": "Italy",
    "US": "USA",
    "GB": "UK",
    "FR": "France",
    "DE": "Germany",
    "ES": "Spain",
    "CA": "Canada",
    "AU": "Australia",
    "BR": "Brazil",
    "JP": "Japan",
    "RU": "Russia",
    "CN": "China",
    "IN": "India",
    "MX": "Mexico",
    "AR": "Argentina",
    "NL": "Netherlands",
    "BE": "Belgium",
    "CH": "Switzerland",
    "SE": "Sweden",
    "NO": "Norway",
    "DK": "Denmark",
    "FI": "Finland",
    "PL": "Poland",
    "AT": "Austria",
    "PT": "Portugal",
    "GR": "Greece",
    "TR": "Turkey",
    "ZA": "South Africa",
    "KR": "South Korea",
    "IE": "Ireland",
    "NZ": "New Zealand",
    "MA": "Morocco",
  };

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
    _fetchTrending();
  }

  String _detectCountry() {
    try {
      final String systemLocale = Platform.localeName;
      if (systemLocale.contains('_')) {
        final parts = systemLocale.split('_');
        if (parts.length > 1) {
          final code = parts[1].toUpperCase();
          if (_countryMap.containsKey(code)) return code;
        }
      }
    } catch (_) {}
    return 'IT'; // Default
  }

  Future<void> _fetchTrending() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Hack: we need an authenticated SpotifyService.
      // We can try to get it from RadioProvider if it exposes it,
      // OR we just create one and hope tokens are in SharedPreferences (SpotifyService.init() loads them).
      final spotify = SpotifyService();
      await spotify.init(); // Load tokens

      _trendingService = TrendingService(spotify);

      final results = await _trendingService.searchTrending(
        _countryMap[_selectedCountryCode] ?? 'Italy',
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
    return Scaffold(
      backgroundColor: Colors.transparent, // Parent handles background
      body: Column(
        children: [
          // Header / Controls
          _buildControls(context),

          // List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                ? Center(
                    child: Text(
                      "Error: $_errorMessage",
                      style: const TextStyle(color: Colors.red),
                    ),
                  )
                : _buildGrid(context),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.5),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
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
                    items: _countryMap.entries.map((e) {
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
                label: Text(_useCustomQuery ? "Use Default" : "Custom Search"),
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
                hintText: "Custom Search (e.g. Best Rock 2020)",
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

  Widget _buildGrid(BuildContext context) {
    if (_playlists.isEmpty)
      return const Center(child: Text("No trending playlists found."));

    return Consumer<RadioProvider>(
      builder: (context, provider, child) {
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 1.1, // Compact cards
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: _playlists.length,
          itemBuilder: (context, index) {
            final item = _playlists[index];
            final isPlaying =
                provider.currentPlayingPlaylistId == 'trending_${item.id}';
            return _buildCard(item, isPlaying);
          },
        );
      },
    );
  }

  Widget _buildCard(TrendingPlaylist item, bool isPlaying) {
    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(12); // Slightly smaller radius

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
          border: isPlaying
              ? Border.all(color: theme.primaryColor, width: 2)
              : Border.all(
                  color: Colors.transparent,
                  width: 1,
                ), // Thinner border placeholder
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1), // Lighter shadow
              blurRadius: 4, // Reduced blur
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Image Area
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(10),
                    ),
                    child: _TrendingPlaylistCover(
                      playlist: item,
                      service: _trendingService,
                    ),
                  ),

                  // Provider Badge (Top Right)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _buildProviderBadge(item.provider),
                  ),

                  // Play/Eq Status
                  if (isPlaying)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.3),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(10),
                          ),
                        ),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: theme.primaryColor,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.equalizer,
                              color: Colors.white,
                              size: 20,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 6.0,
                  vertical: 4.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12, // Smaller font
                        color: isPlaying
                            ? theme.primaryColor
                            : theme.textTheme.bodyLarge?.color,
                        height: 1.1,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${item.trackCount} songs",
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.textTheme.bodySmall?.color ?? Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4),
        ],
      ),
      child: Icon(icon, color: color, size: 14),
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
          .where((img) => img != null && img!.isNotEmpty)
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
