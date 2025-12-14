import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io'; // Added for Platform.localeName
import 'package:audioplayers/audioplayers.dart';
import '../models/station.dart';
import '../providers/radio_provider.dart';
import '../utils/genre_mapper.dart';

class EditStationScreen extends StatefulWidget {
  final Station? station; // null for new station

  const EditStationScreen({super.key, this.station});

  @override
  State<EditStationScreen> createState() => _EditStationScreenState();
}

class _EditStationScreenState extends State<EditStationScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameController;
  late TextEditingController _urlController;
  late TextEditingController _logoController;
  late TextEditingController _colorController;

  // Custom State for complex fields
  List<String> _selectedGenres = [];
  String? _selectedCategory; // Single selection
  String _selectedSearchCountry =
      "ALL"; // Default to global, will update in initState
  bool _isSearching = false;
  bool _isTestingLink = false;
  String? _deviceCountryCode;

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

  Future<void> _testStreamUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Please enter a URL first")));
      return;
    }

    setState(() => _isTestingLink = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Testing stream... (Playing for 3s)")),
    );

    final player = AudioPlayer();
    try {
      await player.setSourceUrl(url);
      await player.setVolume(1.0);
      await player.resume();

      await Future.delayed(const Duration(seconds: 3));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.green,
            content: Text("Success: Stream is working!"),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red,
            content: Text("Error: Cannot play stream.\n$e"),
          ),
        );
      }
    } finally {
      try {
        await player.stop();
        await player.dispose();
      } catch (_) {}
      if (mounted) setState(() => _isTestingLink = false);
    }
  }

  final List<Color> _colorPalette = [
    Colors.red,
    Colors.redAccent,
    Colors.pink,
    Colors.pinkAccent,
    Colors.purple,
    Colors.purpleAccent,
    Colors.deepPurple,
    Colors.deepPurpleAccent,
    Colors.indigo,
    Colors.indigoAccent,
    Colors.blue,
    Colors.blueAccent,
    Colors.lightBlue,
    Colors.lightBlueAccent,
    Colors.cyan,
    Colors.cyanAccent,
    Colors.teal,
    Colors.tealAccent,
    Colors.green,
    Colors.greenAccent,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.grey,
    Colors.blueGrey,
    const Color(0xFF000000),
    const Color(0xFFFFFFFF),
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.station?.name ?? '');
    _urlController = TextEditingController(text: widget.station?.url ?? '');
    _logoController = TextEditingController(text: widget.station?.logo ?? '');

    // Listen to updates for preview
    _logoController.addListener(() => setState(() {}));

    // Color Init
    String initialColor =
        widget.station?.color.replaceFirst('0xff', '#') ?? '#ffffff';
    // Ensure it starts with # if not present
    if (!initialColor.startsWith('#')) initialColor = '#$initialColor';
    _colorController = TextEditingController(text: initialColor);

    // Genre Init
    if (widget.station?.genre != null && widget.station!.genre.isNotEmpty) {
      _selectedGenres = widget.station!.genre
          .split('|')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    // Category Init (Single selection)
    if (widget.station?.category != null &&
        widget.station!.category.isNotEmpty) {
      final split = widget.station!.category.split('|');
      if (split.isNotEmpty) {
        _selectedCategory = split.first.trim();
      }
    }

    // Detect Device Country
    try {
      final String systemLocale = Platform.localeName; // e.g., en_US
      if (systemLocale.contains('_')) {
        final parts = systemLocale.split('_');
        if (parts.length > 1) {
          final countryCode = parts[1].toUpperCase();
          if (_countryMap.containsKey(countryCode)) {
            _deviceCountryCode = countryCode;
            // Set default default to device country
            _selectedSearchCountry = countryCode;
          }
        }
      }
    } catch (_) {
      // Ignore errors, stay on ALL
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _logoController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  String _formatColor(String color) {
    color = color.trim().replaceAll('#', '');
    if (color.length == 6) {
      return '0xff$color';
    }
    return color;
  }

  Color? _getColorFromHex(String hexColor) {
    hexColor = hexColor.toUpperCase().replaceAll("#", "");
    if (hexColor.length == 6) {
      hexColor = "FF$hexColor";
    }
    if (hexColor.length == 8) {
      return Color(int.tryParse("0x$hexColor") ?? 0xFFFFFFFF);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);

    // Extract existing unique values for suggestions
    final Set<String> allGenres = {};
    final Set<String> allCategories = {};

    for (var s in provider.stations) {
      // Split genres
      s.genre.split('|').forEach((g) => allGenres.add(g.trim()));
      // s.category.split('|').forEach((c) => allCategories.add(c.trim())); // No longer split? Actually still should to find all options
      s.category.split('|').forEach((c) => allCategories.add(c.trim()));
    }
    // Add defaults if missing
    allCategories.addAll(["International", "Italian", "News", "Sports"]);
    allGenres.addAll(["Pop", "Rock", "News", "Jazz", "Classical"]);

    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        title: Text(widget.station == null ? "Add Station" : "Edit Station"),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionTitle("General Info"),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _buildTextField(
                      "Station Name",
                      _nameController,
                      Icons.radio,
                      suffix: IconButton(
                        icon: _isSearching
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.search, color: Colors.white),
                        tooltip: "Auto-complete",
                        onPressed: _isSearching ? null : _autoCompleteStation,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: Container(
                      height: 56, // Match text field height generally
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedSearchCountry,
                          isExpanded: true,
                          dropdownColor: const Color(0xFF1a1a2e),
                          style: const TextStyle(color: Colors.white),
                          icon: const Icon(Icons.public, color: Colors.white54),
                          items: () {
                            List<DropdownMenuItem<String>> items = [];

                            // 1. Device Country (if exists)
                            if (_deviceCountryCode != null &&
                                _countryMap.containsKey(_deviceCountryCode)) {
                              items.add(
                                DropdownMenuItem(
                                  value: _deviceCountryCode,
                                  child: Text(_countryMap[_deviceCountryCode]!),
                                ),
                              );
                            }

                            // 2. Global
                            items.add(
                              const DropdownMenuItem(
                                value: "ALL",
                                child: Text("Global"),
                              ),
                            );

                            // 3. Others (Sorted Alphabetically)
                            final sortedEntries = _countryMap.entries.toList()
                              ..sort((a, b) => a.value.compareTo(b.value));

                            for (var entry in sortedEntries) {
                              // Skip if it's the device country (already added at top)
                              if (entry.key == _deviceCountryCode) continue;

                              items.add(
                                DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ),
                              );
                            }
                            return items;
                          }(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _selectedSearchCountry = val);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildTextField(
                "Stream URL",
                _urlController,
                Icons.link,
                suffix: IconButton(
                  icon: _isTestingLink
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.play_circle_fill,
                          color: Colors.greenAccent,
                        ),
                  tooltip: "Test Link",
                  onPressed: _isTestingLink ? null : _testStreamUrl,
                ),
              ),

              const SizedBox(height: 32),
              _buildSectionTitle("Classification"),

              // Custom Genre Selector
              const Text(
                "Genres",
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 8),
              _buildGenreSelector(context, allGenres.toList()),

              const SizedBox(height: 24),

              // Custom Category Selector (Single Select)
              const Text(
                "Category",
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 8),
              _buildCategorySelector(context, allCategories.toList()),

              const SizedBox(height: 32),
              _buildSectionTitle("Appearance"),

              // Color Picker
              _buildColorSelector(context),
              const SizedBox(height: 24),

              _buildTextField(
                "Logo URL",
                _logoController,
                Icons.image,
                isOptional: true,
                suffix: _logoController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () {
                          setState(() {
                            _logoController.clear();
                          });
                        },
                      )
                    : null,
              ),
              const SizedBox(height: 16),

              // Preview Logic
              Builder(
                builder: (context) {
                  String? previewUrl = _logoController.text.trim();
                  if (previewUrl.isEmpty && _selectedGenres.isNotEmpty) {
                    previewUrl = GenreMapper.getGenreImage(
                      _selectedGenres.first,
                    );
                  }

                  return Center(
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white24),
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: (previewUrl != null && previewUrl.isNotEmpty)
                          ? (previewUrl.startsWith('http')
                                ? Image.network(
                                    previewUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (c, e, s) => const Icon(
                                      Icons.broken_image,
                                      color: Colors.white24,
                                      size: 40,
                                    ),
                                  )
                                : Image.asset(
                                    previewUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (c, e, s) => const Icon(
                                      Icons.image_not_supported,
                                      color: Colors.white24,
                                      size: 40,
                                    ),
                                  ))
                          : const Center(
                              child: Icon(
                                Icons.radio,
                                size: 50,
                                color: Colors.white24,
                              ),
                            ),
                    ),
                  );
                },
              ),

              // Icon selector removed
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 8,
                    shadowColor: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.5),
                  ),
                  onPressed: _save,
                  child: const Text(
                    "Save Station",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).primaryColor,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildGenreSelector(
    BuildContext context,
    List<String> availableGenres,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._selectedGenres.map(
                (g) => Chip(
                  label: Text(g),
                  backgroundColor: Theme.of(
                    context,
                  ).primaryColor.withValues(alpha: 0.2),
                  labelStyle: const TextStyle(color: Colors.white),
                  deleteIcon: const Icon(
                    Icons.close,
                    size: 16,
                    color: Colors.white70,
                  ),
                  onDeleted: () {
                    setState(() {
                      _selectedGenres.remove(g);
                      _updateLogoFromGenres();
                    });
                  },
                  side: BorderSide.none,
                ),
              ),
              ActionChip(
                label: const Text("Add +"),
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                labelStyle: const TextStyle(color: Colors.white),
                side: BorderSide.none,
                onPressed: () {
                  _showAddGenreDialog(context, availableGenres);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAddGenreDialog(BuildContext context, List<String> existing) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _GenreSelectionDialog(
        existing: existing,
        initialSelected: _selectedGenres,
      ),
    );

    if (result != null) {
      setState(() {
        _selectedGenres = result;
        _updateLogoFromGenres();
      });
    }
  }

  void _updateLogoFromGenres() {
    if (_selectedGenres.isEmpty) return;

    final currentLogo = _logoController.text.trim();
    // Update if empty OR if it's a generated pollinations image
    if (currentLogo.isEmpty || currentLogo.contains('pollinations.ai')) {
      final firstGenre = _selectedGenres.first;
      final newUrl = GenreMapper.getGenreImage(firstGenre);
      if (newUrl != null) {
        _logoController.text = newUrl;
      }
    }
  }

  Widget _buildCategorySelector(
    BuildContext context,
    List<String> availableCategories,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          if (_selectedCategory != null)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Chip(
                label: Text(_selectedCategory!),
                backgroundColor: Theme.of(
                  context,
                ).primaryColor.withValues(alpha: 0.2),
                labelStyle: const TextStyle(color: Colors.white),
                deleteIcon: const Icon(
                  Icons.edit,
                  size: 14,
                  color: Colors.white70,
                ),
                onDeleted: () {
                  _showSelectCategoryDialog(context, availableCategories);
                },
                side: BorderSide.none,
              ),
            ),
          if (_selectedCategory == null)
            ActionChip(
              label: const Text("Select Category"),
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              labelStyle: const TextStyle(color: Colors.white),
              side: BorderSide.none,
              onPressed: () {
                _showSelectCategoryDialog(context, availableCategories);
              },
            ),
        ],
      ),
    );
  }

  void _showSelectCategoryDialog(
    BuildContext context,
    List<String> existing,
  ) async {
    final result = await showDialog<Map<String, String?>>(
      context: context,
      builder: (ctx) => _CategorySelectionDialog(
        existing: existing,
        initialSelected: _selectedCategory,
      ),
    );

    if (result != null && result.containsKey('selection')) {
      setState(() {
        _selectedCategory = result['selection'];
      });
    }
  }

  Widget _buildColorSelector(BuildContext context) {
    Color currentColor =
        _getColorFromHex(_colorController.text) ?? Colors.white;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: currentColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: currentColor.withValues(alpha: 0.4),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  controller: _colorController,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    labelText: "Hex Color",
                    labelStyle: TextStyle(color: Colors.white54),
                    border: InputBorder.none,
                  ),
                  onChanged: (val) {
                    setState(() {});
                  },
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white10, height: 24),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _colorPalette.length,
            itemBuilder: (context, index) {
              final color = _colorPalette[index];
              final isSelected = color == currentColor;
              return GestureDetector(
                onTap: () {
                  String hex =
                      '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
                  _colorController.text = hex;
                  setState(() {});
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: isSelected
                        ? Border.all(color: Colors.white, width: 2)
                        : null,
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 16)
                      : null,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    IconData icon, {
    bool isOptional = false,
    Widget? suffix,
  }) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        prefixIcon: Icon(icon, color: Colors.white54),
        suffixIcon: suffix,
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.white12),
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Theme.of(context).primaryColor),
          borderRadius: BorderRadius.circular(12),
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
      ),
      validator: (val) {
        if (isOptional) return null;
        return val == null || val.isEmpty ? "Required" : null;
      },
    );
  }

  Future<void> _autoCompleteStation() async {
    final query = _nameController.text.trim();
    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a station name")),
      );
      return;
    }

    if (_isSearching) return;

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _isSearching = true);

    try {
      Uri url;

      if (_selectedSearchCountry == "ALL") {
        url = Uri.parse(
          "https://de1.api.radio-browser.info/json/stations/byname/${Uri.encodeComponent(query)}?limit=30",
        );
      } else {
        url = Uri.parse(
          "https://de1.api.radio-browser.info/json/stations/search?name=${Uri.encodeComponent(query)}&countrycode=${_selectedSearchCountry}&limit=30",
        );
      }

      List<dynamic> stations = [];
      try {
        final response = await http
            .get(url)
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          stations = json.decode(response.body);
        }
      } catch (e) {
        debugPrint("Station search exception: $e");
      }

      if (!mounted) return;

      if (stations.isNotEmpty) {
        // Filter and Sort logic
        final stationsWithImages = stations
            .where((r) => (r['favicon'] as String?)?.isNotEmpty == true)
            .toList();
        final stationsOthers = stations
            .where((r) => (r['favicon'] as String?)?.isEmpty ?? true)
            .toList();

        // Sort by bitrate to promote higher quality
        stationsWithImages.sort(
          (a, b) => (b['bitrate'] ?? 0).compareTo(a['bitrate'] ?? 0),
        );
        stationsOthers.sort(
          (a, b) => (b['bitrate'] ?? 0).compareTo(a['bitrate'] ?? 0),
        );

        final candidates = [
          ...stationsWithImages,
          ...stationsOthers,
        ].take(20).toList();

        if (candidates.isNotEmpty) {
          setState(() => _isSearching = false);
          final selected = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (ctx) => _StationSelectionDialog(stations: candidates),
          );

          if (selected != null) {
            _populateStationData(selected);
            return;
          }
          // Fallthrough if cancelled? No, we just stop.
        } else {
          // Empty after filter
          if (mounted) await _searchAndShowLogos(context, query);
        }
      } else {
        // No stations found -> Logos
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("No stations found. Searching for logos..."),
            ),
          );
          await _searchAndShowLogos(context, query);
        }
      }
    } catch (e) {
      if (mounted) {
        debugPrint("Overall search error: $e");
        await _searchAndShowLogos(context, query);
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _populateStationData(Map<String, dynamic> selected) {
    _urlController.text = selected['url_resolved'] ?? selected['url'] ?? '';
    final String favicon = selected['favicon'] ?? '';
    if (favicon.isNotEmpty) _logoController.text = favicon;
    final String name = selected['name'] ?? '';
    if (name.isNotEmpty) _nameController.text = name;

    final String tags = selected['tags'] ?? '';
    if (tags.isNotEmpty) {
      final List<String> newGenres = tags
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && e.length < 20)
          .take(3)
          .toList();
      _selectedGenres = newGenres.map((g) {
        if (g.isEmpty) return g;
        return g[0].toUpperCase() + g.substring(1);
      }).toList();
      _updateLogoFromGenres();
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text("Selected: ${selected['name']}")));
  }

  Future<void> _searchAndShowLogos(BuildContext context, String query) async {
    if (!_isSearching) setState(() => _isSearching = true);

    try {
      final Set<String> imageUrls = {};

      Future<void> safeFetch(
        String name,
        Future<List<String>> Function() fetcher,
      ) async {
        try {
          final results = await fetcher();
          if (mounted) {
            imageUrls.addAll(results);
          }
        } catch (e) {
          debugPrint("Error fetching $name: $e");
        }
      }

      await Future.wait([
        // 1. iTunes Podcast Search
        safeFetch("iTunes", () async {
          final uri = Uri.parse(
            "https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&media=podcast&entity=podcast&limit=15",
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

        // 2. Clearbit
        safeFetch("Clearbit", () async {
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

        // 3. Web Search Simulation (Google Images fallback via Bing)
        // We use Bing's thumbnail proxy which is reliable and acts very similarly to Google Images
        // for "best match" retrieval without needing an API key/parsing HTML.
        safeFetch("WebSearch", () async {
          final base = "https://tse2.mm.bing.net/th";
          final params = "&w=500&h=500&c=7&rs=1&p=0"; // p=0 high quality

          String makeUrl(String q) =>
              "$base?q=${Uri.encodeComponent(q)}$params";

          // Generate diverse variations to get different results
          return [
            makeUrl("$query logo"),
            makeUrl("$query station icon"),
            makeUrl("$query radio fm logo"),
            makeUrl("$query broadcast"),
            makeUrl(query), // Fallback to raw query
            makeUrl("$query logo png"), // Try to get transparent-ish
            makeUrl("$query logo square"), // Try to get square
          ];
        }),
      ]);

      if (!mounted) return;

      // 4. Verify Images (filter out broken links)
      // We do a quick HEAD check to ensure the image exists and is accessible.
      final List<String> verifiedImages = [];
      final rawList = imageUrls
          .where((u) => u.startsWith('http'))
          .toSet()
          .toList();

      // Check in parallel batches to be faster, but limited concurrency isn't strictly needed for few items.
      // We will check all.
      await Future.wait(
        rawList.map((url) async {
          try {
            final response = await http
                .head(Uri.parse(url))
                .timeout(const Duration(milliseconds: 1500));
            if (response.statusCode == 200) {
              // If content-type is available, check if image. If not, assume yes if 200.
              final cType = response.headers['content-type'];
              if (cType == null ||
                  cType.contains('image') ||
                  cType == 'application/octet-stream') {
                verifiedImages.add(url);
              }
            }
          } catch (_) {
            // Ignore failures
          }
        }),
      );

      // Stop searching spinner
      setState(() => _isSearching = false);

      if (verifiedImages.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No valid logo suggestions found.")),
          );
        }
        return;
      }

      if (!mounted) return;

      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF16213e),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            "Select Logo for '$query'",
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: verifiedImages.length,
              itemBuilder: (context, index) {
                final url = verifiedImages[index];
                return GestureDetector(
                  onTap: () => Navigator.pop(context, url),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Center(
                        child: Icon(Icons.broken_image, color: Colors.white24),
                      ),
                      loadingBuilder: (ctx, child, loading) {
                        if (loading == null) return child;
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
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
          ],
        ),
      );

      if (selected != null && mounted) {
        setState(() => _logoController.text = selected);
      }
    } catch (e) {
      if (mounted) {
        debugPrint("Logo search error: $e");
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error searching logos: $e")));
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      final provider = Provider.of<RadioProvider>(context, listen: false);

      // Validate Genres
      if (_selectedGenres.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Please select at least one Genre"),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      String genreString = _selectedGenres.join(" | ");

      // Validate Category
      if (_selectedCategory == null || _selectedCategory!.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Please select a Category"),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      String categoryString = _selectedCategory!;

      String finalLogo = _logoController.text.trim();

      // Automatic Image from Genre if logo is empty
      if (finalLogo.isEmpty && _selectedGenres.isNotEmpty) {
        final firstGenre = _selectedGenres.first;
        // This will return a generative URL for new/existing genres deterministically
        final generatedUrl = GenreMapper.getGenreImage(firstGenre);
        if (generatedUrl != null) {
          finalLogo = generatedUrl;
        }
      }

      final newStation = Station(
        id: widget.station?.id ?? DateTime.now().millisecondsSinceEpoch,
        name: _nameController.text.trim(),
        genre: genreString,
        url: _urlController.text.trim(),
        logo: finalLogo.isEmpty ? null : finalLogo,
        color: _formatColor(_colorController.text),
        category: categoryString,
        icon: 'music',
      );

      if (widget.station == null) {
        provider.addStation(newStation);
      } else {
        provider.editStation(newStation);
      }

      Navigator.pop(context);
    }
  }
}

class _GenreSelectionDialog extends StatefulWidget {
  final List<String> existing;
  final List<String> initialSelected;

  const _GenreSelectionDialog({
    required this.existing,
    required this.initialSelected,
  });

  @override
  State<_GenreSelectionDialog> createState() => _GenreSelectionDialogState();
}

class _GenreSelectionDialogState extends State<_GenreSelectionDialog> {
  late Set<String> tempSelected;
  late TextEditingController textController;
  String searchQuery = '';

  @override
  void initState() {
    super.initState();
    tempSelected = {...widget.initialSelected};
    textController = TextEditingController();
  }

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF16213e),
      title: const Text("Select Genres", style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search Bar
            TextField(
              decoration: InputDecoration(
                hintText: "Search genres...",
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                filled: true,
                fillColor: Colors.black12,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 0,
                  horizontal: 12,
                ),
              ),
              style: const TextStyle(color: Colors.white),
              onChanged: (val) {
                setState(() {
                  searchQuery = val;
                });
              },
            ),
            const SizedBox(height: 16),

            // Scrollable Chips Area
            Flexible(
              child: SingleChildScrollView(
                child: Builder(
                  builder: (context) {
                    // Combine and sort options
                    final allOptions = {
                      ...widget.existing,
                      ...tempSelected,
                    }.toList();

                    // Filter based on search
                    final filteredOptions = allOptions.where((g) {
                      if (searchQuery.isEmpty) return true;
                      return g.toLowerCase().contains(
                        searchQuery.toLowerCase(),
                      );
                    }).toList();

                    filteredOptions.sort(
                      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                    );

                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: filteredOptions.map((g) {
                        final isSelected = tempSelected.contains(g);
                        return FilterChip(
                          label: Text(g),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                tempSelected.add(g);
                              } else {
                                tempSelected.remove(g);
                              }
                            });
                          },
                          selectedColor: Theme.of(
                            context,
                          ).primaryColor.withValues(alpha: 0.2),
                          labelStyle: const TextStyle(color: Colors.white),
                          checkmarkColor: Colors.white,
                          backgroundColor: Colors.white10,
                          side: BorderSide.none,
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
            ),

            const Divider(color: Colors.white24, height: 32),

            // Fixed "Add New" Area at bottom
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Or add new:",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: textController,
                        decoration: const InputDecoration(
                          hintText: "New Genre Name",
                          hintStyle: TextStyle(color: Colors.white24),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                          ),
                        ),
                        style: const TextStyle(color: Colors.white),
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            setState(() {
                              tempSelected.add(val.trim());
                              textController.clear();
                            });
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.add_circle,
                        color: Theme.of(context).primaryColor,
                      ),
                      onPressed: () {
                        if (textController.text.trim().isNotEmpty) {
                          setState(() {
                            tempSelected.add(textController.text.trim());
                            textController.clear();
                          });
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            // Check text field one last time
            if (textController.text.trim().isNotEmpty) {
              tempSelected.add(textController.text.trim());
            }
            Navigator.pop(context, tempSelected.toList());
          },
          child: const Text("Done"),
        ),
      ],
    );
  }
}

