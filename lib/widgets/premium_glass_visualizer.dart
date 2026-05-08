import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

class PremiumGlassVisualizer extends StatefulWidget {
  final Color color;
  final int barCount;
  final double opacity;
  final double height;
  final bool isPlaying;

  const PremiumGlassVisualizer({
    super.key,
    required this.color,
    this.barCount = 40,
    this.opacity = 0.2,
    this.height = 100,
    this.isPlaying = true,
  });

  @override
  State<PremiumGlassVisualizer> createState() => _PremiumGlassVisualizerState();
}

class _PremiumGlassVisualizerState extends State<PremiumGlassVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<double> _heights;
  late List<double> _targets;
  late List<double> _speeds;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _heights = List.generate(widget.barCount, (_) => _random.nextDouble());
    _targets = List.generate(widget.barCount, (_) => _random.nextDouble());
    _speeds = List.generate(widget.barCount, (_) => 0.05 + _random.nextDouble() * 0.1);

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_updateValues);
    
    if (widget.isPlaying) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(PremiumGlassVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  void _updateValues() {
    setState(() {
      for (int i = 0; i < widget.barCount; i++) {
        // Smoothly move towards target
        double diff = _targets[i] - _heights[i];
        _heights[i] += diff * _speeds[i];

        // If reached target, pick a new one
        if (diff.abs() < 0.05) {
          _targets[i] = _random.nextDouble();
          _speeds[i] = 0.05 + _random.nextDouble() * 0.15;
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: widget.height,
      child: Stack(
        children: [
          // Optional: Add a very subtle blur to the visualizer itself
          Positioned.fill(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(widget.barCount, (index) {
                return Flexible(
                  child: FractionallySizedBox(
                    heightFactor: 0.1 + (_heights[index] * 0.9),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            widget.color.withValues(alpha: widget.opacity),
                            widget.color.withValues(alpha: 0.2),
                          ],
                        ),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: widget.color.withValues(alpha: widget.opacity),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          // Reflection / Mirror effect (optional, bottom up)
          Positioned.fill(
            child: Opacity(
              opacity: 0.3,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(widget.barCount, (index) {
                  return Flexible(
                    child: FractionallySizedBox(
                      heightFactor: (0.1 + (_heights[index] * 0.9)) * 0.4,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1.0),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              widget.color.withValues(alpha: widget.opacity * 0.5),
                              widget.color.withValues(alpha: 0.0),
                            ],
                          ),
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(20),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
