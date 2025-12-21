import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import '../models/station.dart';
import '../providers/radio_provider.dart';

import 'realistic_visualizer.dart';
import 'pulsing_indicator.dart';
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
    final isCompact = provider.isCompactView;

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
          transform: Matrix4.translationValues(
            0.0,
            _isHovering ? -5.0 : 0.0,
            0.0,
          ),
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
            borderRadius: BorderRadius.circular(isCompact ? 16 : 24),
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
            borderRadius: BorderRadius.circular(isCompact ? 16 : 24),
            child: Stack(
              children: [
                if (isCompact && isPlaying)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(
                              int.parse(widget.station.color),
                            ).withValues(alpha: 0.3),
                            Colors.transparent,
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment: MainAxisAlignment.end,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (provider.isRecognizing)
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: 16,
                                  bottom: 8,
                                ),
                                child: PulsingIndicator(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  size: 40,
                                ),
                              )
                            else
                              Flexible(
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    right: 8,
                                    bottom: 0,
                                  ),
                                  child: ShaderMask(
                                    shaderCallback: (bounds) => LinearGradient(
                                      colors: [
                                        Colors.white.withValues(alpha: 0.6),
                                        Colors.white.withValues(alpha: 0.1),
                                      ],
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                    ).createShader(bounds),
                                    blendMode: BlendMode.dstIn,
                                    child: RealisticVisualizer(
                                      color: Color(
                                        int.parse(widget.station.color),
                                      ),
                                      barCount: 20,
                                      isBackground: true,
                                      volume: provider.volume,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isCompact ? 12.0 : 20.0,
                    vertical: isCompact ? 8.0 : 12.0,
                  ),
                  child: Row(
                    children: [
                      // Icon / Logo
                      Container(
                        width: isCompact ? 40 : 56,
                        height: isCompact ? 40 : 56,
                        padding: EdgeInsets.all(isCompact ? 6 : 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(
                            isCompact ? 10 : 14,
                          ),
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

                      SizedBox(width: isCompact ? 12 : 20),

                      // Info
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.station.name,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: isCompact ? 15 : 18,
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: isCompact ? 2 : 4),
                            Text(
                              widget.station.genre.toUpperCase(),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: isCompact ? 9 : 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.0,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),

                      // Favorite & Live Status (Hidden in Compact View if Playing)
                      if (!isCompact)
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (isPlaying) ...[
                              const SizedBox(height: 4),
                              _LiveBadge(
                                color: Colors.white70,
                                isRecognizing: provider.isRecognizing,
                                isCompact: isCompact,
                              ),
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
          fit: BoxFit.cover,
          errorBuilder: (c, e, s) => _buildIcon(station.icon),
        );
      }
      return Image.network(
        station.logo!,
        fit: BoxFit.cover,
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
  final bool isRecognizing;
  final bool isCompact;

  const _LiveBadge({
    required this.color,
    required this.isRecognizing,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 6 : 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          isRecognizing
              ? const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: PulsingIndicator(color: Colors.white70, size: 10),
                )
              : Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: SizedBox(
                    width: 20,
                    height: 12,
                    child: RealisticVisualizer(color: color),
                  ),
                ),
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
