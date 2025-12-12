import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import '../models/station.dart';
import '../providers/radio_provider.dart';

import '../utils/icon_library.dart';

class StationCard extends StatefulWidget {
  final Station station;

  const StationCard({super.key, required this.station});

  @override
  State<StationCard> createState() => _StationCardState();
}

class _StationCardState extends State<StationCard> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RadioProvider>(context);
    final isFavorite = provider.favorites.contains(widget.station.id);
    final isPlaying =
        provider.currentStation?.id == widget.station.id && provider.isPlaying;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => provider.playStation(widget.station),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          transform: Matrix4.identity()
            ..translate(0.0, _isHovering ? -5.0 : 0.0),
          decoration: BoxDecoration(
            // Gradient background for premium feel
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(int.parse(widget.station.color)).withValues(alpha: 0.15),
                Colors.white.withValues(alpha: 0.05),
              ],
            ),
            borderRadius: BorderRadius.circular(24), // Softer corners
            border: Border.all(
              color: _isHovering
                  ? Color(
                      int.parse(widget.station.color),
                    ).withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.1),
              width: _isHovering ? 1.5 : 1,
            ),
            boxShadow: _isHovering
                ? [
                    BoxShadow(
                      color: Color(
                        int.parse(widget.station.color),
                      ).withValues(alpha: 0.3),
                      blurRadius: 20,
                      spreadRadius: -2,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20.0,
                    vertical: 12.0,
                  ),
                  child: Row(
                    children: [
                      // Icon / Logo
                      Container(
                        width: 56,
                        height: 56,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Center(child: _buildVisual(widget.station)),
                      ),

                      const SizedBox(width: 20),

                      // Info
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.station.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 18,
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.station.genre.toUpperCase(),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.0,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),

                      // Favorite & Live Status
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          GestureDetector(
                            onTap: () =>
                                provider.toggleFavorite(widget.station.id),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isFavorite
                                    ? Colors.white.withValues(alpha: 0.1)
                                    : Colors.transparent,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 22,
                                color: isFavorite
                                    ? const Color(0xFFFF5252)
                                    : Colors.white38,
                              ),
                            ),
                          ),
                          if (isPlaying) ...[
                            const SizedBox(height: 4),
                            if (provider.isRecognizing)
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).primaryColor,
                                ),
                              )
                            else
                              _LiveBadge(color: Theme.of(context).primaryColor),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // _buildVisual and _buildIcon methods remain the same...

  Widget _buildVisual(Station station) {
    if (station.logo != null && station.logo!.isNotEmpty) {
      if (station.logo!.startsWith('assets/')) {
        return Image.asset(
          station.logo!,
          fit: BoxFit.contain,
          errorBuilder: (c, e, s) => _buildIcon(station.icon),
        );
      }
      return Image.network(
        station.logo!,
        fit: BoxFit.contain,
        errorBuilder: (c, e, s) => _buildIcon(station.icon),
      );
    }

    /* 
    // Fallback to Genre Default
    final defaultImg = GenreMapper.getGenreImage(station.genre);
    if (defaultImg != null) {
      if (defaultImg.startsWith('http')) {
        return Image.network(
          defaultImg,
          fit: BoxFit.cover,
          errorBuilder: (c, e, s) => _buildIcon(station.icon),
        );
      }
      return Image.asset(
        defaultImg,
        fit: BoxFit.cover,
        errorBuilder: (c, e, s) => _buildIcon(station.icon),
      );
    }
    */

    return _buildIcon(station.icon);
  }

  Widget _buildIcon(String? iconName) {
    IconData iconData = IconLibrary.getIcon(iconName);

    return FaIcon(
      iconData,
      size: 32,
      color: Color(int.parse(widget.station.color)),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  final Color color;
  const _LiveBadge({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MiniVisualizer(color: color),
          const SizedBox(width: 4),
          Text(
            "LIVE",
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniVisualizer extends StatefulWidget {
  final Color color;
  const _MiniVisualizer({required this.color});

  @override
  State<_MiniVisualizer> createState() => _MiniVisualizerState();
}

class _MiniVisualizerState extends State<_MiniVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final double height =
                4 +
                8 *
                    (0.5 +
                        0.5 *
                            (index % 2 == 0
                                ? DateTime.now().millisecondsSinceEpoch %
                                      1000 /
                                      1000
                                : 1 -
                                      (DateTime.now().millisecondsSinceEpoch %
                                          1000 /
                                          1000)));
            return Container(
              width: 3,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(1),
              ),
            );
          },
        );
      }),
    );
  }
}
