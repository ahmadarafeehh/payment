import 'package:flutter/material.dart';

class NumberParticle {
  double x;
  double y;
  double speed;
  double rotation;
  double rotationSpeed;
  double opacity;
  int number;
  double fontSize;
  double sway;
  double swaySpeed;
  Color color; // NEW: Added color property

  NumberParticle({
    required this.x,
    required this.y,
    required this.speed,
    required this.rotation,
    required this.rotationSpeed,
    required this.opacity,
    required this.number,
    required this.fontSize,
    required this.sway,
    required this.swaySpeed,
    required this.color, // NEW: Added color parameter
  });
}
