import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text("Appearance"),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader("Dark Themes"),
            const SizedBox(height: 16),
            _buildGrid(context, themeProvider, themeProvider.darkPresets),

            const SizedBox(height: 32),

            _buildSectionHeader("Light Themes"),
            const SizedBox(height: 16),
            _buildGrid(context, themeProvider, themeProvider.lightPresets),

            const SizedBox(height: 32),
            _buildSectionHeader("Manual Overrides"),
            const SizedBox(height: 8),
            const Text(
              "Modify specific colors of the current theme manually.",
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _buildCustomColorSection(context, themeProvider),

            if (themeProvider.hasCustomColors) ...[
              const SizedBox(height: 24),
              Center(
                child: TextButton.icon(
                  onPressed: () => themeProvider.resetCustomColors(),
                  icon: const Icon(Icons.refresh),
                  label: const Text("Reset to Preset Defaults"),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildCustomColorSection(
    BuildContext context,
    ThemeProvider provider,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        children: [
          _buildColorTile(
            context,
            "Primary Color",
            "Main accent color for buttons and highlights",
            provider.activePrimaryColor,
            (c) => provider.setCustomPrimaryColor(c),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _buildColorTile(
            context,
            "Background Color",
            "Main app background",
            provider.activeBackgroundColor,
            (c) => provider.setCustomBackgroundColor(c),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _buildColorTile(
            context,
            "Card Color",
            "Background for lists and cards",
            provider.activeCardColor,
            (c) => provider.setCustomCardColor(c),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _buildColorTile(
            context,
            "Surface / Header",
            "App Bar, Nav Bar, and other surfaces",
            provider.activeSurfaceColor,
            (c) => provider.setCustomSurfaceColor(c),
          ),
        ],
      ),
    );
  }

  Widget _buildColorTile(
    BuildContext context,
    String title,
    String subtitle,
    Color currentColor,
    Function(Color) onColorSelected,
  ) {
    return ListTile(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: currentColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      ),
      onTap: () => _showColorPicker(context, title, onColorSelected),
    );
  }

  void _showColorPicker(
    BuildContext context,
    String title,
    Function(Color) onSelect,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return _EnhancedColorPicker(title: title, onSelect: onSelect);
      },
    );
  }

  Widget _buildGrid(
    BuildContext context,
    ThemeProvider provider,
    List<ThemePreset> presets,
  ) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 1.4,
      ),
      itemCount: presets.length,
      itemBuilder: (context, index) {
        final preset = presets[index];
        final isSelected =
            provider.currentPreset.id == preset.id && !provider.hasCustomColors;

        return GestureDetector(
          onTap: () => provider.setPreset(preset.id),
          child: Container(
            decoration: BoxDecoration(
              color: preset.backgroundColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? provider.currentPreset.primaryColor
                    : Colors.grey.withValues(alpha: 0.2),
                width: isSelected ? 3 : 1,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: provider.currentPreset.primaryColor.withValues(
                          alpha: 0.3,
                        ),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : [],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                children: [
                  // Mock UI to show off colors
                  Column(
                    children: [
                      // Header
                      Container(
                        height: 30,
                        width: double.infinity,
                        color: preset.surfaceColor,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Container(
                              width: 30,
                              height: 6,
                              decoration: BoxDecoration(
                                color: preset.brightness == Brightness.dark
                                    ? Colors.white24
                                    : Colors.black12,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              // Sidebar
                              Container(
                                width: 20,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: preset.surfaceColor,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              // Content
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 80,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: preset.cardColor,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Container(
                                      width: 50,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: preset.primaryColor,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
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

                  // Label Overlay
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                      ),
                      child: Text(
                        preset.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  if (isSelected)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: provider.currentPreset.primaryColor,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EnhancedColorPicker extends StatefulWidget {
  final String title;
  final Function(Color) onSelect;

  const _EnhancedColorPicker({required this.title, required this.onSelect});

  @override
  State<_EnhancedColorPicker> createState() => _EnhancedColorPickerState();
}

class _EnhancedColorPickerState extends State<_EnhancedColorPicker> {
  final TextEditingController _hexController = TextEditingController();
  Color? _customColor;

  final List<Color> _pickerColors = [
    // Vibrants
    const Color(0xFF6c5ce7), const Color(0xFFa29bfe), // Purples
    const Color(0xFF0984e3), const Color(0xFF74b9ff), // Blues
    const Color(0xFF00b894), const Color(0xFF55efc4), // Greens
    const Color(0xFFd63031), const Color(0xFFff7675), // Reds
    const Color(0xFFe17055), const Color(0xFFfab1a0), // Oranges
    const Color(0xFFfdcb6e), const Color(0xFFffeaa7), // Yellows
    const Color(0xFFe84393), const Color(0xFFfd79a8), // Pinks
    const Color(0xFF341f97), const Color(0xFF5f27cd), // Deep Purples
    const Color(0xFFff9f43), const Color(0xFFfeca57), // Amber/Orange
    const Color(0xFF1DB954), // Spotify Green
    // Darks / Greys
    const Color(0xFF2d3436), const Color(0xFF636e72),
    const Color(0xFF000000), const Color(0xFF1e1e1e),
    const Color(0xFF0a0a0f), const Color(0xFF13131f), // Deep darks
    const Color(0xFF1e1e24), const Color(0xFF1e1e2e),
    const Color(0xFF222f3e), const Color(0xFF2f3542),
    // Lights / Whites
    const Color(0xFFdfe6e9), const Color(0xFFb2bec3),
    const Color(0xFFffffff), const Color(0xFFf5f6fa),
    const Color(0xFFfff0f6), const Color(0xFFfcf4ff),
  ];

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _onHexChanged(String value) {
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6 || value.length == 8) {
      try {
        if (value.length == 6) value = 'FF$value';
        final color = Color(int.parse(value, radix: 16));
        setState(() {
          _customColor = color;
        });
      } catch (_) {
        // Invalid hex
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                "Select ${widget.title}",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
            ),

            // Hex Code Input
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hexController,
                      onChanged: _onHexChanged,
                      decoration: InputDecoration(
                        hintText: "Enter Hex Code (e.g. #6C5CE7)",
                        prefixText: "# ",
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.palette_outlined),
                          onPressed: () => _showFullPalette(context),
                        ),
                        filled: true,
                        fillColor: Theme.of(context).scaffoldBackgroundColor,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        isDense: true,
                      ),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  if (_customColor != null) ...[
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () {
                        widget.onSelect(_customColor!);
                        Navigator.pop(context);
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _customColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 2),
                        ),
                        child: const Icon(Icons.check, color: Colors.white),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 20),

            Expanded(
              child: GridView.builder(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 1.0,
                ),
                itemCount: _pickerColors.length,
                itemBuilder: (context, index) {
                  final color = _pickerColors[index];
                  return GestureDetector(
                    onTap: () {
                      widget.onSelect(color);
                      Navigator.pop(context);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.grey.withValues(alpha: 0.3),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
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
      },
    );
  }

  void _showFullPalette(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          "Full Palette",
          style: TextStyle(
            color: Theme.of(context).textTheme.titleLarge?.color,
          ),
        ),
        content: SizedBox(
          width: 320,
          height: 400,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _buildHueSection(ctx, "Vibrant Reds", Colors.red, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                    _buildHueSection(ctx, "Deep Oranges", Colors.orange, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                    _buildHueSection(ctx, "Golden Yellows", Colors.amber, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                    _buildHueSection(ctx, "Emerald Greens", Colors.green, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                    _buildHueSection(ctx, "Ocean Blues", Colors.blue, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                    _buildHueSection(ctx, "Indigo & Violets", Colors.indigo, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                    _buildHueSection(ctx, "Purple Hues", Colors.purple, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                    _buildHueSection(ctx, "Neutral Greys", Colors.grey, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                    _buildHueSection(ctx, "Blue Greys", Colors.blueGrey, [
                      50,
                      100,
                      200,
                      300,
                      400,
                      500,
                      600,
                      700,
                      800,
                      900,
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  Widget _buildHueSection(
    BuildContext context,
    String title,
    MaterialColor color,
    List<int> shades,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: shades.map((shade) {
            final c = color[shade]!;
            return GestureDetector(
              onTap: () {
                _hexController.text = c.value
                    .toRadixString(16)
                    .substring(2)
                    .toUpperCase();
                _onHexChanged(_hexController.text);
                Navigator.pop(context);
              },
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