class _CategorySelectionDialog extends StatefulWidget {
  final List<String> existing;
  final String? initialSelected;

  const _CategorySelectionDialog({
    required this.existing,
    this.initialSelected,
  });

  @override
  State<_CategorySelectionDialog> createState() =>
      _CategorySelectionDialogState();
}

class _CategorySelectionDialogState extends State<_CategorySelectionDialog> {
  String? tempSelected;
  late TextEditingController textController;
  String searchQuery = '';

  @override
  void initState() {
    super.initState();
    tempSelected = widget.initialSelected;
    textController = TextEditingController();
  }

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF16213e),
      title: const Text(
        "Select Category",
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search Bar
            TextField(
              decoration: InputDecoration(
                hintText: "Search categories...",
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                filled: true,
                fillColor: Colors.black12,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 0,
                  horizontal: 12,
                ),
              ),
              style: const TextStyle(color: Colors.white),
              onChanged: (val) {
                setState(() {
                  searchQuery = val;
                });
              },
            ),
            const SizedBox(height: 16),

            // Scrollable Chips Area
            Flexible(
              child: SingleChildScrollView(
                child: Builder(
                  builder: (context) {
                    final allOptions = {
                      ...widget.existing,
                      if (tempSelected != null) tempSelected!,
                    }.toList();

                    final filteredOptions = allOptions.where((c) {
                      if (searchQuery.isEmpty) return true;
                      return c.toLowerCase().contains(
                        searchQuery.toLowerCase(),
                      );
                    }).toList();

                    filteredOptions.sort(
                      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                    );

                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: filteredOptions.map((c) {
                        final isSelected = tempSelected == c;
                        return ChoiceChip(
                          label: Text(c),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                tempSelected = c;
                              } else {
                                tempSelected = null;
                              }
                            });
                          },
                          selectedColor: Theme.of(context).primaryColor,
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.white : Colors.white70,
                          ),
                          backgroundColor: Colors.white10,
                          side: BorderSide.none,
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
            ),

            const Divider(color: Colors.white24, height: 32),

            // Fixed "Add New" Area at bottom
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Or add new:",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: textController,
                        decoration: const InputDecoration(
                          hintText: "New Category Name",
                          hintStyle: TextStyle(color: Colors.white24),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                          ),
                        ),
                        style: const TextStyle(color: Colors.white),
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            setState(() {
                              tempSelected = val.trim();
                              textController.clear();
                            });
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.add_circle,
                        color: Theme.of(context).primaryColor,
                      ),
                      onPressed: () {
                        if (textController.text.trim().isNotEmpty) {
                          setState(() {
                            tempSelected = textController.text.trim();
                            textController.clear();
                          });
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (textController.text.trim().isNotEmpty) {
              tempSelected = textController.text.trim();
            }
            Navigator.pop(context, {'selection': tempSelected});
          },
          child: const Text("Done"),
        ),
      ],
    );
  }
}

