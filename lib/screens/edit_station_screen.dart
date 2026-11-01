import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io'; // Added for Platform.localeName
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;

import 'package:palette_generator/palette_generator.dart';
import '../models/station.dart';
import '../providers/radio_provider.dart';
import '../utils/genre_mapper.dart';
import '../utils/glass_utils.dart';

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
            SnackBar(content: Text(langProvider.translate('stream_valid'))),
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
            '#${extracted.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
        _colorController.text = hex;
        setState(() {}); // Refresh UI

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(langProvider.translate('color_updated')),
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
    final result = await GlassUtils.showGlassDialog<List<String>>(
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
    final result = await GlassUtils.showGlassDialog<Map<String, String?>>(
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
          final selected = await GlassUtils.showGlassDialog<Map<String, dynamic>>(
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

  // --- Logo search helpers ---------------------------------------------------

  /// Words that do not help identifying a specific radio station.
  static const Set<String> _logoStopWords = {
    'radio',
    'fm',
    'am',
    'live',
    'online',
    'stream',
    'streaming',
    'station',
    'the',
    'official',
    'web',
    'hd',
    'hq',
    'music',
  };

  static const Map<String, String> _logoDiacritics = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ø': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
    'ñ': 'n',
    'ý': 'y',
    'ÿ': 'y',
    'ß': 'ss',
    'æ': 'ae',
    'œ': 'oe',
  };

  String _normalizeStationName(String value) {
    var text = value.toLowerCase();
    _logoDiacritics.forEach((from, to) => text = text.replaceAll(from, to));
    text = text.replaceAll(
      RegExp(r"[\s\-_.,/\\|:;!?()\[\]{}'’“”«»&+#@*~^%$=<>]+"),
      ' ',
    );
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<String> _stationTokens(String normalized) {
    return normalized
        .split(' ')
        .where((t) => t.isNotEmpty && !_logoStopWords.contains(t))
        .toList();
  }

  /// Returns true only when [candidateName] refers to the same radio station
  /// as [query] (same brand name), avoiding unrelated stations/logos.
  bool _isSameStation(String candidateName, String query) {
    final candidate = _normalizeStationName(candidateName);
    final queryNorm = _normalizeStationName(query);
    if (candidate.isEmpty || queryNorm.isEmpty) return false;
    if (candidate == queryNorm) return true;

    final candidateNameTokens = candidate.split(' ');
    final queryNameTokens = queryNorm.split(' ');
    final queryTokens = _stationTokens(queryNorm);
    final candidateTokens = _stationTokens(candidate);
    final queryCore = queryTokens.join(' ');
    final candidateCore = candidateTokens.join(' ');

    if (queryCore.isEmpty) {
      // Query made only of generic words (e.g. "Radio"): require a close match.
      return candidateCore == queryCore;
    }
    if (candidateCore.isEmpty) return false;
    if (candidateCore == queryCore) return true;

    // Purely numeric brands ("Radio 105") must match exactly, otherwise
    // frequencies such as "Radio 105.5" would be treated as the same station.
    final numericQuery = RegExp(r'^\d+$').hasMatch(queryCore);
    final numericCandidate = RegExp(r'^\d+$').hasMatch(candidateCore);
    if (numericQuery || numericCandidate) return false;

    // Multi-word brands may differ by a suffix/prefix ("Radio Kiss Kiss" vs
    // "Kiss Kiss Napoli"), so core phrase containment is enough.
    if (queryTokens.length >= 2 &&
        (_phraseContains(candidateTokens, queryTokens) ||
            _phraseContains(queryTokens, candidateTokens))) {
      return true;
    }

    // Single-word brands ("Radio Italia", "Virgin Radio") must appear as a
    // whole phrase in the full name, otherwise stations that merely share a
    // word ("Italia 1") would contribute the wrong logo.
    return _phraseContains(candidateNameTokens, queryNameTokens) ||
        _phraseContains(queryNameTokens, candidateNameTokens);
  }

  /// Returns true when [needle] appears as a consecutive sequence in
  /// [haystack].
  bool _phraseContains(List<String> haystack, List<String> needle) {
    if (needle.isEmpty || needle.length > haystack.length) return false;
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      var matches = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  int _stationMatchScore(String candidateName, String query) {
    final candidate = _normalizeStationName(candidateName);
    final queryNorm = _normalizeStationName(query);
    if (candidate == queryNorm) return 100;

    final candidateCore = _stationTokens(candidate).join(' ');
    final queryCore = _stationTokens(queryNorm).join(' ');
    if (queryCore.isEmpty) {
      return candidate.contains(queryNorm) ? 40 : 10;
    }
    if (candidateCore == queryCore) return 90;
    if (candidateCore.startsWith(queryCore)) return 80;
    if (candidateCore.contains(queryCore)) return 70;
    if (queryCore.contains(candidateCore)) return 60;
    return 20;
  }

  int _clickCount(Map<String, dynamic> station) {
    final value = station['clickcount'];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String? _hostFromUrl(String? rawUrl) {
    if (rawUrl == null) return null;
    var value = rawUrl.trim();
    if (value.isEmpty) return null;
    if (!value.contains('://')) value = 'https://$value';
    try {
      final uri = Uri.parse(value);
      var host = uri.host.toLowerCase();
      if (host.isEmpty) return null;
      if (host.startsWith('www.')) host = host.substring(4);
      return host.contains('.') ? host : null;
    } catch (_) {
      return null;
    }
  }

  /// Generic streaming providers: their favicon is never the station's logo.
  static const Set<String> _streamProviderHosts = {
    'radio-browser.info',
    'zeno.fm',
    'radio.co',
    'streamguys.com',
    'shoutcast.com',
    'radionomy.com',
    'live365.com',
    'securenetsystems.net',
    'spacial.com',
    'listen2myradio.com',
    'myradiostream.com',
    'cristalhost.com',
    'streamerr.net',
  };

  /// Directories, social pages and aggregators: their favicon is never the
  /// station's logo either.
  static const Set<String> _aggregatorHosts = {
    'onlineradiobox.com',
    'streema.com',
    'tunein.com',
    'radio.it',
    'radioguide.fm',
    'streamingradioguide.com',
    'facebook.com',
    'instagram.com',
    'twitter.com',
    'x.com',
    'youtube.com',
    'tiktok.com',
    'linkedin.com',
    'linktr.ee',
    'sites.google.com',
  };

  /// Hosts that must never be used as a logo source, even when the station
  /// itself declares them (radio-browser placeholder icons and similar).
  static const Set<String> _faviconBlockedHosts = {
    'radio-browser.info',
  };

  static const Map<String, String> _logoHttpHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,image/avif,image/webp,'
        'image/png,image/*;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
  };

  bool _hostInSet(String host, Set<String> hosts) {
    return hosts.any(
      (candidate) => host == candidate || host.endsWith('.$candidate'),
    );
  }

  bool _isStationLogoHost(String host) {
    return !_hostInSet(host, _streamProviderHosts) &&
        !_hostInSet(host, _aggregatorHosts);
  }

  /// Official logo/favicon endpoints for a station's own domain.
  List<String> _logoUrlsForHost(String host) => [
    'https://www.google.com/s2/favicons?domain=$host&sz=256',
    'https://icons.duckduckgo.com/ip3/$host.ico',
    'https://logo.clearbit.com/$host',
  ];

  String? _absoluteLogoUrl(String value, String baseUrl) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('data:') || lower.startsWith('javascript:')) {
      return null;
    }
    try {
      final base = Uri.parse(baseUrl);
      final resolved = base.resolve(trimmed);
      if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
      return resolved.toString();
    } catch (_) {
      return null;
    }
  }

  /// Reads the station's website and extracts the logos it declares itself
  /// (`og:image`, `twitter:image`, `apple-touch-icon` and `<link rel=icon>`).
  Future<List<String>> _homepageLogoUrls(String homepage) async {
    final host = _hostFromUrl(homepage);
    if (host == null || !_isStationLogoHost(host)) return [];

    var pageUrl = homepage.trim();
    if (!pageUrl.contains('://')) pageUrl = 'https://$pageUrl';

    try {
      final response = await http
          .get(Uri.parse(pageUrl), headers: _logoHttpHeaders)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) return [];

      final contentType =
          response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.isNotEmpty && !contentType.contains('html')) return [];

      final html = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (html.isEmpty) return [];

      final urls = <String>[];
      void addFromTag(String tagPattern, String attribute) {
        final tagRegExp = RegExp(
          tagPattern,
          caseSensitive: false,
          dotAll: true,
        );
        final attributeRegExp = RegExp(
          '$attribute\\s*=\\s*["\']([^"\']+)["\']',
          caseSensitive: false,
          dotAll: true,
        );
        for (final match in tagRegExp.allMatches(html)) {
          final tag = match.group(0);
          if (tag == null) continue;
          final value = attributeRegExp.firstMatch(tag)?.group(1);
          final resolved = value == null ? null : _absoluteLogoUrl(value, pageUrl);
          if (resolved != null && !urls.contains(resolved)) {
            urls.add(resolved);
          }
        }
      }

      // The icons declared by the website are usually the square logo and
      // look best in the picker.
      addFromTag(
        r"""<link[^>]+rel\s*=\s*["'][^"']*(?:apple-touch-icon|icon)[^"']*["'][^>]*>""",
        'href',
      );
      // Open Graph / Twitter images are a last resort: they are often wide
      // banners rather than a proper logo.
      addFromTag(
        r"""<meta[^>]+(?:property|name)\s*=\s*["'](?:og:image(?::url|:secure_url)?|twitter:image(?::src)?|image)["'][^>]*>""",
        'content',
      );

      return urls.take(6).toList();
    } catch (e) {
      debugPrint('Logo search: homepage $homepage failed: $e');
      return [];
    }
  }

  /// Downloads the raw bytes of a candidate image.
  Future<Uint8List?> _downloadLogo(String url) async {
    try {
      final response = await http
          .get(Uri.parse(url), headers: _logoHttpHeaders)
          .timeout(const Duration(seconds: 6));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final bytes = response.bodyBytes;
      if (bytes.length < 64 || bytes.length > 4 * 1024 * 1024) return null;

      final contentType =
          response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.contains('text/html') ||
          contentType.contains('application/json')) {
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Decodes and normalizes a downloaded image, so the dialog always shows
  /// exactly the bytes that were validated. Returns null for broken images.
  ({Uint8List bytes, String signature})? _prepareLogo(Uint8List raw) {
    try {
      final decoded = img.decodeImage(raw);
      if (decoded == null) return null;
      if (decoded.width < 16 || decoded.height < 16) return null;
      if (decoded.width * decoded.height > 40000000) return null;

      // Signature of a normalized thumbnail: identical logos returned by
      // different services are collapsed into a single entry.
      final signature = crypto.sha1
          .convert(
            img.encodePng(
              img.copyResize(decoded, width: 32, height: 32),
            ),
          )
          .toString();

      var output = decoded;
      final maxSide = math.max(decoded.width, decoded.height);
      if (maxSide > 512) {
        output = img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? 512 : null,
          height: decoded.height > decoded.width ? 512 : null,
        );
      }

      return (
        bytes: Uint8List.fromList(img.encodePng(output, level: 6)),
        signature: signature,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<dynamic>> _fetchRadioBrowserStations(String query) async {
    final encoded = Uri.encodeComponent(query);
    for (int i = 1; i <= 5; i++) {
      final server = "de$i.api.radio-browser.info";
      final url = Uri.parse(
        "https://$server/json/stations/search?name=$encoded&limit=100&hidebroken=true&order=clickcount&reverse=true",
      );
      try {
        final response = await http
            .get(url)
            .timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final decoded = json.decode(response.body);
          if (decoded is List) return decoded;
        }
      } catch (e) {
        debugPrint("Logo search: server $server failed: $e");
      }
    }
    return [];
  }

  /// Gathers and validates logo candidates for [query]. Only logos that
  /// belong to the station itself are returned.
  Future<List<({String url, Uint8List bytes})>> _collectLogosForQuery(
    String query,
  ) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return [];

    try {
      // Only show logos that belong to the radio being edited: query Radio
      // Browser for stations with the same name, keep only strict name
      // matches and derive favicons from each station's own domain.
      final coreQuery = _stationTokens(
        _normalizeStationName(trimmedQuery),
      ).join(' ');
      final searchQueries = <String>{
        trimmedQuery,
        if (coreQuery.isNotEmpty) coreQuery,
      };
      final stationsByUuid = <String, Map<String, dynamic>>{};
      for (final searchQuery in searchQueries) {
        final results = await _fetchRadioBrowserStations(searchQuery);
        for (final item in results.whereType<Map>()) {
          final station = Map<String, dynamic>.from(item);
          final uuid = (station['stationuuid'] ?? station['name'] ?? '')
              .toString();
          stationsByUuid.putIfAbsent(uuid, () => station);
        }
      }

      final matchingStations = stationsByUuid.values
          .map((s) => MapEntry(s, s['name']?.toString() ?? ''))
          .where((entry) => _isSameStation(entry.value, trimmedQuery))
          .toList();

      final selectedCountry = _selectedSearchCountry.toUpperCase();
      matchingStations.sort((a, b) {
        final scoreA = _stationMatchScore(a.value, trimmedQuery);
        final scoreB = _stationMatchScore(b.value, trimmedQuery);
        if (scoreA != scoreB) return scoreB.compareTo(scoreA);

        if (selectedCountry != 'ALL') {
          final countryA =
              (a.key['countrycode'] ?? '').toString().toUpperCase();
          final countryB =
              (b.key['countrycode'] ?? '').toString().toUpperCase();
          final matchA = countryA == selectedCountry;
          final matchB = countryB == selectedCountry;
          if (matchA != matchB) return matchA ? -1 : 1;
        }

        return _clickCount(b.key).compareTo(_clickCount(a.key));
      });

      // Gather candidates in order of reliability: logos declared by the
      // station's own website, then the station favicon, then favicon
      // services for the station's own domain.
      final homepageLogos = <String>[];
      final stationFavicons = <String>[];
      final domainLogos = <String>[];
      final streamHostLogos = <String>[];

      void addTo(List<String> target, String? url) {
        final value = url?.trim();
        if (value == null || value.isEmpty) return;
        if (!value.startsWith('http')) return;
        if (!target.contains(value)) target.add(value);
      }

      // Scraping is the most reliable source, but limit the number of pages.
      final stationsForHomepage = matchingStations.take(4).toList();
      final homepageResults = await Future.wait(
        stationsForHomepage.map((entry) async {
          final homepage = entry.key['homepage']?.toString() ?? '';
          if (homepage.isEmpty) return const <String>[];
          return _homepageLogoUrls(homepage);
        }),
      );
      for (final logos in homepageResults) {
        for (final url in logos) {
          addTo(homepageLogos, url);
        }
      }

      for (final entry in matchingStations) {
        final station = entry.key;

        final favicon = station['favicon']?.toString();
        final faviconHost = _hostFromUrl(favicon);
        if (faviconHost != null &&
            !_hostInSet(faviconHost, _faviconBlockedHosts)) {
          addTo(stationFavicons, favicon);
        }

        final homepageHost = _hostFromUrl(station['homepage']?.toString());
        if (homepageHost != null && _isStationLogoHost(homepageHost)) {
          for (final url in _logoUrlsForHost(homepageHost)) {
            addTo(domainLogos, url);
          }
        }

        // Stream hosts are often shared hosting providers, so they are used
        // only when the station has no usable website of its own.
        final streamHost = _hostFromUrl(
          (station['url_resolved'] ?? station['url'])?.toString(),
        );
        if (homepageHost == null &&
            streamHost != null &&
            _isStationLogoHost(streamHost)) {
          for (final url in _logoUrlsForHost(streamHost)) {
            addTo(streamHostLogos, url);
          }
        }
      }

      // The stream URL currently typed in the form is another strong hint.
      final typedHost = _hostFromUrl(_urlController.text);
      if (typedHost != null && _isStationLogoHost(typedHost)) {
        for (final url in _logoUrlsForHost(typedHost)) {
          addTo(streamHostLogos, url);
        }
      }

      const maxCandidates = 32;
      final seenUrls = <String>{};
      final candidateUrls = <String>[];
      for (final group in [
        homepageLogos,
        stationFavicons,
        domainLogos,
        streamHostLogos,
      ]) {
        for (final url in group) {
          if (candidateUrls.length >= maxCandidates) break;
          if (seenUrls.add(url)) candidateUrls.add(url);
        }
      }

      if (!mounted) return [];

      // Download and validate the actual bytes: the dialog shows these exact
      // bytes, so a listed logo can never fail to render and images that are
      // not real pictures (HTML error pages, SVG, broken files) are dropped.
      const batchSize = 10;
      final preparedLogos =
          <({String url, Uint8List bytes, String signature})>[];
      for (var i = 0; i < candidateUrls.length; i += batchSize) {
        final batch = candidateUrls.skip(i).take(batchSize);
        final batchResults = await Future.wait(
          batch.map((url) async {
            final raw = await _downloadLogo(url);
            if (raw == null) return null;
            final prepared = _prepareLogo(raw);
            if (prepared == null) return null;
            return (
              url: url,
              bytes: prepared.bytes,
              signature: prepared.signature,
            );
          }),
        );
        for (final result in batchResults) {
          if (result != null) preparedLogos.add(result);
        }
      }

      // Collapse duplicates coming from different services (same logo served
      // by Google, DuckDuckGo and Clearbit for example).
      final seenSignatures = <String>{};
      final logos = <({String url, Uint8List bytes})>[];
      for (final item in preparedLogos) {
        if (logos.length >= 15) break;
        if (!seenSignatures.add(item.signature)) continue;
        logos.add((url: item.url, bytes: item.bytes));
      }

      return logos;
    } catch (e) {
      debugPrint('Logo search error: $e');
      return [];
    }
  }

  Future<void> _searchAndShowLogos(BuildContext context, String query) async {
    final langProvider = Provider.of<LanguageProvider>(
      context,
      listen: false,
    );
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return;
    if (!_isSearching) setState(() => _isSearching = true);

    List<({String url, Uint8List bytes})> logos = [];
    try {
      logos = await _collectLogosForQuery(trimmedQuery);
    } catch (e) {
      if (context.mounted) {
        debugPrint('Logo search error: $e');
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

    if (!context.mounted) return;

    final selected = await GlassUtils.showGlassDialog<String>(
      context: context,
      builder: (ctx) => _LogoPickerDialog(
        initialQuery: trimmedQuery,
        initialLogos: logos,
        onSearch: _collectLogosForQuery,
      ),
    );

    if (selected != null && mounted) {
      setState(() => _logoController.text = selected);
      // Automatic Color Extraction
      _extractColorFromLogo();
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
          ),
        );
        return;
      }
      if (_selectedCategory!.length > 35) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(langProvider.translate('category_too_long'))),
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
                      ?tempSelected,
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
                                errorBuilder: (_, _, _) => const Icon(
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

/// Logo picker with an editable search query: the user can refine the query
/// and re-run the logo search without leaving the dialog.
class _LogoPickerDialog extends StatefulWidget {
  final String initialQuery;
  final List<({String url, Uint8List bytes})> initialLogos;
  final Future<List<({String url, Uint8List bytes})>> Function(String query)
  onSearch;

  const _LogoPickerDialog({
    required this.initialQuery,
    required this.initialLogos,
    required this.onSearch,
  });

  @override
  State<_LogoPickerDialog> createState() => _LogoPickerDialogState();
}

class _LogoPickerDialogState extends State<_LogoPickerDialog> {
  late final TextEditingController _queryController;
  late List<({String url, Uint8List bytes})> _logos;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _logos = List.of(widget.initialLogos);
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _isLoading) return;

    FocusScope.of(context).unfocus();
    setState(() => _isLoading = true);
    try {
      final results = await widget.onSearch(query);
      if (!mounted) return;
      setState(() {
        _logos = results;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      final langProvider = Provider.of<LanguageProvider>(
        context,
        listen: false,
      );
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
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(
      context,
      listen: false,
    );
    final theme = Theme.of(context);
    final titleQuery = _queryController.text.trim();
    final contentHeight = math.min(
      460.0,
      MediaQuery.sizeOf(context).height * 0.55,
    );

    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        langProvider.translate('select_logo_for', args: [titleQuery]),
        style: TextStyle(
          color: theme.textTheme.titleLarge?.color,
          fontSize: 16,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: contentHeight,
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search,
                    size: 20,
                    color: theme.primaryColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _queryController,
                      enabled: !_isLoading,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _runSearch(),
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(
                        color: theme.textTheme.bodyMedium?.color,
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: langProvider.translate(
                          'logo_search_hint',
                        ),
                        hintStyle: TextStyle(
                          color: theme.hintColor.withValues(alpha: 0.7),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: _isLoading
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 20,
                            tooltip: langProvider.translate(
                              'search_default_logo',
                            ),
                            icon: Icon(
                              Icons.refresh_rounded,
                              size: 20,
                              color: theme.primaryColor,
                            ),
                            onPressed: _runSearch,
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: theme.primaryColor,
                      ),
                    )
                  : _logos.isEmpty
                  ? Center(
                      child: Text(
                        langProvider.translate('no_valid_logo_suggestions'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      itemCount: _logos.length,
                      itemBuilder: (context, index) {
                        final logo = _logos[index];
                        return GestureDetector(
                          onTap: () => Navigator.pop(context, logo.url),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white12),
                            ),
                            clipBehavior: Clip.antiAlias,
                            padding: const EdgeInsets.all(6),
                            child: Image.memory(
                              logo.bytes,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
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
          onPressed: () => Navigator.pop(context),
          child: Text(langProvider.translate('cancel')),
        ),
      ],
    );
  }
}
