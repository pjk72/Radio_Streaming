import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../models/station.dart';
import '../providers/radio_provider.dart';
import '../utils/icon_library.dart';

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
  late TextEditingController _iconController;

  // Custom State for complex fields
  List<String> _selectedGenres = [];
  String? _selectedCategory; // Single selection
  String _iconSearchQuery = ''; // Search state for icons
  bool _isSearching = false;

  final List<Color> _colorPalette = [
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.deepOrange,
    Colors.orange,
    Colors.amber,
    Colors.brown,
    Colors.blueGrey,
    const Color(0xFF000000), // Black
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

    _iconController = TextEditingController(
      text: widget.station?.icon ?? 'music',
    );

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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _logoController.dispose();
    _colorController.dispose();
    _iconController.dispose();
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
              _buildTextField(
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
              const SizedBox(height: 16),
              _buildTextField("Stream URL", _urlController, Icons.link),

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
              ),
              const SizedBox(height: 16),

              Center(
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white24),
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _logoController.text.isNotEmpty
                      ? (_logoController.text.startsWith('http')
                            ? Image.network(
                                _logoController.text,
                                fit: BoxFit.cover,
                                errorBuilder: (c, e, s) => const Icon(
                                  Icons.broken_image,
                                  color: Colors.white24,
                                ),
                              )
                            : Image.asset(
                                _logoController.text,
                                fit: BoxFit.cover,
                                errorBuilder: (c, e, s) => const Icon(
                                  Icons.image_not_supported,
                                  color: Colors.white24,
                                ),
                              ))
                      : Center(
                          child: FaIcon(
                            IconLibrary.getIcon(_iconController.text),
                            color: Colors.white,
                            size: 40,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Icon Selector
              _buildIconSelector(context),

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
      });
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
              final isSelected = color.value == currentColor.value;
              return GestureDetector(
                onTap: () {
                  String hex =
                      '#${color.value.toRadixString(16).substring(2).toUpperCase()}';
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

  Widget _buildIconSelector(BuildContext context) {
    Color currentColor =
        _getColorFromHex(_colorController.text) ?? Colors.white;
    String currentIcon = _iconController.text;
    if (currentIcon.isEmpty) currentIcon = 'music';

    // Filter icons based on search query
    final filteredIcons = IconLibrary.icons.entries.where((entry) {
      if (_iconSearchQuery.isEmpty) return true;
      return entry.key.toLowerCase().contains(_iconSearchQuery.toLowerCase());
    }).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Station Icon",
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              // Search Field
              SizedBox(
                width: 150,
                height: 35,
                child: TextField(
                  decoration: InputDecoration(
                    hintText: "Search Icon...",
                    hintStyle: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 0,
                      horizontal: 8,
                    ),
                    filled: true,
                    fillColor: Colors.black12,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 14,
                      color: Colors.white38,
                    ),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: (val) {
                    setState(() {
                      _iconSearchQuery = val;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (filteredIcons.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(
                child: Text(
                  "No icons found",
                  style: TextStyle(color: Colors.white38),
                ),
              ),
            )
          else
            SizedBox(
              height:
                  300, // Fixed height specifically for the grid to be scrollable
              child: GridView.builder(
                padding: EdgeInsets.zero, // Remove default padding
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: filteredIcons.length,
                itemBuilder: (context, index) {
                  final entry = filteredIcons[index];
                  final name = entry.key;
                  final iconData = entry.value;
                  final isSelected =
                      name == currentIcon ||
                      (currentIcon.isEmpty && name == 'music');

                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _iconController.text = name;
                      });
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? currentColor.withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: isSelected
                            ? Border.all(color: currentColor, width: 2)
                            : Border.all(color: Colors.white10),
                      ),
                      child: Center(
                        child: FaIcon(
                          iconData,
                          color: isSelected ? currentColor : Colors.white54,
                          size: 20,
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
        const SnackBar(content: Text("Please enter a station name content")),
      );
      return;
    }

    setState(() => _isSearching = true);

    try {
      final url = Uri.parse(
        "https://de1.api.radio-browser.info/json/stations/byname/${Uri.encodeComponent(query)}",
      );
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final List<dynamic> results = json.decode(response.body);
        if (results.isNotEmpty) {
          // Use the first result
          final info = results[0];

          _urlController.text = info['url_resolved'] ?? info['url'] ?? '';

          final String favicon = info['favicon'] ?? '';
          if (favicon.isNotEmpty) {
            _logoController.text = favicon;
          }

          final String tags = info['tags'] ?? '';
          if (tags.isNotEmpty) {
            final List<String> newGenres = tags
                .split(',')
                .map((e) => e.trim())
                .where(
                  (e) => e.isNotEmpty && e.length < 20,
                ) // Filter out garbage
                .take(3) // Limit to 3 tags
                .toList();

            // Capitalize
            _selectedGenres = newGenres.map((g) {
              if (g.isEmpty) return g;
              return g[0].toUpperCase() + g.substring(1);
            }).toList();
          }

          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text("Found: ${info['name']}")));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No station found with that name.")),
          );
        }
      } else {
        throw Exception("API Error");
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Search failed: $e")));
    } finally {
      setState(() => _isSearching = false);
    }
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      final provider = Provider.of<RadioProvider>(context, listen: false);

      // Construct Genre String
      String genreString = _selectedGenres.join(" | ");
      if (genreString.isEmpty) genreString = "General"; // Default

      // Construct Category String (Single Select)
      String categoryString = _selectedCategory ?? "Custom";

      final newStation = Station(
        id: widget.station?.id ?? DateTime.now().millisecondsSinceEpoch,
        name: _nameController.text.trim(),
        genre: genreString,
        url: _urlController.text.trim(),
        logo: _logoController.text.trim().isEmpty
            ? null
            : _logoController.text.trim(),
        color: _formatColor(_colorController.text),
        category: categoryString,
        icon: _iconController.text.trim().isEmpty
            ? 'music'
            : _iconController.text.trim(),
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
