import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/radio_provider.dart';
import '../widgets/player_bar.dart';
import '../widgets/sidebar.dart';
import '../widgets/banner_ad_widget.dart';
import '../widgets/admob_banner_widget.dart';

import 'playlist_screen.dart';
import 'settings_screen.dart';
import 'musicstream_home.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _navIndex = 0; // Navigation state

  @override
  void initState() {
    super.initState();
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

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
          if (Platform.isAndroid || Platform.isIOS) const BannerAdWidget(),
          // Second Banner (AdMob)
          if (Platform.isAndroid || Platform.isIOS) const AdMobBannerWidget(),
        ],
      ),
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
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
          ),
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
                          ? Icon(
                              Icons.person,
                              size: 14,
                              color: Theme.of(context).iconTheme.color,
                            )
                          : null,
                    ),
                  ),
                ),
                Center(
                  child: Text(
                    "MusicStream",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).textTheme.titleLarge?.color,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Row 2: Navigation Menu (Pill Style)
          Container(
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.all(4),
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
                ? Theme.of(context).primaryColor.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: isSelected
                ? Border.all(
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.3),
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
                color: isSelected
                    ? Theme.of(context).primaryColor
                    : Theme.of(context).unselectedWidgetColor,
                size: 14,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? Theme.of(context).primaryColor
                      : Theme.of(
                          context,
                        ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
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
    // _bgController.dispose();
    super.dispose();
  }
}
