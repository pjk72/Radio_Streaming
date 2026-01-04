import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/radio_provider.dart';
import '../widgets/player_bar.dart';
import '../widgets/sidebar.dart';
import '../widgets/banner_ad_widget.dart';

import 'playlist_screen.dart';
import 'settings_screen.dart';
import 'musicstream_home.dart';

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
          body: Column(
            children: [
              // Unified Top Header (Title + Nav)
              if (!isDesktop) _buildTopHeader(context),

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

                    // Main Content Area
                    Expanded(
                      child: IndexedStack(
                        index: _navIndex,
                        children: [
                          const MusicStreamHome(),
                          const PlaylistScreen(),
                          const SettingsScreen(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Player Bar
              const PlayerBar(),

              // Banner Ad
              if (!isDesktop) const BannerAdWidget(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTopHeader(BuildContext context) {
    // Only for Mobile/Tablet (!isDesktop)
    final provider = Provider.of<RadioProvider>(context);

    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        bottom: 12,
        left: 16,
        right: 16,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF14141E).withValues(alpha: 0.95),
            const Color(0xFF14141E).withValues(alpha: 0.0),
          ],
          stops: const [0.7, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: Profile + Title
          SizedBox(
            height: 32,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.white24,
                      backgroundImage:
                          provider.backupService.currentUser?.photoUrl != null
                          ? NetworkImage(
                              provider.backupService.currentUser!.photoUrl!,
                            )
                          : null,
                      child:
                          provider.backupService.currentUser?.photoUrl == null
                          ? const Icon(
                              Icons.person,
                              size: 14,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
                const Center(
                  child: Text(
                    "MusicStream",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          // Row 2: Navigation Menu (Pill Style)
          Container(
            height: 24,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                _buildTopNavItem(Icons.radio, "Radio", 0),
                _buildTopNavItem(Icons.playlist_play_rounded, "Playlist", 1),
                _buildTopNavItem(Icons.settings, "Settings", 2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopNavItem(IconData icon, String label, int index) {
    final isSelected = _navIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _navIndex = index),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: isSelected
                ? Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  )
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: isSelected ? Colors.white : Colors.white60,
                size: 14,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white60,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _bgController.dispose();
    super.dispose();
  }
}
