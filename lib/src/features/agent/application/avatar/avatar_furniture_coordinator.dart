import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'avatar_runtime.dart';
import 'avatar_projection_production_authority.dart';

/// Account-owned schedule/wake policy. Uses existing text/VAD events and never
/// opens a microphone or starts another runtime conversation.
class AvatarFurnitureCoordinator extends AppService {
  AvatarFurnitureCoordinator({
    required this.activeAvatar,
    required this.presence,
    required this.canPresent,
    required this.runtimeBusy,
  });
  final ActiveAvatarRuntime activeAvatar;
  final AgentPresenceService presence;
  final bool Function() canPresent;
  final bool Function() runtimeBusy;
  Worker? _presenceWorker;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  DateTime? _lastTurn;
  bool _speaking = false;
  bool _userSpeaking = false;
  bool _pending = false;
  bool _wakePending = false;
  bool _closed = false;
  String? _lastRequested;

  @override
  void onInit() {
    super.onInit();
    _lastTurn = presence.state.value.lastUserInteractionAt;
    _presenceWorker = ever<AgentPresenceState>(presence.state, (state) {
      final turn = state.lastUserInteractionAt;
      final newTurn = turn != null && turn != _lastTurn;
      _lastTurn = turn;
      unawaited(reconcile(wake: newTurn));
    });
    _subscriptions.add(
      EventBus().on<UserSpeakingStartedEvent>().listen((_) {
        _userSpeaking = true;
        unawaited(reconcile(wake: true));
      }),
    );
    _subscriptions.add(
      EventBus().on<UserSpeakingEndedEvent>().listen(
        (_) => _userSpeaking = false,
      ),
    );
    _subscriptions.add(
      EventBus()
          .on<SpeakingStatusEvent>()
          .where((e) => e.agentId == null || e.agentId == 'self')
          .listen((e) => _speaking = e.isSpeaking),
    );
  }

  Future<void> reconcile({bool wake = false}) async {
    if (_closed || !canPresent()) return;
    if (wake) _wakePending = true;
    if (_pending) return;
    wake = _wakePending;
    _wakePending = false;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final renderer = activeAvatar.current;
    if (renderer?.isReady.value != true) return;
    if (renderer is! AvatarFurnitureRuntime) return;
    final posture = (renderer as AvatarFurnitureRuntime).furnitureState;
    final restingOnBed =
        _lastRequested == 'lie_bed' ||
        (posture?.furnitureId == 'bed' &&
            (posture?.sleeping == true || posture?.transitioning == true));
    String? gesture;
    if (wake && restingOnBed) {
      gesture = 'sit_bed';
    } else if (!wake &&
        !_speaking &&
        !_userSpeaking &&
        !runtimeBusy() &&
        presence.state.value.mode == AgentPresenceMode.sleeping &&
        (posture == null || posture.phase == AvatarFurniturePhase.standing)) {
      gesture = 'lie_bed';
    }
    if (gesture == null) {
      _lastRequested = null;
      return;
    }
    if (_lastRequested == gesture) return;
    final authority = AvatarProductionOwnership.currentFor('self');
    if (authority == null) return;
    _pending = true;
    final admittedTurn = presence.state.value.lastUserInteractionAt;
    try {
      final result = await authority.applyBehavior(
        bodyGesture: gesture,
        duration: const Duration(seconds: 5),
        ambient: !wake,
        shouldContinue: () =>
            !_closed &&
            canPresent() &&
            (wake ||
                presence.state.value.lastUserInteractionAt == admittedTurn) &&
            identical(renderer, activeAvatar.current),
      );
      if (result.applied) _lastRequested = gesture;
    } finally {
      _pending = false;
      if (_wakePending && !_closed) unawaited(reconcile(wake: true));
    }
  }

  @override
  void onClose() {
    _closed = true;
    _presenceWorker?.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.onClose();
  }
}
