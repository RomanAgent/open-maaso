/// Local rendering phases of device handoff and Home entrance. These are lifecycle
/// operations, never raw motion instructions exposed to the language model.
enum AvatarPresencePhase { prepare, exit, enter, restore, holdHidden }

enum AvatarPresenceEdge { left, right }

class AvatarPresenceTransition {
  const AvatarPresenceTransition({
    required this.requestId,
    required this.transitionId,
    required this.phase,
    this.edge = AvatarPresenceEdge.left,
    this.durationMs = 1000,
    this.stationaryWalk = false,
    this.doNotInterrupt = false,
  });

  final String requestId;
  final String transitionId;
  final AvatarPresencePhase phase;
  final AvatarPresenceEdge edge;
  final int durationMs;

  /// The desktop host moves its transparent window while Unity walks in place.
  final bool stationaryWalk;

  /// Opportunistic Home entrances must yield to an active handoff transaction.
  /// The same fence also applies to delayed cancellation and timeout commands.
  final bool doNotInterrupt;

  void validate() {
    final identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$');
    if (!identifier.hasMatch(requestId) || !identifier.hasMatch(transitionId)) {
      throw ArgumentError('Presence request and transition IDs are invalid');
    }
    final maximum = stationaryWalk && phase == AvatarPresencePhase.exit
        ? 60000
        : 3000;
    if (durationMs < 300 || durationMs > maximum) {
      throw ArgumentError.value(
        durationMs,
        'durationMs',
        'Must be 300..$maximum',
      );
    }
  }

  Map<String, Object> toJson() => {
    'requestId': requestId,
    'transitionId': transitionId,
    'phase': phase.name,
    'edge': edge.name,
    'durationMs': durationMs,
    'stationaryWalk': stationaryWalk,
    'doNotInterrupt': doNotInterrupt,
  };
}

class AvatarPresenceTransitionException implements Exception {
  const AvatarPresenceTransitionException(this.code);
  final String code;

  @override
  String toString() => 'AvatarPresenceTransitionException($code)';
}
