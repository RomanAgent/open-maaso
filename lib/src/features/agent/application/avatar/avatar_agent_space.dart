import 'avatar_runtime.dart';

/// One local personal room, using the account's already selected avatar.
/// Session identifiers fence entry, movement and exit across page lifecycles.
abstract interface class AvatarAgentSpaceRuntime {
  Future<void> enterAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  });
  Future<void> leaveAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  });
  Future<void> moveAgentSpaceAtScreenPoint({
    required String sessionId,
    required double x,
    required double y,
  });
}

final class AvatarAgentSpaceCommandException implements Exception {
  const AvatarAgentSpaceCommandException({
    required this.method,
    required this.code,
  });
  final String method;
  final String code;
  @override
  String toString() => 'AvatarAgentSpaceCommandException($method: $code)';
}

const avatarAgentSpaceFailureCodes = <String>{
  'invalid_request',
  'unsupported_command',
  'space_renderer_failed',
  'session_retired',
  'space_busy',
  'space_transition_cancelled',
  'personal_room_unavailable',
  'personal_navigation_unavailable',
  'personal_camera_unavailable',
  'avatar_renderer_unavailable',
  'avatar_presentation_unavailable',
  'selected_avatar_unavailable',
  'avatar_floor_unavailable',
  'session_mismatch',
  'invalid_screen_point',
  'outside_walkable_floor',
  'path_blocked',
};
