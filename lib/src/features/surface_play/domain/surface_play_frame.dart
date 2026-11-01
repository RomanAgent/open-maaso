import 'surface_play_protocol.dart';

/// A lossy, role-projected rendering snapshot. It is never a command token,
/// durable event cursor, rule checkpoint, or a model-decision trigger.
final class SurfacePlayFrame {
  SurfacePlayFrame(Map<String, Object?> raw)
    : _json = Map.unmodifiable(
        playObject(playSnapshot(raw, maximumBytes: maximumBytes)),
      ) {
    playKeys(_json, {
      'protocolVersion',
      'projectId',
      'revisionId',
      'sessionId',
      'matchId',
      'matchEpoch',
      'seatId',
      'frameSequence',
      'simTick',
      'decisionRevision',
      'windowId',
      'phase',
      'allowedView',
    });
    if (_json['protocolVersion'] != 2 ||
        !surfacePlayRoles.contains(_json['seatId']) ||
        !const {
          'ready',
          'playing',
          'paused',
          'ended',
        }.contains(_json['phase'])) {
      throw const FormatException('invalid_play_frame');
    }
    for (final key in [
      'projectId',
      'revisionId',
      'sessionId',
      'matchId',
      'windowId',
    ]) {
      playIdentifier(_json[key]);
    }
    for (final key in [
      'matchEpoch',
      'frameSequence',
      'simTick',
      'decisionRevision',
    ]) {
      playInteger(_json[key]);
    }
    playObject(_json['allowedView']);
  }
  static const maximumBytes = 8192;
  final Map<String, Object?> _json;
  String get sessionId => _json['sessionId']! as String;
  String get matchId => _json['matchId']! as String;
  String get seatId => _json['seatId']! as String;
  String get phase => _json['phase']! as String;
  String get windowId => _json['windowId']! as String;
  int get matchEpoch => _json['matchEpoch']! as int;
  int get simTick => _json['simTick']! as int;
  int get frameSequence => _json['frameSequence']! as int;
  int get decisionRevision => _json['decisionRevision']! as int;
  Map<String, Object?> get allowedView => playObject(_json['allowedView']);
  Map<String, Object?> toJson() => _json;
}