class _StationSelectionDialog extends StatelessWidget {
  final List<dynamic> stations;

  const _StationSelectionDialog({required this.stations});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF16213e),
      title: const Text(
        "Select Station",
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.7,
          ),
          itemCount: stations.length,
          itemBuilder: (context, index) {
            final s = stations[index];
            final String? favicon = s['favicon'];
            final hasImage = favicon != null && favicon.isNotEmpty;

            return GestureDetector(
              onTap: () => Navigator.pop(context, s),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Container(
                        decoration: const BoxDecoration(
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(12),
                          ),
                          color: Colors.black12,
                        ),
                        child: hasImage
                            ? Image.network(
                                favicon,
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const Icon(
                                  Icons.radio,
                                  color: Colors.white24,
                                  size: 40,
                                ),
                              )
                            : const Icon(
                                Icons.radio,
                                color: Colors.white24,
                                size: 40,
                              ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8.0,
                          vertical: 4.0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              s['name'] ?? 'Unknown',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "${(s['bitrate'] ?? 0)} kbps | ${s['countrycode'] ?? ''}",
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (s['country'] != null &&
                                s['country'].toString().isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                s['country'],
                                style: const TextStyle(
                                  color: Colors.white24,
                                  fontSize: 10,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
      ],
    );
  }
}
