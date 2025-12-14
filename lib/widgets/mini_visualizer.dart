import 'package:flutter/material.dart';

class MiniVisualizer extends StatefulWidget {
  final Color color;
  const MiniVisualizer({super.key, required this.color});

  @override
  State<MiniVisualizer> createState() => _MiniVisualizerState();
}

class _MiniVisualizerState extends State<MiniVisualizer>
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
    return Container(
      width: 10,
      height: 10,
      alignment: Alignment.bottomCenter,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final double height =
                  3.0 +
                  7.0 *
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
                width: 2,
                height: height,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(1),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
