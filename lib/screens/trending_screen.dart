import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../services/trending_service.dart';
import '../providers/radio_provider.dart';
import 'trending_details_screen.dart';
import '../providers/language_provider.dart';
import '../models/saved_song.dart';
import 'artist_details_screen.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/glass_utils.dart';

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
  final TextEditingController _filterController = TextEditingController();

  bool _isLoading = false;
  List<TrendingPlaylist> _playlists = [];
  String? _errorMessage;

  // Speech to Text variables
  late stt.SpeechToText _speech;
  bool _isListening = false;

  // Scrolling
  final GlobalKey _providersKey = GlobalKey();

  Map<String, String> _getCountryMap(LanguageProvider langProvider) {
    final codes = [
      "ALL", "AL", "DZ", "AD", "AO", "SA", "AR", "AM", "AU", "AT", "AZ",
      "BH", "BD", "BE", "BY", "BO", "BR", "BG", "CA", "CL", "CN",
      "CY", "CO", "KR", "CR", "HR", "CU", "DK", "EC", "EG", "AE",
      "EE", "PH", "FI", "FR", "GE", "DE", "JP", "JM", "JO", "GR",
      "GT", "HN", "IN", "ID", "IR", "IQ", "IE", "IS", "IL", "IT",
      "KZ", "KE", "KW", "LV", "LB", "LT", "LU", "MY", "MT", "MA",
      "MX", "MD", "MC", "ME", "NG", "NO", "NZ", "NL", "PK", "PA",
      "PY", "PE", "PL", "PT", "QA", "GB", "CZ", "DO", "RO", "RU",
      "SG", "SI", "SK", "ES", "US", "ZA", "SE", "CH", "TH", "TN",
      "TR", "UA", "HU", "UY", "VE", "VN"
    ];

    final Map<String, String> map = {};
    for (var code in codes) {
      final name = langProvider.translate('country_$code');
      if (code == "ALL") {
        map[code] = "🌍 $name";
      } else {
        map[code] = "${_getFlag(code)} $name";
      }
    }

    // Sort alphabetically by name
    final sortedEntries = map.entries.toList()
      ..sort((a, b) => a.value.substring(5).compareTo(b.value.substring(5)));

    return Map.fromEntries(sortedEntries);
  }

  String _getFlag(String countryCode) {
    return countryCode.toUpperCase().replaceAllMapped(
      RegExp(r'[A-Z]'),
      (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) + 127397),
    );
  }

  @override
  void initState() {
    super.initState();

    _selectedCountryCode = _detectCountry();
    _systemCountryCode = _selectedCountryCode;
    _speech = stt.SpeechToText();
    if (_playlists.isEmpty) {
      _fetchTrending();
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final langProvider = Provider.of<LanguageProvider>(context);
    final provider = Provider.of<RadioProvider>(context, listen: false);

    final countryMap = _getCountryMap(langProvider);
    final countryName = countryMap[_selectedCountryCode]!.contains(' ')
        ? countryMap[_selectedCountryCode]!.substring(
            countryMap[_selectedCountryCode]!.indexOf(' ') + 1,
          )
        : countryMap[_selectedCountryCode] ?? 'USA';

    provider.preFetchForYou(
      countryCode: _selectedCountryCode,
      countryName: countryName,
      languageCode: langProvider.resolvedLanguageCode,
    );
  }

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
    // Dismiss keyboard safely if a search is being performed
    if (_customQueryController.text.isNotEmpty) {
      FocusManager.instance.primaryFocus?.unfocus();
    }

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

      // Lazily setup the intelligent recommendations
      final provider = Provider.of<RadioProvider>(context, listen: false);
      final countryName = countryMap[_selectedCountryCode]!.contains(' ')
          ? countryMap[_selectedCountryCode]!.substring(
              countryMap[_selectedCountryCode]!.indexOf(' ') + 1,
            )
          : countryMap[_selectedCountryCode] ?? 'USA';

      provider.preFetchForYou(
        countryCode: _selectedCountryCode,
        countryName: countryName,
        languageCode: langProvider.resolvedLanguageCode,
      );

      _trendingService = TrendingService();

      final results = await _trendingService.searchTrending(
        // Robust extraction: Handle "🇮🇹 Italy" vs "Italy" vs legacy
        // We take everything AFTER the first space to get the full country name ("South Africa", not just "Africa")
        countryMap[_selectedCountryCode]!.contains(' ')
            ? countryMap[_selectedCountryCode]!.substring(
                countryMap[_selectedCountryCode]!.indexOf(' ') + 1,
              )
            : countryMap[_selectedCountryCode] ?? 'USA',
        DateTime.now().year.toString(),
        countryCode:
            _selectedCountryCode, // ISO code (IT, US, etc.) for Apple Music
        customQuery: _customQueryController.text.isNotEmpty
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

        // Auto-scroll to the search results/bar when doing a custom search
        if (_customQueryController.text.isNotEmpty) {
          // Robust scrolling: Delay + PostFrameCallback ensures the dynamic list has settled
          Future.delayed(const Duration(milliseconds: 400), () {
            if (mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_providersKey.currentContext != null) {
                  Scrollable.ensureVisible(
                    _providersKey.currentContext!,
                    duration: const Duration(milliseconds: 1000),
                    curve: Curves.fastOutSlowIn,
                    alignment: 0.0, // Bring it to the top
                  );
                }
              });
            }
          });
        }
      }
    }
  }

  @override
  void dispose() {
    // _trendingService.dispose(); // If we kept it around
    _customQueryController.dispose();
    _filterController.dispose();
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
                child: (_isLoading && _playlists.isEmpty)
                    ? _buildSkeletonLoading(context, langProvider)
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
      decoration: const BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(0)),
      ),
      child: Row(
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
                      _customQueryController.clear();
                      _playlists.clear(); // Clear to show full-screen loader
                      _errorMessage = null; 
                    });
                    _fetchTrending();
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: TextField(
                controller: _filterController,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: langProvider.translate('search'),
                  prefixIcon: const Icon(Icons.filter_list, size: 18, color: Colors.white54),
                  suffixIcon: _filterController.text.isNotEmpty 
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            setState(() {
                              _filterController.clear();
                            });
                          },
                        ) 
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: (_) {
                  setState(() {}); // Trigger local filtering
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  void _toggleListening() async {
    if (!_isListening) {
      // Prompt for permission if not granted
      var status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        // Show an alert or a snackbar explaining need for permission
        return;
      }

      bool available = await _speech.initialize(
        onStatus: (val) {
          if (val == 'done' || val == 'notListening') {
            setState(() => _isListening = false);
            // Optionally auto-fetch when stop talking, or let user hit search!
            if (_customQueryController.text.isNotEmpty) {
              _fetchTrending();
            }
          }
        },
        onError: (val) {
          setState(() => _isListening = false);
        },
      );
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) => setState(() {
            _customQueryController.text = val.recognizedWords;
          }),
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
      _fetchTrending();
    }
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

        // 2. Prepare Trending Playlists by Provider (with filter)
        final String filterText = _filterController.text.toLowerCase();
        final Map<String, List<TrendingPlaylist>> groupedTrending = {};
        for (var p in _playlists) {
          if (filterText.isNotEmpty) {
            final title = p.title.toLowerCase();
            final owner = p.owner?.toLowerCase() ?? '';
            final provider = p.provider.toLowerCase();
            if (!title.contains(filterText) && 
                !owner.contains(filterText) && 
                !provider.contains(filterText)) {
              continue;
            }
          }
          final groupKey = p.categoryTitle ?? p.provider;
          groupedTrending.putIfAbsent(groupKey, () => []).add(p);
        }

        return ListView(
          cacheExtent: 3000, // Pre-render more children to ensure keys are available for scrolling
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            // Error Message (if any)
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          langProvider
                              .translate('error_prefix')
                              .replaceAll('{0}', _errorMessage!),
                          style: const TextStyle(color: Colors.red, fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16, color: Colors.red),
                        onPressed: () => setState(() => _errorMessage = null),
                      ),
                    ],
                  ),
                ),
              ),
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

            // AI "For You" Section
            if (provider.forYouList.isNotEmpty)
              _buildHorizontalSection(
                title: '✨ ${langProvider.translate('for_you')}',
                height: 180, // Compact height
                items: provider.forYouList,
                itemBuilder: (data) {
                  final item = data as TrendingPlaylist?;
                  if (item == null) {
                    return _buildShimmerCard();
                  }
                  return SizedBox(
                    width: 125, // Compact width
                    child: _buildMixCard(item, false, langProvider),
                  );
                },
              ),

            // Unified FIFO Section (Recently Played)
            if (unifiedRecent.isNotEmpty)
              _buildHorizontalSection(
                title: langProvider.translate('recently_played'),
                topPadding: 8,
                height: 180, // Compact height
                items: unifiedRecent.take(30).toList(),
                itemBuilder: (data) {
                  final item = data as Map<String, dynamic>;
                  return SizedBox(
                    width: 125, // Compact width
                    child: _buildSongCard(
                      item['song'] as SavedSong,
                      provider,
                      langProvider,
                      showCarIcon: item['isLastFromAA'] == true,
                    ),
                  );
                },
              ),

            // Search skeleton (for custom queries)
            if (_isLoading && _customQueryController.text.isNotEmpty)
              _buildHorizontalSection(
                title: langProvider.translate('custom_search'),
                height: 180,
                items: List.generate(5, (_) => null),
                itemBuilder: (_) => _buildShimmerCard(),
                topPadding: 16,
              ),

            // Trending Playlists by Category
            ...() {
              final List<Widget> sections = [];
              bool ytSeen = false;

              final entries = groupedTrending.entries.toList();
              // Check if YouTube exists in our map
              final hasYouTube = entries.any((e) => e.key == 'YouTube');

              for (int i = 0; i < entries.length; i++) {
                final entry = entries[i];
                final String key = entry.key;

                // Move Search Bar just before YouTube
                if (key == 'YouTube' || (!hasYouTube && !ytSeen && key == 'AUDIUS')) {
                  ytSeen = true;
                  sections.add(_buildInlineSearchCard(context, langProvider));
                }

                // ALL playlist rows should now be compact (125x180)
                const double currentHeight = 180;
                const double currentWidth = 125;

                final String translated = langProvider.translate(key);
                final String sectionTitle = (translated != key) 
                    ? translated 
                    : "$key ${langProvider.translate('playlists_suffix')}";

                sections.add(_buildHorizontalSection(
                  title: sectionTitle,
                  showTitle: i == 0 && _customQueryController.text.isEmpty, // Show title only for the first line after Recently Played (hide if searching)
                  topPadding: 16,   // Compact padding
                  height: currentHeight,
                  items: entry.value,
                  itemBuilder: (playlist) {
                    final item = playlist as TrendingPlaylist;
                    final isPlaying =
                        provider.currentPlayingPlaylistId ==
                        'trending_${item.id}';
                    return SizedBox(
                      width: currentWidth,
                      child: _buildCard(item, isPlaying, langProvider),
                    );
                  },
                ));
              }

              // Fallback if YouTube wasn't found (add at the end)
              if (!ytSeen) {
                sections.add(_buildInlineSearchCard(context, langProvider));
              }

              return sections;
            }(),

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
    double topPadding = 24,
    bool showTitle = true,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: topPadding),
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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

  Widget _buildInlineSearchCard(
    BuildContext context,
    LanguageProvider langProvider,
  ) {
    return Padding(
      key: _providersKey,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            langProvider.translate('custom_search'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: TextField(
              controller: _customQueryController,
              decoration: InputDecoration(
                hintText: langProvider.translate('custom_search_hint'),
                prefixIcon: Icon(Icons.search, color: Theme.of(context).primaryColor),
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isLoading)
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).primaryColor),
                        ),
                      ),
                    IconButton(
                      icon: Icon(
                        _isListening ? Icons.mic : Icons.mic_none,
                        color: _isListening ? Colors.red : Colors.white70,
                      ),
                      onPressed: _toggleListening,
                    ),
                    if (_customQueryController.text.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () {
                          setState(() {
                            _customQueryController.clear();
                            _fetchTrending();
                          });
                        },
                      ),
                  ],
                ),
              ),
              onSubmitted: (_) => _fetchTrending(),
            ),
          ),
        ],
      ),
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
                    song.title.replaceFirst("⬇️ ", "").replaceFirst("📱 ", ""),
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
    );
  }

  List<Color> _generateGradient(String text) {
    final int hash = text.hashCode;
    final List<List<Color>> palettes = [
      [const Color(0xFFff9a9e), const Color(0xFFfecfef)],
      [const Color(0xFFa18cd1), const Color(0xFFfbc2eb)],
      [const Color(0xFF84fab0), const Color(0xFF8fd3f4)],
      [const Color(0xFFfccb90), const Color(0xFFd57eeb)],
      [const Color(0xFFe0c3fc), const Color(0xFF8ec5fc)],
      [const Color(0xFF4facfe), const Color(0xFF00f2fe)],
      [const Color(0xFF43e97b), const Color(0xFF38f9d7)],
      [const Color(0xFFfa709a), const Color(0xFFfee140)],
      [const Color(0xFF667eea), const Color(0xFF764ba2)],
      [const Color(0xFFff0844), const Color(0xFFffb199)],
      [const Color(0xFFb224ef), const Color(0xFF7579ff)],
      [const Color(0xFF0ba360), const Color(0xFF3cba92)],
      [const Color(0xFFff758c), const Color(0xFFff7eb3)],
      [const Color(0xFFf12711), const Color(0xFFf5af19)],
    ];
    return palettes[hash.abs() % palettes.length];
  }

  IconData _getGenreIcon(String title) {
    final String t = title.toLowerCase();
    if (t.contains('rock') || t.contains('metal') || t.contains('punk')) {
      return FontAwesomeIcons.guitar;
    }
    if (t.contains('workout') ||
        t.contains('gym') ||
        t.contains('running') ||
        t.contains('running')) {
      return Icons.fitness_center;
    }
    if (t.contains('pop') || t.contains('disco') || t.contains('party')) {
      return Icons.wb_sunny_outlined;
    }
    if (t.contains('chill') ||
        t.contains('ambient') ||
        t.contains('sleep') ||
        t.contains('lofi') ||
        t.contains('focus')) {
      return Icons.nights_stay_outlined;
    }
    if (t.contains('jazz') || t.contains('blues') || t.contains('soul')) {
      return Icons.music_video_outlined;
    }
    if (t.contains('hip hop') || t.contains('r&b') || t.contains('rap')) {
      return Icons.mic_external_on;
    }
    if (t.contains('classical') || t.contains('piano')) {
      return Icons.piano;
    }
    if (t.contains('edm') ||
        t.contains('techno') ||
        t.contains('house') ||
        t.contains('trance')) {
      return Icons.speaker_group_outlined;
    }
    if (t.contains('gaming')) {
      return Icons.videogame_asset_outlined;
    }
    if (t.contains('romance') || t.contains('favorite')) {
      return Icons.favorite_outline;
    }
    if (t.contains('weekly') || t.contains('personal')) {
      return Icons.person_outline;
    }
    if (t.contains('discovery') || t.contains('scoperta')) {
      return Icons.explore_outlined;
    }
    if (t.contains('80s') || t.contains('90s') || t.contains('70s')) {
      return Icons.vibration_outlined; // Retro feel
    }
    return Icons.music_note_outlined;
  }

  Widget _buildMixCard(
    TrendingPlaylist item,
    bool isPlaying,
    LanguageProvider langProvider,
  ) {
    final theme = Theme.of(context);
    final String mainImageUrl = item.imageUrls.isNotEmpty
        ? item.imageUrls.first
        : '';
    final bool isAI = item.provider == 'AI' || item.provider == 'APPLEMUSIC';
    final List<Color> gradientColors = _generateGradient(item.title);

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TrendingDetailsScreen(playlist: item),
          ),
        );
      },
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
                  border: Border.all(
                    color: Colors.purple.withValues(alpha: 0.3),
                    width: 1.5,
                  ),
                  image: !isAI && mainImageUrl.isNotEmpty
                      ? DecorationImage(
                          image: CachedNetworkImageProvider(mainImageUrl),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: Stack(
                  children: [
                    if (isAI)
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: LinearGradient(
                            colors: gradientColors,
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: Stack(
                          children: [
                            Positioned(
                              right: -15,
                              bottom: -15,
                              child: Icon(
                                _getGenreIcon(item.title),
                                size: 100, // Even bigger
                                color: Colors.white.withValues(
                                  alpha: 0.3,
                                ), // More visible
                              ),
                            ),
                            Positioned.fill(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10.0,
                                  vertical: 14.0,
                                ),
                                child: Column(
                                  children: [
                                    const SizedBox(
                                      height: 15,
                                    ), // Offset title higher
                                    Text(
                                      langProvider.translate(item.title),
                                      textAlign: TextAlign.center,
                                      maxLines: 4,
                                      softWrap: true,
                                      style: GoogleFonts.outfit(
                                        color: Colors.white,
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        height: 1.1,
                                        shadows: [
                                          Shadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.5,
                                            ),
                                            offset: const Offset(0, 4),
                                            blurRadius: 10,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Spacer(),
                                    // Artists List at the bottom
                                    if (item.predefinedTracks != null &&
                                        item.predefinedTracks!.isNotEmpty)
                                      Text(
                                        "${item.predefinedTracks!.take(5).map((t) => t['artist'].toString().split(',').first.trim()).join(', ')}...",
                                        textAlign: TextAlign.center,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.outfit(
                                          color: Colors.white,
                                          fontSize: 12, // Slightly larger
                                          fontWeight: FontWeight
                                              .w600, // Semi-bold for better impact
                                          letterSpacing: 0.3,
                                          height: 1.1,
                                          shadows: [
                                            Shadow(
                                              color: Colors.black.withValues(
                                                alpha: 0.5,
                                              ),
                                              offset: const Offset(0, 1),
                                              blurRadius: 4,
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Heart button overlay for Promoted Apple Playlists in For You
                    if (item.provider == 'APPLEMUSIC')
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Consumer<RadioProvider>(
                          builder: (context, radioProvider, _) {
                            final isPromoted = radioProvider.isPlaylistPromoted(item.id);
                            return GestureDetector(
                              onTap: () {
                                radioProvider.togglePromotedPlaylist(item);
                              },
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isPromoted ? Icons.favorite : Icons.favorite_border,
                                  color: isPromoted ? Colors.red : Colors.white70,
                                  size: 16,
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                    if (!isAI && mainImageUrl.isEmpty)
                      const Center(
                        child: Icon(
                          Icons.auto_awesome,
                          size: 40,
                          color: Colors.white24,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!isAI) ...[
              const SizedBox(height: 8),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: isPlaying ? theme.primaryColor : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
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
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TrendingDetailsScreen(playlist: item),
          ),
        );
        if (mounted) setState(() {});
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

                    // Heart button overlay for Apple Music Playlists
                    if (item.provider == 'APPLEMUSIC')
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Consumer<RadioProvider>(
                          builder: (context, radioProvider, _) {
                            final isPromoted = radioProvider.isPlaylistPromoted(item.id);
                            return GestureDetector(
                              onTap: () {
                                radioProvider.togglePromotedPlaylist(item);
                              },
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isPromoted ? Icons.favorite : Icons.favorite_border,
                                  color: isPromoted ? Colors.red : Colors.white70,
                                  size: 14,
                                ),
                              ),
                            );
                          },
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
                        langProvider.translate(item.title),
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
                                    item.trackCount == -1
                                        ? "?"
                                        : item.trackCount.toString(),
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


  Widget _buildSkeletonLoading(BuildContext context, LanguageProvider langProvider) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: 4,
      itemBuilder: (context, index) {
        return _buildHorizontalSection(
          title: "        ", // Hidden title shimmer
          height: 180,
          items: List.generate(5, (_) => null),
          itemBuilder: (_) => _buildShimmerCard(),
          topPadding: 16,
        );
      },
    );
  }

  Widget _buildShimmerCard() {
    final theme = Theme.of(context);
    final baseColor = theme.cardColor.withValues(alpha: 0.3);

    return SizedBox(
      width: 130,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 5,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: baseColor,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.05),
                  width: 1.5,
                ),
              ),
              child: Stack(
                children: [
                  Positioned(
                    right: -10,
                    bottom: -10,
                    child: Icon(
                      Icons.blur_on,
                      size: 60,
                      color: Colors.white.withValues(alpha: 0.05),
                    ),
                  ),
                  const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white12,
                        ),
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
                Container(
                  width: 80,
                  height: 12,
                  decoration: BoxDecoration(
                    color: baseColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 50,
                  height: 10,
                  decoration: BoxDecoration(
                    color: baseColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
    GlassUtils.showGlassDialog(
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
