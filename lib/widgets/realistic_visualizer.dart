import 'dart:math';

import 'package:flutter/material.dart';

class RealisticVisualizer extends StatefulWidget {
  final Color color;
  final int barCount;
  final bool isBackground;
  final double volume;

  const RealisticVisualizer({
    super.key,
    required this.color,
    this.barCount = 3,
    this.isBackground = false,
    this.volume = 1.0,
  });

  @override
  State<RealisticVisualizer> createState() => _RealisticVisualizerState();
}

class _RealisticVisualizerState extends State<RealisticVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<double> _barHeights;
  late List<double> _barTargets;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _barHeights = List.generate(
      widget.barCount,
      (_) => _random.nextDouble(), // Start random
    );
    _barTargets = List.generate(
      widget.barCount,
      (_) => _random.nextDouble(), // Target random
    );

    _controller =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 100),
          )
          ..addListener(_updateBars)
          ..repeat();
  }

  void _updateBars() {
    for (int i = 0; i < widget.barCount; i++) {
      // Move towards target
      double diff = _barTargets[i] - _barHeights[i];
      _barHeights[i] += diff * 0.15; // Smooth speed

      // Pick new target if close
      if (diff.abs() < 0.05) {
        _barTargets[i] = _random.nextDouble();
      }
    }
  }

  @override
  void didUpdateWidget(RealisticVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.barCount != oldWidget.barCount) {
      _barHeights = List.generate(widget.barCount, (_) => _random.nextDouble());
      _barTargets = List.generate(widget.barCount, (_) => _random.nextDouble());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Limit bar count to fit width if needed
        double barWidth = widget.isBackground
            ? 6.0
            : 3.0; // Slightly wider for impact
        double spacing = widget.isBackground ? 4.0 : 1.0;
        double totalPerBar = barWidth + (spacing * 2);

        int maxBars;
        if (constraints.maxWidth.isInfinite) {
          maxBars = 1000;
        } else {
          maxBars = (constraints.maxWidth / totalPerBar).floor();
        }

        int safeCount = widget.barCount > maxBars ? maxBars : widget.barCount;
        if (safeCount <= 0) safeCount = 1;

        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            if (_barHeights.isEmpty) return const SizedBox();
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: List.generate(safeCount, (index) {
                // Use pre-calculated smooth height, ensure index is safe
                int dataIndex = index % _barHeights.length;
                double rawHeight = _barHeights[dataIndex];

                // Scale by volume (min 0.3 visualization even at low volume)
                double volScale = (widget.volume < 0.3) ? 0.3 : widget.volume;

                double baseHeight = widget.isBackground ? 5.0 : 2.0;
                double dynamicRange = widget.isBackground ? 40.0 : 8.0;

                double height =
                    baseHeight + (rawHeight * dynamicRange * volScale);

                return Container(
                  width: barWidth,
                  height: height,
                  margin: EdgeInsets.symmetric(horizontal: spacing),
                  decoration: BoxDecoration(
                    color: widget.color.withOpacity(
                      widget.isBackground ? 0.8 : 1.0,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            );
          },
        );
      },
    );
  }
}
