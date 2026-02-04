import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:palette_generator/palette_generator.dart';
import 'dart:convert';
import 'dart:io';

import '../providers/radio_provider.dart';
import '../models/station.dart';
import '../utils/genre_mapper.dart';

class TutorialCreateRadioWizard extends StatefulWidget {
  const TutorialCreateRadioWizard({super.key});

  @override
  State<TutorialCreateRadioWizard> createState() =>
      _TutorialCreateRadioWizardState();
}

class _TutorialCreateRadioWizardState extends State<TutorialCreateRadioWizard> {
  @override
  void dispose() {
    super.dispose();
  }

  int _step = 0; // 0: Country Selection, 1: Search & Select
  String? _selectedCountryCode;
  String? _selectedCountryName;
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

  String _getFlag(String countryCode) {
    return countryCode.toUpperCase().replaceAllMapped(
      RegExp(r'[A-Z]'),
      (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) + 127397),
    );
  }

  void _scanRadios() async {
    setState(() {
      _isLoading = true;
      _step = 1;
      _searchResults = [];
      _selectedIndices.clear();
      _favoriteIndices.clear();
      _customLogos.clear();
    });

    try {
      List<dynamic> stations = [];
      // Try servers de1 to de5
      for (int i = 1; i <= 5; i++) {
        final server = "de$i.api.radio-browser.info";
        final Uri url;

        if (_selectedCountryCode == "ALL") {
          // Top Clicked Global
          url = Uri.parse(
            "https://$server/json/stations/search?limit=100&order=clickcount&reverse=true",
          );
        } else {
          // Top Clicked by Country
          // limit increased to show ample options
          url = Uri.parse(
            //"https://$server/json/stations/search?countrycode=${_selectedCountryCode!.toLowerCase()}&limit=500&order=clickcount&reverse=true",
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
            stations.sort(
              (a, b) => (a['name']?.toString() ?? '').toLowerCase().compareTo(
                (b['name']?.toString() ?? '').toLowerCase(),
              ),
            );
            break;
          }
        } catch (_) {}
      }

      if (mounted) {
        // Synchronize with existing stations
        final provider = Provider.of<RadioProvider>(context, listen: false);
        final existingStations = provider.stations;
        // final favorites = provider.favorites; // No longer needed if we exclude them

        // Remove stations that are already present in the provider
        stations.removeWhere((s) {
          final sName = (s['name']?.toString() ?? '').toLowerCase();
          return existingStations.any((e) => e.name.toLowerCase() == sName);
        });

        // We no longer need to sync selection for existing ones because they are removed.
        // We only show NEW stations.

        /* 
        // OLD LOGIC: Mark existing as selected
        for (int i = 0; i < stations.length; i++) {
           ...
        }
        */

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error searching radios: $e")));
      }
    }
  }

  Future<void> _searchAndShowLogos(int index, String query) async {
    // Reusing logo search logic - simplified for this widget
    if (query.isEmpty) return;

    // Show simple loading dialog
    showDialog(
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
            "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&media=podcast&entity=podcast&limit=5",
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
                  "https://autocomplete.clearbit.com/v1/companies/suggest?query=${Uri.encodeComponent(query)}",
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
            makeUrl("$query logo"),
            makeUrl("$query radio station"),
            makeUrl(query),
          ];
        }),
      ]);

      if (!mounted) {
        if (Navigator.canPop(context)) Navigator.pop(context);
        return;
      }
      // Pop loading
      Navigator.pop(context);

      if (imageUrls.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("No logos found")));
        return;
      }

      // Show Selection Dialog
      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: Text(
            "Select Logo for $query",
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
          _customLogos[index] = selected;
        });
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context))
        Navigator.pop(context); // Pop loading if error
    }
  }

  Future<void> _testStream(String url) async {
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
            const SnackBar(
              backgroundColor: Colors.green,
              content: Text("Success: Stream is valid!"),
              duration: Duration(seconds: 2),
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
            backgroundColor: Colors.red,
            content: Text("Stream verify failed: $e"),
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
        return '0xff${extracted.value.toRadixString(16).substring(2).toUpperCase()}';
      }
    } catch (_) {}
    return '0xFFFFFFFF';
  }

  void _finish() async {
    final provider = Provider.of<RadioProvider>(context, listen: false);

    int count = 0;

    // Show loading
    setState(() => _isLoading = true);

    try {
      for (int i = 0; i < _searchResults.length; i++) {
        if (_selectedIndices[i] == true) {
          final data = _searchResults[i];
          final name = data['name'] ?? 'Unknown Radio';
          final url = data['url_resolved'] ?? data['url'] ?? '';
          final genre = (data['tags'] ?? '').toString().replaceAll(',', ' | ');
          final String? customLogo = _customLogos[i];
          final String? apiIcon = data['favicon'];

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

          final newStation = Station(
            id: existingIndex != -1
                ? provider.stations[existingIndex].id
                : DateTime.now().millisecondsSinceEpoch + i,
            name: name,
            url: url,
            genre: genre.isNotEmpty ? genre : 'Pop',
            logo: finalLogo,
            category: _selectedCountryName ?? 'International',
            color: finalColor,
            icon: 'radio',
          );

          if (existingIndex != -1) {
            await provider.editStation(newStation);
          } else {
            await provider.addStation(newStation);
          }

          // Handle Favorites
          if (_favoriteIndices[i] == true) {
            if (!provider.favorites.contains(newStation.id)) {
              provider.toggleFavorite(newStation.id);
            }
          }
          count++;
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Processed $count stations!")));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_step == 0) return _buildCountrySelection();
    return _buildRadioSelection();
  }

  Widget _buildCountrySelection() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 600),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.public, size: 64, color: Colors.blueAccent),
            const SizedBox(height: 16),
            Text(
              "Welcome! Let's set up your radio.",
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              "Allows you to choose your preferred region to find the best stations.",
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 120),
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
                        const Divider(color: Colors.white24, height: 32),
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
      leading: Text(
        code == "ALL" ? "🌍" : _getFlag(code),
        style: const TextStyle(fontSize: 24),
      ),
      title: Text(name, style: const TextStyle(color: Colors.white)),
      trailing: const Icon(
        Icons.arrow_forward_ios,
        size: 16,
        color: Colors.white24,
      ),
      onTap: () {
        setState(() {
          _selectedCountryCode = code;
          _selectedCountryName = name;
        });
        _scanRadios();
      },
    );
  }

  Widget _buildRadioSelection() {
    final selectedCount = _selectedIndices.values
        .where((selected) => selected)
        .length;
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text("Scanning frequencies..."),
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
                    tooltip: "Back",
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Results for $_selectedCountryName",
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          "${filteredStations.length} stations found",
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
                        hintText: "Search station...",
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
                          : Colors.white54,
                    ),
                    tooltip: "Show selected only",
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
                          station['name'] ?? "Unknown",
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white70,
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
                                            errorBuilder: (_, __, ___) =>
                                                const Icon(
                                                  Icons.radio,
                                                  size: 12,
                                                ),
                                          )
                                        : const Icon(Icons.radio, size: 12),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _searchAndShowLogos(
                                      index,
                                      station['name'] ?? "",
                                    ),
                                    icon: const Icon(
                                      Icons.image_search,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      "Logo",
                                      style: TextStyle(fontSize: 12),
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
                                      : Colors.white38,
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
                                tooltip: "Test Connection",
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
        // Sticky Bottom Footer
        _buildFooter(selectedCount),
        // Sticky Bottom Footer
      ],
    );
  }

  Widget _buildFooter(int selectedCount) {
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
                ? "Create $selectedCount Stations"
                : "Create Stations",
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
