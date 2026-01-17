
import 'package:flutter/material.dart';
import '../services/lyrics_service.dart';

class LyricsWidget extends StatefulWidget {
  final LyricsData lyrics;
  final Color accentColor;
  final Duration lyricsOffset;
  final Stream<Duration> positionStream;

  const LyricsWidget({
    super.key,
    required this.lyrics,
    required this.accentColor,
    required this.lyricsOffset,
    required this.positionStream,
  });

  @override
  State<LyricsWidget> createState() => _LyricsWidgetState();
}

class _LyricsWidgetState extends State<LyricsWidget> {
  int _currentIndex = -1;
  final Map<int, GlobalKey> _lineKeys = {};
  double _lastViewportHeight = 0.0;
  bool _isManuallyScrolling = false;

  void _scrollToIndex(int index) {
    if (_isManuallyScrolling) return;

    _currentIndex = index;

    final key = _lineKeys[index];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        alignment: 0.5, // Center the text in the viewport
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final effectivePosition = position - widget.lyricsOffset;

        int index = -1;
        if (widget.lyrics.lines.isNotEmpty) {
          for (int i = 0; i < widget.lyrics.lines.length; i++) {
            final lineTime = widget.lyrics.lines[i].time;
            if (effectivePosition >= lineTime) {
              index = i;
            } else {
              break;
            }
          }
        }

        // Trigger scroll if index changed
        if (index != -1 && index != _currentIndex) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToIndex(index),
          );
        }

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification) {
              if (notification.dragDetails != null) {
                _isManuallyScrolling = true;
              }
            } else if (notification is ScrollEndNotification) {
              // Resume auto-scroll after a delay
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) _isManuallyScrolling = false;
              });
            }
            return false;
          },
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    // Re-center if viewport size changes (e.g. closing the sheet)
                    if (_currentIndex != -1 &&
                        (constraints.viewportMainAxisExtent -
                                    _lastViewportHeight)
                                .abs() >
                            1.0) {
                      _lastViewportHeight = constraints.viewportMainAxisExtent;
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _scrollToIndex(_currentIndex),
                      );
                    }
                    _lastViewportHeight = constraints.viewportMainAxisExtent;

                    if (widget.lyrics.lines.isEmpty) {
                      return const SliverToBoxAdapter(child: SizedBox.shrink());
                    }

                    return SliverList(
                      delegate: SliverChildBuilderDelegate((context, i) {
                        final isSynced = widget.lyrics.isSynced;
                        final isCurrent = isSynced ? (i == index) : true;
                        final line = widget.lyrics.lines[i];

                        // Ensure key exists
                        _lineKeys[i] ??= GlobalKey();

                        return Padding(
                          key: _lineKeys[i],
                          padding: const EdgeInsets.symmetric(vertical: 12.0),
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 300),
                            style: TextStyle(
                              color: isCurrent ? Colors.white : Colors.white24,
                              fontSize: isSynced
                                  ? (isCurrent ? 24 : 18)
                                  : 20, // Larger font for readability
                              height: 1.4,
                              fontWeight: (isSynced && isCurrent) || !isSynced
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              shadows: isCurrent && isSynced
                                  ? [
                                      Shadow(
                                        color: widget.accentColor.withValues(
                                          alpha: 0.6,
                                        ),
                                        blurRadius: 12,
                                      ),
                                    ]
                                  : null,
                            ),
                            textAlign: TextAlign.center,
                            child: Text(line.text),
                          ),
                        );
                      }, childCount: widget.lyrics.lines.length),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class DraggableSyncOverlay extends StatefulWidget {
  final Duration currentOffset;
  final ValueChanged<Duration> onOffsetChanged;
  final VoidCallback onClose;

  const DraggableSyncOverlay({
    super.key,
    required this.currentOffset,
    required this.onOffsetChanged,
    required this.onClose,
  });

  @override
  State<DraggableSyncOverlay> createState() => _DraggableSyncOverlayState();
}

class _DraggableSyncOverlayState extends State<DraggableSyncOverlay> {
  Offset _position = const Offset(20, 100);

  @override
  Widget build(BuildContext context) {
    final double currentOffsetSecs =
        widget.currentOffset.inMilliseconds / 1000.0;

    void updateOffset(double newTime) {
      final clamped = newTime.clamp(-50.0, 50.0);
      widget.onOffsetChanged(Duration(milliseconds: (clamped * 1000).toInt()));
    }

    return Stack(
      children: [
        Positioned(
          left: _position.dx,
          top: _position.dy,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 300,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Draggable Header
                  GestureDetector(
                    onPanUpdate: (details) {
                      setState(() {
                        _position += details.delta;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Icon(
                            Icons.drag_indicator,
                            color: Colors.white38,
                            size: 20,
                          ),
                          const Text(
                            "Sync Lyrics",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          GestureDetector(
                            onTap: widget.onClose,
                            child: const Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          'Offset: ${currentOffsetSecs.toStringAsFixed(2)}s',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildSyncButton(
                              Icons.fast_rewind_rounded,
                              () => updateOffset(currentOffsetSecs - 1.0),
                              "-1s",
                            ),
                            _buildSyncButton(
                              Icons.remove_rounded,
                              () => updateOffset(currentOffsetSecs - 0.1),
                              "-0.1s",
                            ),
                            _buildSyncButton(
                              Icons.add_rounded,
                              () => updateOffset(currentOffsetSecs + 0.1),
                              "+0.1s",
                            ),
                            _buildSyncButton(
                              Icons.fast_forward_rounded,
                              () => updateOffset(currentOffsetSecs + 1.0),
                              "+1s",
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            overlayShape: SliderComponentShape.noOverlay,
                          ),
                          child: Slider(
                            value: currentOffsetSecs.clamp(-50.0, 50.0),
                            min: -50.0,
                            max: 50.0,
                            divisions: 200,
                            activeColor: Colors.white,
                            inactiveColor: Colors.white24,
                            onChanged: updateOffset,
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "-50s",
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                              ),
                            ),
                            const Text(
                              "+50s",
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () {
                            widget.onOffsetChanged(Duration.zero);
                          },
                          child: const Text(
                            "Reset",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSyncButton(IconData icon, VoidCallback onPressed, String label) {
    return Column(
      children: [
        IconButton(
          icon: Icon(icon, color: Colors.white70),
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }
}
