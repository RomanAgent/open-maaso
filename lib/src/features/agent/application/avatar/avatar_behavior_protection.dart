import 'package:maaso/src/core/foundation/app_framework.dart';

/// Account-owned protection against ambient behavior replacing an expression.
/// Holds expire even when a renderer call never completes.
final class AvatarBehaviorProtection extends AppService {
  AvatarBehaviorProtection({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const maximumDuration = Duration(seconds: 5);
  final DateTime Function() _now;
  final Map<String, Map<Object, DateTime>> _holds = {};
  final Map<String, int> _revisions = {};

  int revisionFor(String agentId) => _revisions[agentId] ?? 0;

  bool allowsAmbient(String agentId, int revision) =>
      !isClosed && revisionFor(agentId) == revision && !isProtected(agentId);

  bool isProtected(String agentId) {
    if (isClosed) return false;
    final holds = _holds[agentId];
    if (holds == null) return false;
    final now = _now();
    holds.removeWhere((_, until) => !until.isAfter(now));
    if (holds.isEmpty) _holds.remove(agentId);
    return holds.isNotEmpty;
  }

  AvatarBehaviorProtectionLease begin(String agentId, Duration duration) {
    final token = Object();
    final bounded = Duration(
      milliseconds: duration.inMilliseconds.clamp(
        350,
        maximumDuration.inMilliseconds,
      ),
    );
    if (!isClosed) {
      _revisions[agentId] = revisionFor(agentId) + 1;
      (_holds[agentId] ??= {})[token] = _now().add(maximumDuration);
    }
    return AvatarBehaviorProtectionLease._(this, agentId, token, bounded);
  }

  void _complete(AvatarBehaviorProtectionLease lease, bool applied) {
    if (isClosed) return;
    final holds = _holds[lease._agentId];
    final deadline = holds?[lease._token];
    if (holds == null || deadline == null) return;
    final now = _now();
    if (applied && deadline.isAfter(now)) {
      holds[lease._token] = now.add(lease._duration);
    } else {
      holds.remove(lease._token);
      if (holds.isEmpty) _holds.remove(lease._agentId);
    }
  }

  @override
  void onClose() {
    _holds.clear();
    _revisions.clear();
    super.onClose();
  }
}

final class AvatarBehaviorProtectionLease {
  AvatarBehaviorProtectionLease._(
    this._owner,
    this._agentId,
    this._token,
    this._duration,
  );

  final AvatarBehaviorProtection _owner;
  final String _agentId;
  final Object _token;
  final Duration _duration;
  bool _completed = false;

  void complete({required bool applied}) {
    if (_completed) return;
    _completed = true;
    _owner._complete(this, applied);
  }
}
