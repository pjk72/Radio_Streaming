import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';
import 'dart:convert';
import 'dart:io';

import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import '../models/station.dart';
import '../utils/genre_mapper.dart';
import '../services/log_service.dart';
import '../utils/glass_utils.dart';

class TutorialCreateRadioWizard extends StatefulWidget {
  const TutorialCreateRadioWizard({super.key});

  @override
  State<TutorialCreateRadioWizard> createState() =>
      _TutorialCreateRadioWizardState();
}

class _TutorialCreateRadioWizardState extends State<TutorialCreateRadioWizard> {
  @override
  void initState() {
    super.initState();
    _loadPreviewRadios();
  }

  @override
  void dispose() {
    super.dispose();
  }

  int _step = 0; // 0: Country Selection, 1: Search & Select
  String? _selectedCountryCode;
  bool _isLoading = false;
  List<dynamic> _searchResults = [];
  String _searchQuery = '';
  bool _showSelectedOnly = false;

  // Audio Preview
  // Stream Testing
  String? _testingUrl;
  final Map<String, bool?> _testResults = {};

  // Selection State
  // Map of Station UUID (or index if no UUID) -> Data
  final Map<int, bool> _selectedIndices = {};
  final Map<int, bool> _favoriteIndices = {};
  final Map<int, String> _customLogos = {};

  // Horizontal Preview carousel variables
  List<dynamic> _previewRadios = [];
  final Set<dynamic> _selectedPreviewRadios = {};
  final Map<dynamic, String> _previewCustomLogos = {};
  bool _isLoadingPreview = true;

