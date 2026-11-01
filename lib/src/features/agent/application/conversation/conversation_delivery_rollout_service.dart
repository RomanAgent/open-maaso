import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';

import 'conversation_turn_controller.dart';

typedef ConversationRolloutTimerFactory =
    Timer Function(Duration delay, void Function() callback);

/// Immutable authority captured when a user turn is admitted.
///
/// The snapshot contains no account identifier. A later rollout mutation makes
/// [isCurrent] false, while the registry separately cancels any active turn.
final class ConversationDeliveryRolloutSnapshot {
  const ConversationDeliveryRolloutSnapshot({
    required this.mode,
    required this.observationEnabled,
    required this.platform,
    required this.authorityGeneration,
    required this.assignmentRevision,
  });

  final ConversationDeliveryMode mode;
  final bool observationEnabled;
  final AppHostPlatform platform;
  final int authorityGeneration;
  final int? assignmentRevision;

  bool get enabled => mode != ConversationDeliveryMode.legacy;
}

/// Account-owned, platform-bounded rollout policy for natural conversation.
///
/// A normal native build has a `speech` compile maximum and can deliver model-
/// selected semantic units without a server assignment. Explicit `legacy`
/// builds cannot be promoted by an assignment. Once an assignment exists, only an
/// effective `enforce` assignment admits new natural-conversation turns;
/// `shadow` observes without changing delivery and `off` is an immediate kill
/// switch. Platform allowlisting is another compile-time upper bound.
final class ConversationDeliveryRolloutService extends AppService {
  ConversationDeliveryRolloutService({
    required MaasoFeatureFlagService featureFlags,
    AppPlatformCapabilities? platformCapabilities,
    ConversationDeliveryMode? compileMaximum,
    Set<AppHostPlatform>? enabledPlatforms,
    DateTime Function()? clock,
    ConversationRolloutTimerFactory? timerFactory,
  }) : _featureFlags = featureFlags,
       _platform =
           (platformCapabilities ?? AppPlatformCapabilities.current()).platform,
       _compileMaximum = compileMaximum ?? defaultConversationDeliveryMode,
       _clock = clock ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new,
       _enabledPlatforms = Set<AppHostPlatform>.unmodifiable(
         enabledPlatforms ?? parseEnabledPlatforms(),
       ) {
    _lastEmitted = currentSnapshot();
    _featureFlagWorker = _featureFlags.state.listen((_) {
      _rescheduleExpiry();
      _emitCurrentSnapshot();
    });
    _rescheduleExpiry();
  }

  static const String enabledPlatformsSource = String.fromEnvironment(
    'MAASO_CONVERSATION_PLATFORMS',
    defaultValue: 'android,ios,macos,windows,linux',
  );

  final MaasoFeatureFlagService _featureFlags;
  final AppHostPlatform _platform;
  final ConversationDeliveryMode _compileMaximum;
  final DateTime Function() _clock;
  final ConversationRolloutTimerFactory _timerFactory;
  final Set<AppHostPlatform> _enabledPlatforms;
  final StreamController<ConversationDeliveryRolloutSnapshot> _changes =
      StreamController<ConversationDeliveryRolloutSnapshot>.broadcast(
        sync: true,
      );
  late final Worker _featureFlagWorker;
  Timer? _expiryTimer;
  ConversationDeliveryRolloutSnapshot? _lastEmitted;

  Stream<ConversationDeliveryRolloutSnapshot> get changes => _changes.stream;

