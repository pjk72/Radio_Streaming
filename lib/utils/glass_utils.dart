import 'dart:ui';
import 'package:flutter/material.dart';

class GlassUtils {
  static Future<T?> showGlassDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    Color? barrierColor,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: '',
      barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1.0).animate(
              CurvedAnimation(parent: anim1, curve: Curves.easeOutCirc),
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                color: Colors.black.withValues(alpha: 0.1),
                child: builder(ctx),
              ),
            ),
          ),
        );
      },
    );
  }

  static Future<T?> showGlassBottomSheet<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = true,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black.withValues(alpha: 0.3),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim1, anim2, child) {
        return _GlassBottomSheetTransition(
          animation: anim1,
          builder: builder,
        );
      },
    );
  }
}

class _GlassBottomSheetTransition extends StatefulWidget {
  final Animation<double> animation;
  final WidgetBuilder builder;

  const _GlassBottomSheetTransition({
    required this.animation,
    required this.builder,
  });

  @override
  State<_GlassBottomSheetTransition> createState() => _GlassBottomSheetTransitionState();
}

class _GlassBottomSheetTransitionState extends State<_GlassBottomSheetTransition> {
  double _dragOffset = 0;

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset += details.delta.dy;
      if (_dragOffset < 0) _dragOffset = 0;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_dragOffset > 100 || details.primaryVelocity! > 500) {
      Navigator.pop(context);
    } else {
      setState(() {
        _dragOffset = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final animValue = widget.animation.value;
    final curve = Curves.easeOutCubic.transform(animValue);
    
    return BackdropFilter(
      filter: ImageFilter.blur(
        sigmaX: 10 * animValue,
        sigmaY: 10 * animValue,
      ),
      child: FadeTransition(
        opacity: widget.animation,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: FractionalTranslation(
                translation: Offset(0, 1 - curve),
                child: Transform.translate(
                  offset: Offset(0, _dragOffset),
                  child: GestureDetector(
                    onVerticalDragUpdate: _onVerticalDragUpdate,
                    onVerticalDragEnd: _onVerticalDragEnd,
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.15),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(32),
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.1),
                            width: 0.5,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: widget.builder(context),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
