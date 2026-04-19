import 'dart:math';
import 'package:flutter/material.dart';

class AdvancedRecognitionVisualizer extends StatefulWidget {
  final bool isAnalyzing;
  final Color color;

  const AdvancedRecognitionVisualizer({
    super.key,
    required this.isAnalyzing,
    this.color = Colors.white,
  });

  @override
  State<AdvancedRecognitionVisualizer> createState() => _AdvancedRecognitionVisualizerState();
}

class _AdvancedRecognitionVisualizerState extends State<AdvancedRecognitionVisualizer>
    with TickerProviderStateMixin {
  late AnimationController _noteController;
  late AnimationController _analysisController;
  final List<NoteParticle> _particles = [];
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _noteController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..addListener(_updateParticles)..repeat();

    _analysisController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    // Initialize some particles
    for (int i = 0; i < 12; i++) {
      _particles.add(NoteParticle(_random));
    }
  }

  void _updateParticles() {
    if (widget.isAnalyzing) return;
    
    for (var particle in _particles) {
      particle.update();
      if (particle.isDead) {
        particle.reset(_random);
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _noteController.dispose();
    _analysisController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: widget.isAnalyzing ? _buildAnalysisView() : _buildRecordingView(),
    );
  }

  Widget _buildRecordingView() {
    return Stack(
      key: const ValueKey('recording'),
      alignment: Alignment.center,
      children: [
        // Particle Field
        CustomPaint(
          size: const Size(200, 200),
          painter: NoteParticlePainter(_particles, widget.color),
        ),
        // Pulsing Microphone
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 1.0, end: 1.2),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
          builder: (context, value, child) {
            return Transform.scale(
              scale: value,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.1),
                ),
                child: Icon(Icons.mic, color: widget.color, size: 28),
              ),
            );
          },
          onEnd: () {}, // Handled by repeating tween if we used a controller, but TweenAnimationBuilder is easier for simple pulse
        ),
      ],
    );
  }

  Widget _buildAnalysisView() {
    return AnimatedBuilder(
      key: const ValueKey('analysis'),
      animation: _analysisController,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            // Rotating Outer Ring
            Transform.rotate(
              angle: _analysisController.value * 2 * pi,
              child: SizedBox(
                width: 70,
                height: 70,
                child: CustomPaint(
                  painter: AnalysisRingPainter(widget.color),
                ),
              ),
            ),
            // Inner Moving Notes
            SizedBox(
              width: 50,
              height: 50,
              child: CustomPaint(
                painter: InnerNotesPainter(_analysisController.value, widget.color),
              ),
            ),
            // Scanning Line
            Transform.translate(
              offset: Offset(0, sin(_analysisController.value * 2 * pi) * 20),
              child: Container(
                width: 45,
                height: 2,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      widget.color.withValues(alpha: 0.8),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class InnerNotesPainter extends CustomPainter {
  final double animationValue;
  final Color color;

  InnerNotesPainter(this.animationValue, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final icons = [Icons.music_note, Icons.audiotrack, Icons.music_video];
    
    // Draw 3 notes in different positions
    for (int i = 0; i < 3; i++) {
      final double angle = (animationValue * 2 * pi) + (i * 2 * pi / 3);
      final double radius = 10 * sin(animationValue * 2 * pi + i);
      final double x = size.width / 2 + cos(angle) * (5 + radius) - 10;
      final double y = size.height / 2 + sin(angle) * (5 + radius) - 10;
      
      final icon = icons[i % icons.length];
      
      textPainter.text = TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 18,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color.withValues(alpha: 0.8),
        ),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x, y));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class NoteParticle {
  late double x, y;
  late double size;
  late IconData icon;
  late double speed;
  late double opacity;
  double life = 0;

  NoteParticle(Random random) {
    reset(random);
  }

  void reset(Random random) {
    // Spawn on a circle
    double angle = random.nextDouble() * 2 * pi;
    double radius = 100 + random.nextDouble() * 20;
    x = cos(angle) * radius;
    y = sin(angle) * radius;
    
    size = 12 + random.nextDouble() * 10;
    icon = [Icons.music_note, Icons.audiotrack, Icons.music_video][random.nextInt(3)];
    // Slower speed as requested (was 1.5 + 2.5)
    speed = 0.8 + random.nextDouble() * 1.5;
    opacity = 0;
    life = 0;
  }

  void update() {
    // Move towards center (0,0)
    double dist = sqrt(x * x + y * y);
    if (dist < 10) {
      life = 1; // Mark as dead
      return;
    }

    double dx = -x / dist * speed;
    double dy = -y / dist * speed;
    x += dx;
    y += dy;

    // Fade in initially, fade out at center
    if (dist > 80) {
      opacity = (100 - dist) / 20; // Fade in from 100 to 80
    } else if (dist < 30) {
      opacity = dist / 30; // Fade out from 30 to 0
    } else {
      opacity = 1;
    }
  }

  bool get isDead => life >= 1;
}

class NoteParticlePainter extends CustomPainter {
  final List<NoteParticle> particles;
  final Color color;

  NoteParticlePainter(this.particles, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    
    for (var p in particles) {
      textPainter.text = TextSpan(
        text: String.fromCharCode(p.icon.codePoint),
        style: TextStyle(
          fontSize: p.size,
          fontFamily: p.icon.fontFamily,
          package: p.icon.fontPackage,
          color: color.withValues(alpha: p.opacity.clamp(0, 1)),
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(size.width / 2 + p.x - p.size / 2, size.height / 2 + p.y - p.size / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class AnalysisRingPainter extends CustomPainter {
  final Color color;

  AnalysisRingPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(Offset(size.width / 2, size.height / 2), size.width / 2, paint);

    // Draw some "tech" notches
    final notchPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    for (int i = 0; i < 4; i++) {
      double angle = i * pi / 2;
      canvas.drawArc(
        Rect.fromCircle(center: Offset(size.width / 2, size.height / 2), radius: size.width / 2),
        angle,
        0.5,
        false,
        notchPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