  ConversationDeliveryRolloutSnapshot currentSnapshot({DateTime? now}) {
    final evaluatedAt = (now ?? _clock()).toUtc();
    final assignment =
        _featureFlags.state.value[MaasoFeatureFlag.naturalConversation];
    final effective = _featureFlags.effectiveMode(
      MaasoFeatureFlag.naturalConversation,
      now: evaluatedAt,
    );
    final rolloutAvailable = !isClosed;
    final platformAllowed = _enabledPlatforms.contains(_platform);
    final hasExplicitAssignment = assignment != null;
    final mode =
        !rolloutAvailable ||
            !platformAllowed ||
            _compileMaximum == ConversationDeliveryMode.legacy ||
            effective != FeatureRolloutMode.enforce
        ? ConversationDeliveryMode.legacy
        : _compileMaximum;
    return ConversationDeliveryRolloutSnapshot(
      mode: mode,
      observationEnabled:
          rolloutAvailable &&
          platformAllowed &&
          hasExplicitAssignment &&
          effective == FeatureRolloutMode.shadow,
      platform: _platform,
      authorityGeneration: _featureFlags.authorityGeneration(
        MaasoFeatureFlag.naturalConversation,
      ),
      assignmentRevision: assignment?.revision,
    );
  }

  bool isCurrent(
    ConversationDeliveryRolloutSnapshot snapshot, {
    DateTime? now,
  }) {
    if (isClosed ||
        snapshot.authorityGeneration !=
            _featureFlags.authorityGeneration(
              MaasoFeatureFlag.naturalConversation,
            )) {
      return false;
    }
    final current = currentSnapshot(now: now);
    return current.mode == snapshot.mode &&
        current.observationEnabled == snapshot.observationEnabled &&
        current.assignmentRevision == snapshot.assignmentRevision;
  }

  @override
  void onClose() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _featureFlagWorker.dispose();
    // [closeLifecycle] marks this service closed before invoking [onClose], so
    // the final snapshot is already fail-closed. Publish it synchronously while
    // subscribers can still revoke admitted work.
    _emitCurrentSnapshot();
    unawaited(_changes.close());
    super.onClose();
  }

  void _rescheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (isClosed) return;
    final assignment =
        _featureFlags.state.value[MaasoFeatureFlag.naturalConversation];
    if (assignment == null) return;
    final remaining = assignment.expiresAt.difference(_clock().toUtc());
    if (remaining <= Duration.zero) return;
    _expiryTimer = _timerFactory(remaining, _onExpiryTimer);
  }

  void _onExpiryTimer() {
    _expiryTimer = null;
    if (isClosed) return;
    final assignment =
        _featureFlags.state.value[MaasoFeatureFlag.naturalConversation];
    if (assignment == null) return;
    final remaining = assignment.expiresAt.difference(_clock().toUtc());
    if (remaining > Duration.zero) {
      _expiryTimer = _timerFactory(remaining, _onExpiryTimer);
      return;
    }
    _emitCurrentSnapshot();
  }

  void _emitCurrentSnapshot() {
    if (_changes.isClosed) return;
    final snapshot = currentSnapshot();
    final previous = _lastEmitted;
    if (previous != null && _sameSnapshot(previous, snapshot)) return;
    _lastEmitted = snapshot;
    _changes.add(snapshot);
  }

  static bool _sameSnapshot(
    ConversationDeliveryRolloutSnapshot left,
    ConversationDeliveryRolloutSnapshot right,
  ) =>
      left.mode == right.mode &&
      left.observationEnabled == right.observationEnabled &&
      left.platform == right.platform &&
      left.authorityGeneration == right.authorityGeneration &&
      left.assignmentRevision == right.assignmentRevision;

  static Set<AppHostPlatform> parseEnabledPlatforms([
    String source = enabledPlatformsSource,
  ]) {
    final result = <AppHostPlatform>{};
    for (final token in source.split(',')) {
      switch (token.trim().toLowerCase()) {
        case 'web':
          result.add(AppHostPlatform.web);
        case 'android':
          result.add(AppHostPlatform.android);
        case 'ios':
          result.add(AppHostPlatform.ios);
        case 'macos':
          result.add(AppHostPlatform.macos);
        case 'windows':
          result.add(AppHostPlatform.windows);
        case 'linux':
          result.add(AppHostPlatform.linux);
        case 'fuchsia':
          result.add(AppHostPlatform.fuchsia);
      }
    }
    return Set<AppHostPlatform>.unmodifiable(result);
  }
}
