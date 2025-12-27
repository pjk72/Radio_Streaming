import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import '../providers/radio_provider.dart';

void scanForDuplicates(
  BuildContext context,
  RadioProvider provider,
  Playlist playlist,
) {
  // 1. Group songs by "Title|Artist"
  final Map<String, List<SavedSong>> groups = {};
  for (var s in playlist.songs) {
    final key =
        "${s.title.trim().toLowerCase()}|${s.artist.trim().toLowerCase()}";
    if (!groups.containsKey(key)) {
      groups[key] = [];
    }
    groups[key]!.add(s);
  }

  // 2. Filter for groups with > 1 song
  final List<List<SavedSong>> duplicates = [];
  groups.forEach((key, list) {
    if (list.length > 1) {
      duplicates.add(list);
    }
  });

  if (duplicates.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("No duplicates found.")));
    return;
  }

  // 3. Show Resolution Dialog
  showDialog(
    context: context,
    builder: (ctx) => _DuplicateResolutionDialog(
      playlist: playlist,
      duplicates: duplicates,
      provider: provider,
    ),
  );
}

class _DuplicateResolutionDialog extends StatefulWidget {
  final Playlist playlist;
  final List<List<SavedSong>> duplicates;
  final RadioProvider provider;

  const _DuplicateResolutionDialog({
    required this.playlist,
    required this.duplicates,
    required this.provider,
  });

  @override
  State<_DuplicateResolutionDialog> createState() =>
      _DuplicateResolutionDialogState();
}

class _DuplicateResolutionDialogState
    extends State<_DuplicateResolutionDialog> {
  // Tracks song IDs marked for removal
  final Set<String> _songsToRemove = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      title: const Text(
        "Duplicate Songs Found",
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.duplicates.isEmpty
            ? const Text(
                "No duplicates remaining.",
                style: TextStyle(color: Colors.white70),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.duplicates.length,
                itemBuilder: (context, index) {
                  final group = widget.duplicates[index];
                  if (group.isEmpty) return const SizedBox.shrink();

                  final firstSong = group.first;
                  final title = firstSong.title;
                  final artist = firstSong.artist;

                  return Card(
                    color: Colors.white.withValues(alpha: 0.1),
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "$title - $artist",
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...group.map((song) {
                            final isMarked = _songsToRemove.contains(song.id);

                            return AnimatedBuilder(
                              animation: widget.provider,
                              builder: (context, child) {
                                final isPlayingThis =
                                    widget.provider.isPlaying &&
                                    widget.provider.audioOnlySongId == song.id;

                                return ListTile(
                                  leading: IconButton(
                                    icon: Icon(
                                      isPlayingThis
                                          ? Icons.stop_rounded
                                          : Icons.play_arrow_rounded,
                                      color: isPlayingThis
                                          ? Colors.redAccent
                                          : Colors.white70,
                                      size: 32,
                                    ),
                                    onPressed: () {
                                      if (isPlayingThis) {
                                        widget.provider.stopYoutubeAudio();
                                      } else {
                                        widget.provider.playPlaylistSong(
                                          song,
                                          widget.playlist.id,
                                        );
                                      }
                                    },
                                  ),
                                  title: Text(
                                    "Duration: ${song.duration?.toString().split('.').first ?? '--:--'}",
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  trailing: Checkbox(
                                    value: isMarked,
                                    checkColor: Colors.black,
                                    activeColor: Colors.white,
                                    side: const BorderSide(
                                      color: Colors.white54,
                                    ),
                                    onChanged: (val) {
                                      setState(() {
                                        if (val == true) {
                                          _songsToRemove.add(song.id);
                                        } else {
                                          _songsToRemove.remove(song.id);
                                        }
                                      });
                                    },
                                  ),
                                );
                              },
                            );
                          }),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: _songsToRemove.isEmpty
              ? null
              : () {
                  _removeSelected();
                  Navigator.of(context).pop();
                },
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          child: Text("Remove Selected (${_songsToRemove.length})"),
        ),
      ],
    );
  }

  void _removeSelected() {
    widget.provider.removeSongsFromPlaylist(
      widget.playlist.id,
      _songsToRemove.toList(),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Removed ${_songsToRemove.length} duplicates.")),
    );
  }
}
