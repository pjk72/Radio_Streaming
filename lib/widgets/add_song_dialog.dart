import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/radio_provider.dart';
import '../services/music_metadata_service.dart';
import '../screens/album_details_screen.dart';

class AddSongDialog extends StatefulWidget {
  final RadioProvider provider;

  const AddSongDialog({super.key, required this.provider});

  static void show(BuildContext context, RadioProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AddSongDialog(provider: provider),
    );
  }

  @override
  State<AddSongDialog> createState() => _AddSongDialogState();
}

class _AddSongDialogState extends State<AddSongDialog> {
  final TextEditingController _controller = TextEditingController();
  List<SongSearchResult> _results = [];
  final Set<SongSearchResult> _selectedItems = {};
  bool _isLoading = false;
  bool _hasSearched = false;
  Timer? _searchDebounce;

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
      final res = await widget.provider.searchMusic(val);
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Search error: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: theme.cardColor,
      title: Text(
        "Add Song",
        style: TextStyle(
          color: theme.textTheme.titleLarge?.color,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Search by Song Name, Artist, or Album",
              style: TextStyle(
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
            TextField(
              controller: _controller,
              style: TextStyle(color: theme.textTheme.bodyMedium?.color),
              decoration: InputDecoration(
                hintText: "Enter search term...",
                hintStyle: TextStyle(
                  color: theme.textTheme.bodyMedium?.color?.withValues(
                    alpha: 0.4,
                  ),
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_controller.text.isNotEmpty)
                      IconButton(
                        icon: Icon(
                          Icons.close,
                          color: theme.iconTheme.color?.withValues(alpha: 0.7),
                          size: 20,
                        ),
                        onPressed: () {
                          _controller.clear();
                          setState(() {});
                        },
                      ),
                    IconButton(
                      icon: Icon(
                        Icons.search,
                        color: theme.iconTheme.color?.withValues(alpha: 0.7),
                      ),
                      onPressed: () => _performSearch(_controller.text),
                    ),
                  ],
                ),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: theme.primaryColor),
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
                setState(() {}); // Update clear button visibility
              },
              onSubmitted: _performSearch,
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              const SizedBox(
                height: 100,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_hasSearched && _results.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  "No results found.",
                  style: TextStyle(
                    color: theme.textTheme.bodySmall?.color?.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
              )
            else if (_results.isNotEmpty)
              Flexible(
                child: SizedBox(
                  height: 400,
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => Divider(
                      color: theme.dividerColor.withValues(alpha: 0.1),
                    ),
                    itemBuilder: (context, index) {
                      final item = _results[index];
                      final s = item.song;
                      final isSelected = _selectedItems.contains(item);

                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        selected: isSelected,
                        selectedTileColor: theme.primaryColor.withValues(
                          alpha: 0.1,
                        ),
                        onTap: () {
                          setState(() {
                            if (isSelected) {
                              _selectedItems.remove(item);
                            } else {
                              _selectedItems.add(item);
                            }
                          });
                        },
                        leading: GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => AlbumDetailsScreen(
                                  albumName: s.album,
                                  artistName: s.artist,
                                  artworkUrl: s.artUri,
                                  appleMusicUrl: s.appleMusicUrl,
                                  songName: s.title,
                                ),
                              ),
                            );
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: s.artUri != null
                                ? CachedNetworkImage(
                                    imageUrl: s.artUri!,
                                    width: 50,
                                    height: 50,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, _, _) => Container(
                                      width: 50,
                                      height: 50,
                                      color: theme.dividerColor.withValues(
                                        alpha: 0.1,
                                      ),
                                      child: Icon(
                                        Icons.music_note,
                                        color: theme.iconTheme.color
                                            ?.withValues(alpha: 0.5),
                                      ),
                                    ),
                                  )
                                : Container(
                                    width: 50,
                                    height: 50,
                                    color: theme.dividerColor.withValues(
                                      alpha: 0.1,
                                    ),
                                    child: Icon(
                                      Icons.music_note,
                                      color: theme.iconTheme.color?.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        title: Text(
                          s.title,
                          style: TextStyle(
                            color: theme.textTheme.titleMedium?.color,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          s.artist,
                          style: TextStyle(
                            color: theme.textTheme.bodyMedium?.color
                                ?.withValues(alpha: 0.7),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Checkbox(
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
                          activeColor: theme.primaryColor,
                          checkColor: Colors.white,
                          side: BorderSide(
                            color: theme.dividerColor.withValues(alpha: 0.5),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          child: const Text("Close"),
          onPressed: () => Navigator.pop(context),
        ),
        if (_selectedItems.isNotEmpty)
          ElevatedButton.icon(
            onPressed: () async {
              for (var item in _selectedItems) {
                await widget.provider.addFoundSongToGenre(item);
              }
              if (mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      "Added ${_selectedItems.length} songs to playlists",
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.add, color: Colors.white),
            label: Text(
              "Add (${_selectedItems.length})",
              style: const TextStyle(color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.primaryColor,
              foregroundColor: Colors.white,
            ),
          ),
      ],
    );
  }
}
