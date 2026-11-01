import 'dart:math' as math;

import 'package:flutter/material.dart';

class DepthWidgetMotion {
  static Offset floatOffset({
    required double progress,
    required int index,
    double xAmplitude = 3,
    double yAmplitude = 7,
  }) {
    final phase = progress * math.pi * 2 + index * 0.7;
    return Offset(math.cos(phase) * xAmplitude, math.sin(phase) * yAmplitude);
  }

  static double rotationAngle({
    required int seed,
    required int index,
    double maxDegrees = 6,
  }) {
    final direction = ((seed ~/ 3) + index).isEven ? 1.0 : -1.0;
    final magnitude = 1.5 + ((seed ~/ 13 + index * 7) % 100) / 100 * 4.5;
    return direction * math.min(magnitude, maxDegrees) * math.pi / 180;
  }

  static DepthWidgetStyle depthStyle({required int seed, required int index}) {
    final raw = ((seed ~/ 5) + index * 19) % 100 / 99;
    final scale = 0.74 + raw * 0.36;
    return DepthWidgetStyle(
      scale: scale,
      opacity: 0.40 + raw * 0.32,
      floatSpeed: 0.76 + raw * 0.38,
      blurBoost: (1 - raw) * 6,
    );
  }

  static Offset avoidAgentOcclusion({
    required Offset topLeft,
    required Size cardSize,
    required Size bounds,
    required Rect occlusion,
    double margin = 12,
    double bottomReserved = 120,
  }) {
    final card = topLeft & cardSize;
    if (!occlusion.contains(card.center)) return topLeft;

    final maxLeft = math.max(margin, bounds.width - cardSize.width - margin);
    final maxTop = math.max(
      margin,
      bounds.height - cardSize.height - bottomReserved,
    );
    final candidates =
        <Offset>[
              Offset(occlusion.left - cardSize.width - margin, topLeft.dy),
              Offset(occlusion.right + margin, topLeft.dy),
              Offset(topLeft.dx, occlusion.top - cardSize.height - margin),
              Offset(topLeft.dx, occlusion.bottom + margin),
            ]
            .map((p) {
              return Offset(
                p.dx.clamp(margin, maxLeft).toDouble(),
                p.dy.clamp(42.0, maxTop).toDouble(),
              );
            })
            .where((p) => !occlusion.contains((p & cardSize).center))
            .toList();

    if (candidates.isEmpty) {
      return Offset(
        topLeft.dx < occlusion.center.dx ? margin : maxLeft,
        topLeft.dy.clamp(42.0, maxTop).toDouble(),
      );
    }

    candidates.sort((a, b) {
      final da = (a - topLeft).distanceSquared;
      final db = (b - topLeft).distanceSquared;
      return da.compareTo(db);
    });
    return candidates.first;
  }
}

class DepthWidgetStyle {
  const DepthWidgetStyle({
    required this.scale,
    required this.opacity,
    required this.floatSpeed,
    required this.blurBoost,
  });

  final double scale;
  final double opacity;
  final double floatSpeed;
  final double blurBoost;
}
