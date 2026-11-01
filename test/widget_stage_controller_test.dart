import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/widgets/widget_stage_controller.dart';

void main() {
  test('opens compact by default and can expand, shrink, and minimize', () {
    final controller = WidgetStageController();
    final item = AgentWidget(
      id: 1,
      agentId: 'self',
      title: 'Weather',
      subtitle: 'Today',
      icon: 'weather',
      spec: const {'type': 'card'},
      createdAt: DateTime(2026, 6, 2),
    );

    controller.present(item);

    expect(controller.active.value, same(item));
    expect(controller.mode.value, WidgetStageMode.compact);

    controller.expand();
    expect(controller.mode.value, WidgetStageMode.fullscreen);

    controller.shrink();
    expect(controller.mode.value, WidgetStageMode.compact);

    controller.minimize();
    expect(controller.active.value, isNull);
    expect(controller.mode.value, WidgetStageMode.compact);
  });

  test('tracks a draggable compact window and normalized gaze target', () {
    final controller = WidgetStageController();
    final item = AgentWidget(
      id: 2,
      agentId: 'self',
      title: 'Weather',
      spec: const {'type': 'card'},
      createdAt: DateTime(2026, 6, 2),
    );

    controller.present(item);
    controller.setCompactFrame(
      viewport: const Size(390, 844),
      frameSize: const Size(300, 360),
      desiredTopLeft: const Offset(320, -40),
    );

    // Gaze is measured from the avatar's input-safe centered eye anchor, so a
    // dragged window reads as a direct look instead of assuming a left-corner
    // avatar pose.
    expect(controller.compactTopLeft.value, const Offset(74, 8));
    expect(controller.gazeTarget.value.dx, closeTo(0.164, 0.01));
    expect(controller.gazeTarget.value.dy, closeTo(0.353, 0.01));

    controller.moveCompactBy(
      const Offset(-40, 80),
      viewport: const Size(390, 844),
      frameSize: const Size(300, 360),
    );

    expect(controller.compactTopLeft.value, const Offset(34, 88));
    expect(controller.gazeTarget.value.dx, closeTo(-0.062, 0.01));
    expect(controller.gazeTarget.value.dy, closeTo(0.145, 0.01));
  });

  test('avatar head anchor stays centered inside the input-safe stage', () {
    final controller = WidgetStageController();
    const viewport = Size(390, 844);

    expect(
      controller.avatarHeadAnchorFraction(viewport: viewport).dx,
      closeTo(0.5, 0.001),
    );
    expect(
      controller.avatarHeadAnchorFraction(viewport: viewport).dy,
      closeTo(0.347, 0.001),
      reason: 'resting avatar head anchor should sit above the input bar',
    );

    final item = AgentWidget(
      id: 3,
      agentId: 'self',
      title: 'Blog',
      spec: const {'type': 'card'},
      createdAt: DateTime(2026, 6, 10),
    );
    controller.present(item);

    expect(
      controller.avatarHeadAnchorFraction(viewport: viewport).dx,
      closeTo(0.5, 0.001),
    );
    expect(
      controller.avatarHeadAnchorFraction(viewport: viewport).dy,
      closeTo(0.383, 0.001),
    );

    controller.expand();
    expect(
      controller.avatarHeadAnchorFraction(viewport: viewport).dx,
      closeTo(0.5, 0.001),
    );
    expect(
      controller.avatarHeadAnchorFraction(viewport: viewport).dy,
      closeTo(0.394, 0.001),
    );

    controller.minimize();
    expect(
      controller.avatarHeadAnchorFraction(viewport: viewport).dy,
      closeTo(0.347, 0.001),
    );
  });

  test('avatar stage insets reserve the chat input but ignore keyboard', () {
    final insets = WidgetStageController.avatarStageInsets(
      topSafeInset: 24,
      bottomSafeInset: 34,
      keyboardInset: 300,
    );

    expect(insets.top, 24);
    expect(insets.bottom, 146);
  });

  test('keyboard does not move or shrink the avatar stage anchor', () {
    final controller = WidgetStageController();
    const viewport = Size(390, 844);

    final resting = controller.avatarHeadAnchorFraction(viewport: viewport);
    final keyboardOpen = controller.avatarHeadAnchorFraction(
      viewport: viewport,
      keyboardInset: 300,
    );

    expect(keyboardOpen.dx, closeTo(resting.dx, 0.001));
    expect(keyboardOpen.dy, closeTo(resting.dy, 0.001));
  });
}
