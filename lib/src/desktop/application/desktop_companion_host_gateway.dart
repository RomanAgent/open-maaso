import 'dart:async';
import 'dart:ui';

import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';

class DesktopCompanionHostMenuItem {
  const DesktopCompanionHostMenuItem({
    required this.id,
    required this.label,
    this.enabled = true,
  });

  final String id;
  final String label;
  final bool enabled;
}

enum DesktopCompanionHostCommand { openApp, hidePet, hostUnavailable, quit }

/// Native host for a truly independent desktop-pet surface.
abstract interface class DesktopCompanionHostGateway {
  bool get isSupported;

  Future<void> initialize({
    required FutureOr<void> Function(String id) onMenuSelected,
    required FutureOr<void> Function(DesktopCompanionHostCommand command)
    onCommand,
    required FutureOr<void> Function(Offset? gaze) onGazeChanged,
    required FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)
    onInteraction,
  });

  Future<void> configureMenu(List<DesktopCompanionHostMenuItem> items);

  Future<void> configurePresentation(
    DesktopCompanionPresentationConfigV1 config,
  );

  Future<void> show({required int interactionGeneration});

  Future<void> hide();

  Future<void> showBubble(String text);

  Future<void> clearBubble();

  Future<void> dispose();
}

final class UnsupportedDesktopCompanionHostGateway
    implements DesktopCompanionHostGateway {
  const UnsupportedDesktopCompanionHostGateway();

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize({
    required FutureOr<void> Function(String id) onMenuSelected,
    required FutureOr<void> Function(DesktopCompanionHostCommand command)
    onCommand,
    required FutureOr<void> Function(Offset? gaze) onGazeChanged,
    required FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)
    onInteraction,
  }) async {}

  @override
  Future<void> configureMenu(List<DesktopCompanionHostMenuItem> items) async {}

  @override
  Future<void> configurePresentation(
    DesktopCompanionPresentationConfigV1 config,
  ) async {}

  @override
  Future<void> show({required int interactionGeneration}) async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> showBubble(String text) async {}

  @override
  Future<void> clearBubble() async {}

  @override
  Future<void> dispose() async {}
}
