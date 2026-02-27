import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';

import '../providers/radio_provider.dart';

import '../utils/icon_library.dart';
import '../widgets/tutorial_create_radio_wizard.dart';
import 'edit_station_screen.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

enum GroupingMode { none, genre, origin }

class ManageStationsScreen extends StatefulWidget {
  const ManageStationsScreen({super.key});

  @override
  State<ManageStationsScreen> createState() => _ManageStationsScreenState();
}

class _ManageStationsScreenState extends State<ManageStationsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  bool _isSearching = false;
  // bool _isGridView = false; - Now in Provider
  // GroupingMode _groupingMode = GroupingMode.none; - Now in Provider

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final langProvider = Provider.of<LanguageProvider>(context);
    final allStations = provider.stations;

    final filteredStations =
        allStations.where((s) {
          if (_searchQuery.isEmpty) return true;
          return s.name.toLowerCase().contains(_searchQuery) ||
              s.genre.toLowerCase().contains(_searchQuery);
        }).toList()..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodyLarge?.color,
                ),
                decoration: InputDecoration(
                  hintText: langProvider.translate('search_stations'),
                  hintStyle: TextStyle(color: Theme.of(context).hintColor),
                  border: InputBorder.none,
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(
                            Icons.close,
                            color: Theme.of(context).iconTheme.color,
                          ),
                          onPressed: () {
                            _searchController.clear();
                          },
                        )
                      : null,
                ),
                autofocus: true,
              )
            : Text(
                langProvider.translate('manage_stations_title'),
                style: TextStyle(
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_fix_high),
            tooltip: langProvider.translate('station_wizard'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => Scaffold(
                    appBar: AppBar(
                      title: Text(langProvider.translate('add_station_wizard')),
                    ),
                    body: const TutorialCreateRadioWizard(),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Theme.of(context).primaryColor,
        child: Icon(Icons.add, color: Theme.of(context).colorScheme.onPrimary),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const EditStationScreen()),
          );
        },
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody(context, provider, filteredStations)),
        ],
      ),
      bottomNavigationBar: Container(
        height: 60,
        margin: const EdgeInsets.only(bottom: 16, left: 16, right: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).shadowColor.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: Icon(
                _isSearching ? Icons.close : Icons.search,
                color: _isSearching
                    ? Colors.blueAccent
                    : Theme.of(context).iconTheme.color,
              ),
              onPressed: () {
                setState(() {
                  if (_isSearching) {
                    _isSearching = false;
                    _searchController.clear();
                  } else {
                    _isSearching = true;
                  }
                });
              },
              tooltip: langProvider.translate('search'),
            ),
            IconButton(
              icon: Icon(
                provider.isManageGridView ? Icons.view_list : Icons.grid_view,
                color: Theme.of(context).iconTheme.color,
              ),
              onPressed: () =>
                  provider.setManageGridView(!provider.isManageGridView),
              tooltip: provider.isManageGridView
                  ? langProvider.translate('list_view')
                  : langProvider.translate('grid_view'),
            ),
            PopupMenuButton<GroupingMode>(
              icon: Icon(
                Icons.sort_rounded,
                color:
                    provider.manageGroupingMode !=
                        0 // 0 is GroupingMode.none
                    ? Colors.blueAccent
                    : Theme.of(context).iconTheme.color,
              ),
              onSelected: (mode) => provider.setManageGroupingMode(mode.index),
              tooltip: langProvider.translate('group_by'),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: GroupingMode.none,
                  child: Text(langProvider.translate('no_grouping')),
                ),
                PopupMenuItem(
                  value: GroupingMode.genre,
                  child: Text(langProvider.translate('group_by_genre')),
                ),
                PopupMenuItem(
                  value: GroupingMode.origin,
                  child: Text(langProvider.translate('group_by_origin')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    RadioProvider provider,
    List<dynamic> stations,
  ) {
    final groupingMode = GroupingMode.values[provider.manageGroupingMode];
    final langProvider = Provider.of<LanguageProvider>(context);
    if (groupingMode == GroupingMode.none) {
      return _buildUngroupedContent(context, provider, stations);
    }

    final Map<String, List<dynamic>> grouped = {};
    for (var s in stations) {
      String key;
      if (groupingMode == GroupingMode.genre) {
        key = s.genre.split('|').first.trim();
        if (key.isEmpty) key = langProvider.translate('unknown_genre');
      } else {
        key = s.category.trim();
        if (key.isEmpty) key = langProvider.translate('unknown_origin');
      }

      if (!grouped.containsKey(key)) grouped[key] = [];
      grouped[key]!.add(s);
    }

    final sortedKeys = grouped.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 90),
      itemCount: sortedKeys.length,
      itemBuilder: (context, index) {
        final key = sortedKeys[index];
        final groupStations = grouped[key]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.label_outline,
                    color: Colors.blueAccent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    key,
                    style: const TextStyle(
                      color: Colors.blueAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Divider(
                      color: Colors.blueAccent.withValues(alpha: 0.2),
                    ),
                  ),
                ],
              ),
            ),
            if (provider.isManageGridView)
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.8,
                ),
                itemCount: groupStations.length,
                itemBuilder: (context, idx) {
                  return _buildStationCard(
                    context,
                    groupStations[idx],
                    provider,
                  );
                },
              )
            else
              ...groupStations.map(
                (s) => _buildStationListItem(context, s, provider),
              ),
          ],
        );
      },
    );
  }

  Widget _buildUngroupedContent(
    BuildContext context,
    RadioProvider provider,
    List<dynamic> stations,
  ) {
    if (provider.isManageGridView) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.8,
        ),
        itemCount: stations.length,
        itemBuilder: (context, index) {
          final s = stations[index];
          return _buildStationCard(context, s, provider);
        },
      );
    } else {
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: 90),
        itemCount: stations.length,
        itemBuilder: (context, index) {
          final s = stations[index];
          return _buildStationListItem(context, s, provider);
        },
      );
    }
  }

  Widget _buildStationListItem(
    BuildContext context,
    dynamic s,
    RadioProvider provider,
  ) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Color(
            int.tryParse(s.color) ?? 0xFFFFFFFF,
          ).withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: s.logo != null && s.logo!.isNotEmpty
              ? (s.logo!.startsWith('http')
                    ? Image.network(
                        s.logo!,
                        errorBuilder: (c, e, s) =>
                            const Icon(Icons.radio, color: Colors.white),
                      )
                    : Image.asset(
                        s.logo!,
                        errorBuilder: (c, e, s) =>
                            const Icon(Icons.radio, color: Colors.white),
                      ))
              : FaIcon(
                  IconLibrary.getIcon(s.icon),
                  color: Colors.white,
                  size: 20,
                ),
        ),
      ),
      title: Text(
        s.name,
        style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
      ),
      subtitle: Text(
        s.genre,
        style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              provider.favorites.contains(s.id)
                  ? Icons.favorite
                  : Icons.favorite_border,
              color: provider.favorites.contains(s.id)
                  ? Colors.redAccent
                  : Colors.white54,
            ),
            onPressed: () => provider.toggleFavorite(s.id),
          ),
          IconButton(
            icon: Icon(
              provider.isPlaying && provider.currentStation?.id == s.id
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline,
              color: provider.isPlaying && provider.currentStation?.id == s.id
                  ? Colors.redAccent
                  : Theme.of(context).textTheme.bodyLarge?.color,
            ),
            onPressed: () {
              if (provider.isPlaying && provider.currentStation?.id == s.id) {
                provider.stop();
              } else {
                provider.playStation(s);
              }
            },
          ),
          _buildPopupMenu(
            context,
            s,
            provider,
            iconColor: Theme.of(context).iconTheme.color,
          ),
        ],
      ),
    );
  }

  Widget _buildPopupMenu(
    BuildContext context,
    dynamic s,
    RadioProvider provider, {
    Color? iconColor,
  }) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert,
        color: iconColor ?? Theme.of(context).iconTheme.color,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Theme.of(context).cardColor,
      onSelected: (value) async {
        final langProvider = Provider.of<LanguageProvider>(
          context,
          listen: false,
        );
        if (value == 'edit') {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => EditStationScreen(station: s)),
          );
        } else if (value == 'delete') {
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: Theme.of(context).cardColor,
              title: Text(
                langProvider.translate('delete_station_title'),
                style: TextStyle(
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
              content: Text(
                langProvider
                    .translate('delete_station_desc')
                    .replaceAll('{0}', s.name),
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                ),
              ),
              actions: [
                TextButton(
                  child: Text(langProvider.translate('cancel')),
                  onPressed: () => Navigator.of(ctx).pop(false),
                ),
                TextButton(
                  child: Text(
                    langProvider.translate('delete'),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(true),
                ),
              ],
            ),
          );

          if (confirm == true) {
            provider.deleteStation(s.id);
          }
        }
      },
      itemBuilder: (BuildContext context) {
        final langProvider = Provider.of<LanguageProvider>(
          context,
          listen: false,
        );
        return [
          PopupMenuItem(
            value: 'edit',
            child: Row(
              children: [
                Icon(Icons.edit, color: Theme.of(context).primaryColor),
                const SizedBox(width: 12),
                Text(
                  langProvider.translate('edit'),
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                const Icon(Icons.delete_outline, color: Colors.redAccent),
                const SizedBox(width: 12),
                Text(
                  langProvider.translate('delete'),
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
              ],
            ),
          ),
        ];
      },
    );
  }

  Widget _buildStationCard(
    BuildContext context,
    dynamic s,
    RadioProvider provider,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Color(
          int.tryParse(s.color) ?? 0xFFFFFFFF,
        ).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                    child: s.logo != null && s.logo!.isNotEmpty
                        ? Image.network(
                            s.logo!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.black26,
                              child: const Icon(
                                Icons.radio,
                                color: Colors.white24,
                                size: 40,
                              ),
                            ),
                          )
                        : Container(
                            color: Colors.black26,
                            child: Center(
                              child: FaIcon(
                                IconLibrary.getIcon(s.icon),
                                color: Colors.white54,
                                size: 30,
                              ),
                            ),
                          ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: _buildPopupMenu(context, s, provider),
                ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        if (provider.isPlaying &&
                            provider.currentStation?.id == s.id) {
                          provider.stop();
                        } else {
                          provider.playStation(s);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Icon(
                          provider.isPlaying &&
                                  provider.currentStation?.id == s.id
                              ? Icons.stop
                              : Icons.play_arrow,
                          color:
                              provider.isPlaying &&
                                  provider.currentStation?.id == s.id
                              ? Colors.redAccent
                              : Theme.of(context).textTheme.bodyLarge?.color,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: GestureDetector(
                    onTap: () => provider.toggleFavorite(s.id),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        provider.favorites.contains(s.id)
                            ? Icons.favorite
                            : Icons.favorite_border,
                        color: provider.favorites.contains(s.id)
                            ? Colors.redAccent
                            : Colors.white70,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  s.genre,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
