import 'package:flutter/widgets.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

/// Device-level Avatar portal shared by authenticated and signed-out surfaces.
class AvatarPortalScope extends InheritedWidget {
  const AvatarPortalScope({
    required this.portal,
    required this.avatarRuntime,
    this.sceneSurfaceActive = true,
    required super.child,
    super.key,
  });

  final AvatarPortalCoordinator portal;
  final ActiveAvatarRuntime avatarRuntime;
  final bool sceneSurfaceActive;

  static AvatarPortalScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AvatarPortalScope>();

  static AvatarPortalScope of(BuildContext context) =>
      maybeOf(context) ??
      (throw StateError('AvatarPortalScope is unavailable'));

  @override
  bool updateShouldNotify(AvatarPortalScope oldWidget) =>
      !identical(portal, oldWidget.portal) ||
      !identical(avatarRuntime, oldWidget.avatarRuntime) ||
      sceneSurfaceActive != oldWidget.sceneSurfaceActive;
}
