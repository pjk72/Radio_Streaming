import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../models/saved_song.dart';
import '../providers/radio_provider.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          Provider.of<LanguageProvider>(
            context,
            listen: false,
          ).translate('no_duplicates_found'),
        ),
      ),
    );
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
      backgroundColor: Theme.of(context).cardColor,
      title: Text(
        Provider.of<LanguageProvider>(
          context,
          listen: false,
        ).translate('duplicate_songs_found'),
        style: TextStyle(color: Theme.of(context).textTheme.titleLarge?.color),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.duplicates.isEmpty
            ? Text(
                Provider.of<LanguageProvider>(
                  context,
                  listen: false,
                ).translate('no_duplicates_remaining'),
                style: TextStyle(
                  color: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
                ),
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
                    color: Theme.of(context).canvasColor.withValues(alpha: 0.3),
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "$title - $artist",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(
                                context,
                              ).textTheme.titleMedium?.color,
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
                                          : Theme.of(
                                              context,
                                            ).textTheme.bodyLarge?.color,
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
                                    "${Provider.of<LanguageProvider>(context, listen: false).translate('duration_label')} ${song.duration?.toString().split('.').first ?? '--:--'}",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color
                                          ?.withValues(alpha: 0.7),
                                    ),
                                  ),
                                  trailing: Checkbox(
                                    value: isMarked,
                                    checkColor: Colors.black,
                                    activeColor: Theme.of(context).primaryColor,
                                    side: BorderSide(
                                      color: Theme.of(context).dividerColor,
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
          child: Text(
            Provider.of<LanguageProvider>(
              context,
              listen: false,
            ).translate('cancel'),
            style: TextStyle(
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ),
        TextButton(
          onPressed: _songsToRemove.isEmpty
              ? null
              : () {
                  _removeSelected();
                  Navigator.of(context).pop();
                },
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          child: Text(
            Provider.of<LanguageProvider>(context, listen: false)
                .translate('remove_selected_count')
                .replaceAll('{0}', _songsToRemove.length.toString()),
          ),
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
      SnackBar(
        content: Text(
          Provider.of<LanguageProvider>(context, listen: false)
              .translate('removed_duplicates_count')
              .replaceAll('{0}', _songsToRemove.length.toString()),
        ),
      ),
    );
  }
}
