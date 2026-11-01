import 'package:flutter/widgets.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_controller.dart';

class CompanionSessionScope extends InheritedWidget {
  const CompanionSessionScope({
    required this.voice,
    required this.portal,
    required this.avatarRuntime,
    required super.child,
    super.key,
  });

  final CompanionVoiceSessionController voice;
  final AvatarPortalCoordinator portal;
  final ActiveAvatarRuntime avatarRuntime;

  static CompanionSessionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CompanionSessionScope>();

  static CompanionSessionScope of(BuildContext context) =>
      maybeOf(context) ??
      (throw StateError('CompanionSessionScope is unavailable'));

  @override
  bool updateShouldNotify(CompanionSessionScope oldWidget) =>
      !identical(voice, oldWidget.voice) ||
      !identical(portal, oldWidget.portal) ||
      !identical(avatarRuntime, oldWidget.avatarRuntime);
}
