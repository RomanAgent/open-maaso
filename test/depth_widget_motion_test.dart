import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:maaso/src/features/home/presentation/depth_widget_motion.dart';

void main() {
  test('floating offset is continuous across animation repeat boundary', () {
    var worstJump = 0.0;

    for (var index = 0; index < 6; index++) {
      final before = DepthWidgetMotion.floatOffset(
        progress: 0.9999,
        index: index,
      );
      final after = DepthWidgetMotion.floatOffset(
        progress: 0.0001,
        index: index,
      );
      final jump = (after - before).distance;
      if (jump > worstJump) worstJump = jump;
    }

    expect(worstJump, lessThan(0.05));
  });

  test('rotation angle is small and includes left and right tilt', () {
    var leftCount = 0;
    var rightCount = 0;

    for (var index = 0; index < 6; index++) {
      final angle = DepthWidgetMotion.rotationAngle(
        seed: 100 + index,
        index: index,
      );

      expect(angle.abs(), lessThanOrEqualTo(0.105));
      if (angle < 0) leftCount++;
      if (angle > 0) rightCount++;
    }

    expect(leftCount, greaterThan(0));
    expect(rightCount, greaterThan(0));
  });

  test('depth style creates stable near and far card scales', () {
    var hasNear = false;
    var hasFar = false;

    for (var index = 0; index < 12; index++) {
      final style = DepthWidgetMotion.depthStyle(
        seed: 200 + index,
        index: index,
      );

      expect(style.scale, inInclusiveRange(0.72, 1.12));
      expect(style.opacity, inInclusiveRange(0.38, 0.76));
      expect(style.floatSpeed, inInclusiveRange(0.72, 1.20));

      hasNear = hasNear || style.scale > 1.0;
      hasFar = hasFar || style.scale < 0.86;

      final again = DepthWidgetMotion.depthStyle(
        seed: 200 + index,
        index: index,
      );
      expect(again.scale, style.scale);
      expect(again.opacity, style.opacity);
      expect(again.floatSpeed, style.floatSpeed);
    }

    expect(hasNear, isTrue);
    expect(hasFar, isTrue);
  });

  test('agent occlusion avoidance pushes centered cards to a visible side', () {
    const bounds = Size(390, 844);
    final occlusion = Rect.fromCenter(
      center: const Offset(187, 405),
      width: 210,
      height: 560,
    );
    const cardSize = Size(140, 100);

    final adjusted = DepthWidgetMotion.avoidAgentOcclusion(
      topLeft: const Offset(150, 360),
      cardSize: cardSize,
      bounds: bounds,
      occlusion: occlusion,
    );

    final adjustedRect = adjusted & cardSize;
    expect(occlusion.contains(adjustedRect.center), isFalse);
    expect(
      adjusted.dx,
      inInclusiveRange(10, bounds.width - cardSize.width - 10),
    );
  });

  test('agent occlusion avoidance leaves already visible cards stable', () {
    const bounds = Size(390, 844);
    final occlusion = Rect.fromCenter(
      center: const Offset(187, 405),
      width: 210,
      height: 560,
    );
    const visible = Offset(260, 160);

    final adjusted = DepthWidgetMotion.avoidAgentOcclusion(
      topLeft: visible,
      cardSize: const Size(120, 90),
      bounds: bounds,
      occlusion: occlusion,
    );

    expect(adjusted, visible);
  });

  test('home no longer mounts the floating depth widget backdrop', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('const _DepthWidgetBackdrop()')));
    expect(source, isNot(contains('const _DepthWidgetHitTargets()')));
  });
}
