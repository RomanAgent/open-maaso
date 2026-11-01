/// Host lifecycle choreography. This contract is never a model-visible action.
enum AvatarDoorwayPhase { prepare, open, enter, frame, skip, cancel }

final class AvatarDoorwayTransition {
  const AvatarDoorwayTransition({
    required this.requestId,
    required this.transitionId,
    required this.phase,
    this.durationMs = 0,
  });
  final String requestId;
  final String transitionId;
  final AvatarDoorwayPhase phase;
  final int durationMs;

  void validate() {
    final identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$');
    if (!identifier.hasMatch(requestId) ||
        !identifier.hasMatch(transitionId) ||
        durationMs < 0 ||
        durationMs > 4000) {
      throw ArgumentError('Invalid doorway presentation request');
    }
  }

  Map<String, Object> toJson() => {
    'requestId': requestId,
    'transitionId': transitionId,
    'phase': phase.name,
    'durationMs': durationMs,
  };
}

final class AvatarDoorwayTransitionException implements Exception {
  const AvatarDoorwayTransitionException(this.code);
  final String code;
  @override
  String toString() => 'AvatarDoorwayTransitionException($code)';
}
