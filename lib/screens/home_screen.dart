import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/radio_provider.dart';
import '../models/station.dart';
import '../widgets/station_card.dart';
import '../widgets/player_bar.dart';
import '../widgets/sidebar.dart';

import 'playlist_screen.dart';
import 'genres_screen.dart';
import 'settings_screen.dart';
import '../widgets/now_playing_header.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _bgController;
  int _navIndex = 0; // Navigation state

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      duration: const Duration(seconds: 15),
      vsync: this,
    )..repeat();

    // Trigger startup playback ONLY when we reach Home Screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<RadioProvider>(
          context,
          listen: false,
        ).handleStartupPlayback();
      }
    });
  }

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    // Group stations
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

    return Stack(
      children: [
        // Animated Background
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) {
              return Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF0f0c29),
                      const Color(0xFF302b63),
                      const Color(0xFF24243e),
                    ],
                    stops: [
                      0.0,
                      0.5 + 0.2 * _bgController.value, // subtle shift
                      1.0,
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // Main Content
        Scaffold(
          key: _scaffoldKey,
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: false, // Prevent overlap
          appBar: !isDesktop && _navIndex != 0
              ? AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  title: const Text(
                    "Radio Stream",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  centerTitle: false,
                  actions: [
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
                              provider.backupService.currentUser?.photoUrl !=
                                  null
                              ? NetworkImage(
                                  provider.backupService.currentUser!.photoUrl!,
                                )
                              : null,
                          child:
                              provider.backupService.currentUser?.photoUrl ==
                                  null
                              ? const Icon(
                                  Icons.person,
                                  size: 16,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ],
                )
              : null,
          bottomNavigationBar: !isDesktop ? _buildBottomNav(context) : null,
          body: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isDesktop)
                      SizedBox(
                        width: 240,
                        child: Sidebar(
                          selectedIndex: _navIndex,
                          onItemSelected: (index) =>
                              setState(() => _navIndex = index),
                        ),
                      ),

                    // Main Grid
                    Expanded(
                      child: _navIndex == 2
                          ? Padding(
                              padding: EdgeInsets.only(
                                top: isDesktop ? 0 : 24.0,
                              ),
                              child: const PlaylistScreen(),
                            )
                          : _navIndex == 1
                          ? Padding(
                              padding: EdgeInsets.only(
                                top: isDesktop ? 0 : 24.0,
                              ),
                              child: const GenresScreen(),
                            )
                          : _navIndex == 3
                          ? Padding(
                              padding: EdgeInsets.only(
                                top: isDesktop ? 0 : 24.0,
                              ),
                              child: const SettingsScreen(),
                            )
                          : /* CUSTOM DRAG & DROP IMPLEMENTATION */ SafeArea(
                              top: false,
                              bottom: false,
                              child: NestedScrollView(
                                headerSliverBuilder: (context, innerBoxIsScrolled) {
                                  return [
                                    if (!isDesktop) ...[
                                      SliverSafeArea(
                                        top: true,
                                        bottom: false,
                                        sliver: SliverAppBar(
                                          backgroundColor: Colors.transparent,
                                          elevation: 0,
                                          floating: false,
                                          pinned: false,
                                          title: const Text(
                                            "Radio Stream",
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                          centerTitle: false,
                                          actions: [
                                            Row(
                                              children: [
                                                Text(
                                                  provider
                                                          .backupService
                                                          .currentUser
                                                          ?.displayName
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
                                                  backgroundColor:
                                                      Colors.white24,
                                                  backgroundImage:
                                                      provider
                                                              .backupService
                                                              .currentUser
                                                              ?.photoUrl !=
                                                          null
                                                      ? NetworkImage(
                                                          provider
                                                              .backupService
                                                              .currentUser!
                                                              .photoUrl!,
                                                        )
                                                      : null,
                                                  child:
                                                      provider
                                                              .backupService
                                                              .currentUser
                                                              ?.photoUrl ==
                                                          null
                                                      ? const Icon(
                                                          Icons.person,
                                                          size: 16,
                                                          color: Colors.white,
                                                        )
                                                      : null,
                                                ),
                                                const SizedBox(width: 16),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    SliverOverlapAbsorber(
                                      handle:
                                          NestedScrollView.sliverOverlapAbsorberHandleFor(
                                            context,
                                          ),
                                      sliver: SliverSafeArea(
                                        top: false,
                                        bottom: false,
                                        sliver: SliverPersistentHeader(
                                          pinned: true,
                                          delegate: NowPlayingHeaderDelegate(
                                            minHeight:
                                                110 +
                                                MediaQuery.of(
                                                  context,
                                                ).padding.top,
                                            maxHeight:
                                                160 +
                                                MediaQuery.of(
                                                  context,
                                                ).padding.top,
                                            topPadding: MediaQuery.of(
                                              context,
                                            ).padding.top,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ];
                                },
                                body: Builder(
                                  builder: (context) {
                                    return CustomScrollView(
                                      physics: const BouncingScrollPhysics(),
                                      slivers: [
                                        SliverOverlapInjector(
                                          handle:
                                              NestedScrollView.sliverOverlapAbsorberHandleFor(
                                                context,
                                              ),
                                        ),
                                        // AppBar moved to headerSliverBuilder
                                        SliverPadding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: contentPadding,
                                          ),
                                          sliver: SliverToBoxAdapter(
                                            child: categories.isEmpty
                                                ? Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          vertical: 48.0,
                                                        ),
                                                    child: Center(
                                                      child: Column(
                                                        children: [
                                                          Icon(
                                                            Icons
                                                                .favorite_border,
                                                            size: 48,
                                                            color:
                                                                Colors.white24,
                                                          ),
                                                          const SizedBox(
                                                            height: 16,
                                                          ),
                                                          Text(
                                                            "No favorites yet",
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize: 18,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                          ),
                                                          const SizedBox(
                                                            height: 8,
                                                          ),
                                                          Text(
                                                            "Go to Genres to add stations",
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white54,
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
                                          padding: EdgeInsets.symmetric(
                                            horizontal: contentPadding,
                                          ),
                                          sliver: SliverReorderableList(
                                            itemCount: categories.length,
                                            onReorder: (oldIndex, newIndex) {
                                              if (oldIndex < newIndex) {
                                                newIndex -= 1;
                                              }
                                              final item = categories[oldIndex];
                                              final temp = List.of(categories)
                                                ..removeAt(oldIndex);

                                              String? after;
                                              String? before;

                                              if (newIndex >= 0 &&
                                                  newIndex < temp.length) {
                                                before = temp[newIndex];
                                              }
                                              if (newIndex > 0 &&
                                                  newIndex - 1 < temp.length) {
                                                after = temp[newIndex - 1];
                                              }

                                              provider.moveCategory(
                                                item,
                                                after,
                                                before,
                                              );
                                            },
                                            proxyDecorator: (child, index, animation) {
                                              return AnimatedBuilder(
                                                animation: animation,
                                                builder:
                                                    (
                                                      BuildContext context,
                                                      Widget? child,
                                                    ) {
                                                      return Material(
                                                        color:
                                                            Colors.transparent,
                                                        child: Container(
                                                          decoration: BoxDecoration(
                                                            color:
                                                                const Color(
                                                                  0xFF1a1a2e,
                                                                ).withValues(
                                                                  alpha: 0.9,
                                                                ), // Solid dark background for readability
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  12,
                                                                ),
                                                            boxShadow: [
                                                              BoxShadow(
                                                                color: Colors
                                                                    .black
                                                                    .withValues(
                                                                      alpha:
                                                                          0.5,
                                                                    ),
                                                                blurRadius: 20,
                                                                spreadRadius: 2,
                                                                offset:
                                                                    const Offset(
                                                                      0,
                                                                      4,
                                                                    ),
                                                              ),
                                                            ],
                                                            border: Border.all(
                                                              color: Colors
                                                                  .white24,
                                                            ),
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
                                              return Container(
                                                key: ValueKey('category_$cat'),
                                                margin: const EdgeInsets.only(
                                                  bottom: 24,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.2),
                                                  border: Border.all(
                                                    color: Colors.white12,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Theme(
                                                  data: Theme.of(context)
                                                      .copyWith(
                                                        dividerColor:
                                                            Colors.transparent,
                                                      ),
                                                  child: ExpansionTile(
                                                    initiallyExpanded: true,
                                                    tilePadding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 16,
                                                          vertical: 8,
                                                        ),
                                                    iconColor: Colors.white,
                                                    collapsedIconColor:
                                                        Colors.white70,
                                                    shape: const Border(),
                                                    collapsedShape:
                                                        const Border(),
                                                    leading:
                                                        ReorderableDragStartListener(
                                                          index: index,
                                                          child: const Icon(
                                                            Icons
                                                                .drag_indicator,
                                                            color:
                                                                Colors.white24,
                                                          ),
                                                        ),
                                                    title: Text(
                                                      cat,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .headlineSmall
                                                          ?.copyWith(
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            color: Colors.white,
                                                            fontSize: isDesktop
                                                                ? 24
                                                                : 20,
                                                          ),
                                                    ),
                                                    children: [
                                                      // Horizontal Reorderable List of Stations
                                                      // Vertically Reorderable List of Stations
                                                      provider.isCompactView
                                                          ? ReorderableGridView.builder(
                                                              shrinkWrap: true,
                                                              physics:
                                                                  const NeverScrollableScrollPhysics(),
                                                              padding:
                                                                  const EdgeInsets.symmetric(
                                                                    horizontal:
                                                                        16,
                                                                    vertical: 8,
                                                                  ),
                                                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                                                maxCrossAxisExtent:
                                                                    220,
                                                                mainAxisExtent:
                                                                    80,
                                                                crossAxisSpacing:
                                                                    8,
                                                                mainAxisSpacing:
                                                                    8,
                                                              ),
                                                              itemCount:
                                                                  grouped[cat]!
                                                                      .length,
                                                              onReorder:
                                                                  (
                                                                    oldIndex,
                                                                    newIndex,
                                                                  ) {
                                                                    final stationList =
                                                                        grouped[cat]!;
                                                                    // Safe access
                                                                    if (oldIndex <
                                                                            0 ||
                                                                        oldIndex >=
                                                                            stationList.length) {
                                                                      return;
                                                                    }

                                                                    final station =
                                                                        stationList[oldIndex];
                                                                    final temp =
                                                                        List.of(
                                                                          stationList,
                                                                        )..removeAt(
                                                                          oldIndex,
                                                                        );

                                                                    int?
                                                                    afterId;
                                                                    int?
                                                                    beforeId;

                                                                    if (newIndex >=
                                                                            0 &&
                                                                        newIndex <
                                                                            temp.length) {
                                                                      beforeId =
                                                                          temp[newIndex]
                                                                              .id;
                                                                    }
                                                                    if (newIndex >
                                                                            0 &&
                                                                        newIndex -
                                                                                1 <
                                                                            temp.length) {
                                                                      afterId =
                                                                          temp[newIndex -
                                                                                  1]
                                                                              .id;
                                                                    }

                                                                    provider.moveStation(
                                                                      station
                                                                          .id,
                                                                      afterId,
                                                                      beforeId,
                                                                    );
                                                                  },
                                                              itemBuilder: (context, index) {
                                                                final station =
                                                                    grouped[cat]![index];
                                                                return Container(
                                                                  key: ValueKey(
                                                                    station.id,
                                                                  ),
                                                                  child: StationCard(
                                                                    station:
                                                                        station,
                                                                  ),
                                                                );
                                                              },
                                                            )
                                                          : ReorderableListView.builder(
                                                              shrinkWrap: true,
                                                              physics:
                                                                  const NeverScrollableScrollPhysics(),
                                                              // No 'scrollDirection' means vertical by default
                                                              padding:
                                                                  const EdgeInsets.symmetric(
                                                                    horizontal:
                                                                        16,
                                                                    vertical: 8,
                                                                  ),

                                                              proxyDecorator:
                                                                  (
                                                                    child,
                                                                    index,
                                                                    animation,
                                                                  ) {
                                                                    return Material(
                                                                      color: Colors
                                                                          .transparent,
                                                                      child: ScaleTransition(
                                                                        scale: animation.drive(
                                                                          Tween<
                                                                                double
                                                                              >(
                                                                                begin: 1.0,
                                                                                end: 1.02,
                                                                              )
                                                                              .chain(
                                                                                CurveTween(
                                                                                  curve: Curves.easeOut,
                                                                                ),
                                                                              ),
                                                                        ),
                                                                        child: Container(
                                                                          decoration: BoxDecoration(
                                                                            color: Colors.black.withValues(
                                                                              alpha: 0.2,
                                                                            ),
                                                                            borderRadius: BorderRadius.circular(
                                                                              12,
                                                                            ),
                                                                            boxShadow: [
                                                                              BoxShadow(
                                                                                color: Colors.black.withValues(
                                                                                  alpha: 0.3,
                                                                                ),
                                                                                blurRadius: 10,
                                                                                spreadRadius: 2,
                                                                              ),
                                                                            ],
                                                                          ),
                                                                          child:
                                                                              child,
                                                                        ),
                                                                      ),
                                                                    );
                                                                  },

                                                              onReorder:
                                                                  (
                                                                    oldIndex,
                                                                    newIndex,
                                                                  ) {
                                                                    if (oldIndex <
                                                                        newIndex) {
                                                                      newIndex -=
                                                                          1;
                                                                    }

                                                                    final stationList =
                                                                        grouped[cat]!;
                                                                    final station =
                                                                        stationList[oldIndex];
                                                                    final temp =
                                                                        List.of(
                                                                          stationList,
                                                                        )..removeAt(
                                                                          oldIndex,
                                                                        );

                                                                    int?
                                                                    afterId;
                                                                    int?
                                                                    beforeId;

                                                                    if (newIndex <
                                                                        temp.length) {
                                                                      beforeId =
                                                                          temp[newIndex]
                                                                              .id;
                                                                    }
                                                                    if (newIndex >
                                                                        0) {
                                                                      afterId =
                                                                          temp[newIndex -
                                                                                  1]
                                                                              .id;
                                                                    }

                                                                    provider.moveStation(
                                                                      station
                                                                          .id,
                                                                      afterId,
                                                                      beforeId,
                                                                    );
                                                                  },
                                                              itemCount:
                                                                  grouped[cat]!
                                                                      .length,
                                                              itemBuilder: (context, index) {
                                                                final station =
                                                                    grouped[cat]![index];
                                                                return Container(
                                                                  key: ValueKey(
                                                                    station.id,
                                                                  ),
                                                                  margin: EdgeInsets.only(
                                                                    bottom:
                                                                        provider
                                                                            .isCompactView
                                                                        ? 8
                                                                        : 12,
                                                                  ),
                                                                  child: StationCard(
                                                                    station:
                                                                        station,
                                                                  ),
                                                                );
                                                              },
                                                            ),
                                                      const SizedBox(
                                                        height: 16,
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
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),

              // Player Bar
              const PlayerBar(),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _bgController.dispose();
    super.dispose();
  }

  Widget _buildBottomNav(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(
          0xFF1a1a2e,
        ).withValues(alpha: 0.95), // Deep dark, slightly transparent
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: _navIndex,
        onTap: (index) => setState(() => _navIndex = index),
        backgroundColor: Colors.transparent, // Handled by Container
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        selectedItemColor: Theme.of(context).primaryColor,
        unselectedItemColor: Colors.white60,
        showUnselectedLabels: true,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.radio),
            label: "Radio Stream",
          ),
          BottomNavigationBarItem(icon: Icon(Icons.category), label: "Genres"),
          BottomNavigationBarItem(
            icon: Icon(Icons.playlist_play_rounded),
            label: "Playlist",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: "Settings",
          ),
        ],
      ),
    );
  }
}
