import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

import '../providers/radio_provider.dart';
import '../models/station.dart';
import '../widgets/station_card.dart';
import '../widgets/now_playing_header.dart';

class MusicStreamHome extends StatelessWidget {
  const MusicStreamHome({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    // User Request: Show ONLY favorites
    var stations = provider.allStations
        .where((s) => provider.favorites.contains(s.id))
        .toList();

    // Grouping Logic
    final Map<String, List<Station>> grouped = {};
    // Group by category for the main view
    for (var s in stations) {
      final category = s.category.trim();
      if (category.isNotEmpty) {
        if (!grouped.containsKey(category)) grouped[category] = [];
        grouped[category]!.add(s);
      }
    }

    // Sort categories
    // Logic: 1. Sync genres to provider. 2. Use provider order.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        provider.syncCategories(grouped.keys.toList());
      }
    });

    final categories = grouped.keys.toList();
    // Sort grouped keys based on provider.categoryOrder
    categories.sort((a, b) {
      int indexA = provider.categoryOrder.indexOf(a);
      int indexB = provider.categoryOrder.indexOf(b);
      if (indexA == -1) indexA = 999;
      if (indexB == -1) indexB = 999;
      return indexA.compareTo(indexB);
    });

    final isDesktop = MediaQuery.of(context).size.width > 700;
    final double contentPadding = isDesktop ? 32.0 : 16.0;

    return SafeArea(
      top: false,
      bottom: false,
      child: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              sliver: SliverSafeArea(
                top: false,
                bottom: false,
                sliver: SliverPersistentHeader(
                  pinned: true,
                  delegate: NowPlayingHeaderDelegate(
                    minHeight: 90 + MediaQuery.of(context).padding.top,
                    maxHeight: 160 + MediaQuery.of(context).padding.top,
                    topPadding: MediaQuery.of(context).padding.top,
                  ),
                ),
              ),
            ),
          ];
        },
        body: Builder(
          builder: (context) {
            return CustomScrollView(
              key: const PageStorageKey(
                "MusicStreamScrollKey",
              ), // Add Key for state preservation
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverOverlapInjector(
                  handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                    context,
                  ),
                ),
                // AppBar moved to headerSliverBuilder
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: contentPadding),
                  sliver: SliverToBoxAdapter(
                    child: categories.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 48.0),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.favorite_border,
                                    size: 48,
                                    color: Theme.of(
                                      context,
                                    ).iconTheme.color?.withValues(alpha: 0.24),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    "No favorites yet",
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).textTheme.headlineSmall?.color,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    "Search for stations to add them to your favorites",
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.color
                                          ?.withValues(alpha: 0.6),
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),

                // Genres List with SliverReorderableList
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: contentPadding),
                  sliver: SliverReorderableList(
                    itemCount: categories.length,
                    onReorder: (oldIndex, newIndex) {
                      if (oldIndex < newIndex) {
                        newIndex -= 1;
                      }
                      final item = categories[oldIndex];
                      final temp = List.of(categories)..removeAt(oldIndex);

                      String? after;
                      String? before;

                      if (newIndex >= 0 && newIndex < temp.length) {
                        before = temp[newIndex];
                      }
                      if (newIndex > 0 && newIndex - 1 < temp.length) {
                        after = temp[newIndex - 1];
                      }

                      provider.moveCategory(item, after, before);
                    },
                    proxyDecorator: (child, index, animation) {
                      return AnimatedBuilder(
                        animation: animation,
                        builder: (BuildContext context, Widget? child) {
                          return Material(
                            color: Colors.transparent,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF1a1a2e,
                                ).withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.5),
                                    blurRadius: 20,
                                    spreadRadius: 2,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                                border: Border.all(color: Colors.white24),
                              ),
                              child: child,
                            ),
                          );
                        },
                        child: child,
                      );
                    },
                    itemBuilder: (context, index) {
                      final cat = categories[index];
                      return StationCategoryTile(
                        key: ValueKey('category_$cat'),
                        category: cat,
                        stations: grouped[cat]!,
                        index: index,
                        isCompactView: provider.isCompactView,
                        isDesktop: isDesktop,
                        provider: provider,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class StationCategoryTile extends StatefulWidget {
  final String category;
  final List<Station> stations;
  final int index;
  final bool isCompactView;
  final bool isDesktop;
  final RadioProvider provider;

  const StationCategoryTile({
    super.key,
    required this.category,
    required this.stations,
    required this.index,
    required this.isCompactView,
    required this.isDesktop,
    required this.provider,
  });

  @override
  State<StationCategoryTile> createState() => _StationCategoryTileState();
}

class _StationCategoryTileState extends State<StationCategoryTile> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Builder(
        builder: (ctx) {
          // Calculate contrast color for the card
          final cardColor = Theme.of(ctx).cardColor;
          final contrastColor = cardColor.computeLuminance() > 0.5
              ? Colors.black
              : Colors.white;

          // Create a local theme override for content inside this card
          final localTheme = Theme.of(ctx).copyWith(
            iconTheme: Theme.of(ctx).iconTheme.copyWith(color: contrastColor),
            textTheme: Theme.of(ctx).textTheme.apply(
              bodyColor: contrastColor,
              displayColor: contrastColor,
            ),
          );

          return Theme(
            data: localTheme,
            child: Column(
              children: [
                Theme(
                  // We already applied the localTheme, but we keep the transparent divider logic
                  data: localTheme.copyWith(dividerColor: Colors.transparent),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: ReorderableDragStartListener(
                      index: widget.index,
                      child: Icon(
                        Icons.drag_indicator,
                        color: Theme.of(
                          context,
                        ).iconTheme.color?.withValues(alpha: 0.2),
                      ),
                    ),
                    title: Text(
                      widget.category,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(
                              context,
                            ).textTheme.headlineSmall?.color,
                            fontSize: widget.isDesktop ? 24 : 20,
                          ),
                    ),
                    trailing: Icon(
                      _isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Theme.of(context).iconTheme.color,
                    ),
                    onTap: () {
                      setState(() {
                        _isExpanded = !_isExpanded;
                      });
                    },
                  ),
                ),
                AnimatedCrossFade(
                  firstChild: Container(),
                  secondChild: Column(
                    children: [
                      widget.isCompactView
                          ? ReorderableGridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 220,
                                    mainAxisExtent: 80,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                  ),
                              itemCount: widget.stations.length,
                              onReorder: (oldIndex, newIndex) {
                                final stationList = widget.stations;
                                if (oldIndex < 0 ||
                                    oldIndex >= stationList.length) {
                                  return;
                                }

                                final station = stationList[oldIndex];
                                final temp = List.of(stationList)
                                  ..removeAt(oldIndex);

                                int? afterId;
                                int? beforeId;

                                if (newIndex >= 0 && newIndex < temp.length) {
                                  beforeId = temp[newIndex].id;
                                }
                                if (newIndex > 0 &&
                                    newIndex - 1 < temp.length) {
                                  afterId = temp[newIndex - 1].id;
                                }

                                widget.provider.moveStation(
                                  station.id,
                                  afterId,
                                  beforeId,
                                );
                              },
                              itemBuilder: (context, index) {
                                final station = widget.stations[index];
                                return Container(
                                  key: ValueKey(station.id),
                                  child: StationCard(station: station),
                                );
                              },
                            )
                          : ReorderableListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              proxyDecorator: (child, index, animation) {
                                return Material(
                                  color: Colors.transparent,
                                  child: ScaleTransition(
                                    scale: animation.drive(
                                      Tween<double>(
                                        begin: 1.0,
                                        end: 1.02,
                                      ).chain(
                                        CurveTween(curve: Curves.easeOut),
                                      ),
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).cardColor,
                                        borderRadius: BorderRadius.circular(12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Theme.of(context).shadowColor
                                                .withValues(alpha: 0.2),
                                            blurRadius: 10,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                      child: child,
                                    ),
                                  ),
                                );
                              },
                              onReorder: (oldIndex, newIndex) {
                                if (oldIndex < newIndex) {
                                  newIndex -= 1;
                                }

                                final stationList = widget.stations;
                                final station = stationList[oldIndex];
                                final temp = List.of(stationList)
                                  ..removeAt(oldIndex);

                                int? afterId;
                                int? beforeId;

                                if (newIndex < temp.length) {
                                  beforeId = temp[newIndex].id;
                                }
                                if (newIndex > 0) {
                                  afterId = temp[newIndex - 1].id;
                                }

                                widget.provider.moveStation(
                                  station.id,
                                  afterId,
                                  beforeId,
                                );
                              },
                              itemCount: widget.stations.length,
                              itemBuilder: (context, index) {
                                final station = widget.stations[index];
                                return Container(
                                  key: ValueKey(station.id),
                                  margin: EdgeInsets.only(
                                    bottom: widget.isCompactView ? 8 : 12,
                                  ),
                                  child: StationCard(station: station),
                                );
                              },
                            ),
                      const SizedBox(height: 16),
                    ],
                  ),
                  crossFadeState: _isExpanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 300),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
