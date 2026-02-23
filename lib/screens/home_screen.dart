import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import '../widgets/player_bar.dart';
import '../widgets/sidebar.dart';

import 'playlist_screen.dart';
import 'settings_screen.dart';
import 'musicstream_home.dart';
import 'trending_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _navIndex = 0;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _navIndex);
    // Trigger startup playback ONLY when we reach Home Screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final radio = Provider.of<RadioProvider>(context, listen: false);
        radio.setShowGlobalBanner(true);
        radio.handleStartupPlayback();
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
                      onItemSelected: (index) {
                        setState(() => _navIndex = index);
                        _pageController.animateToPage(
                          index,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                    ),
                  ),

                // Main Content Area
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (index) {
                      setState(() => _navIndex = index);
                    },
                    children: [
                      const MusicStreamHome(),
                      const PlaylistScreen(),
                      const TrendingScreen(),
                      const SettingsScreen(),
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
    );
  }

  Widget _buildTopHeader(BuildContext context) {
    // Only for Mobile/Tablet (!isDesktop)
    final langProvider = Provider.of<LanguageProvider>(context);

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
          // Navigation Menu (Underline Style)
          Container(
            height: 40,
            padding: EdgeInsets.zero,
            child: Row(
              children: [
                _buildTopNavItem(
                  Icons.radio,
                  langProvider.translate('tab_radio'),
                  0,
                ),
                _buildTopNavItem(
                  Icons.playlist_play_rounded,
                  langProvider.translate('tab_library'),
                  1,
                ),
                _buildTopNavItem(
                  Icons.whatshot,
                  langProvider.translate('tab_trending'),
                  2,
                ),
                _buildTopNavItem(
                  Icons.settings,
                  langProvider.translate('settings'),
                  3,
                ),
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
        onTap: () {
          setState(() => _navIndex = index);
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected
                    ? Theme.of(context).primaryColor
                    : Colors.transparent,
                width: 3.0,
              ),
            ),
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
    _pageController.dispose();
    super.dispose();
  }
}
