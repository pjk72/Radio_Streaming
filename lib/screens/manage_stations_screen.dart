import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/radio_provider.dart';

import '../utils/icon_library.dart';
import 'edit_station_screen.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class ManageStationsScreen extends StatefulWidget {
  const ManageStationsScreen({super.key});

  @override
  State<ManageStationsScreen> createState() => _ManageStationsScreenState();
}

class _ManageStationsScreenState extends State<ManageStationsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isSearching = false;

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
    final allStations = provider.stations;

    final filteredStations = allStations.where((s) {
      if (_searchQuery.isEmpty) return true;
      return s.name.toLowerCase().contains(_searchQuery) ||
          s.genre.toLowerCase().contains(_searchQuery);
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: "Search Stations...",
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                autofocus: true,
              )
            : const Text(
                "Manage Stations",
                style: TextStyle(color: Colors.white),
              ),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close : Icons.search,
              color: Colors.white,
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
          ),
          if (!_isSearching) ...[
            Row(
              children: [
                Text(
                  provider.backupService.currentUser?.displayName
                          ?.split(' ')
                          .first ??
                      "Guest",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.white24,
                  backgroundImage:
                      provider.backupService.currentUser?.photoUrl != null
                      ? NetworkImage(
                          provider.backupService.currentUser!.photoUrl!,
                        )
                      : null,
                  child: provider.backupService.currentUser?.photoUrl == null
                      ? const Icon(Icons.person, size: 16, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 16),
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Theme.of(context).primaryColor,
        child: const Icon(Icons.add, color: Colors.white),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const EditStationScreen()),
          );
        },
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: filteredStations.length,
              itemBuilder: (context, index) {
                final s = filteredStations[index];
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
                                    errorBuilder: (c, e, s) => const Icon(
                                      Icons.radio,
                                      color: Colors.white,
                                    ),
                                  )
                                : Image.asset(
                                    s.logo!,
                                    errorBuilder: (c, e, s) => const Icon(
                                      Icons.radio,
                                      color: Colors.white,
                                    ),
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
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    s.genre,
                    style: const TextStyle(color: Colors.white54),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.white60),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => EditStationScreen(station: s),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.white60),
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: const Color(0xFF16213e),
                              title: const Text(
                                "Delete Station?",
                                style: TextStyle(color: Colors.white),
                              ),
                              content: Text(
                                "Are you sure you want to delete '${s.name}'?",
                                style: const TextStyle(color: Colors.white70),
                              ),
                              actions: [
                                TextButton(
                                  child: const Text("Cancel"),
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                ),
                                TextButton(
                                  child: const Text(
                                    "Delete",
                                    style: TextStyle(color: Colors.redAccent),
                                  ),
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                ),
                              ],
                            ),
                          );

                          if (confirm == true) {
                            provider.deleteStation(s.id);
                          }
                        },
                      ),
                    ],
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
