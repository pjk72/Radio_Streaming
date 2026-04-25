import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import '../models/station.dart';
import '../providers/radio_provider.dart';

import 'premium_glass_visualizer.dart';

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
    final isCompact = provider.isCategoryCompact(widget.station.category);

    final isPlaying =
        provider.currentStation?.id == widget.station.id &&
        provider.isPlaying &&
        !provider.isLoading;

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
            // Gradient background for premium feel using the station color
            gradient: LinearGradient(
              begin: Alignment.centerRight,
              end: Alignment.centerLeft,
              colors: [
                Color(
                  int.parse(widget.station.color),
                ).withValues(alpha: 0.05), // Light under the photo
                Color(int.parse(widget.station.color)).withValues(
                  alpha: 0.4,
                ), // Less intense color at the edge of the photo
                Color(int.parse(widget.station.color)).withValues(
                  alpha: 0.02,
                ), // Very smooth, almost transparent fade towards the far left
              ],
              stops: const [0.3, 0.55, 1.0],
            ),
            borderRadius: BorderRadius.circular(isCompact ? 16 : 24),
            border: Border.all(
              color: isPlaying || _isHovering
                  ? Color(
                      int.parse(widget.station.color),
                    ).withValues(alpha: 0.8)
                  : Theme.of(context).dividerColor.withValues(alpha: 0.1),
              width: isPlaying ? 2.0 : (_isHovering ? 1.5 : 1.0),
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
                if (isCompact) ...[
                  Positioned.fill(
                    child: _buildVisual(widget.station, isBackground: true),
                  ),
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withValues(alpha: 0.1),
                            Colors.black.withValues(alpha: 0.9),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ),
                  if (isPlaying)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: PremiumGlassVisualizer(
                        color: Color(int.parse(widget.station.color)),
                        isPlaying: isPlaying,
                        height: 40,
                        barCount: 30,
                        opacity: 0.6,
                      ),
                    ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.station.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.station.genre.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.0,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  // Right-aligned Station Image Background
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FractionallySizedBox(
                        widthFactor: 0.45, // Occupy right 45% and fade out
                        child: ShaderMask(
                          shaderCallback: (rect) {
                            return const LinearGradient(
                              begin: Alignment.centerRight,
                              end: Alignment.centerLeft,
                              colors: [Colors.white, Colors.transparent],
                              stops: [0.4, 1.0], // Starts fading at 40%
                            ).createShader(rect);
                          },
                          blendMode: BlendMode.dstIn,
                          child: Opacity(
                            opacity: 0.8, // More visible than before
                            child: _buildVisual(
                              widget.station,
                              isBackground: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  if (isPlaying)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: PremiumGlassVisualizer(
                        color: Color(int.parse(widget.station.color)),
                        isPlaying: isPlaying,
                        height: isCompact ? 40 : 60,
                        barCount: isCompact ? 30 : 50,
                        opacity: 0.6,
                      ),
                    ),

                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isCompact ? 12.0 : 20.0,
                      vertical: isCompact ? 8.0 : 12.0,
                    ),
                    child: Row(
                      children: [
                        // Info
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      widget.station.name,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: isCompact ? 15 : 18,
                                        color: Theme.of(
                                          context,
                                        ).textTheme.titleMedium?.color,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (!isCompact && isPlaying) ...[
                                    const SizedBox(width: 8),
                                    _LiveBadge(
                                      color:
                                          Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.color
                                              ?.withValues(alpha: 0.7) ??
                                          Colors.white70,
                                      isRecognizing: provider.isRecognizing,
                                      isCompact: isCompact,
                                    ),
                                  ],
                                ],
                              ),
                              SizedBox(height: isCompact ? 2 : 4),
                              Text(
                                widget.station.genre.toUpperCase(),
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color
                                      ?.withValues(alpha: 0.7),
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

                        // Live status was relocated next to the radio name
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // _buildVisual and _buildIcon methods remain the same...

  Widget _buildVisual(Station station, {bool isBackground = false}) {
    if (station.logo != null && station.logo!.isNotEmpty) {
      if (station.logo!.startsWith('assets/')) {
        return Image.asset(
          station.logo!,
          fit: BoxFit.cover,
          width: isBackground ? double.infinity : null,
          height: isBackground ? double.infinity : null,
          errorBuilder: (c, e, s) =>
              _buildIcon(station.icon, isBackground: isBackground),
        );
      }
      return Image.network(
        station.logo!,
        fit: BoxFit.cover,
        width: isBackground ? double.infinity : null,
        height: isBackground ? double.infinity : null,
        errorBuilder: (c, e, s) =>
            _buildIcon(station.icon, isBackground: isBackground),
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
          errorBuilder: (c, e, s) => _buildIcon(station.icon, isBackground: isBackground),
        );
      }
      return Image.asset(
        defaultImg,
        fit: BoxFit.cover,
        errorBuilder: (c, e, s) => _buildIcon(station.icon, isBackground: isBackground),
      );
    }
    */

    return _buildIcon(station.icon, isBackground: isBackground);
  }

  Widget _buildIcon(String? iconName, {bool isBackground = false}) {
    IconData iconData = IconLibrary.getIcon(iconName);

    return Center(
      child: FaIcon(
        iconData,
        size: isBackground ? 70 : 32,
        color: Color(
          int.parse(widget.station.color),
        ).withValues(alpha: isBackground ? 0.3 : 1.0),
      ),
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
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
