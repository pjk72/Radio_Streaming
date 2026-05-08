import 'package:flutter/material.dart';
import 'dart:math';

class MiniVisualizer extends StatefulWidget {
  final Color color;
  final double width;
  final double height;
  final bool active;

  const MiniVisualizer({
    super.key,
    required this.color,
    this.width = 24,
    this.height = 24,
    this.active = true,
  });

  @override
  State<MiniVisualizer> createState() => _MiniVisualizerState();
}

class _MiniVisualizerState extends State<MiniVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  // Pre-generate random seeds for each bar to ensure they move differently
  final List<double> _randomSeeds = List.generate(
    4,
    (_) => Random().nextDouble(),
  );

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600), // Faster random movement
    );
    if (widget.active) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(MiniVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      if (widget.active) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.value = 0.1; // Reset to low state
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(4, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              if (!widget.active) {
                return Container(
                  width: widget.width / 6,
                  height: 3,
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }

              // Random height calculation
              // We use sine waves with different frequencies and offsets (seeds)
              final t = _controller.value * 2 * pi;
              final r = _randomSeeds[index];

              // Combine sine waves for randomness
              double rawHeight = sin(t + r * 5) * 0.5 + 0.5;
              // Add a second harmonic
              rawHeight = (rawHeight + sin(t * 2 + r * 10) * 0.5 + 0.5) / 2;

              final double barHeight = 4.0 + (widget.height - 4.0) * rawHeight;

              return Container(
                width: widget.width / 6,
                height: barHeight,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