  Future<void> _loadPreviewRadios([String? countryCode]) async {
    setState(() => _isLoadingPreview = true);
    String code = countryCode ?? "US"; // fallback

    if (countryCode == null) {
      try {
        final locale = Platform.localeName;
        if (locale.contains('_')) {
          final parts = locale.split('_');
          if (parts.length > 1) {
            code = parts[1].toUpperCase();
          }
        } else if (locale.length == 2) {
          code = locale.toUpperCase();
        }
      } catch (_) {}
    }

    try {
      for (int i = 1; i <= 5; i++) {
        final server = "de$i.api.radio-browser.info";
        final url = (code == "ALL")
            ? Uri.parse(
                "https://$server/json/stations/search?limit=100&order=clickcount&reverse=true",
              )
            : Uri.parse(
                "https://$server/json/stations/search?countrycode=${code.toLowerCase()}&limit=100&order=clickcount&reverse=true",
              );

        final response = await http
            .get(url)
            .timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final List<dynamic> raw = json.decode(response.body);

          if (mounted) {
            // Sort explicitly by clickcount DESC, then votes DESC
            raw.sort((a, b) {
              final aClicks =
                  int.tryParse(a['clickcount']?.toString() ?? '0') ?? 0;
              final bClicks =
                  int.tryParse(b['clickcount']?.toString() ?? '0') ?? 0;
              int comp = bClicks.compareTo(aClicks);
              if (comp != 0) return comp;
              final aVotes = int.tryParse(a['votes']?.toString() ?? '0') ?? 0;
              final bVotes = int.tryParse(b['votes']?.toString() ?? '0') ?? 0;
              return bVotes.compareTo(aVotes);
            });

            // 1. Filter internal duplicates (API often returns same station 4 times)
            // We do this by keeping only the first (most popular) occurrence of each name
            final seenNames = <String>{};
            final uniquePreviewRadios = <dynamic>[];

            for (final s in raw) {
              final sName = (s['name']?.toString() ?? '').toLowerCase().trim();
              if (sName.isNotEmpty && !seenNames.contains(sName)) {
                seenNames.add(sName);
                uniquePreviewRadios.add(s);
              }
              // We stop when we have enough unique ones to fill the 25 slots
              if (uniquePreviewRadios.length >= 25) break;
            }

            final finalPreview = uniquePreviewRadios;

            setState(() {
              _previewRadios = finalPreview;
              _previewCustomLogos.clear();
              _selectedPreviewRadios.clear();
              _isLoadingPreview = false;
            });

            // Start an async background task to find missing logos
            _autoFetchMissingLogos();
          }
          break;
        }
      }
    } catch (_) {}
    if (mounted && _isLoadingPreview) {
      setState(() => _isLoadingPreview = false);
    }
  }

  void _togglePreviewSelection(dynamic data) {
    setState(() {
      if (_selectedPreviewRadios.contains(data)) {
        _selectedPreviewRadios.remove(data);
      } else {
        _selectedPreviewRadios.add(data);
      }
    });
  }

  Future<void> _addStationToProvider(
    dynamic data,
    String? customLogo,
    bool isFavorite,
  ) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);

    final name = data['name'] ?? 'Unknown Radio';
    final url = data['url_resolved'] ?? data['url'] ?? '';
    final genre = (data['tags'] ?? '').toString().replaceAll(',', ' | ');
    final String? apiIcon = data['favicon'];

    // Log the click count and votes as requested
    final clicks = data['clickcount']?.toString() ?? '0';
    final votes = data['votes']?.toString() ?? '0';
    LogService().log(
      "Station Inserted: $name (Clicks: $clicks, Votes: $votes)",
    );

    // Priority: Custom -> API -> Genre Generated
    String? finalLogo = customLogo;
    if ((finalLogo == null || finalLogo.isEmpty) &&
        (apiIcon != null && apiIcon.isNotEmpty)) {
      finalLogo = apiIcon;
    }
    if (finalLogo == null || finalLogo.isEmpty) {
      final splitted = genre.split('|');
      if (splitted.isNotEmpty) {
        finalLogo = GenreMapper.getGenreImage(splitted.first.trim());
      }
    }

    // EXTRACT COLOR (Async)
    String finalColor = '0xFFFFFFFF';
    if (finalLogo != null && finalLogo.isNotEmpty) {
      finalColor = await _extractColor(finalLogo);
    }

    // Check Duplicates in Provider
    final existingIndex = provider.stations.indexWhere(
      (s) => s.name.toLowerCase() == name.toLowerCase(),
    );

    // Determine Category: Selection -> Device Locale -> Default
    String? effectiveCode = _selectedCountryCode;
    if (effectiveCode == null) {
      try {
        final locale = Platform.localeName;
        if (locale.contains('_')) {
          effectiveCode = locale.split('_')[1].toUpperCase();
        } else if (locale.length == 2) {
          effectiveCode = locale.toUpperCase();
        }
      } catch (_) {}
    }

    String category = 'International';
    if (effectiveCode != null && _countryMap.containsKey(effectiveCode)) {
      category = _countryMap[effectiveCode]!;
    } else if (data['country'] != null &&
        data['country'].toString().isNotEmpty) {
      category = data['country'].toString();
    }

    final newStation = Station(
      id: existingIndex != -1
          ? provider.stations[existingIndex].id
          : DateTime.now().millisecondsSinceEpoch + name.hashCode,
      name: name,
      url: url,
      genre: genre.isNotEmpty ? genre : 'Pop',
      logo: finalLogo,
      category: category,
      color: finalColor,
      icon: 'radio',
    );

    if (existingIndex != -1) {
      await provider.editStation(newStation);
    } else {
      await provider.addStation(newStation);
    }

    // Handle Favorites
    if (isFavorite) {
      if (!provider.favorites.contains(newStation.id)) {
        provider.toggleFavorite(newStation.id);
      }
    }
  }

  Map<String, String> get _countryMap {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    return {
      "ALL": langProvider.translate('country_ALL'),
      "IT": langProvider.translate('country_IT'),
      "US": langProvider.translate('country_US'),
      "GB": langProvider.translate('country_GB'),
      "FR": langProvider.translate('country_FR'),
      "DE": langProvider.translate('country_DE'),
      "ES": langProvider.translate('country_ES'),
      "CA": langProvider.translate('country_CA'),
      "AU": langProvider.translate('country_AU'),
      "BR": langProvider.translate('country_BR'),
      "JP": langProvider.translate('country_JP'),
      "RU": langProvider.translate('country_RU'),
      "CN": langProvider.translate('country_CN'),
      "IN": langProvider.translate('country_IN'),
      "MX": langProvider.translate('country_MX'),
      "AR": langProvider.translate('country_AR'),
      "NL": langProvider.translate('country_NL'),
      "BE": langProvider.translate('country_BE'),
      "CH": langProvider.translate('country_CH'),
      "SE": langProvider.translate('country_SE'),
      "NO": langProvider.translate('country_NO'),
      "DK": langProvider.translate('country_DK'),
      "FI": langProvider.translate('country_FI'),
      "PL": langProvider.translate('country_PL'),
      "AT": langProvider.translate('country_AT'),
      "PT": langProvider.translate('country_PT'),
      "GR": langProvider.translate('country_GR'),
      "TR": langProvider.translate('country_TR'),
      "ZA": langProvider.translate('country_ZA'),
      "KR": langProvider.translate('country_KR'),
      "IE": langProvider.translate('country_IE'),
      "NZ": langProvider.translate('country_NZ'),
      "MA": langProvider.translate('country_MA'),
    };
  }

  String _getFlag(String countryCode) {
    return countryCode.toUpperCase().replaceAllMapped(
      RegExp(r'[A-Z]'),
      (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) + 127397),
    );
  }

  void _scanRadios() async {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    setState(() {
      _isLoading = true;
      _step = 1;
      _searchResults = [];
      _selectedIndices.clear();
      _favoriteIndices.clear();
      _customLogos.clear();
    });

    // Make sure preview reflects selected country
    _loadPreviewRadios(_selectedCountryCode);

    try {
      List<dynamic> stations = [];
      // Try servers de1 to de5
      for (int i = 1; i <= 5; i++) {
        final server = "de$i.api.radio-browser.info";
        final Uri url;

        if (_selectedCountryCode == "ALL") {
          // Top Global
          url = Uri.parse(
            "https://$server/json/stations/search?limit=100&order=clickcount&reverse=true",
          );
        } else {
          // Top by Country
          url = Uri.parse(
            "https://$server/json/stations/search?countrycode=${_selectedCountryCode!.toLowerCase()}&order=clickcount&reverse=true",
          );
        }

        try {
          final response = await http
              .get(url)
              .timeout(const Duration(seconds: 4));

          if (response.statusCode == 200) {
            final List<dynamic> rawStations = json.decode(response.body);
            final seenUuids = <String>{};
            final seenUrls = <String>{};
            stations = [];
            for (final s in rawStations) {
              final uuid = s['stationuuid']?.toString();
              final String url = (s['url_resolved'] ?? s['url'] ?? '')
                  .toString();
              final int bitrate = s['bitrate'] ?? 0;

              if (uuid != null &&
                  url.isNotEmpty &&
                  !seenUuids.contains(uuid) &&
                  !seenUrls.contains(url) &&
                  bitrate > 0) {
                seenUuids.add(uuid);
                seenUrls.add(url);
                stations.add(s);
              }
            }
            // Explicitly sort memory by clickcount then votes
            stations.sort((a, b) {
              final aClicks =
                  int.tryParse(a['clickcount']?.toString() ?? '0') ?? 0;
              final bClicks =
                  int.tryParse(b['clickcount']?.toString() ?? '0') ?? 0;
              int comp = bClicks.compareTo(aClicks);
              if (comp != 0) return comp;
              final aVotes = int.tryParse(a['votes']?.toString() ?? '0') ?? 0;
              final bVotes = int.tryParse(b['votes']?.toString() ?? '0') ?? 0;
              return bVotes.compareTo(aVotes);
            });
            break;
          }
        } catch (_) {}
      }

      if (mounted) {
        // Synchronize with existing stations
        final provider = Provider.of<RadioProvider>(context, listen: false);
        final existingStations = provider.stations;
        // Remove stations that are already present in the provider
        stations.removeWhere((s) {
          final sName = (s['name']?.toString() ?? '').toLowerCase();
          return existingStations.any((e) => e.name.toLowerCase() == sName);
        });

        // We no longer need to sync selection for existing ones because they are removed.
        // We only show NEW stations.

        // We only show NEW stations.

        setState(() {
          _searchResults = stations;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              langProvider
                  .translate('error_searching')
                  .replaceAll('{0}', e.toString()),
            ),
          ),
        );
      }
    }
  }

  Future<String?> _fetchFirstLogo(dynamic station) async {
    if (station == null) return null;

    final String name = (station['name']?.toString() ?? '').trim();
    final String homepage = (station['homepage']?.toString() ?? '').trim();
    final String country = (station['country']?.toString() ?? '').trim();

    if (name.isEmpty) return null;

    // 1. Google Favicon Service (Highest Accuracy for Radios with websites)
    if (homepage.isNotEmpty && homepage.startsWith('http')) {
      try {
        final uri = Uri.parse(homepage);
        // Returns a 256x256 icon extracted from the official website
        return "https://www.google.com/s2/favicons?sz=256&domain_url=${uri.host}";
      } catch (_) {}
    }

    // Prepare refined search query
    String searchQuery = name;
    if (!searchQuery.toLowerCase().contains('radio')) {
      searchQuery += " Radio";
    }
    if (country.isNotEmpty &&
        !searchQuery.toLowerCase().contains(country.toLowerCase())) {
      searchQuery += " $country";
    }

    try {
      // 2. iTunes Search API (Highest quality for media/radio logos)
      try {
        final itunesUri = Uri.parse(
          "https://itunes.apple.com/search?term=${Uri.encodeComponent(searchQuery)}&media=podcast&entity=podcast&limit=1",
        );
        final itunesResp = await http
            .get(itunesUri)
            .timeout(const Duration(seconds: 3));
        if (itunesResp.statusCode == 200) {
          final data = json.decode(itunesResp.body);
          final results = data['results'] as List?;
          if (results != null && results.isNotEmpty) {
            final logo =
                results[0]['artworkUrl600'] ?? results[0]['artworkUrl100'];
            if (logo != null) return logo.toString();
          }
        }
      } catch (_) {}

      // 3. Clearbit (Company Logos)
      try {
        final resp = await http
            .get(
              Uri.parse(
                "https://autocomplete.clearbit.com/v1/companies/suggest?query=${Uri.encodeComponent(name)}",
              ),
            )
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          final List data = json.decode(resp.body);
          for (var item in data) {
            final companyName = (item['name']?.toString() ?? '').toLowerCase();
            // Basic verification: does it match our station name?
            if (companyName.contains(name.toLowerCase()) ||
                name.toLowerCase().contains(companyName)) {
              final logo = item['logo']?.toString() ?? "";
              if (logo.isNotEmpty) return logo;
            }
          }
        }
      } catch (_) {}

      // 4. Fallback to Bing Proxy with refined query
      final base = "https://tse2.mm.bing.net/th";
      final params = "&w=500&h=500&c=7&rs=1&p=0";
      return "$base?q=${Uri.encodeComponent("$searchQuery logo")}$params";
    } catch (_) {
      return null;
    }
  }

  void _autoFetchMissingLogos() async {
    // Traverse preview radios, find a high-quality logo
    for (final s in _previewRadios) {
      if (!mounted) break;

      // We always try to find a BETTER logo for Top Radios to ensure high quality
      if (_previewCustomLogos[s] == null) {
        final fetchedLogo = await _fetchFirstLogo(s);
        if (fetchedLogo != null && fetchedLogo.isNotEmpty && mounted) {
          setState(() {
            _previewCustomLogos[s] = fetchedLogo;
          });
        }
      }
    }
  }

  Future<void> _searchAndShowLogos({
    int? index,
    dynamic previewStation,
    required dynamic station,
  }) async {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);

    final String name = (station['name']?.toString() ?? '').trim();
    final String country = (station['country']?.toString() ?? '').trim();

    if (name.isEmpty) return;

    // Refined query for better accuracy
    String searchQuery = name;
    if (!searchQuery.toLowerCase().contains('radio')) {
      searchQuery += " Radio";
    }
    if (country.isNotEmpty &&
        !searchQuery.toLowerCase().contains(country.toLowerCase())) {
      searchQuery += " $country";
    }

    // Show simple loading dialog
    GlassUtils.showGlassDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final Set<String> imageUrls = {};

      Future<void> safeFetch(Future<List<String>> Function() fetcher) async {
        try {
          final results = await fetcher();
          imageUrls.addAll(results);
        } catch (_) {}
      }

      await Future.wait([
        safeFetch(() async {
          final uri = Uri.parse(
            "https://itunes.apple.com/search?term=${Uri.encodeComponent(searchQuery)}&media=podcast&entity=podcast&limit=10",
          );
          final resp = await http.get(uri).timeout(const Duration(seconds: 4));
          if (resp.statusCode == 200) {
            final data = json.decode(resp.body);
            return (data['results'] as List?)
                    ?.map(
                      (e) =>
                          (e['artworkUrl600'] ?? e['artworkUrl100'])
                              ?.toString() ??
                          "",
                    )
                    .where((s) => s.isNotEmpty)
                    .toList() ??
                [];
          }
          return [];
        }),
        safeFetch(() async {
          final resp = await http
              .get(
                Uri.parse(
                  "https://autocomplete.clearbit.com/v1/companies/suggest?query=${Uri.encodeComponent(name)}",
                ),
              )
              .timeout(const Duration(seconds: 4));
          if (resp.statusCode == 200) {
            final List data = json.decode(resp.body);
            return data
                .map((e) => e['logo']?.toString() ?? "")
                .where((s) => s.isNotEmpty)
                .toList();
          }
          return [];
        }),
        safeFetch(() async {
          // Bing Proxy
          final base = "https://tse2.mm.bing.net/th";
          final params = "&w=500&h=500&c=7&rs=1&p=0";
          String makeUrl(String q) =>
              "$base?q=${Uri.encodeComponent(q)}$params";
          return [
            makeUrl("$searchQuery logo"),
            makeUrl(searchQuery),
            makeUrl("$name station logo"),
          ];
        }),
      ]);

      if (!mounted) return;
      // Pop loading
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      if (imageUrls.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(langProvider.translate('no_logos_found'))),
        );
        return;
      }

      // Show Selection Dialog
      final selected = await GlassUtils.showGlassDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(
            langProvider.translate('select_logo_for').replaceAll('{0}', name),
            style: TextStyle(
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: imageUrls.length,
              itemBuilder: (c, i) {
                final url = imageUrls.elementAt(i);
                return GestureDetector(
                  onTap: () => Navigator.pop(c, url),
                  child: Image.network(url, fit: BoxFit.cover),
                );
              },
            ),
          ),
        ),
      );

      if (selected != null) {
        setState(() {
          if (index != null) {
            _customLogos[index] = selected;
          } else if (previewStation != null) {
            _previewCustomLogos[previewStation] = selected;
          }
        });
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context); // Pop loading if error
      }
    }
  }

  Future<void> _testStream(String url) async {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    if (_testingUrl == url) return; // Already testing

    setState(() {
      _testingUrl = url;
      _testResults[url] = null; // Reset result
    });

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 3));

      if (response.statusCode >= 200 && response.statusCode < 400) {
        if (mounted) {
          setState(() {
            _testResults[url] = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(langProvider.translate('stream_valid')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        throw Exception("Status code: ${response.statusCode}");
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testResults[url] = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              langProvider
                  .translate('stream_verify_failed')
                  .replaceAll('{0}', e.toString()),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      client.close();
      if (mounted) {
        setState(() {
          _testingUrl = null;
        });
      }
    }
  }

  Future<String> _extractColor(String? logoUrl) async {
    if (logoUrl == null || logoUrl.isEmpty) return '0xFFFFFFFF';
    try {
      ImageProvider imageProvider;
      if (logoUrl.startsWith('http')) {
        imageProvider = NetworkImage(logoUrl);
      } else {
        imageProvider = AssetImage(logoUrl);
      }

      // PaletteGenerator must be imported at top level
      final palette = await PaletteGenerator.fromImageProvider(
        imageProvider,
        maximumColorCount: 20,
      ).timeout(const Duration(milliseconds: 1500));
      // Timeout to avoid hanging too long on one image

      final extracted =
          palette.dominantColor?.color ??
          palette.vibrantColor?.color ??
          palette.lightVibrantColor?.color ??
          palette.darkVibrantColor?.color;

      if (extracted != null) {
        return '0xff${extracted.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
      }
    } catch (_) {}
    return '0xFFFFFFFF';
  }

  void _finish() async {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);

    int count = 0;

    // Show loading
    setState(() => _isLoading = true);

    try {
      // 1. Process Main Search Selections
      for (int i = 0; i < _searchResults.length; i++) {
        if (_selectedIndices[i] == true) {
          final data = _searchResults[i];
          await _addStationToProvider(
            data,
            _customLogos[i],
            _favoriteIndices[i] == true,
          );
          count++;
        }
      }

      // 2. Process Preview Selections
      for (final previewData in _selectedPreviewRadios) {
        // Apply custom logo if set, set as favorite by default as requested
        final String? customLogo = _previewCustomLogos[previewData];
        await _addStationToProvider(previewData, customLogo, true);
        count++;
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            langProvider
                .translate('processed_count')
                .replaceAll('{0}', count.toString()),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    int totalSelected =
        _selectedIndices.values.where((v) => v).length +
        _selectedPreviewRadios.length;

    return Column(
      children: [
        _buildTopRadiosCarousel(),
        Expanded(
          child: _step == 0 ? _buildCountrySelection() : _buildRadioSelection(),
        ),
        if (totalSelected > 0) _buildFooter(totalSelected),
      ],
    );
  }

  Widget _buildCountrySelection() {
    final langProvider = Provider.of<LanguageProvider>(context);

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 600),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.public, size: 48, color: Colors.blueAccent),
            const SizedBox(height: 12),
            Text(
              langProvider.translate('wizard_welcome'),
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              langProvider.translate('wizard_desc'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(
                  context,
                ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  ...() {
                    // 1. Convert to list and sort alphabetically by Name
                    final entries = _countryMap.entries.toList()
                      ..sort((a, b) => a.value.compareTo(b.value));

                    // 2. Detect Device Country
                    String? deviceCode;
                    try {
                      final locale = Platform.localeName; // e.g. en_US
                      if (locale.contains('_')) {
                        final parts = locale.split('_');
                        if (parts.length > 1) {
                          deviceCode = parts[1].toUpperCase();
                        }
                      }
                    } catch (_) {}

                    // 3. Separate Device Country from list
                    MapEntry<String, String>? deviceEntry;
                    if (deviceCode != null) {
                      final index = entries.indexWhere(
                        (e) => e.key == deviceCode,
                      );
                      if (index != -1) {
                        deviceEntry = entries.removeAt(index);
                      }
                    }

                    // 4. Build List
                    final List<Widget> children = [];

                    // Add Device Country (if found)
                    if (deviceEntry != null) {
                      children.add(
                        _buildCountryTile(deviceEntry.key, deviceEntry.value),
                      );
                      children.add(
                        Divider(
                          color: Theme.of(context).dividerColor,
                          height: 16,
                        ),
                      ); // Separator
                    }

                    // Add Rest
                    children.addAll(
                      entries.map((e) => _buildCountryTile(e.key, e.value)),
                    );

                    return children;
                  }(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountryTile(String code, String name) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      leading: Text(
        code == "ALL" ? "🌍" : _getFlag(code),
        style: const TextStyle(fontSize: 22),
      ),
      title: Text(
        name,
        style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
      ),
      trailing: Icon(
        Icons.arrow_forward_ios,
        size: 14,
        color: Theme.of(
          context,
        ).textTheme.bodySmall?.color?.withValues(alpha: 0.3),
      ),
      onTap: () {
        setState(() {
          _selectedCountryCode = code;
        });
        _scanRadios();
      },
    );
  }

  Widget _buildRadioSelection() {
    final langProvider = Provider.of<LanguageProvider>(context);

    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(langProvider.translate('scanning_freq')),
          ],
        ),
      );
    }

    // Filter results preserving original indices
    final filteredStations = _searchResults.asMap().entries.where((entry) {
      final index = entry.key;
      final matchesSearch = (entry.value['name']?.toString() ?? '')
          .toLowerCase()
          .contains(_searchQuery.toLowerCase());
      final isSelected = _selectedIndices[index] ?? false;

      if (_showSelectedOnly && !isSelected) return false;
      return matchesSearch;
    }).toList();

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, size: 20),
                    onPressed: () {
                      setState(() {
                        _step = 0;
                        _searchResults = [];
                        _selectedIndices.clear();
                        _favoriteIndices.clear();
                        _customLogos.clear();
                        _searchQuery = '';
                      });
                    },
                    tooltip: langProvider.translate('back'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${langProvider.translate('results_for')} ${_countryMap[_selectedCountryCode] ?? ''}",
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          "${filteredStations.length} ${langProvider.translate('stations_found')}",
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Search Bar & Filter
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: langProvider.translate('search_station'),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Theme.of(context).cardColor,
                      ),
                      style: const TextStyle(fontSize: 14),
                      onChanged: (val) {
                        setState(() {
                          _searchQuery = val;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(
                      _showSelectedOnly
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                      color: _showSelectedOnly
                          ? Theme.of(context).primaryColor
                          : Theme.of(
                              context,
                            ).iconTheme.color?.withValues(alpha: 0.54),
                    ),
                    tooltip: langProvider.translate('show_selected'),
                    onPressed: () {
                      setState(() {
                        _showSelectedOnly = !_showSelectedOnly;
                      });
                    },
                    style: IconButton.styleFrom(
                      backgroundColor: Theme.of(context).cardColor,
                      padding: const EdgeInsets.all(12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            primary: false, // Prevent conflict
            padding: const EdgeInsets.only(bottom: 140),
            itemCount: filteredStations.length,
            itemBuilder: (context, i) {
              final entry = filteredStations[i];
              final index = entry.key; // Original Index
              final station = entry.value;
              final isSelected = _selectedIndices[index] ?? false;
              final isFavorite = _favoriteIndices[index] ?? false;
              final customLogo = _customLogos[index];
              final apiLogo = station['favicon'];

              return RepaintBoundary(
                child: Card(
                  key: ValueKey(station['stationuuid'] ?? index),
                  color: isSelected
                      ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
                      : Colors.transparent,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        leading: Checkbox(
                          value: isSelected,
                          onChanged: (v) {
                            setState(() {
                              _selectedIndices[index] = v ?? false;
                              // Auto-favorite if selected (user convenience, optional)
                              if (v == true) _favoriteIndices[index] = true;
                            });
                          },
                        ),
                        title: Text(
                          station['name'] ?? langProvider.translate('unknown'),
                          style: TextStyle(
                            color: isSelected
                                ? Theme.of(context).primaryColor
                                : Theme.of(context).textTheme.bodyLarge?.color,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "${station['bitrate'] ?? 0} Kbps",
                              style: TextStyle(
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color
                                    ?.withValues(alpha: 0.7),
                                fontSize: 11,
                              ),
                            ),
                            if (isSelected) ...[
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Logo Preview
                                  Container(
                                    width: 24,
                                    height: 24,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.black,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child:
                                        (customLogo != null ||
                                            (apiLogo != null &&
                                                apiLogo.toString().isNotEmpty))
                                        ? Image.network(
                                            customLogo ?? apiLogo,
                                            errorBuilder:
                                                (context, error, stackTrace) =>
                                                    const Icon(
                                                      Icons.radio,
                                                      size: 12,
                                                    ),
                                          )
                                        : const Icon(Icons.radio, size: 12),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _searchAndShowLogos(
                                      index: index,
                                      station: station,
                                    ),
                                    icon: const Icon(
                                      Icons.image_search,
                                      size: 16,
                                    ),
                                    label: Text(
                                      langProvider.translate('logo'),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(60, 30),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isSelected)
                              IconButton(
                                icon: Icon(
                                  isFavorite
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: isFavorite
                                      ? Colors.redAccent
                                      : Theme.of(context).disabledColor,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _favoriteIndices[index] = !isFavorite;
                                  });
                                },
                              ),
                            // Stream Check Button
                            if (_testingUrl ==
                                (station['url_resolved'] ?? station['url']))
                              Container(
                                width: 36,
                                height: 36,
                                padding: const EdgeInsets.all(8),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).primaryColor,
                                ),
                              )
                            else
                              IconButton(
                                icon: Icon(
                                  _testResults[station['url_resolved'] ??
                                              station['url']] ==
                                          true
                                      ? Icons.check_circle
                                      : _testResults[station['url_resolved'] ??
                                                station['url']] ==
                                            false
                                      ? Icons.error
                                      : Icons.network_check,
                                  color:
                                      _testResults[station['url_resolved'] ??
                                              station['url']] ==
                                          true
                                      ? Colors.green
                                      : _testResults[station['url_resolved'] ??
                                                station['url']] ==
                                            false
                                      ? Colors.red
                                      : Theme.of(context).primaryColor,
                                ),
                                onPressed: () {
                                  final url =
                                      station['url_resolved'] ??
                                      station['url'] ??
                                      '';
                                  if (url.isNotEmpty) {
                                    _testStream(url);
                                  }
                                },
                                tooltip: langProvider.translate(
                                  'test_connection',
                                ),
                              ),
                          ],
                        ),
                        onTap: () {
                          setState(() {
                            _selectedIndices[index] = !isSelected;
                            if (!isSelected) _favoriteIndices[index] = true;
                          });
                        },
                      ),
                      if ((station['url_resolved'] ?? station['url']) != null)
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 16,
                            right: 16,
                            bottom: 8,
                          ),
                          child: Text(
                            (station['url_resolved'] ?? station['url'])
                                .toString(),
                            style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color
                                  ?.withValues(alpha: 0.5),
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTopRadiosCarousel() {
    final langProvider = Provider.of<LanguageProvider>(context);

    if (_isLoadingPreview) {
      return Container(
        height: 140,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    }

    if (_previewRadios.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 180,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              langProvider.translate('top_radios'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _previewRadios.length,
              itemBuilder: (context, index) {
                final station = _previewRadios[index];
                return _buildPreviewCard(station);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard(dynamic station) {
    if (station == null) return const SizedBox.shrink();
    final isSelected = _selectedPreviewRadios.contains(station);
    final customLogo = _previewCustomLogos[station];
    final displayLogo = customLogo ?? station['favicon'];

    return GestureDetector(
      onTap: () => _togglePreviewSelection(station),
      child: Container(
        width: 120,
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
              : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: Theme.of(context).primaryColor, width: 2)
              : Border.all(color: Colors.transparent, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child:
                        (displayLogo != null &&
                            displayLogo.toString().isNotEmpty)
                        ? Image.network(
                            displayLogo,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(Icons.radio, size: 40),
                          )
                        : const Icon(Icons.radio, size: 40),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                    station['name'] ?? 'Unknown',
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
            if (isSelected)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.favorite,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            Positioned(
              top: 4,
              left: 4,
              child: GestureDetector(
                onTap: () => _searchAndShowLogos(
                  previewStation: station,
                  station: station,
                ),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.image_search,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(int selectedCount) {
    final langProvider = Provider.of<LanguageProvider>(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.9),
      child: SizedBox(
        width: double.infinity,
        height: 40,
        child: ElevatedButton.icon(
          onPressed: selectedCount > 0 ? _finish : null,
          icon: const Icon(Icons.check, size: 18),
          label: Text(
            selectedCount > 0
                ? langProvider
                      .translate('create_n_stations')
                      .replaceAll('{0}', selectedCount.toString())
                : langProvider.translate('create_stations'),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Theme.of(
              context,
            ).primaryColor.withValues(alpha: 0.3),
            disabledForegroundColor: Colors.white38,
            elevation: 0,
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
