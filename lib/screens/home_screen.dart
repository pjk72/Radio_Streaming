import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/radio_provider.dart';
import '../widgets/player_bar.dart';
import '../widgets/sidebar.dart';

import 'playlist_screen.dart';
import 'settings_screen.dart';
import 'radio_stream_home.dart';

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

    final isDesktop = MediaQuery.of(context).size.width > 700;

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

                    // Main Content Area with IndexedStack
                    Expanded(
                      child: IndexedStack(
                        index: _navIndex,
                        children: [
                          // 0. Radio Stream (Home)
                          const RadioStreamHome(),

                          // 1. Playlist
                          Padding(
                            padding: EdgeInsets.only(top: isDesktop ? 0 : 0.0),
                            child: const PlaylistScreen(),
                          ),

                          // 2. Settings
                          Padding(
                            padding: EdgeInsets.only(top: isDesktop ? 0 : 0.0),
                            child: const SettingsScreen(),
                          ),
                        ],
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
