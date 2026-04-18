import 'dart:convert';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../providers/language_provider.dart';

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final langProvider = Provider.of<LanguageProvider>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        title: Text(langProvider.translate('appearance')),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 90),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Manual Overrides (Moved to Top) ---
            // --- Manual Overrides (Moved to Top) ---
            _buildSectionHeader(langProvider.translate('manual_overrides')),
            const SizedBox(height: 8),
            Text(
              langProvider.translate('manual_overrides_desc'),
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _buildCustomColorSection(context, themeProvider),
            const SizedBox(height: 32),

            _buildSectionHeader(langProvider.translate('background_image')),
            const SizedBox(height: 8),
            Text(
              langProvider.translate('background_image_desc'),
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _buildBackgroundImageSection(context, themeProvider),

            if (themeProvider.hasCustomColors) ...[
              const SizedBox(height: 24),
              Center(
                child: TextButton.icon(
                  onPressed: () => themeProvider.resetCustomColors(),
                  icon: const Icon(Icons.refresh),
                  label: Text(langProvider.translate('reset_to_defaults')),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 32),

            _buildSectionHeader(langProvider.translate('dark_themes')),
            const SizedBox(height: 16),
            _buildGrid(context, themeProvider, themeProvider.darkPresets),

            const SizedBox(height: 32),

            _buildSectionHeader(langProvider.translate('light_themes')),
            const SizedBox(height: 16),
            _buildGrid(context, themeProvider, themeProvider.lightPresets),

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
    final langProvider = Provider.of<LanguageProvider>(context);
    final hasImage = provider.customBackgroundImageUrl != null;

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
            langProvider.translate('primary_color'),
            langProvider.translate('primary_color_desc'),
            provider.activePrimaryColor,
            (c) => provider.setCustomPrimaryColor(c),
            'primary',
            provider,
          ),
          if (!hasImage) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            _buildColorTile(
              context,
              langProvider.translate('background_color'),
              langProvider.translate('background_color_desc'),
              provider.activeBackgroundColor,
              (c) => provider.setCustomBackgroundColor(c),
              'background',
              provider,
              isDisabled: hasImage,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _buildColorTile(
              context,
              langProvider.translate('card_color'),
              langProvider.translate('card_color_desc'),
              provider.activeCardColor,
              (c) => provider.setCustomCardColor(c),
              'card',
              provider,
              isDisabled: hasImage,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _buildColorTile(
              context,
              langProvider.translate('surface_header'),
              langProvider.translate('surface_header_desc'),
              provider.activeSurfaceColor,
              (c) => provider.setCustomSurfaceColor(c),
              'surface',
              provider,
              isDisabled: hasImage,
            ),
          ],
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
    String colorKey,
    ThemeProvider provider, {
    bool isDisabled = false,
  }) {
    return ListTile(
      enabled: !isDisabled,
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: isDisabled ? Colors.grey : null,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: isDisabled ? Colors.grey : null),
      ),
      trailing: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: currentColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      ),
      onTap: isDisabled
          ? null
          : () => _showColorPicker(context, colorKey, provider),
    );
  }

  void _showColorPicker(
    BuildContext context,
    String initialKey,
    ThemeProvider provider,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _AdvancedColorPicker(
          initialKey: initialKey,
          provider: provider,
        ),
      ),
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
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.5,
      ),
      itemCount: presets.length,
      itemBuilder: (context, index) {
        final preset = presets[index];
        final isSelected =
            provider.currentPreset.id == preset.id && !provider.hasCustomColors;

        return GestureDetector(
          onTap: () => provider.setPreset(preset.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: preset.backgroundColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? preset.primaryColor
                    : Colors.grey.withValues(alpha: 0.1),
                width: isSelected ? 2.5 : 1,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: preset.primaryColor.withValues(alpha: 0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : [],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                children: [
                  // Mock UI
                  Column(
                    children: [
                      Container(
                        height: 28,
                        width: double.infinity,
                        color: preset.surfaceColor,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Container(
                              width: 24,
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
                        child: Row(
                          children: [
                            Container(
                              width: 24,
                              color: preset.surfaceColor.withValues(alpha: 0.5),
                            ),
                            Expanded(
                              child: Center(
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: preset.cardColor,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  alignment: Alignment.center,
                                  child: Container(
                                    width: 20,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      color: preset.primaryColor,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Name Label
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      color: Colors.black.withValues(alpha: 0.6),
                      child: Text(
                        preset.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (isSelected)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: CircleAvatar(
                        radius: 8,
                        backgroundColor: preset.primaryColor,
                        child: const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 10,
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

  Widget _buildBackgroundImageSection(
    BuildContext context,
    ThemeProvider provider,
  ) {
    final langProvider = Provider.of<LanguageProvider>(context);
    final hasImage = provider.customBackgroundImageUrl != null;

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
          ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.image, color: Theme.of(context).primaryColor),
            ),
            title: Text(
              langProvider.translate('background_image'),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            subtitle: Text(
              hasImage
                  ? langProvider.translate('custom_search')
                  : langProvider.translate('use_default'),
              style: const TextStyle(fontSize: 12),
            ),
            onTap: () => _openImageSearch(context, provider),
          ),
          if (hasImage) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(
                Icons.refresh,
                color: Colors.redAccent,
                size: 20,
              ),
              title: Text(
                langProvider.translate('reset_background'),
                style: const TextStyle(color: Colors.redAccent, fontSize: 14),
              ),
              onTap: () => provider.setCustomBackgroundImage(null),
            ),
          ],
        ],
      ),
    );
  }

  void _openImageSearch(BuildContext context, ThemeProvider provider) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _ImageSearchPage(provider: provider),
      ),
    );
  }
}

class _ImageSearchPage extends StatefulWidget {
  final ThemeProvider provider;
  const _ImageSearchPage({required this.provider});

  @override
  State<_ImageSearchPage> createState() => _ImageSearchPageState();
}

class _ImageSearchPageState extends State<_ImageSearchPage> {
  final stt.SpeechToText speech = stt.SpeechToText();
  final TextEditingController controller = TextEditingController();
  List<String> results = [];
  bool isSearching = false;
  bool isListening = false;

  Future<void> performSearch() async {
    if (controller.text.isEmpty) return;
    setState(() {
      isSearching = true;
      results = [];
    });
    try {
      final urls = await _searchImagesRemote(controller.text);
      if (mounted) {
        setState(() {
          results = urls;
          isSearching = false;
        });
        if (urls.isEmpty) {
          final langProvider = Provider.of<LanguageProvider>(context, listen: false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(langProvider.translate('no_images_found')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isSearching = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Error searching images")),
        );
      }
    }
  }

  Future<void> listen() async {
    if (!isListening) {
      bool available = await speech.initialize(
        onStatus: (val) {
          if (val == 'done' || val == 'notListening') {
            if (mounted) setState(() => isListening = false);
          }
        },
        onError: (val) => mounted ? setState(() => isListening = false) : null,
      );
      if (available) {
        setState(() => isListening = true);
        speech.listen(
          onResult: (val) {
            setState(() {
              controller.text = val.recognizedWords;
              if (val.finalResult) {
                isListening = false;
                performSearch();
              }
            });
          },
        );
      }
    } else {
      setState(() => isListening = false);
      speech.stop();
    }
  }

  Future<List<String>> _searchImagesRemote(String query) async {
    try {
      final String encodedQuery = Uri.encodeComponent(query);
      final endpoints = [
        'https://unsplash.com/napi/search/photos?query=$encodedQuery&per_page=30',
        'https://unsplash.com/napi/search?query=$encodedQuery&per_page=30',
        'https://unsplash.com/napi/search/photos?query=$encodedQuery&xp=search-trending:control',
      ];
      final headers = {
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Accept': 'application/json',
        'Referer': 'https://unsplash.com/',
      };
      for (var endpoint in endpoints) {
        try {
          final url = Uri.parse(endpoint);
          final res = await http.get(url, headers: headers).timeout(const Duration(seconds: 8));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            dynamic resultsData;
            if (data['results'] is List) {
              resultsData = data['results'];
            } else if (data['photos']?['results'] is List) {
              resultsData = data['photos']['results'];
            } else if (data['results']?['photos']?['results'] is List) {
              resultsData = data['results']['photos']['results'];
            }
            if (resultsData is List && resultsData.isNotEmpty) {
              return resultsData
                  .map<String>((item) {
                    if (item is Map) {
                      final urls = item['urls'] as Map?;
                      return urls?['regular']?.toString() ??
                          urls?['small']?.toString() ??
                          urls?['full']?.toString() ??
                          '';
                    }
                    return '';
                  })
                  .where((u) => u.isNotEmpty)
                  .toList();
            }
          }
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
      debugPrint("Global search error: $e");
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = Provider.of<LanguageProvider>(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(langProvider.translate('background_image')),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: langProvider.translate('search_images_hint'),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (controller.text.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.clear_rounded),
                              onPressed: () => setState(() => controller.clear()),
                            ),
                          IconButton(
                            icon: Icon(
                              isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                              color: isListening ? Theme.of(context).primaryColor : null,
                            ),
                            onPressed: listen,
                          ),
                        ],
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    ),
                    onSubmitted: (_) => performSearch(),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: performSearch,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  style: IconButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          if (isSearching)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (results.isEmpty)
            Expanded(child: Center(child: Text(langProvider.translate('no_images_found'))))
          else
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.7,
                ),
                itemCount: results.length,
                itemBuilder: (ctx, index) {
                  return GestureDetector(
                    onTap: () {
                      widget.provider.setCustomBackgroundImage(results[index]);
                      Navigator.pop(context);
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(
                            results[index],
                            fit: BoxFit.cover,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return const Center(child: CircularProgressIndicator());
                            },
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey.withValues(alpha: 0.1),
                              child: const Icon(Icons.error_outline),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.8),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                              child: Text(
                                langProvider.translate('select_as_background'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
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
        ],
      ),
    );
  }
}

class _AdvancedColorPicker extends StatefulWidget {
  final String initialKey;
  final ThemeProvider provider;

  const _AdvancedColorPicker({
    required this.initialKey,
    required this.provider,
  });

  @override
  State<_AdvancedColorPicker> createState() => _AdvancedColorPickerState();
}

class _AdvancedColorPickerState extends State<_AdvancedColorPicker> {
  late String _activeKey;
  late Map<String, Color> _draftColors;

  late HSVColor _hsv;
  late TextEditingController _hexController;
  double _alpha = 1.0;

  @override
  void initState() {
    super.initState();
    _activeKey = widget.initialKey;
    if (widget.provider.customBackgroundImageUrl != null) {
      _activeKey = 'primary';
    }

    // Initialize draft colors from provider
    _draftColors = {
      'primary': widget.provider.activePrimaryColor,
      'background': widget.provider.activeBackgroundColor,
      'card': widget.provider.activeCardColor,
      'surface': widget.provider.activeSurfaceColor,
    };

    _loadColorForActiveKey();
  }

  void _loadColorForActiveKey() {
    final color = _draftColors[_activeKey]!;
    _hsv = HSVColor.fromColor(color);
    _alpha = color.opacity;
    _hexController = TextEditingController(
      text: color.value
          .toRadixString(16)
          .padLeft(8, '0')
          .substring(2)
          .toUpperCase(),
    );
  }

  void _switchKey(String userKey) {
    if (_activeKey == userKey) return;
    setState(() {
      _activeKey = userKey;
      _loadColorForActiveKey();
    });
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _onColorChanged(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      final newColor = hsv.toColor().withValues(alpha: _alpha);
      _draftColors[_activeKey] = newColor;

      _hexController.text = newColor.value
          .toRadixString(16)
          .padLeft(8, '0')
          .substring(2)
          .toUpperCase();
    });
  }

  void _onAlphaChanged(double val) {
    setState(() {
      _alpha = val;
      _draftColors[_activeKey] = _hsv.toColor().withValues(alpha: _alpha);
    });
  }

  void _onHexSubmitted(String val) {
    if (val.startsWith('#')) val = val.substring(1);
    if (val.length == 6) val = "FF$val";
    try {
      final int v = int.parse(val, radix: 16);
      setState(() {
        final color = Color(v);
        _hsv = HSVColor.fromColor(color);
        _alpha = color.opacity;
        _draftColors[_activeKey] = color;
      });
    } catch (_) {}
  }

  void _onHexChanged(String val) {
    if (val.startsWith('#')) val = val.substring(1);
    if (val.length == 6) val = "FF$val";
    if (val.length != 8) return; // Only update on valid Hex length

    try {
      final int v = int.parse(val, radix: 16);
      setState(() {
        final color = Color(v);
        _hsv = HSVColor.fromColor(color);
        _alpha = color.opacity;
        _draftColors[_activeKey] = color;
      });
    } catch (_) {}
  }

  void _saveAll() {
    widget.provider.setCustomPrimaryColor(_draftColors['primary']!);
    widget.provider.setCustomBackgroundColor(_draftColors['background']!);
    widget.provider.setCustomCardColor(_draftColors['card']!);
    widget.provider.setCustomSurfaceColor(_draftColors['surface']!);
    Navigator.pop(context);
  }

  Widget _buildPreview() {
    final langProvider = Provider.of<LanguageProvider>(context);
    final Color effectivePrimary = _draftColors['primary']!;
    final Color effectiveBg = _draftColors['background']!;
    final Color effectiveCard = _draftColors['card']!;
    final Color effectiveSurface = _draftColors['surface']!;

    final Color effectiveTextOnBg = effectiveBg.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

    final Color effectiveTextOnSurface =
        effectiveSurface.computeLuminance() > 0.5 ? Colors.black : Colors.white;

    final Color effectiveTextOnCard = effectiveCard.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;

    final String? backgroundUrl = widget.provider.customBackgroundImageUrl;

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            if (backgroundUrl != null)
              Positioned.fill(
                child: Image.network(
                  backgroundUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            // Glass effect overlay if image exists
            if (backgroundUrl != null)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                  child: Container(color: effectiveBg.withValues(alpha: 0.3)),
                ),
              ),
            Column(
              children: [
                // Mock Header / Surface
                Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: effectiveSurface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(Icons.menu, color: effectiveTextOnSurface, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          langProvider.translate('preview'),
                          style: TextStyle(
                            color: effectiveTextOnSurface,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.search,
                        color: effectiveTextOnSurface,
                        size: 20,
                      ),
                    ],
                  ),
                ),
                // Body content
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        langProvider.translate('content_area'),
                        style: TextStyle(
                          color: effectiveTextOnBg.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Mock Card 1
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: effectiveCard,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: effectivePrimary.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.music_note,
                                color: effectivePrimary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    langProvider.translate('song_title'),
                                    style: TextStyle(
                                      color: effectiveTextOnCard,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    langProvider.translate('artist_name'),
                                    style: TextStyle(
                                      color: effectiveTextOnCard.withValues(
                                        alpha: 0.6,
                                      ),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.play_circle_fill,
                              color: effectivePrimary,
                              size: 32,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final langProvider = Provider.of<LanguageProvider>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(langProvider.translate('edit_theme_colors')),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: ElevatedButton(
              onPressed: _saveAll,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor:
                    Theme.of(context).primaryColor.computeLuminance() > 0.5
                        ? Colors.black
                        : Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: Text(
                langProvider.translate('save'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
            // Tabs
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _buildTab(
                      langProvider.translate('color_primary'),
                      "primary",
                    ),
                  ),
                  if (widget.provider.customBackgroundImageUrl == null) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: _buildTab(
                        langProvider.translate('color_bg'),
                        "background",
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _buildTab(
                        langProvider.translate('color_card'),
                        "card",
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _buildTab(
                        langProvider.translate('color_surface'),
                        "surface",
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                children: [
                  // Preview
                  _buildPreview(),

                  const SizedBox(height: 16),

                  // 4. Hex Input
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white24),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: _hexController,
                          onSubmitted: _onHexSubmitted,
                          onChanged: _onHexChanged,
                          decoration: InputDecoration(
                            labelText: langProvider.translate('hex_code'),
                            prefixText: "#",
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // 1. Saturation / Value Box
                  AspectRatio(
                    aspectRatio: 1.5,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return GestureDetector(
                          onPanUpdate: (details) {
                            final box = context.findRenderObject() as RenderBox;
                            final localOffset = box.globalToLocal(
                              details.globalPosition,
                            );
                            final dx = localOffset.dx.clamp(
                              0.0,
                              constraints.maxWidth,
                            );
                            final dy = localOffset.dy.clamp(
                              0.0,
                              constraints.maxHeight,
                            );

                            setState(() {
                              _hsv = _hsv
                                  .withSaturation(dx / constraints.maxWidth)
                                  .withValue(1 - (dy / constraints.maxHeight));
                              _onColorChanged(_hsv);
                            });
                          },
                          onTapDown: (details) {
                            final dx = details.localPosition.dx.clamp(
                              0.0,
                              constraints.maxWidth,
                            );
                            final dy = details.localPosition.dy.clamp(
                              0.0,
                              constraints.maxHeight,
                            );
                            setState(() {
                              _hsv = _hsv
                                  .withSaturation(dx / constraints.maxWidth)
                                  .withValue(1 - (dy / constraints.maxHeight));
                              _onColorChanged(_hsv);
                            });
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white10),
                              color: HSVColor.fromAHSV(
                                1,
                                _hsv.hue,
                                1,
                                1,
                              ).toColor(),
                            ),
                            child: Stack(
                              children: [
                                // Saturation Gradient (Left to Right: White -> Pure)
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    gradient: const LinearGradient(
                                      colors: [
                                        Colors.white,
                                        Colors.transparent,
                                      ],
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                    ),
                                  ),
                                ),
                                // Value Gradient (Top to Bottom: Transparent -> Black)
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    gradient: const LinearGradient(
                                      colors: [
                                        Colors.transparent,
                                        Colors.black,
                                      ],
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                    ),
                                  ),
                                ),
                                // Cursor
                                Positioned(
                                  left:
                                      _hsv.saturation * constraints.maxWidth -
                                      10,
                                  top:
                                      (1 - _hsv.value) * constraints.maxHeight -
                                      10,
                                  child: Container(
                                    width: 20,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                      color: color,
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
                  const SizedBox(height: 24),

                  // 2. Hue Slider (Rainbow)
                  Container(
                    height: 20,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      gradient: LinearGradient(
                        colors: [
                          Colors.red,
                          Colors.yellow,
                          Colors.green,
                          Colors.cyan,
                          Colors.blue,
                          Color(0xFFFF00FF),
                          Colors.red,
                        ],
                      ),
                    ),
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 20,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 12,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 20,
                        ),
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        value: _hsv.hue,
                        min: 0,
                        max: 360,
                        onChanged: (val) {
                          _onColorChanged(_hsv.withHue(val));
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                  // Alpha Slider
                  Container(
                    height: 20,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color:
                          Colors.grey[300], // rudimentary checkerboard fallback
                    ),
                    child: Stack(
                      children: [
                        // Gradient from transparent to color
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: CustomPaint(
                              size: const Size.fromHeight(20),
                              painter: CheckerBoardPainter(),
                            ),
                          ),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            gradient: LinearGradient(
                              colors: [
                                _hsv.toColor().withValues(alpha: 0),
                                _hsv.toColor().withValues(alpha: 1),
                              ],
                            ),
                          ),
                        ),
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 20,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 12,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 20,
                            ),
                            activeTrackColor: Colors.transparent,
                            inactiveTrackColor: Colors.transparent,
                            thumbColor: Colors.white,
                          ),
                          child: Slider(
                            value: _alpha,
                            min: 0,
                            max: 1.0,
                            onChanged: _onAlphaChanged,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  Text(
                    langProvider.translate('rgb_channels'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),

                  // 3. RGB Sliders
                  _buildRGBSlider("R", color.red, Colors.red, (val) {
                    _onColorChanged(
                      HSVColor.fromColor(color.withRed(val.toInt())),
                    );
                  }),
                  _buildRGBSlider("G", color.green, Colors.green, (val) {
                    _onColorChanged(
                      HSVColor.fromColor(color.withGreen(val.toInt())),
                    );
                  }),
                  _buildRGBSlider("B", color.blue, Colors.blue, (val) {
                    _onColorChanged(
                      HSVColor.fromColor(color.withBlue(val.toInt())),
                    );
                  }),

                  const SizedBox(height: 40),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTab(String label, String key) {
    final bool isActive = _activeKey == key;
    final color = _draftColors[key]!;

    return GestureDetector(
      onTap: () => _switchKey(key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Theme.of(context).primaryColor : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive
                ? Colors.transparent
                : Colors.grey.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1),
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: isActive
                      ? Colors.white
                      : Theme.of(context).textTheme.bodyMedium?.color,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRGBSlider(
    String label,
    int value,
    Color activeColor,
    Function(double) onChanged,
  ) {
    return Row(
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: activeColor,
              thumbColor: activeColor,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 255,
              divisions: 255,
              label: value.toString(),
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 35,
          child: Text(value.toString(), textAlign: TextAlign.end),
        ),
      ],
    );
  }
}

class CheckerBoardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.src);
    final paint = Paint()..color = Colors.grey.shade300;
    const double sizeSq = 8;
    for (double y = 0; y < size.height; y += sizeSq) {
      for (double x = 0; x < size.width; x += sizeSq) {
        if (((x / sizeSq).floor() + (y / sizeSq).floor()) % 2 == 0) {
          canvas.drawRect(Rect.fromLTWH(x, y, sizeSq, sizeSq), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
