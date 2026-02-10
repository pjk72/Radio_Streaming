import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/entitlement_service.dart';
import '../screens/debug_log_screen.dart';

class AdminDebugOverlay extends StatefulWidget {
  const AdminDebugOverlay({super.key});

  @override
  State<AdminDebugOverlay> createState() => _AdminDebugOverlayState();
}

class _AdminDebugOverlayState extends State<AdminDebugOverlay> {
  bool _isOpen = false;
  Offset _position = const Offset(20, 100);
  Size _size = const Size(320, 450);
  bool _isInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      final screenWidth = MediaQuery.of(context).size.width;
      if (screenWidth > 400) {
        _position = Offset(screenWidth - 340, 100);
      }
      _isInitialized = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<EntitlementService>(
      builder: (context, entitlements, child) {
        if (!entitlements.isFeatureEnabled('debug_logs')) {
          return const SizedBox.shrink();
        }

        final screenSize = MediaQuery.of(context).size;
        final effectivePosition = Offset(
          _position.dx.clamp(0.0, (screenSize.width - 50.0).toDouble()),
          _position.dy.clamp(0.0, (screenSize.height - 50.0).toDouble()),
        );

        // Positioned.fill ensures we cover the screen area for positioning our children.
        // Stack allows us to place the icon and window.
        // Touches on empty space will fall through because Stack doesn't have a background.
        return Positioned.fill(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 1. The Toggle Icon
              Positioned(
                top: MediaQuery.of(context).padding.top + 10,
                right: 16,
                child: _buildToggleIcon(),
              ),

              // 2. The Window
              if (_isOpen)
                Positioned(
                  left: effectivePosition.dx,
                  top: effectivePosition.dy,
                  child: _buildWindow(effectivePosition),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildToggleIcon() {
    return InkWell(
      onTap: () => setState(() => _isOpen = !_isOpen),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _isOpen ? Colors.redAccent : Colors.black54,
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.redAccent.withOpacity(0.5),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Icon(
          _isOpen ? Icons.close : Icons.bug_report_outlined,
          color: _isOpen ? Colors.white : Colors.redAccent,
          size: 20,
        ),
      ),
    );
  }

  Widget _buildWindow(Offset clampedPosition) {
    final screenSize = MediaQuery.of(context).size;

    return Container(
      width: _size.width.clamp(200.0, screenSize.width),
      height: _size.height.clamp(200.0, screenSize.height),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withOpacity(0.3), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: Stack(
        children: [
          // Content (The Debug Log UI)
          ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Material(
              color: Colors.black.withOpacity(0.85),
              type: MaterialType.canvas,
              child: ScaffoldMessenger(
                child: HeroControllerScope.none(
                  child: Navigator(
                    onGenerateRoute: (settings) => MaterialPageRoute(
                      builder: (context) => const Material(
                        type: MaterialType.transparency,
                        child: Directionality(
                          textDirection: TextDirection.ltr,
                          child: DebugLogScreen(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Drag Handle (Header)
          GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _position += details.delta;
              });
            },
            child: Container(
              height: 56,
              width: double.infinity,
              color: Colors.transparent,
            ),
          ),

          // Resize Handle
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  _size = Size(
                    _size.width + details.delta.dx,
                    _size.height + details.delta.dy,
                  );
                });
              },
              child: Container(
                width: 30,
                height: 30,
                padding: const EdgeInsets.all(4),
                child: CustomPaint(painter: _ResizeHandlePainter()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResizeHandlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.redAccent.withOpacity(0.5)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(size.width * 0.4, size.height),
      Offset(size.width, size.height * 0.4),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.7, size.height),
      Offset(size.width, size.height * 0.7),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
