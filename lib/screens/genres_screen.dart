import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../widgets/station_card.dart';

import '../utils/genre_mapper.dart';

class GenresScreen extends StatefulWidget {
  const GenresScreen({super.key});

  @override
  State<GenresScreen> createState() => _GenresScreenState();
}

class _GenresScreenState extends State<GenresScreen> {
  String? _selectedGenre;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

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
    final stations = provider.allStations;

    // Extract Genres
    final Set<String> rawGenres = {};
    for (var s in stations) {
      final split = s.genre.split(RegExp(r'[|/,]'));
      for (var g in split) {
        final clean = g.trim();
        if (clean.isNotEmpty) rawGenres.add(clean);
      }
    }
    final List<String> genres = rawGenres.toList()..sort();

    // Level 2: Stations List for Selected Genre
    if (_selectedGenre != null) {
      final genreStations =
          stations.where((s) {
            final split = s.genre.split(RegExp(r'[|/,]'));
            final matchesGenre = split.any((g) => g.trim() == _selectedGenre);
            if (!matchesGenre) return false;
            if (_searchQuery.isEmpty) return true;
            return s.name.toLowerCase().contains(_searchQuery);
          }).toList()..sort((a, b) {
            final isFavA = provider.favorites.contains(a.id);
            final isFavB = provider.favorites.contains(b.id);
            if (isFavA && !isFavB) return -1;
            if (!isFavA && isFavB) return 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });

      return Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2), // Separate area
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 8.0,
              ),
              color: Colors.white.withValues(alpha: 0.05),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () {
                      setState(() {
                        _selectedGenre = null;
                        _searchController.clear();
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _selectedGenre!,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                  const Spacer(),
                  // Search Bar
                  Container(
                    width: 200,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: "Search stations...",
                        hintStyle: TextStyle(
                          color: Colors.white38,
                          fontSize: 13,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: Colors.white38,
                          size: 18,
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.only(top: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  const SizedBox(height: 16),
                  const SizedBox(height: 16),

                  // NowPlayingHeader removed as requested
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: genreStations.isEmpty
                        ? const Center(
                            child: Text(
                              "No stations found",
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : GridView.builder(
                            padding: EdgeInsets.zero,
                            physics: const NeverScrollableScrollPhysics(),
                            shrinkWrap: true,
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 600,
                                  mainAxisExtent: 100,
                                  crossAxisSpacing: 16,
                                  mainAxisSpacing: 16,
                                ),
                            itemCount: genreStations.length,
                            itemBuilder: (context, index) {
                              return StationCard(station: genreStations[index]);
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Level 1: Genres List
    final filteredGenres = genres.where((g) {
      return g.toLowerCase().contains(_searchQuery);
    }).toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2), // Separate area
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16.0),
            color: Colors.white.withValues(alpha: 0.05),
            child: Row(
              children: [
                const Icon(Icons.category_rounded, color: Colors.white),
                const SizedBox(width: 12),
                Text(
                  "Genres",
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // Search Bar
                Container(
                  width: 180,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: "Search...",
                      hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: Icon(
                        Icons.search,
                        color: Colors.white38,
                        size: 18,
                      ),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.only(
                        top: 8,
                      ), // center text vertically
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: filteredGenres.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                childAspectRatio: 1.0,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemBuilder: (context, index) {
                final genre = filteredGenres[index];
                final count = stations.where((s) {
                  final split = s.genre.split(RegExp(r'[|/,]'));
                  return split.any((g) => g.trim() == genre);
                }).length;

                final genreImg = GenreMapper.getGenreImage(genre);

                return InkWell(
                  onTap: () {
                    setState(() {
                      _selectedGenre = genre;
                      _searchController.clear();
                    });
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: genreImg == null
                          ? Colors.white.withValues(alpha: 0.1)
                          : null,
                      border: Border.all(color: Colors.white12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        if (genreImg != null)
                          Positioned.fill(
                            child: genreImg.startsWith('http')
                                ? Image.network(
                                    genreImg,
                                    fit: BoxFit.cover,
                                    color: Colors.black.withValues(alpha: 0.6),
                                    colorBlendMode: BlendMode.darken,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Container(
                                        color: Colors.white.withValues(
                                          alpha: 0.1,
                                        ),
                                      );
                                    },
                                  )
                                : Image.asset(
                                    genreImg,
                                    fit: BoxFit.cover,
                                    color: Colors.black.withValues(alpha: 0.6),
                                    colorBlendMode: BlendMode.darken,
                                  ),
                          ),
                        Positioned(
                          right: -10,
                          bottom: -10,
                          child: Icon(
                            Icons.music_note,
                            size: 80,
                            color: Colors.white.withValues(alpha: 0.1),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(bottom: 8.0),
                                child: Icon(
                                  Icons.radio,
                                  color: Colors.white70,
                                  size: 24,
                                ),
                              ),
                              Text(
                                genre,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  letterSpacing: 1.0,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "$count Stations",
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12,
                                ),
                              ),
                            ],
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
