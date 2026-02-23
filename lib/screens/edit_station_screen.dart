import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io'; // Added for Platform.localeName

import 'package:palette_generator/palette_generator.dart';
import '../models/station.dart';
import '../providers/radio_provider.dart';
import '../utils/genre_mapper.dart';

class EditStationScreen extends StatefulWidget {
  final Station? station; // null for new station

  const EditStationScreen({super.key, this.station});

  @override
  State<EditStationScreen> createState() => _EditStationScreenState();
}

String _getFlag(String countryCode) {
  if (countryCode == "ALL") return "🌍";
  return countryCode.toUpperCase().replaceAllMapped(
    RegExp(r'[A-Z]'),
    (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) + 127397),
  );
}

Map<String, String> _getCountryMap(LanguageProvider langProvider) {
  return {
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
  Map<String, String> get _countryMap {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    return _getCountryMap(langProvider);
  }

  bool? _lastTestResult;

  Future<void> _testStreamUrl() async {
    final url = _urlController.text.trim();
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(langProvider.translate('please_enter_url'))),
      );
      return;
    }

    setState(() {
      _isTestingLink = true;
      _lastTestResult = null;
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
            _lastTestResult = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.green,
              content: Text(langProvider.translate('stream_valid')),
            ),
          );
        }
      } else {
        throw Exception("Status code: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Stream Test Error: $e");
      if (mounted) {
        setState(() {
          _lastTestResult = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red,
            content: Text(
              langProvider
                  .translate('stream_invalid')
                  .replaceAll('{0}', e.toString()),
            ),
          ),
        );
      }
    } finally {
      client.close();
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
    _logoController.addListener(() {
      setState(() {});
      // Debounce color extraction
      _debounceColorExtraction();
    });
    _nameController.addListener(() => setState(() {}));

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

  Timer? _debounceTimer;

  void _debounceColorExtraction() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_logoController.text.trim().isNotEmpty) {
        _extractColorFromLogo();
      }
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _nameController.dispose();
    _urlController.dispose();
    _logoController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  Future<void> _extractColorFromLogo() async {
    final url = _logoController.text.trim();
    if (url.isEmpty) return;

    try {
      ImageProvider imageProvider;
      if (url.startsWith('http')) {
        imageProvider = NetworkImage(url);
      } else {
        // Assume asset
        imageProvider = AssetImage(url);
      }

      // Check if PaletteGenerator is available (it should be imported at top)
      final palette = await PaletteGenerator.fromImageProvider(
        imageProvider,
        maximumColorCount: 20,
      );

      Color? extracted = palette.dominantColor?.color;
      extracted ??= palette.vibrantColor?.color;
      extracted ??= palette.lightVibrantColor?.color;
      extracted ??= palette.darkVibrantColor?.color;

      if (extracted != null && mounted) {
        final langProvider = Provider.of<LanguageProvider>(
          context,
          listen: false,
        );
        // Convert to Hex
        final hex =
            '#${extracted.value.toRadixString(16).substring(2).toUpperCase()}';
        _colorController.text = hex;
        setState(() {}); // Refresh UI

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(langProvider.translate('color_updated')),
            backgroundColor: extracted,
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error extracting color: $e");
    }
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
    try {
      if (hexColor.length == 8) {
        return Color(int.parse("0x$hexColor"));
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final langProvider = Provider.of<LanguageProvider>(context);

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
    allCategories.addAll([]);
    allGenres.addAll([]);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          widget.station == null
              ? langProvider.translate('add_station')
              : langProvider.translate('edit_station'),
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.check, color: Theme.of(context).primaryColor),
            onPressed: () => _save(),
            tooltip: langProvider.translate('save_station'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionTitle(langProvider.translate('general_info')),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _buildTextField(
                      langProvider.translate('station_name'),
                      _nameController,
                      Icons.radio,
                      suffix: IconButton(
                        icon: _isSearching
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).primaryColor,
                                ),
                              )
                            : Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).primaryColor,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.search,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                  size: 20,
                                ),
                              ),
                        tooltip: langProvider.translate('auto_complete'),
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
                        color: Theme.of(
                          context,
                        ).cardColor.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).dividerColor.withValues(alpha: 0.1),
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedSearchCountry,
                          isExpanded: true,
                          dropdownColor: Theme.of(context).cardColor,
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodyLarge?.color,
                          ),
                          icon: Icon(
                            Icons.public,
                            color: Theme.of(context).iconTheme.color,
                          ),
                          items: () {
                            List<DropdownMenuItem<String>> items = [];

                            // 1. Device Country (if exists)
                            if (_deviceCountryCode != null &&
                                _countryMap.containsKey(_deviceCountryCode)) {
                              items.add(
                                DropdownMenuItem(
                                  value: _deviceCountryCode,
                                  child: Text(
                                    "${_getFlag(_deviceCountryCode!)} ${_countryMap[_deviceCountryCode]!}",
                                  ),
                                ),
                              );
                            }

                            // 2. Global
                            items.add(
                              DropdownMenuItem(
                                value: "ALL",
                                child: Text(
                                  "${_getFlag('ALL')} ${langProvider.translate('global')}",
                                ),
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
                                  child: Text(
                                    "${_getFlag(entry.key)} ${entry.value}",
                                  ),
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
                langProvider.translate('stream_url'),
                _urlController,
                Icons.link,
                suffix: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.image_search,
                        color: _nameController.text.trim().isNotEmpty
                            ? Theme.of(context).primaryColor
                            : Theme.of(context).disabledColor,
                      ),
                      tooltip: langProvider.translate('search_default_logo'),
                      onPressed:
                          _nameController.text.trim().isNotEmpty &&
                              !_isSearching
                          ? () => _searchAndShowLogos(
                              context,
                              _nameController.text.trim(),
                            )
                          : null,
                    ),
                    IconButton(
                      icon: _isTestingLink
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).primaryColor,
                              ),
                            )
                          : Icon(
                              _lastTestResult == true
                                  ? Icons.check_circle
                                  : _lastTestResult == false
                                  ? Icons.error
                                  : Icons.network_check,
                              color: _lastTestResult == true
                                  ? Colors.green
                                  : _lastTestResult == false
                                  ? Colors.red
                                  : Theme.of(context).primaryColor,
                            ),
                      tooltip: langProvider.translate('test_link'),
                      onPressed: _isTestingLink ? null : _testStreamUrl,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),
              _buildSectionTitle(langProvider.translate('classification')),

              const SizedBox(height: 8),
              // Custom Genre Selector
              Text(
                langProvider.translate('genres'),
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              _buildGenreSelector(context, allGenres.toList()),

              const SizedBox(height: 24),

              // Custom Category Selector (Single Select)
              Text(
                langProvider.translate('category'),
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              _buildCategorySelector(context, allCategories.toList()),

              const SizedBox(height: 32),
              _buildSectionTitle(langProvider.translate('appearance')),

              // Color Picker
              _buildColorSelector(context),
              const SizedBox(height: 24),

              _buildTextField(
                langProvider.translate('logo_url'),
                _logoController,
                Icons.image,
                isOptional: true,
                suffix: _logoController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.close,
                          color: Theme.of(context).primaryColor,
                        ),
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
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).dividerColor.withValues(alpha: 0.2),
                        ),
                        color: Theme.of(context).cardColor,
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
              // Save Button Removed (Moved to AppBar)
              const SizedBox(height: 24),
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
    final langProvider = Provider.of<LanguageProvider>(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
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
                  labelStyle: TextStyle(
                    color: Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                  deleteIcon: Icon(
                    Icons.close,
                    size: 16,
                    color: Theme.of(context).iconTheme.color,
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
                label: Text(langProvider.translate('add_genre')),
                backgroundColor: Theme.of(context).cardColor,
                labelStyle: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                ),
                side: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
                ),
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
    final langProvider = Provider.of<LanguageProvider>(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        children: [
          if (_selectedCategory != null)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Chip(
                label: Text(() {
                  final countryMap = _getCountryMap(langProvider);
                  final entry = countryMap.entries.firstWhere(
                    (e) => e.value == _selectedCategory,
                    orElse: () => const MapEntry('', ''),
                  );
                  if (entry.key.isNotEmpty) {
                    return "${_getFlag(entry.key)} $_selectedCategory";
                  }
                  if (_selectedCategory == langProvider.translate('global')) {
                    return "🌍 $_selectedCategory";
                  }
                  return _selectedCategory!;
                }()),
                backgroundColor: Theme.of(
                  context,
                ).primaryColor.withValues(alpha: 0.2),
                labelStyle: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                ),
                deleteIcon: Icon(
                  Icons.edit,
                  size: 14,
                  color: Theme.of(context).iconTheme.color,
                ),
                onDeleted: () {
                  _showSelectCategoryDialog(context, availableCategories);
                },
                side: BorderSide.none,
              ),
            ),
          if (_selectedCategory == null)
            ActionChip(
              label: Text(langProvider.translate('select_category')),
              backgroundColor: Theme.of(context).cardColor,
              labelStyle: TextStyle(
                color: Theme.of(context).textTheme.bodyMedium?.color,
              ),
              side: BorderSide(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
              ),
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
        color: Theme.of(context).cardColor.withValues(alpha: 0.3),
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
                  border: Border.all(
                    color: Theme.of(context).dividerColor,
                    width: 2,
                  ),
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
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodyMedium?.color,
                    fontFamily: 'monospace',
                  ),
                  decoration: InputDecoration(
                    labelText: "Hex Color",
                    labelStyle: TextStyle(color: Theme.of(context).hintColor),
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
                        ? Border.all(
                            color: Theme.of(context).iconTheme.color!,
                            width: 2,
                          )
                        : null,
                  ),
                  child: isSelected
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).cardColor,
                          size: 16,
                        )
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
      style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Theme.of(context).hintColor),
        prefixIcon: Icon(icon, color: Theme.of(context).iconTheme.color),
        suffixIcon: suffix,
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Theme.of(context).primaryColor),
          borderRadius: BorderRadius.circular(12),
        ),
        filled: true,
        fillColor: Theme.of(context).cardColor.withValues(alpha: 0.5),
      ),
      validator: (val) {
        if (isOptional) return null;
        return val == null || val.isEmpty ? "Required" : null;
      },
    );
  }

  Future<void> _autoCompleteStation() async {
    final query = _nameController.text.trim();

    // If query is empty, we only proceed if a specific country is selected.
    if (query.isEmpty && _selectedSearchCountry == "ALL") {
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(langProvider.translate('please_enter_name_or_country')),
        ),
      );
      return;
    }

    if (_isSearching) return;

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _isSearching = true);

    try {
      List<dynamic> stations = [];
      String? successServer;

      // Try servers de1 to de5
      for (int i = 1; i <= 5; i++) {
        final server = "de$i.api.radio-browser.info";
        Uri url;

        if (query.isEmpty) {
          url = Uri.parse(
            "https://$server/json/stations/search?countrycode=${_selectedSearchCountry.toLowerCase()}&limit=100&order=clickcount&reverse=true",
          );
        } else if (_selectedSearchCountry == "ALL") {
          url = Uri.parse(
            "https://$server/json/stations/byname/${Uri.encodeComponent(query)}?limit=100",
          );
        } else {
          url = Uri.parse(
            "https://$server/json/stations/search?name=${Uri.encodeComponent(query)}&countrycode=${_selectedSearchCountry.toLowerCase()}&limit=100",
          );
        }

        try {
          debugPrint("Trying Radio Browser Server: $server");
          final response = await http
              .get(url)
              .timeout(
                const Duration(seconds: 4),
              ); // Short timeout for faster failover

          if (response.statusCode == 200) {
            stations = json.decode(response.body);
            successServer = server;
            break; // Success! Exit loop.
          }
        } catch (e) {
          debugPrint("Failed to fetch from $server: $e");
          // Continue to next server
        }
      }

      if (successServer == null) {
        debugPrint("All Radio Browser servers failed.");
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

        final candidates = [...stationsWithImages, ...stationsOthers].toList();

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
          final langProvider = Provider.of<LanguageProvider>(
            context,
            listen: false,
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(langProvider.translate('no_stations_found')),
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
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    setState(() {
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

      // Auto-set Category from Country
      String category = langProvider.translate('country_ALL');
      String apiCountry = selected['country'] ?? '';
      String apiCountryCode = selected['countrycode'] ?? '';

      // 1. Try to match by Country Code (e.g. IT -> Italy)
      if (apiCountryCode.isNotEmpty &&
          _countryMap.containsKey(apiCountryCode.toUpperCase())) {
        category = _countryMap[apiCountryCode.toUpperCase()]!;
      }
      // 2. Try to match by Country Name directly (e.g. "Italy" == "Italy")
      else if (apiCountry.isNotEmpty) {
        // Check if apiCountry exists in _countryMap values
        final matchingEntry = _countryMap.entries.firstWhere(
          (entry) => entry.value.toLowerCase() == apiCountry.toLowerCase(),
          orElse: () => const MapEntry('', ''),
        );

        if (matchingEntry.key.isNotEmpty) {
          category = matchingEntry.value;
        } else {
          category = langProvider.translate('country_ALL');
        }
      }

      if (category.length > 35) {
        category = category.substring(0, 35);
      }
      _selectedCategory = category;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          langProvider
              .translate('station_selected')
              .replaceAll('{0}', selected['name']),
        ),
      ),
    );
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
            SnackBar(content: Text(Provider.of<LanguageProvider>(context, listen: false).translate('no_valid_logo_suggestions'))),
          );
        }
        return;
      }

      if (!mounted) return;

      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            "Select Logo for '$query'",
            style: TextStyle(
              color: Theme.of(context).textTheme.titleLarge?.color,
              fontSize: 16,
            ),
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
              child: Text(Provider.of<LanguageProvider>(context, listen: false).translate('cancel')),
            ),
          ],
        ),
      );

      if (selected != null && mounted) {
        setState(() => _logoController.text = selected);
        // Automatic Color Extraction
        _extractColorFromLogo();
      }
    } catch (e) {
      if (mounted) {
        final langProvider = Provider.of<LanguageProvider>(
          context,
          listen: false,
        );
        debugPrint("Logo search error: $e");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              langProvider
                  .translate('logo_search_error')
                  .replaceAll('{0}', e.toString()),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      final provider = Provider.of<RadioProvider>(context, listen: false);

      // Validate Genres
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
      if (_selectedGenres.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(langProvider.translate('select_min_one_genre')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      String genreString = _selectedGenres.join(" | ");

      // Validate Category
      if (_selectedCategory == null || _selectedCategory!.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(langProvider.translate('select_category_error')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      if (_selectedCategory!.length > 35) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(langProvider.translate('category_too_long')),
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
    final langProvider = Provider.of<LanguageProvider>(context);
    return AlertDialog(
      backgroundColor: Theme.of(context).cardColor,
      title: Text(
        langProvider.translate('select_genres'),
        style: TextStyle(color: Theme.of(context).textTheme.titleLarge?.color),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search Bar
            TextField(
              decoration: InputDecoration(
                hintText: langProvider.translate('search_genres'),
                hintStyle: TextStyle(color: Theme.of(context).hintColor),
                prefixIcon: Icon(
                  Icons.search,
                  color: Theme.of(context).iconTheme.color,
                ),
                filled: true,
                fillColor: Theme.of(context).scaffoldBackgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 0,
                  horizontal: 12,
                ),
              ),
              style: TextStyle(
                color: Theme.of(context).textTheme.bodyLarge?.color,
              ),
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
                          backgroundColor:
                              Theme.of(context).brightness == Brightness.dark
                              ? Colors.white10
                              : Colors.black12,
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
                Text(
                  langProvider.translate('or_add_new'),
                  style: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontSize: 12,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: textController,
                        decoration: InputDecoration(
                          hintText: langProvider.translate('new_genre_name'),
                          hintStyle: TextStyle(
                            color: Theme.of(context).hintColor,
                          ),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodyMedium?.color,
                        ),
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
          child: Text(langProvider.translate('done')),
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
    final langProvider = Provider.of<LanguageProvider>(context);
    return AlertDialog(
      backgroundColor: Theme.of(context).cardColor,
      title: Text(
        langProvider.translate('select_category'),
        style: TextStyle(color: Theme.of(context).textTheme.titleLarge?.color),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search Bar
            TextField(
              decoration: InputDecoration(
                hintText: langProvider.translate('search_categories'),
                hintStyle: TextStyle(color: Theme.of(context).hintColor),
                prefixIcon: Icon(
                  Icons.search,
                  color: Theme.of(context).iconTheme.color,
                ),
                filled: true,
                fillColor: Theme.of(context).scaffoldBackgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 0,
                  horizontal: 12,
                ),
              ),
              style: TextStyle(
                color: Theme.of(context).textTheme.bodyLarge?.color,
              ),
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
                          label: Text(() {
                            final countryMap = _getCountryMap(langProvider);
                            final entry = countryMap.entries.firstWhere(
                              (e) => e.value == c,
                              orElse: () => const MapEntry('', ''),
                            );
                            if (entry.key.isNotEmpty) {
                              return "${_getFlag(entry.key)} $c";
                            }
                            if (c == langProvider.translate('global')) {
                              return "🌍 $c";
                            }
                            return c;
                          }()),
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
                            color: isSelected
                                ? Colors.white
                                : Theme.of(context).textTheme.bodySmall?.color,
                          ),
                          backgroundColor:
                              Theme.of(context).brightness == Brightness.dark
                              ? Colors.white10
                              : Colors.grey.withValues(alpha: 0.1),
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
                Text(
                  langProvider.translate('or_add_new'),
                  style: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontSize: 12,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: textController,
                        decoration: InputDecoration(
                          hintText: langProvider.translate('new_category_name'),
                          hintStyle: TextStyle(
                            color: Theme.of(context).hintColor,
                          ),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodyMedium?.color,
                        ),
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            String newCat = val.trim();
                            if (newCat.length > 35) {
                              newCat = newCat.substring(0, 35);
                            }
                            setState(() {
                              tempSelected = newCat;
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
                          String newCat = textController.text.trim();
                          if (newCat.length > 35) {
                            newCat = newCat.substring(0, 35);
                          }
                          setState(() {
                            tempSelected = newCat;
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
              String newCat = textController.text.trim();
              if (newCat.length > 35) {
                newCat = newCat.substring(0, 35);
              }
              tempSelected = newCat;
            }
            Navigator.pop(context, {'selection': tempSelected});
          },
          child: Text(langProvider.translate('done')),
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
    final langProvider = Provider.of<LanguageProvider>(context);
    return AlertDialog(
      backgroundColor: Theme.of(context).cardColor,
      title: Text(
        langProvider.translate('select_station'),
        style: TextStyle(color: Theme.of(context).textTheme.titleLarge?.color),
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
                  color: Theme.of(context).cardColor.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).dividerColor.withValues(alpha: 0.2),
                  ),
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
                          color:
                              Colors.black12, // Keep dark for image background
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
                              s['name'] ?? langProvider.translate('unknown'),
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).textTheme.bodyLarge?.color,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "${(s['bitrate'] ?? 0)} kbps | ${s['countrycode'] ?? ''}",
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).textTheme.bodySmall?.color,
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
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).textTheme.bodySmall?.color,
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
          child: Text(langProvider.translate('cancel')),
        ),
      ],
    );
  }
}
