import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/radio_provider.dart';
import '../services/music_metadata_service.dart';
import '../providers/language_provider.dart';
import 'trending_details_screen.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import '../utils/glass_utils.dart';

class AddSongScreen extends StatefulWidget {
  const AddSongScreen({super.key});

  @override
  State<AddSongScreen> createState() => _AddSongScreenState();
}

class _AddSongScreenState extends State<AddSongScreen> {
  final TextEditingController _controller = TextEditingController();
  List<SongSearchResult> _results = [];
  final Set<SongSearchResult> _selectedItems = {};
  bool _isLoading = false;
  bool _hasSearched = false;
  Timer? _searchDebounce;

  // Speech to Text variables
  late stt.SpeechToText _speech;
  bool _isListening = false;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _performSearch(String val) async {
    if (val.trim().isEmpty) return;

    setState(() {
      _isLoading = true;
      _hasSearched = true;
      _results = [];
    });

    try {
      final provider = Provider.of<RadioProvider>(context, listen: false);
      final res = await provider.searchMusic(val);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _results = res;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        final lang = Provider.of<LanguageProvider>(context, listen: false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lang.translate('search_error').replaceAll('{0}', e.toString()),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          lang.translate('add_new_song'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_selectedItems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 8.0,
              ),
              child: ElevatedButton.icon(
                onPressed: _saveSelectedSongs,
                icon: const Icon(Icons.add, size: 18),
                label: Text(
                  lang
                      .translate('add_count')
                      .replaceAll('{0}', _selectedItems.length.toString()),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Container(
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.1),
                ),
              ),
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: lang.translate('search_hint'),
                  hintStyle: TextStyle(
                    color: theme.hintColor.withValues(alpha: 0.5),
                  ),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          _isListening ? Icons.mic : Icons.mic_none,
                          color: _isListening ? Colors.red : null,
                        ),
                        onPressed: _toggleListening,
                      ),
                      if (_controller.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () {
                            _controller.clear();
                            setState(() {
                              _hasSearched = false;
                              _results = [];
                            });
                          },
                        ),
                    ],
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                onChanged: (val) {
                  _searchDebounce?.cancel();
                  if (val.trim().length >= 3) {
                    _searchDebounce = Timer(
                      const Duration(milliseconds: 600),
                      () => _performSearch(val),
                    );
                  }
                  setState(() {});
                },
                onSubmitted: _performSearch,
              ),
            ),
          ),

          // Results Section
          Expanded(child: _buildResultsView(theme)),
        ],
      ),
    );
  }

  void _toggleListening() async {
    if (!_isListening) {
      // Prompt for permission if not granted
      var status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        return;
      }

      bool available = await _speech.initialize(
        onStatus: (val) {
          if (val == 'done' || val == 'notListening') {
            setState(() => _isListening = false);
            if (_controller.text.isNotEmpty) {
              _performSearch(_controller.text);
            }
          }
        },
        onError: (val) {
          setState(() => _isListening = false);
        },
      );
      if (available) {
        setState(() {
          _isListening = true;
          // When starting listen logic, clear results so it feels responsive
          _hasSearched = false;
          _results = [];
        });
        _speech.listen(
          onResult: (val) => setState(() {
            _controller.text = val.recognizedWords;
          }),
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
      if (_controller.text.isNotEmpty) {
        _performSearch(_controller.text);
      }
    }
  }

  Widget _buildResultsView(ThemeData theme) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasSearched) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 64,
              color: theme.dividerColor.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              lang.translate('start_searching'),
              style: TextStyle(color: theme.hintColor.withValues(alpha: 0.6)),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.music_off,
              size: 64,
              color: theme.dividerColor.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              lang.translate('no_results_found'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              lang.translate('try_searching_different'),
              style: TextStyle(color: theme.hintColor.withValues(alpha: 0.6)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final item = _results[index];
        final song = item.song;
        final isSelected = _selectedItems.contains(item);

        return Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: InkWell(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _selectedItems.remove(item);
                } else {
                  _selectedItems.add(item);
                }
              });
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.primaryColor.withValues(alpha: 0.1)
                    : theme.cardColor.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? theme.primaryColor.withValues(alpha: 0.3)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  // Album Art
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => TrendingDetailsScreen(
                            albumName: song.album,
                            artistName: song.artist,
                            artworkUrl: song.artUri,
                            appleMusicUrl: song.appleMusicUrl,
                            songName: song.title,
                          ),
                        ),
                      );
                    },
                    child: Hero(
                      tag: 'add_song_art_${song.id}_$index',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: song.artUri != null
                            ? CachedNetworkImage(
                                imageUrl: song.artUri!,
                                width: 56,
                                height: 56,
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Container(
                                  width: 56,
                                  height: 56,
                                  color: theme.dividerColor.withValues(
                                    alpha: 0.1,
                                  ),
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white24,
                                  ),
                                ),
                                errorWidget: (context, url, error) => Container(
                                  width: 56,
                                  height: 56,
                                  color: theme.dividerColor.withValues(
                                    alpha: 0.1,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    color: Colors.white24,
                                  ),
                                ),
                              )
                            : Container(
                                width: 56,
                                height: 56,
                                color: theme.dividerColor.withValues(
                                  alpha: 0.1,
                                ),
                                child: const Icon(
                                  Icons.music_note,
                                  color: Colors.white24,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Title & Artist
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          song.artist,
                          style: TextStyle(
                            color: theme.hintColor,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // Checkbox
                  Checkbox(
                    value: isSelected,
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _selectedItems.add(item);
                        } else {
                          _selectedItems.remove(item);
                        }
                      });
                    },
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    activeColor: theme.primaryColor,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showPlaylistSelectionDialog() {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    final playlists = provider.playlists;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.5,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).scaffoldBackgroundColor.withValues(alpha: 0.9),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(color: Colors.white10),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    lang.translate('add_to_playlist'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Option: Create New Playlist
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.add, color: Theme.of(context).primaryColor),
                ),
                title: Text(
                  lang.translate('create_new_playlist'),
                  style: TextStyle(
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _createNewPlaylistAndSave();
                },
              ),
              const Divider(color: Colors.white10),
              // Playlists List
              Expanded(
                child: ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final p = playlists[index];
                    return ListTile(
                      leading: const Icon(
                        Icons.playlist_play_rounded,
                        color: Colors.white70,
                      ),
                      title: Text(
                        p.name,
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _performSaveToPlaylist(p.id);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _createNewPlaylistAndSave() {
    final controller = TextEditingController();
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    GlassUtils.showGlassDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(
          lang.translate('new_playlist'),
          style: const TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: lang.translate('playlist_name'),
            labelStyle: const TextStyle(color: Colors.white54),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Theme.of(context).primaryColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(lang.translate('cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final name = controller.text;
                Navigator.pop(ctx);
                _performSaveToPlaylist(null, newPlaylistName: name);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
            ),
            child: Text(
              lang.translate('create'),
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _performSaveToPlaylist(
    String? playlistId, {
    String? newPlaylistName,
  }) async {
    final provider = Provider.of<RadioProvider>(context, listen: false);
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    final count = _selectedItems.length;

    // Show loading indicator
    GlassUtils.showGlassDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final songs = _selectedItems.map((item) => item.song).toList();
      String targetPlaylistId;

      if (newPlaylistName != null) {
        final newPlaylist = await provider.createPlaylist(
          newPlaylistName,
          songs: songs,
        );
        targetPlaylistId = newPlaylist.id;
      } else {
        await provider.addSongsToPlaylist(playlistId!, songs);
        targetPlaylistId = playlistId;
      }

      // Start background resolution for all added songs to ensure video links etc.
      provider.resolvePlaylistLinksInBackground(targetPlaylistId, songs);

      if (mounted) {
        Navigator.pop(context); // Pop loading
        Navigator.pop(context); // Pop AddSongScreen
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lang
                  .translate('successfully_added')
                  .replaceAll('{0}', count.toString())
                  .replaceAll(
                    '{1}',
                    count == 1
                        ? lang.translate('song_singular')
                        : lang.translate('songs_plural'),
                  ),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Pop loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lang
                  .translate('error_adding_songs')
                  .replaceAll('{0}', e.toString()),
            ),
          ),
        );
      }
    }
  }

  Future<void> _saveSelectedSongs() async {
    if (_selectedItems.isEmpty) return;
    _showPlaylistSelectionDialog();
  }
}
